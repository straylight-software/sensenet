{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : NativeLink.Execution
Description : Remote Execution client for NativeLink

Implements the Execution service for remote builds.
Handles action creation, input tree upload, and execution polling.
-}
module NativeLink.Execution (
    -- * Execution
    executeAction,
    ExecuteResult (..),

    -- * Action building
    createAction,
    createCommand,

    -- * Merkle tree
    uploadDirectory,
    uploadInputTree,
    DirectoryTree (..),
    FileEntry (..),

    -- * Test
    testCapabilities,
) where

import Control.Exception (SomeException, try)
import qualified System.Exit
import qualified System.Process
import System.Timeout (timeout)
import Data.Aeson (Value(..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Lazy.Char8 as LBS8
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.ProtoLens (Message, defMessage)
import qualified Data.ProtoLens as ProtoLens
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Int (Int64)
import Data.Maybe (mapMaybe)

import Lens.Micro ((&), (.~), (^.))

import Network.GRPC.Client (
    recvNextOutputElem,
    sendFinalInput,
    withRPC,
 )
import Network.GRPC.Common (NextElem (..), def)

import qualified Proto.Google.Longrunning.Operations as LRO
import qualified Proto.Google.Longrunning.Operations_Fields as LRO
import qualified Proto.Google.Protobuf.Any_Fields as Any
import qualified Proto.RemoteExecution as RE
import qualified Proto.RemoteExecution_Fields as RE

import Network.GRPC.Client (recvFinalOutput)
import NativeLink.Client (CASClient, toProtoDigest, uploadBlob)
import qualified NativeLink.Client as Client
import NativeLink.Client (Digest (..))  -- Explicit re-import to use in types
import NativeLink.Proto (ExecutionExecute, CapabilitiesGetCapabilities)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Types
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

data ExecuteResult = ExecuteResult
    { execOutputs :: Map Text Digest
    , execExitCode :: Int
    , execStdout :: Maybe Digest
    , execStderr :: Maybe Digest
    }
    deriving (Show, Eq)

-- | A file entry for building Merkle trees
data FileEntry = FileEntry
    { feContent :: ByteString
    , feExecutable :: Bool
    }
    deriving (Show, Eq)

-- | A directory tree for building Merkle trees
data DirectoryTree = DirectoryTree
    { dtFiles :: Map Text FileEntry
    , dtDirs :: Map Text DirectoryTree
    }
    deriving (Show, Eq)

emptyTree :: DirectoryTree
emptyTree = DirectoryTree Map.empty Map.empty

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Action Building
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- | Create a Command proto
createCommand ::
    [Text] ->         -- ^ Command arguments
    [(Text, Text)] -> -- ^ Environment variables
    [Text] ->         -- ^ Output paths
    Text ->           -- ^ Working directory
    RE.Command
createCommand args env outputs workdir =
    defMessage
        & RE.arguments .~ args
        & RE.environmentVariables .~ map mkEnvVar (sortEnv env)
        & RE.outputPaths .~ outputs
        & RE.workingDirectory .~ workdir
  where
    mkEnvVar (name, value) =
        defMessage
            & RE.name .~ name
            & RE.value .~ value
    sortEnv = sortBy (\(a, _) (b, _) -> compare a b)
    sortBy f = foldr (insertBy f) []
    insertBy _ x [] = [x]
    insertBy f x (y:ys)
        | f x y == GT = y : insertBy f x ys
        | otherwise = x : y : ys

-- | Create an Action proto
createAction ::
    Digest ->               -- ^ Command digest
    Digest ->               -- ^ Input root digest
    [(Text, Text)] ->       -- ^ Platform properties
    RE.Action
createAction cmdDigest inputDigest props =
    defMessage
        & RE.commandDigest .~ toProtoDigest cmdDigest
        & RE.inputRootDigest .~ toProtoDigest inputDigest
        & RE.platform .~ mkPlatform props
  where
    mkPlatform ps =
        defMessage
            & RE.properties .~ map mkProp (sortProps ps)
    mkProp (name, value) =
        defMessage
            & RE.name .~ name
            & RE.value .~ value
    sortProps = foldr (insertBy (\(a, _) (b, _) -> compare a b)) []
    insertBy _ x [] = [x]
    insertBy f x (y:ys)
        | f x y == GT = y : insertBy f x ys
        | otherwise = x : y : ys

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Merkle Tree Upload
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- | Upload a directory tree to CAS, returning the root digest
uploadDirectory :: CASClient -> DirectoryTree -> IO Digest
uploadDirectory client tree = do
    -- First upload all files and collect their digests
    fileDigests <- mapM uploadFile (Map.toList (dtFiles tree))

    -- Recursively upload subdirectories
    dirDigests <- mapM uploadSubdir (Map.toList (dtDirs tree))

    -- Build the Directory proto
    let dir :: RE.Directory
        dir = buildDirectory fileDigests dirDigests

    -- Serialize and upload the directory
    let dirBytes = ProtoLens.encodeMessage dir
    uploadBlob client dirBytes
  where
    uploadFile (name, entry) = do
        digest <- uploadBlob client (feContent entry)
        pure (name, digest, feExecutable entry)

    uploadSubdir (name, subtree) = do
        digest <- uploadDirectory client subtree
        pure (name, digest)

    buildDirectory files dirs =
        defMessage
            & RE.files .~ map mkFileNode (sortByName files)
            & RE.directories .~ map mkDirNode (sortByName' dirs)

    mkFileNode (name, digest, exec) =
        defMessage
            & RE.name .~ name
            & RE.digest .~ toProtoDigest digest
            & RE.isExecutable .~ exec

    mkDirNode (name, digest) =
        defMessage
            & RE.name .~ name
            & RE.digest .~ toProtoDigest digest

    sortByName = foldr (insertBy (\(a, _, _) (b, _, _) -> compare a b)) []
    sortByName' = foldr (insertBy (\(a, _) (b, _) -> compare a b)) []
    insertBy _ x [] = [x]
    insertBy f x (y:ys)
        | f x y == GT = y : insertBy f x ys
        | otherwise = x : y : ys

-- | Upload an input tree from a list of file paths
-- Returns the root digest
uploadInputTree :: CASClient -> [(FilePath, ByteString, Bool)] -> IO Digest
uploadInputTree client files = do
    let tree = buildTree files
    uploadDirectory client tree
  where
    buildTree :: [(FilePath, ByteString, Bool)] -> DirectoryTree
    buildTree = foldr insertFile emptyTree

    insertFile (path, content, exec) tree =
        let parts = T.splitOn "/" (T.pack path)
         in insertPath parts content exec tree

    insertPath [] _ _ tree = tree
    insertPath [name] content exec tree =
        tree {dtFiles = Map.insert name (FileEntry content exec) (dtFiles tree)}
    insertPath (dir : rest) content exec tree =
        let subtree = Map.findWithDefault emptyTree dir (dtDirs tree)
            subtree' = insertPath rest content exec subtree
         in tree {dtDirs = Map.insert dir subtree' (dtDirs tree)}

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Execution
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- | Execute an action and wait for completion via grpcurl
-- Uses grpcurl as a workaround for grapesy issues with some endpoints
-- Takes scheduler config (host/port) and action digest
executeAction ::
    Client.CASConfig ->
    Digest ->    -- ^ Action digest
    IO (Either Text ExecuteResult)
executeAction config actionDigest = do
    let host = Client.casHost config
        port = Client.casPort config
        instanceName = Client.casInstanceName config
        digestJson = "{\"instance_name\": \"" <> T.unpack instanceName
            <> "\", \"action_digest\": {\"hash\": \"" <> T.unpack (Client.digestHash actionDigest)
            <> "\", \"size_bytes\": " <> show (Client.digestSize actionDigest)
            <> "}, \"skip_cache_lookup\": false}"
        hostPort = host <> ":" <> show port

    -- Use full path to grpcurl from nixpkgs
    let grpcurlPath = "/nix/store/0zc1l7dijlqzd0vgd18rx3gr2biq7bkc-grpcurl-1.9.3/bin/grpcurl"
        protoPath = "/home/b7r6/src/nix-serve-cas/packages/nativelink-hs/proto"
        tlsArgs = if Client.casUseTLS config then [] else ["-plaintext"]
    (code, out, err) <- System.Process.readProcessWithExitCode grpcurlPath
        (tlsArgs ++
        [ "-d", digestJson
        , "-import-path", protoPath
        , "-proto", "remote_execution.proto"
        , hostPort
        , "build.bazel.remote.execution.v2.Execution/Execute"
        ]) ""

    case code of
        System.Exit.ExitSuccess -> parseExecuteResponse (LBS8.pack out)
        System.Exit.ExitFailure _ -> pure $ Left (T.pack err)

-- | Parse the streaming JSON response from grpcurl Execute
-- grpcurl outputs multiple JSON objects, one per streaming message
-- We need to find the final one with "done": true
parseExecuteResponse :: LBS.ByteString -> IO (Either Text ExecuteResult)
parseExecuteResponse output = do
    -- Split by "}\n{" to get individual JSON objects
    -- grpcurl outputs them concatenated
    let jsonObjs = parseJsonStream output
        doneObj = filter isDone jsonObjs
    case doneObj of
        [] -> pure $ Left "No completed operation in response"
        (obj:_) -> pure $ extractResult obj
  where
    isDone (Object o) = case KM.lookup "done" o of
        Just (Bool True) -> True
        _ -> False
    isDone _ = False

    extractResult (Object o) = do
        let response = KM.lookup "response" o
        case response of
            Just (Object resp) -> extractExecuteResponse resp
            _ -> Left "No response in operation"
    extractResult _ = Left "Invalid operation format"

    extractExecuteResponse resp = do
        let result = KM.lookup "result" resp
            status = KM.lookup "status" resp
        case result of
            Just (Object r) -> extractActionResult r status
            _ -> Left "No result in response"

    extractActionResult r status = do
        let exitCode = case KM.lookup "exitCode" r of
                Just (Number n) -> round n
                _ -> 0
            stdoutDigest = extractDigest =<< KM.lookup "stdoutDigest" r
            stderrDigest = extractDigest =<< KM.lookup "stderrDigest" r
            errorMsg = case status of
                Just (Object s) -> case KM.lookup "message" s of
                    Just (String msg) | not (T.null msg) -> Just msg
                    _ -> Nothing
                _ -> Nothing
        case errorMsg of
            Just msg -> Left msg
            Nothing -> Right ExecuteResult
                { execOutputs = Map.empty  -- nix-store outputs to stdout, not outputFiles
                , execExitCode = exitCode
                , execStdout = stdoutDigest
                , execStderr = stderrDigest
                }

    extractDigest (Object d) = do
        hash <- case KM.lookup "hash" d of
            Just (String h) -> Just h
            _ -> Nothing
        size <- case KM.lookup "sizeBytes" d of
            Just (String s) -> Just (read (T.unpack s) :: Int64)
            Just (Number n) -> Just (round n)
            _ -> Just 0
        if hash == "0000000000000000000000000000000000000000000000000000000000000000"
            then Nothing
            else Just (Client.Digest hash size)
    extractDigest _ = Nothing

-- | Parse a stream of concatenated JSON objects
parseJsonStream :: LBS.ByteString -> [Value]
parseJsonStream bs
    | LBS.null bs = []
    | otherwise = case Aeson.decode bs of
        Just v -> [v]  -- Single object
        Nothing -> mapMaybe Aeson.decode (splitJsonObjects bs)

-- | Split concatenated JSON objects (heuristic: split on "}\n{")
splitJsonObjects :: LBS.ByteString -> [LBS.ByteString]
splitJsonObjects bs = go (LBS8.lines bs) [] (0 :: Int)
  where
    go [] acc depth
        | depth == 0 && not (null acc) = [LBS8.unlines (reverse acc)]
        | otherwise = []
    go (line:rest) acc depth =
        let opens = LBS8.count '{' line
            closes = LBS8.count '}' line
            newDepth = depth + fromIntegral opens - fromIntegral closes
            acc' = line : acc
        in if newDepth == 0 && depth > 0
            then LBS8.unlines (reverse acc') : go rest [] 0
            else go rest acc' newDepth

-- | Original grapesy-based execution (currently broken due to grapesy/scheduler issue)
_executeActionGrapesy ::
    CASClient ->
    Digest ->    -- ^ Action digest
    IO (Either Text ExecuteResult)
_executeActionGrapesy client actionDigest = do
    let request :: RE.ExecuteRequest
        request =
            defMessage
                & RE.instanceName .~ Client.casInstanceName (Client.clientConfig client)
                & RE.actionDigest .~ toProtoDigest actionDigest
                & RE.skipCacheLookup .~ False

    maybeResult <- timeout (10 * 1000000) $ try @SomeException $
        withRPC (Client.clientConn client) def (Proxy @ExecutionExecute) $ \call -> do
            sendFinalInput call (encodeMessage request)
            waitForCompletion call

    case maybeResult of
        Nothing -> pure (Left "RPC timeout after 10s")
        Just (Left err) -> pure (Left (T.pack (show err)))
        Just (Right res) -> pure res
  where
    waitForCompletion call = do
        next <- recvNextOutputElem call
        case next of
            NoNextElem -> pure (Left "No response from execution service")
            NextElem opBytes ->
                case decodeMessage @LRO.Operation opBytes of
                    Left err -> pure (Left (T.pack err))
                    Right op ->
                        if op ^. LRO.done
                            then parseResult op
                            else waitForCompletion call -- Keep polling

    parseResult op = do
        -- The result is in op.response as an Any containing ExecuteResponse
        let anyResponse = op ^. LRO.response
            typeUrl = anyResponse ^. Any.typeUrl
            responseBytes = anyResponse ^. Any.value

        if "ExecuteResponse" `T.isInfixOf` typeUrl
            then case ProtoLens.decodeMessage (LBS.toStrict (LBS.fromStrict responseBytes)) of
                Left err -> pure (Left (T.pack err))
                Right (execResponse :: RE.ExecuteResponse) ->
                    let actionResult = execResponse ^. RE.result
                        exitCode = fromIntegral (actionResult ^. RE.exitCode)
                        stdoutDigest = fromProtoDigest (actionResult ^. RE.stdoutDigest)
                        stderrDigest = fromProtoDigest (actionResult ^. RE.stderrDigest)
                        outputs = parseOutputs (actionResult ^. RE.outputFiles)
                     in pure $ Right ExecuteResult
                            { execOutputs = outputs
                            , execExitCode = exitCode
                            , execStdout = if Client.digestSize stdoutDigest > 0 then Just stdoutDigest else Nothing
                            , execStderr = if Client.digestSize stderrDigest > 0 then Just stderrDigest else Nothing
                            }
            else pure (Left ("Unexpected response type: " <> typeUrl))

    parseOutputs files = Map.fromList
        [ (f ^. RE.path, fromProtoDigest (f ^. RE.digest))
        | f <- files
        ]

    fromProtoDigest pd = Client.Digest (pd ^. RE.hash) (pd ^. RE.sizeBytes)

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Proto helpers
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

encodeMessage :: Message msg => msg -> LBS.ByteString
encodeMessage = LBS.fromStrict . ProtoLens.encodeMessage

decodeMessage :: Message msg => LBS.ByteString -> Either String msg
decodeMessage = ProtoLens.decodeMessage . LBS.toStrict

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- Test
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- | Test GetCapabilities RPC
testCapabilities :: CASClient -> IO (Either Text Text)
testCapabilities client = do
    let request :: RE.GetCapabilitiesRequest
        request =
            defMessage
                & RE.instanceName .~ Client.casInstanceName (Client.clientConfig client)

    result <- try @SomeException $
        withRPC (Client.clientConn client) def (Proxy @CapabilitiesGetCapabilities) $ \call -> do
            sendFinalInput call (encodeMessage request)
            recvFinalOutput call

    case result of
        Left err -> pure (Left (T.pack (show err)))
        Right (respBytes, _) ->
            case decodeMessage @RE.ServerCapabilities respBytes of
                Left err -> pure (Left (T.pack err))
                Right caps -> pure (Right (T.pack (show (caps ^. RE.executionCapabilities))))
