{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE LambdaCase #-}

-- | Remote Execution via NativeLink
--
-- Wraps nativelink-hs to submit build actions to a remote executor.
-- Actions are constructed from the same IR as local builds, but executed
-- on a worker via the Remote Execution API (REAPI).
module SenseNet.Remote
  ( RemoteConfig(..)
  , defaultConfig
  , remoteBuild
  , testConnection
  ) where

import Control.Monad (forM)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Text.Encoding as TE
import qualified Data.ProtoLens as ProtoLens
import System.Directory (doesFileExist)
import System.FilePath ((</>), takeFileName)

import NativeLink (
    CASConfig(..),
    CASClient,
    withCASClient,
    uploadBlob,
    downloadBlob,
    Digest(..),
    )
import NativeLink.Execution (
    ExecuteResult(..),
    createCommand,
    createAction,
    uploadInputTree,
    executeAction,
    testCapabilities,
    )

import qualified SenseNet.IR as IR
import qualified SenseNet.Toolchains as TC

-- | Remote execution configuration
data RemoteConfig = RemoteConfig
  { host :: String
  , port :: Int
  , useTLS :: Bool
  , instanceName :: Text
  } deriving (Show, Eq)

-- | Default config for local NativeLink (started via lre-start)
defaultConfig :: RemoteConfig
defaultConfig = RemoteConfig
  { host = "localhost"
  , port = 50051
  , useTLS = False
  , instanceName = "main"
  }

-- | Convert our config to CASConfig
toCASConfig :: RemoteConfig -> CASConfig
toCASConfig cfg = CASConfig
  { casHost = cfg.host
  , casPort = fromIntegral cfg.port
  , casUseTLS = cfg.useTLS
  , casInstanceName = cfg.instanceName
  }

-- | Test connection to the remote executor
testConnection :: RemoteConfig -> IO (Either Text Text)
testConnection cfg = do
  withCASClient (toCASConfig cfg) $ \client -> do
    testCapabilities client

-- | Build a target remotely
remoteBuild :: 
  RemoteConfig -> 
  TC.Toolchains -> 
  FilePath ->      -- ^ Project root
  IR.Package -> 
  Text ->          -- ^ Target name
  IO (Either Text [FilePath])
remoteBuild cfg tc projectRoot pkg targetName = do
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ "Target not found: " <> targetName
    Just rule -> remoteBuildRule cfg tc projectRoot pkg.path rule

findRule :: Text -> [IR.Rule] -> Maybe IR.Rule
findRule name = foldr (\r acc -> if IR.ruleName r == name then Just r else acc) Nothing

-- | Build a rule remotely
remoteBuildRule :: 
  RemoteConfig -> 
  TC.Toolchains -> 
  FilePath -> 
  FilePath -> 
  IR.Rule -> 
  IO (Either Text [FilePath])
remoteBuildRule cfg tc projectRoot pkgPath = \case
  IR.RCxxBinary r -> remoteBuildCxxBinary cfg tc projectRoot pkgPath r
  IR.RGenrule r -> remoteBuildGenrule cfg tc projectRoot pkgPath r
  rule -> pure $ Left $ "Remote execution not yet supported for: " <> T.pack (show rule)

-- | Build C++ binary remotely
remoteBuildCxxBinary :: 
  RemoteConfig -> 
  TC.Toolchains -> 
  FilePath -> 
  FilePath -> 
  IR.CxxBinary -> 
  IO (Either Text [FilePath])
remoteBuildCxxBinary cfg tc projectRoot pkgPath bin = do
  let casConfig = toCASConfig cfg
      srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = T.unpack bin.name
  
  -- Toolchain paths (these must exist on the worker!)
  let cxx = T.unpack tc.cxx.cxx.path
      ld = T.unpack tc.cxx.ld.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      cxxLibs = map T.unpack tc.cxx.paths.libs
      sysroot = T.unpack tc.cxx.sysroot
  
  withCASClient casConfig $ \client -> do
    -- Read source files
    srcContents <- forM bin.srcs $ \src -> do
      let srcPath = srcDir </> T.unpack src
      exists <- doesFileExist srcPath
      if exists
        then do
          content <- BS.readFile srcPath
          pure $ Right (T.unpack src, content, False)
        else pure $ Left $ "Source not found: " <> T.pack srcPath
    
    case sequence srcContents of
      Left err -> pure $ Left err
      Right files -> do
        -- Upload input tree (source files)
        inputDigest <- uploadInputTree client files
        TIO.putStrLn $ "  uploaded input tree: " <> digestHash inputDigest
        
        -- Build command arguments
        let stdFlag = cxxStdFlag bin.std
            includeFlags = concatMap (\i -> ["-isystem", T.pack i]) cxxIncludes
            libFlags = concatMap (\l -> [T.pack $ "-B" <> l, T.pack $ "-L" <> l]) cxxLibs
            sysrootFlag = if null sysroot then [] else [T.pack $ "--sysroot=" <> sysroot]
            linkFlag = [T.pack $ "-fuse-ld=" <> ld]
            srcs = map (\s -> T.pack (T.unpack s)) bin.srcs
            cflags = bin.cflags
            ldflags = bin.ldflags
            args = [T.pack cxx, stdFlag] ++ sysrootFlag ++ includeFlags ++ cflags ++ srcs 
                   ++ ["-o", T.pack outBin] ++ linkFlag ++ libFlags ++ ldflags
        
        -- Create command
        let cmd = createCommand args [] [T.pack outBin] ""
        
        -- Upload command
        let cmdBytes = ProtoLens.encodeMessage cmd
        cmdDigest <- uploadBlob client cmdBytes
        TIO.putStrLn $ "  uploaded command: " <> digestHash cmdDigest
        
        -- Create action with platform properties for worker matching
        let platformProps = 
              [ ("OSFamily", "linux")
              , ("ISA", "x86-64")
              ]
            action = createAction cmdDigest inputDigest platformProps
        
        -- Upload action
        let actionBytes = ProtoLens.encodeMessage action
        actionDigest <- uploadBlob client actionBytes
        TIO.putStrLn $ "  uploaded action: " <> digestHash actionDigest
        
        -- Execute!
        TIO.putStrLn "  executing remotely..."
        result <- executeAction casConfig actionDigest
        
        case result of
          Left err -> pure $ Left $ "Execution failed: " <> err
          Right execResult -> do
            if execResult.execExitCode /= 0
              then do
                -- Try to get stderr
                stderrContent <- case execResult.execStderr of
                  Just d -> downloadBlob client d
                  Nothing -> pure Nothing
                let errMsg = case stderrContent of
                      Just bs -> TE.decodeUtf8 bs
                      Nothing -> "exit code " <> T.pack (show execResult.execExitCode)
                pure $ Left $ "Build failed: " <> errMsg
              else do
                -- Download output
                let outputPath = outDir </> outBin
                -- For now, just report success - outputs would need to be downloaded
                TIO.putStrLn $ "  remote build succeeded, exit code: " <> T.pack (show execResult.execExitCode)
                pure $ Right [outputPath]

-- | Build genrule remotely
remoteBuildGenrule ::
  RemoteConfig ->
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.Genrule ->
  IO (Either Text [FilePath])
remoteBuildGenrule cfg _tc projectRoot pkgPath gen = do
  let casConfig = toCASConfig cfg
      srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outPath = T.unpack gen.out
  
  withCASClient casConfig $ \client -> do
    -- Read source files
    srcContents <- forM gen.srcs $ \src -> do
      let srcPath = srcDir </> T.unpack src
      exists <- doesFileExist srcPath
      if exists
        then do
          content <- BS.readFile srcPath
          pure $ Right (T.unpack src, content, False)
        else pure $ Left $ "Source not found: " <> T.pack srcPath
    
    case sequence srcContents of
      Left err -> pure $ Left err
      Right files -> do
        -- Upload input tree
        inputDigest <- uploadInputTree client files
        TIO.putStrLn $ "  uploaded input tree: " <> digestHash inputDigest
        
        -- Substitute $SRCS and $OUT in command
        let srcs = T.intercalate " " gen.srcs
            cmdText = T.replace "$SRCS" srcs $ T.replace "$OUT" (T.pack outPath) gen.cmd
            args = ["sh", "-c", cmdText]
        
        -- Create command
        let cmd = createCommand args [] [T.pack outPath] ""
        
        -- Upload command
        let cmdBytes = ProtoLens.encodeMessage cmd
        cmdDigest <- uploadBlob client cmdBytes
        TIO.putStrLn $ "  uploaded command: " <> digestHash cmdDigest
        
        -- Create action
        let platformProps = [("OSFamily", "linux")]
            action = createAction cmdDigest inputDigest platformProps
        
        -- Upload action
        let actionBytes = ProtoLens.encodeMessage action
        actionDigest <- uploadBlob client actionBytes
        TIO.putStrLn $ "  uploaded action: " <> digestHash actionDigest
        
        -- Execute
        TIO.putStrLn "  executing remotely..."
        result <- executeAction casConfig actionDigest
        
        case result of
          Left err -> pure $ Left $ "Execution failed: " <> err
          Right execResult -> do
            if execResult.execExitCode /= 0
              then pure $ Left $ "Build failed with exit code " <> T.pack (show execResult.execExitCode)
              else pure $ Right [outDir </> outPath]

-- | Convert C++ standard to flag
cxxStdFlag :: IR.CxxStd -> Text
cxxStdFlag = \case
  IR.Cxx11 -> "-std=c++11"
  IR.Cxx14 -> "-std=c++14"
  IR.Cxx17 -> "-std=c++17"
  IR.Cxx20 -> "-std=c++20"
  IR.Cxx23 -> "-std=c++23"
