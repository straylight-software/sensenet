{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : SenseNet.Remote
-- Description : Remote execution client for sensenet
--
-- Native NativeLink integration for remote builds.
-- Uses grapesy/proto-lens for REAPI v2.
--
-- This module is only compiled with -fremote flag.
-- sensenet-local excludes this module entirely.
module SenseNet.Remote
  ( -- * Configuration
    RemoteConfig (..),
    defaultRemoteConfig,
    loadRemoteConfig,

    -- * Client
    RemoteClient,
    withRemoteClient,
    connectToScheduler,

    -- * Remote Execution
    executeRemote,
    uploadInputs,
    downloadOutputs,
    canRunRemote,
    defaultPlatformProperties,

    -- * CAS Operations
    uploadBlob,
    downloadBlob,
    blobExists,

    -- * Types
    Digest (..),
    ExecuteResult (..),
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import NativeLink.Client (CASClient, CASConfig (..), Digest (..), withCASClient)
import NativeLink.Client qualified as CAS
import NativeLink.Execution (ExecuteResult (..), executeAction, uploadInputTree)
import NativeLink.Execution qualified as Exec
import Network.Socket (PortNumber)

-- ══════════════════════════════════════════════════════════════════════════════
-- Configuration
-- ══════════════════════════════════════════════════════════════════════════════

-- | Remote execution configuration
data RemoteConfig = RemoteConfig
  { -- | Scheduler host (also CAS for NativeLink)
    rcScheduler :: String,
    -- | gRPC port
    rcPort :: PortNumber,
    -- | Use TLS (default: True for production)
    rcUseTLS :: Bool,
    -- | Instance name (default: "")
    rcInstanceName :: Text
  }
  deriving (Show, Eq)

-- | Default config for local testing
defaultRemoteConfig :: RemoteConfig
defaultRemoteConfig =
  RemoteConfig
    { rcScheduler = "localhost",
      rcPort = 50051,
      rcUseTLS = False,
      rcInstanceName = ""
    }

-- | Load remote config from .sensenet/remote.dhall
-- Falls back to defaultRemoteConfig if file doesn't exist
loadRemoteConfig :: FilePath -> IO RemoteConfig
loadRemoteConfig _projectRoot = do
  -- TODO: Parse .sensenet/remote.dhall
  -- For now, use GCP gigafleet
  pure
    RemoteConfig
      { rcScheduler = "34.28.196.149",
        rcPort = 50051,
        rcUseTLS = False,
        rcInstanceName = ""
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- Client
-- ══════════════════════════════════════════════════════════════════════════════

-- | Remote client handle
data RemoteClient = RemoteClient
  { rcCASClient :: CASClient,
    rcConfig :: RemoteConfig
  }

-- | Convert RemoteConfig to CASConfig
toCASConfig :: RemoteConfig -> CASConfig
toCASConfig RemoteConfig {..} =
  CASConfig
    { casHost = rcScheduler,
      casPort = rcPort,
      casUseTLS = rcUseTLS,
      casInstanceName = rcInstanceName
    }

-- | Run an action with a remote client
withRemoteClient :: RemoteConfig -> (RemoteClient -> IO a) -> IO a
withRemoteClient config action =
  withCASClient (toCASConfig config) $ \casClient ->
    action
      RemoteClient
        { rcCASClient = casClient,
          rcConfig = config
        }

-- | Connect to scheduler (alias for withRemoteClient for API compatibility)
connectToScheduler :: RemoteConfig -> (RemoteClient -> IO a) -> IO a
connectToScheduler = withRemoteClient

-- ══════════════════════════════════════════════════════════════════════════════
-- Remote Execution
-- ══════════════════════════════════════════════════════════════════════════════

-- | Execute an action on a remote worker
--
-- 1. Upload command and inputs to CAS
-- 2. Create Action proto
-- 3. Call Execute RPC
-- 4. Poll for completion
-- 5. Return result with output digests
executeRemote ::
  RemoteClient ->
  -- | Command arguments
  [Text] ->
  -- | Environment variables
  [(Text, Text)] ->
  -- | Input files (path, content, executable)
  [(FilePath, ByteString, Bool)] ->
  -- | Output paths
  [Text] ->
  -- | Platform properties
  [(Text, Text)] ->
  IO (Either Text ExecuteResult)
executeRemote client args env inputs outputs platformProps = do
  let casClient = rcCASClient client
      casConfig = toCASConfig (rcConfig client)

  -- 1. Upload input tree to CAS
  inputRootDigest <- uploadInputTree casClient inputs

  -- 2. Create and upload command
  let command = Exec.createCommand args env outputs ""
      cmdBytes = encodeCommand command
  cmdDigest <- CAS.uploadBlob casClient cmdBytes

  -- 3. Create and upload action
  let action = Exec.createAction cmdDigest inputRootDigest platformProps
      actionBytes = encodeAction action
  actionDigest <- CAS.uploadBlob casClient actionBytes

  -- 4. Execute (uses grpcurl internally for now)
  executeAction casConfig actionDigest
  where
    encodeCommand = BS.pack . map (fromIntegral . fromEnum) . show
    encodeAction = BS.pack . map (fromIntegral . fromEnum) . show

-- | Upload input files and return root digest
uploadInputs ::
  RemoteClient ->
  -- | (path, content, executable)
  [(FilePath, ByteString, Bool)] ->
  IO Digest
uploadInputs client inputs =
  uploadInputTree (rcCASClient client) inputs

-- | Download outputs from CAS
downloadOutputs ::
  RemoteClient ->
  -- | Output path -> digest mapping
  Map Text Digest ->
  IO (Map Text ByteString)
downloadOutputs client outputs = do
  results <- mapM downloadOne (Map.toList outputs)
  pure $ Map.fromList [(p, c) | (p, Just c) <- results]
  where
    downloadOne (path, digest) = do
      content <- CAS.downloadBlob (rcCASClient client) digest
      pure (path, content)

-- ══════════════════════════════════════════════════════════════════════════════
-- CAS Operations (re-exported from NativeLink.Client)
-- ══════════════════════════════════════════════════════════════════════════════

-- | Upload a blob to CAS
uploadBlob :: RemoteClient -> ByteString -> IO Digest
uploadBlob client = CAS.uploadBlob (rcCASClient client)

-- | Download a blob from CAS
downloadBlob :: RemoteClient -> Digest -> IO (Maybe ByteString)
downloadBlob client = CAS.downloadBlob (rcCASClient client)

-- | Check if a blob exists in CAS
blobExists :: RemoteClient -> Digest -> IO Bool
blobExists client = CAS.blobExists (rcCASClient client)

-- ══════════════════════════════════════════════════════════════════════════════
-- DICE Action Integration
-- ══════════════════════════════════════════════════════════════════════════════

-- | Check if an action can run remotely based on its coeffects
--
-- Remote-eligible:
--   - Pure (no external deps)
--   - FilesystemCA (content-addressed files can be uploaded)
--   - NetworkCA (content-addressed network deps)
--   - CoeffectGpu (remote GPU workers exist)
--
-- Local-only:
--   - Filesystem (non-CA path deps)
--   - Environment (local env vars)
--   - Time/Random (non-deterministic)
--   - Identity (local uid/gid)
--   - Auth (local credentials)
--   - Network (non-CA network)
canRunRemote :: [Text] -> Bool
canRunRemote coeffects = all isRemoteable coeffects
  where
    isRemoteable c
      | "pure" `T.isPrefixOf` c = True
      | "filesystem-ca:" `T.isPrefixOf` c = True
      | "network-ca:" `T.isPrefixOf` c = True
      | "gpu:" `T.isPrefixOf` c = True
      | otherwise = False

-- | Default platform properties for sensenet workers
defaultPlatformProperties :: [(Text, Text)]
defaultPlatformProperties =
  [ ("OSFamily", "linux"),
    ("container-image", "sensenet-worker"),
    ("toolchains", "cxx,rust,haskell")
  ]
