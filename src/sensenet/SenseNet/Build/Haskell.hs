{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Haskell build functions
module SenseNet.Build.Haskell
  ( buildHaskellBinary,
    buildHaskellLibrary,
    buildHaskellBinaryWithDeps,
    buildHaskellFFIBinary,
  )
where

import Control.Monad (forM)
import Data.List (nub, sort, groupBy)
import Data.Text (Text)
import Data.Text qualified as T
import SenseNet.Build.Types (BuildError (..), BuildResult (..))
import SenseNet.IR qualified as IR
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeBaseName, takeDirectory, (</>))
import System.Process (readProcessWithExitCode)

buildHaskellBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.HaskellBinary -> IO (Either BuildError BuildResult)
buildHaskellBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let ghc = T.unpack tc.haskell.ghc.path
      pkgDb = tc.haskell.paths.includes -- Package DB paths
      libPaths = map T.unpack tc.haskell.paths.libs

  createDirectoryIfMissing True outDir

  -- Use srcs list, not main (main is the module name, not file)
  let srcFiles = map (\s -> srcDir </> T.unpack s) bin.srcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) bin.packages
      extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions
      ghcOpts = map T.unpack bin.ghcOptions
      mainFlag = ["-main-is", T.unpack bin.main]
      pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb
      libFlags = concatMap (\l -> ["-L" <> l]) libPaths
      includeFlags = ["-i" <> srcDir, "-i" <> outDir]
      cmd = [ghc] ++ pkgDbFlags ++ includeFlags ++ extFlags ++ pkgFlags ++ ghcOpts ++ mainFlag ++ srcFiles ++ ["-o", outBin] ++ libFlags

  -- Check first source exists
  case srcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (mainSrc : _) -> do
      exists <- doesFileExist mainSrc
      if not exists
        then pure $ Left $ SourceNotFound mainSrc
        else do
          (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildHaskellLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.HaskellLibrary -> IO (Either BuildError BuildResult)
buildHaskellLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath

  -- Toolchain
  let ghc = T.unpack tc.haskell.ghc.path
      pkgDb = tc.haskell.paths.includes
      libPaths = map T.unpack tc.haskell.paths.libs

  createDirectoryIfMissing True outDir

  -- Create output subdirectories for nested modules
  forM lib.srcs $ \src -> do
    let objPath = outDir </> T.unpack src <> ".o"
    createDirectoryIfMissing True (takeDirectory objPath)

  -- Use --make mode to compile all sources at once (handles dependency order automatically)
  let srcFiles = map (\s -> srcDir </> T.unpack s) lib.srcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) lib.packages
      extFlags = map (\e -> "-X" <> T.unpack e) lib.languageExtensions
      ghcOpts = map T.unpack lib.ghcOptions
      pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb
      libFlags = concatMap (\l -> ["-L" <> l]) libPaths
      includeFlags = ["-i" <> srcDir, "-i" <> outDir]
      -- Use --make to handle dependency ordering, -no-link to avoid linking
      cmd =
        [ghc, "--make", "-no-link"]
          ++ pkgDbFlags
          ++ includeFlags
          ++ extFlags
          ++ pkgFlags
          ++ ghcOpts
          ++ ["-odir", outDir, "-hidir", outDir]
          ++ libFlags
          ++ srcFiles

  -- Check first source exists
  case srcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (firstSrc : _) -> do
      exists <- doesFileExist firstSrc
      if not exists
        then pure $ Left $ SourceNotFound firstSrc
        else do
          (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
          case exitCode of
            ExitSuccess -> do
              -- Return all .o files as outputs
              -- GHC --make puts .o at module path (e.g., SenseNet/IR.o not SenseNet/IR.hs.o)
              let srcToObj s = outDir </> dropHsExt (T.unpack s) <> ".o"
                  dropHsExt p = if ".hs" `isSuffixOf` p then take (length p - 3) p else p
                  isSuffixOf suf str = suf == drop (length str - length suf) str
                  objs = map srcToObj lib.srcs
              pure $ Right $ BuildSuccess objs
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- | Build Haskell binary with resolved dependency outputs
-- Dep outputs (.o and .hi files) are added to the compilation
buildHaskellBinaryWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.HaskellBinary ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildHaskellBinaryWithDeps tc projectRoot pkgPath bin depOutputs = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let ghc = T.unpack tc.haskell.ghc.path
      pkgDb = tc.haskell.paths.includes
      libPaths = map T.unpack tc.haskell.paths.libs

  createDirectoryIfMissing True outDir

  -- Use srcs list
  let srcFiles = map (\s -> srcDir </> T.unpack s) bin.srcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) bin.packages
      extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions
      ghcOpts = map T.unpack bin.ghcOptions
      mainFlag = ["-main-is", T.unpack bin.main]
      pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb
      libFlags = concatMap (\l -> ["-L" <> l]) libPaths
      -- Add dep output .o files to link line
      depObjs = concatMap snd depOutputs
      -- Add dep output directories to -i search path (for .hi files)
      depDirs = nub $ map takeDirectory $ concatMap snd depOutputs
      -- Include source dir and output dir plus dep dirs for module discovery
      searchFlags = ["-i" <> srcDir, "-i" <> outDir] ++ map (\d -> "-i" <> d) depDirs
      cmd =
        [ghc]
          ++ pkgDbFlags
          ++ extFlags
          ++ pkgFlags
          ++ ghcOpts
          ++ searchFlags
          ++ mainFlag
          ++ srcFiles
          ++ depObjs
          ++ ["-o", outBin]
          ++ libFlags

  -- Check first source exists
  case srcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (mainSrc : _) -> do
      exists <- doesFileExist mainSrc
      if not exists
        then pure $ Left $ SourceNotFound mainSrc
        else do
          (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- | Build a Haskell binary that links against C/Rust FFI libraries
-- This is for binaries like sensenet itself that need dice_ffi, superconsole_ffi
buildHaskellFFIBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.HaskellFFIBinary -> IO (Either BuildError BuildResult)
buildHaskellFFIBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchains
  let ghc = T.unpack tc.haskell.ghc.path
      cxx = T.unpack tc.cxx.cxx.path
      pkgDb = tc.haskell.paths.includes
      libPaths = map T.unpack tc.haskell.paths.libs
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      cxxLibs = map T.unpack tc.cxx.paths.libs

  createDirectoryIfMissing True outDir

  -- Step 1: Compile C++ sources to object files
  let cxxSrcFiles = map (\s -> srcDir </> T.unpack s) bin.cxxSrcs
      cxxHeaderDirs = [srcDir] ++ map (\h -> takeDirectory (srcDir </> T.unpack h)) bin.cxxHeaders
      cxxIncludeFlags = concatMap (\i -> ["-isystem", i]) cxxIncludes
                     ++ concatMap (\i -> ["-I", i]) (nub cxxHeaderDirs)
                     ++ concatMap (\i -> ["-I", T.unpack i]) bin.includeDirs

  -- Compile each C++ source to an object file
  objFiles <- forM cxxSrcFiles $ \cxxSrc -> do
    let baseName = takeBaseName cxxSrc
        objFile = outDir </> baseName <> ".o"
        compileCmd = [cxx, "-c", "-std=c++17", "-fPIC", "-O2"]
                  ++ cxxIncludeFlags
                  ++ [cxxSrc, "-o", objFile]
    exists <- doesFileExist cxxSrc
    if not exists
      then pure $ Left $ SourceNotFound cxxSrc
      else do
        (exitCode, _, stderr) <- readProcessWithExitCode cxx (tail compileCmd) ""
        case exitCode of
          ExitSuccess -> pure $ Right objFile
          ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords compileCmd) n (T.pack stderr)

  case sequence objFiles of
    Left err -> pure $ Left err
    Right objs -> do
      -- Step 2: Compile Haskell and link with C++ objects
      let hsSrcFiles = map (\s -> srcDir </> T.unpack s) bin.hsSrcs
          pkgFlags = concatMap (\p -> ["-package", T.unpack p]) bin.packages
          extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions
          ghcOpts = map T.unpack bin.ghcOptions
          pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb

          -- Standard lib paths from toolchain
          libFlags = concatMap (\l -> ["-L" <> l]) libPaths

          -- C++ lib paths for linking libstdc++ etc
          cxxLibFlags = concatMap (\l -> ["-L" <> l, "-optl-Wl,-rpath," <> l]) cxxLibs

          -- Extra lib dirs for FFI libs (e.g., dice_ffi, superconsole_ffi)
          extraLibDirFlags = concatMap (\l -> ["-L" <> T.unpack l]) bin.extraLibDirs

          -- Extra libs to link (e.g., -ldice_ffi -lsuperconsole_ffi)
          extraLibFlags = concatMap (\l -> ["-l" <> T.unpack l]) bin.extraLibs

          -- Extra linker flags
          linkerFlags = map T.unpack bin.linkerFlags

          -- Include dirs for C headers (for Haskell FFI imports)
          includeFlags = concatMap (\i -> ["-I" <> i]) (nub cxxHeaderDirs)
                      ++ concatMap (\i -> ["-I" <> T.unpack i]) bin.includeDirs

          -- Search paths
          searchFlags = ["-i" <> srcDir, "-i" <> outDir]

          -- Threaded runtime for FFI
          rtFlags = ["-threaded", "-rtsopts", "-with-rtsopts=-N"]

          -- Link with C++ runtime
          cxxLinkFlags = ["-lstdc++"]

          cmd =
            [ghc]
              ++ pkgDbFlags
              ++ searchFlags
              ++ extFlags
              ++ pkgFlags
              ++ ghcOpts
              ++ rtFlags
              ++ includeFlags
              ++ hsSrcFiles
              ++ objs  -- Include compiled C++ object files
              ++ ["-o", outBin]
              ++ libFlags
              ++ cxxLibFlags
              ++ extraLibDirFlags
              ++ extraLibFlags
              ++ cxxLinkFlags
              ++ linkerFlags

      -- Check first source exists
      case hsSrcFiles of
        [] -> pure $ Left $ SourceNotFound "no sources"
        (mainSrc : _) -> do
          exists <- doesFileExist mainSrc
          if not exists
            then pure $ Left $ SourceNotFound mainSrc
            else do
              (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
              case exitCode of
                ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
                ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
