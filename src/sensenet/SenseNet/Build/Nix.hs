{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Nix C++ build functions (builds with nix flake dependencies)
module SenseNet.Build.Nix
  ( buildNixCxxBinary,
    resolveNixDeps,
    extractPkgName,
  )
where

import Control.Monad (forM)
import Data.Text (Text)
import Data.Text qualified as T
import SenseNet.Build.Helpers (checkSources)
import SenseNet.Build.Types (BuildError (..), BuildResult (..))
import SenseNet.IR qualified as IR
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

buildNixCxxBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.NixCxxBinary -> IO (Either BuildError BuildResult)
buildNixCxxBinary tc projectRoot pkgPath bin = do
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

  -- Resolve nix dependencies to get include/lib paths
  nixPaths <- resolveNixDeps bin.nixDeps
  case nixPaths of
    Left err -> pure $ Left $ CompileFailed "nix eval" 1 err
    Right (nixIncludes, nixLibPaths, nixLinkFlags) -> do
      -- Check all sources exist
      missingCheck <- checkSources srcDir bin.srcs
      case missingCheck of
        Just missing -> pure $ Left $ SourceNotFound missing
        Nothing -> do
          -- Compile
          let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs
              cflags = map T.unpack bin.compilerFlags
              ldflags = map T.unpack bin.linkerFlags
              includeFlags = concatMap (\i -> ["-isystem", i]) (cxxIncludes ++ nixIncludes)
              libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) (cxxLibs ++ nixLibPaths)
              sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
              linkFlag = ["-fuse-ld=" <> ld]
              cmd = [cxx, "-std=c++17"] ++ sysrootFlag ++ includeFlags ++ cflags ++ srcs ++ ["-o", outBin] ++ linkFlag ++ libFlags ++ nixLinkFlags ++ ldflags

          (exitCode, _stdout, stderr) <- readProcessWithExitCode cxx (tail cmd) ""

          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- | Resolve nix flake refs to include/lib paths
-- Returns (includes, libPaths, linkFlags)
resolveNixDeps :: [Text] -> IO (Either Text ([FilePath], [FilePath], [String]))
resolveNixDeps deps = do
  results <- forM deps $ \dep -> do
    -- Get dev output for headers (fallback to out, then default)
    let flakeRef = T.unpack dep
        -- Extract package name for -l flag (e.g., "nixpkgs#zlib" -> "z")
        pkgName = extractPkgName dep

    -- Try dev output first for headers
    (devExit, devOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".dev.outPath"] ""
    devPath <-
      if devExit == ExitSuccess
        then pure devOut
        else do
          -- Fall back to out output
          (outExit, outOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".out.outPath"] ""
          if outExit == ExitSuccess
            then pure outOut
            else do
              -- Fall back to default output
              (mainExit, mainOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".outPath"] ""
              pure $ if mainExit == ExitSuccess then mainOut else ""

    -- Get out output for libs (not default, which may be bin)
    (outExit, outOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".out.outPath"] ""
    libPath <-
      if outExit == ExitSuccess
        then pure outOut
        else do
          -- Fall back to default output
          (mainExit, mainOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".outPath"] ""
          pure $ if mainExit == ExitSuccess then mainOut else ""

    if null devPath && null libPath
      then pure $ Left $ "Failed to resolve nix dep: " <> dep
      else pure $ Right (devPath, libPath, pkgName)

  case sequence results of
    Left err -> pure $ Left err
    Right paths -> do
      let includes = [p </> "include" | (p, _, _) <- paths, not (null p)]
          libPaths = [p </> "lib" | (_, p, _) <- paths, not (null p)]
          -- Flatten list of library names and create -l flags
          linkFlags = concatMap (\(_, _, ns) -> ["-l" <> n | n <- ns, not (null n)]) paths
      pure $ Right (includes, libPaths, linkFlags)

-- | Extract library names from flake ref for -l flags
-- Some packages provide multiple libraries (e.g., openssl -> ssl, crypto)
-- "nixpkgs#zlib" -> ["z"], "nixpkgs#openssl" -> ["ssl", "crypto"]
extractPkgName :: Text -> [String]
extractPkgName ref = case T.splitOn "#" ref of
  [_, pkg] -> libNamesFor (T.unpack pkg)
  _ -> []
  where
    -- Common mappings (some packages provide multiple libraries)
    libNamesFor "zlib" = ["z"]
    libNamesFor "openssl" = ["ssl", "crypto"]
    libNamesFor "sqlite" = ["sqlite3"]
    libNamesFor "curl" = ["curl"]
    libNamesFor "libpng" = ["png"]
    libNamesFor "libjpeg" = ["jpeg"]
    libNamesFor name = [name]
