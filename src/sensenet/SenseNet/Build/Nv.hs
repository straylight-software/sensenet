{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | NVIDIA/CUDA build functions
module SenseNet.Build.Nv
  ( buildNvBinary,
    buildNvLibrary,
  )
where

import Control.Monad (forM)
import Data.Text qualified as T
import SenseNet.Build.Types (BuildError (..), BuildResult (..))
import SenseNet.IR qualified as IR
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

buildNvBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.NvBinary -> IO (Either BuildError BuildResult)
buildNvBinary tc projectRoot pkgPath bin = do
  case tc.nv of
    Nothing -> pure $ Left $ UnsupportedRule "NvBinary requires NVIDIA toolchain (not configured)"
    Just nv -> do
      let srcDir = projectRoot </> pkgPath
          outDir = projectRoot </> "sensenet-out" </> pkgPath
          outBin = outDir </> T.unpack bin.name

      createDirectoryIfMissing True outDir

      -- Use toolchain paths (nv contains its own cxx toolchain for stdlib)
      let clang = T.unpack nv.clang.path
          cudaPath = T.unpack nv.sdk_path
          cudaIncludes = map T.unpack nv.sdk.includes
          cudaLibs = map T.unpack nv.sdk.libs
          cxxIncludes = map T.unpack nv.cxx.paths.includes
          cxxLibs = map T.unpack nv.cxx.paths.libs
          ld = T.unpack nv.cxx.ld.path
          sysroot = T.unpack nv.cxx.sysroot

      -- Source files
      let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs

      -- Architecture flags (from rule or toolchain defaults)
      let ruleArchs = bin.archs
          tcArchs = nv.archs
          archs = if null ruleArchs then tcArchs else ruleArchs
          archFlags = concatMap (\a -> ["--cuda-gpu-arch=" <> T.unpack a, "--cuda-include-ptx=" <> T.unpack a]) archs

      -- Compile flags
      let cudaFlags =
            [ "-x",
              "cuda",
              "--cuda-path=" <> cudaPath,
              "-std=c++23",
              "-Wno-unknown-cuda-version"
            ]
              ++ concatMap (\i -> ["-isystem", i]) cudaIncludes
              ++ concatMap (\i -> ["-isystem", i]) cxxIncludes
              ++ (if null sysroot then [] else ["--sysroot=" <> sysroot])

      -- Link flags (-B tells linker where to find crt*.o files)
      let linkFlags =
            [ "-fuse-ld=" <> ld,
              "-lcudart"
            ]
              ++ concatMap (\l -> ["-L" <> l, "-Wl,-rpath," <> l]) cudaLibs
              ++ concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) cxxLibs

      let cmd = [clang] ++ cudaFlags ++ archFlags ++ srcs ++ ["-o", outBin] ++ linkFlags

      (exitCode, _, stderr) <- readProcessWithExitCode clang (tail cmd) ""
      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildNvLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.NvLibrary -> IO (Either BuildError BuildResult)
buildNvLibrary tc projectRoot pkgPath lib = do
  case tc.nv of
    Nothing -> pure $ Left $ UnsupportedRule "NvLibrary requires NVIDIA toolchain (not configured)"
    Just nv -> do
      let srcDir = projectRoot </> pkgPath
          outDir = projectRoot </> "sensenet-out" </> pkgPath

      createDirectoryIfMissing True outDir

      -- Use toolchain paths (nv contains its own cxx toolchain for stdlib)
      let clang = T.unpack nv.clang.path
          cudaPath = T.unpack nv.sdk_path
          cudaIncludes = map T.unpack nv.sdk.includes
          cxxIncludes = map T.unpack nv.cxx.paths.includes
          sysroot = T.unpack nv.cxx.sysroot

      -- Architecture flags
      let ruleArchs = lib.archs
          tcArchs = nv.archs
          archs = if null ruleArchs then tcArchs else ruleArchs
          archFlags = concatMap (\a -> ["--cuda-gpu-arch=" <> T.unpack a, "--cuda-include-ptx=" <> T.unpack a]) archs

      -- Compile flags
      let cudaFlags =
            [ "-x",
              "cuda",
              "--cuda-path=" <> cudaPath,
              "-std=c++23",
              "-Wno-unknown-cuda-version",
              "-fPIC",
              "-c"
            ]
              ++ concatMap (\i -> ["-isystem", i]) cudaIncludes
              ++ concatMap (\i -> ["-isystem", i]) cxxIncludes
              ++ (if null sysroot then [] else ["--sysroot=" <> sysroot])

      -- Compile each source to .o
      results <- forM lib.srcs $ \src -> do
        let srcPath = srcDir </> T.unpack src
            objPath = outDir </> T.unpack src <> ".o"
            cmd = [clang] ++ cudaFlags ++ archFlags ++ [srcPath, "-o", objPath]

        exists <- doesFileExist srcPath
        if not exists
          then pure $ Left $ SourceNotFound srcPath
          else do
            (exitCode, _, stderr) <- readProcessWithExitCode clang (tail cmd) ""
            case exitCode of
              ExitSuccess -> pure $ Right objPath
              ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

      case sequence results of
        Left err -> pure $ Left err
        Right objs -> pure $ Right $ BuildSuccess objs
