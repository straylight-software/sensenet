{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Rust build functions
module SenseNet.Build.Rust
  ( buildRustBinary,
    buildRustLibrary,
    buildRustBinaryWithDeps,
  )
where

import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as T
import SenseNet.Build.Helpers (rustEditionFlag)
import SenseNet.Build.Types (BuildError (..), BuildResult (..))
import SenseNet.IR qualified as IR
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (readProcessWithExitCode)

buildRustBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.RustBinary -> IO (Either BuildError BuildResult)
buildRustBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let rustc = T.unpack tc.rust.rustc.path
      target = T.unpack tc.rust.target

  createDirectoryIfMissing True outDir

  -- For single-file Rust, compile directly
  -- For multi-file, we'd need proper crate handling
  case bin.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag bin.edition
          cmd = [rustc, "--edition", edition, "--target", target, srcPath, "-o", outBin]

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    srcs -> do
      -- Multi-file: use first as main, compile all
      let mainSrc = srcDir </> T.unpack (head srcs)
          edition = rustEditionFlag bin.edition
          cmd = [rustc, "--edition", edition, "--target", target, mainSrc, "-o", outBin]

      (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildRustLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.RustLibrary -> IO (Either BuildError BuildResult)
buildRustLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      crateName = maybe (T.unpack lib.name) T.unpack lib.crateName
      outLib = outDir </> ("lib" <> crateName <> ".rlib")

  -- Toolchain
  let rustc = T.unpack tc.rust.rustc.path
      target = T.unpack tc.rust.target

  createDirectoryIfMissing True outDir

  case lib.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag lib.edition
          cmd =
            [ rustc,
              "--edition",
              edition,
              "--target",
              target,
              "--crate-type",
              "rlib",
              "--crate-name",
              crateName,
              srcPath,
              "-o",
              outLib
            ]

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outLib]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    _ -> pure $ Left $ UnsupportedRule "Multi-file Rust library"

-- | Build a Rust binary with resolved dependency outputs
buildRustBinaryWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.RustBinary ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildRustBinaryWithDeps tc projectRoot pkgPath bin depOutputs = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let rustc = T.unpack tc.rust.rustc.path
      target = T.unpack tc.rust.target

  createDirectoryIfMissing True outDir

  -- Extract .rlib files from deps and generate --extern flags
  let rlibFiles = concatMap snd depOutputs
      -- Get unique directories for -L flags
      libDirs = nub $ map takeDirectory rlibFiles
      libDirFlags = concatMap (\d -> ["-L", d]) libDirs
      -- Generate --extern cratename=path.rlib for each dep
      externFlags = concatMap mkExternFlag depOutputs

  case bin.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag bin.edition
          cmd =
            [rustc, "--edition", edition, "--target", target]
              ++ externFlags
              ++ libDirFlags
              ++ [srcPath, "-o", outBin]

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    srcs -> do
      -- Multi-file: use first as main
      let mainSrc = srcDir </> T.unpack (head srcs)
          edition = rustEditionFlag bin.edition
          cmd =
            [rustc, "--edition", edition, "--target", target]
              ++ externFlags
              ++ libDirFlags
              ++ [mainSrc, "-o", outBin]

      (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
  where
    -- Convert dep name + rlib path to --extern flag
    -- e.g., ("//pkg:mathlib", [".../libmathlib.rlib"]) -> ["--extern", "mathlib=.../libmathlib.rlib"]
    -- depName may be a full target path like "//src/examples/rust:mathlib"
    mkExternFlag :: (Text, [FilePath]) -> [String]
    mkExternFlag (depName, paths) = case paths of
      [rlib] ->
        -- Extract crate name from target path (e.g., "//pkg:mathlib" -> "mathlib")
        let crateName = case T.splitOn ":" depName of
              [_, name] -> T.unpack name
              _ -> T.unpack depName -- Fallback to full name
         in ["--extern", crateName <> "=" <> rlib]
      _ -> [] -- Skip if not exactly one .rlib
