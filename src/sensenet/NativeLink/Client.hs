{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : NativeLink.Client
-- Description : CAS client for NativeLink / Remote Execution API
--
-- Full CAS client for NativeLink using proto-lens generated types.
-- Implements ByteStream and ContentAddressableStorage services.
module NativeLink.Client
  ( -- * Configuration
    CASConfig (..),

    -- * Client
    CASClient (..),
    withCASClient,

    -- * CAS Operations
    uploadBlob,
    downloadBlob,
    streamBlob,
    blobExists,

    -- * ActionCache Operations
    getActionResult,
    updateActionResult,

    -- * Digest
    Digest (..),
    digestFromBytes,
    digestFromHash,
    digestToResourceName,
    hashBytes,
    toProtoDigest,
  )
where

import Control.Exception (SomeException, displayException, try)
import Control.Monad.IO.Class (liftIO)
import Crypto.Hash (SHA256 (..), hashWith)
import qualified Data.ByteArray.Encoding as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Conduit (ConduitT, yield)
import Data.Int (Int64)
import Data.ProtoLens (Message, defMessage)
import qualified Data.ProtoLens as ProtoLens
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Lens.Micro ((&), (.~), (^.))
import NativeLink.Proto (ActionCacheGetActionResult, ActionCacheUpdateActionResult, ByteStreamRead, ByteStreamWrite, CASBatchUpdateBlobs, CASFindMissingBlobs)
import Network.GRPC.Client
  ( Address (..),
    Connection,
    Server (..),
    ServerValidation (..),
    certStoreFromSystem,
    recvFinalOutput,
    recvNextOutputElem,
    sendFinalInput,
    sendNextInput,
    withConnection,
    withRPC,
  )
import Network.GRPC.Common (NextElem (..), def)
import Network.Socket (PortNumber)
import qualified Proto.Bytestream as PB
import qualified Proto.Bytestream_Fields as PB
import qualified Proto.RemoteExecution as RE
import qualified Proto.RemoteExecution_Fields as RE
import System.IO (hFlush, hPutStrLn, stderr, stdout)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Configuration
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data CASConfig = CASConfig
  { casHost :: String,
    casPort :: PortNumber,
    casUseTLS :: Bool,
    casInstanceName :: Text
  }
  deriving (Show, Eq)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Client
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data CASClient = CASClient
  { clientConfig :: CASConfig,
    clientConn :: Connection
  }

withCASClient :: CASConfig -> (CASClient -> IO a) -> IO a
withCASClient config action = do
  let address =
        Address
          { addressHost = casHost config,
            addressPort = casPort config,
            addressAuthority = Nothing
          }
      validation = ValidateServer certStoreFromSystem
      server =
        if casUseTLS config
          then ServerSecure validation def address
          else ServerInsecure address
  withConnection def server $ \connection ->
    action CASClient {clientConfig = config, clientConn = connection}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Digest
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data Digest = Digest
  { digestHash :: Text,
    digestSize :: Int64
  }
  deriving (Show, Eq)

digestFromBytes :: ByteString -> Digest
digestFromBytes content =
  Digest
    { digestHash = hashBytes content,
      digestSize = fromIntegral (BS.length content)
    }

digestFromHash :: Text -> Int64 -> Digest
digestFromHash = Digest

hashBytes :: ByteString -> Text
hashBytes content =
  let hash = hashWith SHA256 content
   in TE.decodeUtf8 $ BA.convertToBase BA.Base16 hash

digestToResourceName :: Text -> Digest -> Text
digestToResourceName instanceName digest =
  instanceName <> "/blobs/" <> digestHash digest <> "/" <> T.pack (show (digestSize digest))

toProtoDigest :: Digest -> RE.Digest
toProtoDigest digest =
  defMessage
    & RE.hash
    .~ digestHash digest
    & RE.sizeBytes
    .~ digestSize digest

_fromProtoDigest :: RE.Digest -> Digest
_fromProtoDigest protoDigest =
  Digest
    { digestHash = protoDigest ^. RE.hash,
      digestSize = protoDigest ^. RE.sizeBytes
    }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Upload Operations
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

uploadBlob :: CASClient -> ByteString -> IO Digest
uploadBlob client content = do
  let digest = digestFromBytes content
  putStrLn $ "uploadBlob: " ++ show (BS.length content) ++ " bytes -> " ++ T.unpack (digestHash digest)
  hFlush stdout
  if BS.length content < 4 * 1024 * 1024
    then batchUpload client digest content
    else streamUpload client digest content
  pure digest

batchUpload :: CASClient -> Digest -> ByteString -> IO ()
batchUpload client digest content = do
  let request :: RE.BatchUpdateBlobsRequest
      request =
        defMessage
          & RE.instanceName
          .~ casInstanceName (clientConfig client)
          & RE.requests
          .~ [ (defMessage :: RE.BatchUpdateBlobsRequest'Request)
                 & RE.digest
                 .~ toProtoDigest digest
                 & RE.data'
                 .~ content
             ]
  result <- try @SomeException $
    withRPC (clientConn client) def (Proxy @CASBatchUpdateBlobs) $ \call -> do
      sendFinalInput call (encodeMessage request)
      recvFinalOutput call
  case result of
    Left err -> do
      -- Debug: print upload error
      putStrLn $ "CAS upload error: " ++ show err
      pure ()
    Right _ -> pure ()

streamUpload :: CASClient -> Digest -> ByteString -> IO ()
streamUpload client digest content = do
  let resourceName =
        casInstanceName (clientConfig client)
          <> "/uploads/nix-serve-cas/blobs/"
          <> digestHash digest
          <> "/"
          <> T.pack (show (digestSize digest))
      chunkSize = 1024 * 1024
      chunks = chunksOf chunkSize content

  result <- try @SomeException $
    withRPC (clientConn client) def (Proxy @ByteStreamWrite) $ \call -> do
      sendChunks call resourceName chunks 0
      -- NativeLink streams the WriteResponse after finishWrite
      -- Use server-streaming pattern to receive chunks until end
      collectWriteResponse call
  case result of
    Left err -> putStrLn $ "Stream upload error: " ++ show err
    Right committedSize -> putStrLn $ "WriteResponse: committed " ++ show committedSize ++ " bytes"
  where
    sendChunks _ _ [] _ = pure ()
    sendChunks call rn [chunk] offset = do
      let request :: PB.WriteRequest
          request =
            defMessage
              & PB.resourceName
              .~ rn
              & PB.writeOffset
              .~ offset
              & PB.finishWrite
              .~ True
              & PB.data'
              .~ chunk
      sendFinalInput call (encodeMessage request)
    sendChunks call rn (chunk : rest) offset = do
      let request :: PB.WriteRequest
          request =
            defMessage
              & PB.resourceName
              .~ rn
              & PB.writeOffset
              .~ offset
              & PB.finishWrite
              .~ False
              & PB.data'
              .~ chunk
      sendNextInput call (encodeMessage request)
      sendChunks call rn rest (offset + fromIntegral (BS.length chunk))

    collectWriteResponse call = do
      next <- recvNextOutputElem call
      case next of
        NoNextElem -> pure (0 :: Int64)
        NextElem chunk ->
          case decodeMessage @PB.WriteResponse chunk of
            Left _ -> collectWriteResponse call
            Right resp -> pure (resp ^. PB.committedSize)

chunksOf :: Int -> ByteString -> [ByteString]
chunksOf size content
  | BS.null content = []
  | otherwise =
      let (chunk, rest) = BS.splitAt size content
       in chunk : chunksOf size rest

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Download Operations
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

downloadBlob :: CASClient -> Digest -> IO (Maybe ByteString)
downloadBlob client digest = do
  let resourceName = digestToResourceName (casInstanceName (clientConfig client)) digest
      request :: PB.ReadRequest
      request =
        defMessage
          & PB.resourceName
          .~ resourceName
          & PB.readOffset
          .~ 0
          & PB.readLimit
          .~ 0

  result <- try @SomeException $
    withRPC (clientConn client) def (Proxy @ByteStreamRead) $ \call -> do
      sendFinalInput call (encodeMessage request)
      collectChunks call BS.empty
  case result of
    Left e -> do
      hPutStrLn stderr $ "NativeLink downloadBlob error: " <> displayException e
      pure Nothing
    Right content
      | BS.null content -> pure Nothing
      | otherwise -> pure (Just content)
  where
    collectChunks call accumulated = do
      next <- recvNextOutputElem call
      case next of
        NoNextElem -> pure accumulated
        NextElem chunk ->
          case decodeMessage @PB.ReadResponse chunk of
            Left _ -> collectChunks call accumulated
            Right response -> collectChunks call (accumulated <> (response ^. PB.data'))

streamBlob :: CASClient -> Digest -> ConduitT () ByteString IO ()
streamBlob client digest = do
  let resourceName = digestToResourceName (casInstanceName (clientConfig client)) digest
      request :: PB.ReadRequest
      request =
        defMessage
          & PB.resourceName
          .~ resourceName
          & PB.readOffset
          .~ 0
          & PB.readLimit
          .~ 0

  result <- liftIO $
    try @SomeException $
      withRPC (clientConn client) def (Proxy @ByteStreamRead) $ \call -> do
        sendFinalInput call (encodeMessage request)
        collectAllChunks call
  case result of
    Left e -> liftIO $ hPutStrLn stderr $ "NativeLink streamBlob error: " <> displayException e
    Right chunks -> mapM_ yield chunks
  where
    collectAllChunks call = go []
      where
        go accumulated = do
          next <- recvNextOutputElem call
          case next of
            NoNextElem -> pure (reverse accumulated)
            NextElem chunk ->
              case decodeMessage @PB.ReadResponse chunk of
                Left _ -> go accumulated
                Right response -> go ((response ^. PB.data') : accumulated)

blobExists :: CASClient -> Digest -> IO Bool
blobExists client digest = do
  let request :: RE.FindMissingBlobsRequest
      request =
        defMessage
          & RE.instanceName
          .~ casInstanceName (clientConfig client)
          & RE.blobDigests
          .~ [toProtoDigest digest]

  result <- try @SomeException $
    withRPC (clientConn client) def (Proxy @CASFindMissingBlobs) $ \call -> do
      sendFinalInput call (encodeMessage request)
      (responseBytes, _) <- recvFinalOutput call
      pure responseBytes
  case result of
    Left e -> do
      hPutStrLn stderr $ "NativeLink blobExists error: " <> displayException e
      pure False
    Right responseBytes ->
      case decodeMessage @RE.FindMissingBlobsResponse responseBytes of
        Left decodeErr -> do
          hPutStrLn stderr $ "NativeLink blobExists decode error: " <> decodeErr
          pure False
        Right response -> pure (null (response ^. RE.missingBlobDigests))

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ActionCache Operations
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- | Get an action result from the ActionCache
-- Used for narinfo lookup: action_digest = narinfoDigest(nix_hash)
-- Returns the stdout_digest which points to the narinfo content in CAS
getActionResult :: CASClient -> Digest -> IO (Maybe Digest)
getActionResult client actionDigest = do
  let request :: RE.GetActionResultRequest
      request =
        defMessage
          & RE.instanceName
          .~ casInstanceName (clientConfig client)
          & RE.actionDigest
          .~ toProtoDigest actionDigest

  result <- try @SomeException $
    withRPC (clientConn client) def (Proxy @ActionCacheGetActionResult) $ \call -> do
      sendFinalInput call (encodeMessage request)
      (responseBytes, _) <- recvFinalOutput call
      pure responseBytes
  case result of
    Left e -> do
      hPutStrLn stderr $ "NativeLink getActionResult error: " <> displayException e
      pure Nothing
    Right responseBytes ->
      case decodeMessage @RE.ActionResult responseBytes of
        Left decodeErr -> do
          hPutStrLn stderr $ "NativeLink getActionResult decode error: " <> decodeErr
          pure Nothing
        Right actionResult ->
          let stdoutDigest = actionResult ^. RE.stdoutDigest
              hash = stdoutDigest ^. RE.hash
              size = stdoutDigest ^. RE.sizeBytes
           in if T.null hash
                then pure Nothing
                else pure (Just (Digest hash size))

-- | Update an action result in the ActionCache
-- Used for narinfo storage: action_digest = narinfoDigest(nix_hash)
-- Stores stdout_digest pointing to the narinfo content in CAS
updateActionResult :: CASClient -> Digest -> Digest -> IO Bool
updateActionResult client actionDigest stdoutDigest = do
  let actionResult :: RE.ActionResult
      actionResult =
        defMessage
          & RE.stdoutDigest
          .~ toProtoDigest stdoutDigest
          & RE.exitCode
          .~ 0

      request :: RE.UpdateActionResultRequest
      request =
        defMessage
          & RE.instanceName
          .~ casInstanceName (clientConfig client)
          & RE.actionDigest
          .~ toProtoDigest actionDigest
          & RE.actionResult
          .~ actionResult

  result <- try @SomeException $
    withRPC (clientConn client) def (Proxy @ActionCacheUpdateActionResult) $ \call -> do
      sendFinalInput call (encodeMessage request)
      recvFinalOutput call
  case result of
    Left e -> do
      hPutStrLn stderr $ "NativeLink updateActionResult error: " <> displayException e
      pure False
    Right _ -> pure True

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Proto helpers
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

encodeMessage :: (Message msg) => msg -> LBS.ByteString
encodeMessage = LBS.fromStrict . ProtoLens.encodeMessage

decodeMessage :: (Message msg) => LBS.ByteString -> Either String msg
decodeMessage = ProtoLens.decodeMessage . LBS.toStrict
