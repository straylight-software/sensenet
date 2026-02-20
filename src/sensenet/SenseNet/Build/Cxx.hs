{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | C++ build functions
module SenseNet.Build.Cxx
  ( buildCxxBinary,
    buildCxxLibrary,
    buildCxxBinaryWithDeps,
  )
where

import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import SenseNet.Build.Helpers (checkSources, cxxStdFlag)
import SenseNet.Build.Types (BuildError (..), BuildResult (..))
import SenseNet.DICE (inject, runDICE, sha256)
import SenseNet.IR qualified as IR
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

buildCxxBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.CxxBinary -> IO (Either BuildError BuildResult)
buildCxxBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      ld = T.unpack tc.cxx.ld.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      cxxLibs = map T.unpack tc.cxx.paths.libs
      sysroot = T.unpack tc.cxx.sysroot

  -- Ensure output directory exists
  createDirectoryIfMissing True outDir

  -- Hash sources and inject into DICE
  diceResult <- runDICE $ do
    forM_ bin.srcs $ \src -> do
      let srcPath = srcDir </> T.unpack src
      exists <- liftIO $ doesFileExist srcPath
      if exists
        then do
          contents <- liftIO $ BS.readFile srcPath
          hash <- sha256 contents
          size <- liftIO $ fromIntegral <$> getFileSize srcPath
          inject (T.pack srcPath) hash size
        else pure () -- Will fail later
    pure ()

  case diceResult of
    Left err -> pure $ Left $ DICEFailed err
    Right () -> do
      -- Check all sources exist
      missingCheck <- checkSources srcDir bin.srcs
      case missingCheck of
        Just missing -> pure $ Left $ SourceNotFound missing
        Nothing -> do
          -- Compile
          let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs
              cflags = map T.unpack bin.cflags
              ldflags = map T.unpack bin.ldflags
              stdFlag = cxxStdFlag bin.std
              includeFlags = concatMap (\i -> ["-isystem", i]) cxxIncludes
              -- -B tells linker where to find crt*.o files, -L/-rpath for libraries
              libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) cxxLibs
              sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
              linkFlag = ["-fuse-ld=" <> ld]
              cmd = [cxx, stdFlag] ++ sysrootFlag ++ includeFlags ++ cflags ++ srcs ++ ["-o", outBin] ++ linkFlag ++ libFlags ++ ldflags

          (exitCode, _stdout, stderr) <- readProcessWithExitCode cxx (tail cmd) ""

          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildCxxLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.CxxLibrary -> IO (Either BuildError BuildResult)
buildCxxLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      sysroot = T.unpack tc.cxx.sysroot

  createDirectoryIfMissing True outDir

  -- Compile each source to .o
  results <- forM lib.srcs $ \src -> do
    let srcPath = srcDir </> T.unpack src
        objPath = outDir </> T.unpack src <> ".o"
        stdFlag = cxxStdFlag lib.std
        cflags = map T.unpack lib.cflags
        includeFlags = concatMap (\i -> ["-isystem", i]) cxxIncludes
        sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
        cmd = [cxx, "-c", stdFlag] ++ sysrootFlag ++ includeFlags ++ cflags ++ [srcPath, "-o", objPath]

    exists <- doesFileExist srcPath
    if not exists
      then pure $ Left $ SourceNotFound srcPath
      else do
        (exitCode, _, stderr) <- readProcessWithExitCode cxx (tail cmd) ""
        case exitCode of
          ExitSuccess -> pure $ Right objPath
          ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

  case sequence results of
    Left err -> pure $ Left err
    Right objs -> pure $ Right $ BuildSuccess objs
  where
    forM = flip mapM

-- | Build C++ binary with resolved dependency outputs
-- Dep outputs (e.g., .o files from libraries) are linked in
buildCxxBinaryWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.CxxBinary ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildCxxBinaryWithDeps tc projectRoot pkgPath bin depOutputs = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      ld = T.unpack tc.cxx.ld.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      cxxLibs = map T.unpack tc.cxx.paths.libs
      sysroot = T.unpack tc.cxx.sysroot

  createDirectoryIfMissing True outDir

  -- Check all sources exist
  missingCheck <- checkSources srcDir bin.srcs
  case missingCheck of
    Just missing -> pure $ Left $ SourceNotFound missing
    Nothing -> do
      -- Compile and link
      let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs
          cflags = map T.unpack bin.cflags
          ldflags = map T.unpack bin.ldflags
          stdFlag = cxxStdFlag bin.std
          includeFlags = concatMap (\i -> ["-isystem", i]) cxxIncludes
          libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) cxxLibs
          sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
          linkFlag = ["-fuse-ld=" <> ld]
          -- Add dep outputs (.o files) to link line
          depObjs = concatMap snd depOutputs
          cmd =
            [cxx, stdFlag]
              ++ sysrootFlag
              ++ includeFlags
              ++ cflags
              ++ srcs
              ++ depObjs
              ++ ["-o", outBin]
              ++ linkFlag
              ++ libFlags
              ++ ldflags

      (exitCode, _stdout, stderr) <- readProcessWithExitCode cxx (tail cmd) ""

      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
