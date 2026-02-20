{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Lean build functions
module SenseNet.Build.Lean
  ( buildLeanBinary,
    buildLeanLibrary,
  )
where

import Control.Monad (forM, when)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.IO.Handle (hGetContents)
import SenseNet.Build.Helpers (copyFile)
import SenseNet.Build.Types (BuildError (..), BuildResult (..))
import SenseNet.IR qualified as IR
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (dropExtension, takeDirectory, (</>))
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, readProcessWithExitCode, waitForProcess)

buildLeanBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.LeanBinary -> IO (Either BuildError BuildResult)
buildLeanBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain paths
  let lean = T.unpack tc.lean.lean.path
      leanc = T.unpack tc.lean.leanc.path
      -- Lean library path (where Init.olean, Std.olean, etc. live)
      leanLib = takeDirectory (takeDirectory lean) </> "lib" </> "lean"

  -- Check for unconfigured toolchain
  if null lean || null leanc
    then pure $ Left $ ToolchainError "Lean toolchain not configured (lean.lean or lean.leanc path is empty)"
    else do
      -- Build directories
      let libLeanDir = outDir </> "lib" </> "lean"
          irDir = outDir </> "ir"
          binDir = outDir

      createDirectoryIfMissing True libLeanDir
      createDirectoryIfMissing True irDir
      createDirectoryIfMissing True binDir

      case bin.srcs of
        -- Single file: simple compilation
        [src] -> do
          let srcPath = srcDir </> T.unpack src
              outC = outDir </> T.unpack bin.name <> ".c"

          exists <- doesFileExist srcPath
          if not exists
            then pure $ Left $ SourceNotFound srcPath
            else do
              -- Step 1: Generate C code
              let genCCmd = [lean, "-c", outC, srcPath]
              (exitCode1, _, stderr1) <- readProcessWithExitCode lean (tail genCCmd) ""
              case exitCode1 of
                ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords genCCmd) n (T.pack stderr1)
                ExitSuccess -> do
                  -- Step 2: Compile C to executable with leanc
                  let compileCmd = [leanc, "-o", outBin, outC]
                  (exitCode2, _, stderr2) <- readProcessWithExitCode leanc (tail compileCmd) ""
                  case exitCode2 of
                    ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
                    ExitFailure n -> pure $ Left $ LinkFailed (T.pack $ unwords compileCmd) n (T.pack stderr2)

        -- Multi-file: full Lean build pipeline
        --
        -- For multi-file Lean projects with a root module (e.g., "Straylight"),
        -- we need to set up the source tree so that module paths match import paths.
        -- Lean derives initialization function names from file paths relative to
        -- the working directory, so we compile from a staging directory where
        -- files are organized as: <rootModule>/<file>.lean for library modules,
        -- and Main.lean at the root.
        srcs -> do
          let rootMod = maybe "" T.unpack bin.rootModule

          -- Build staging directory - this is our "project root" for compilation
          let stageDir = outDir </> ".lean-stage"
              stageSrcDir = if null rootMod then stageDir else stageDir </> rootMod
              stageLibDir = stageDir </> ".lake" </> "build" </> "lib" </> "lean"
              stageIrDir = stageDir </> ".lake" </> "build" </> "ir"

          createDirectoryIfMissing True stageSrcDir
          createDirectoryIfMissing True stageLibDir
          createDirectoryIfMissing True stageIrDir
          when (not $ null rootMod) $ do
            createDirectoryIfMissing True (stageLibDir </> rootMod)
            createDirectoryIfMissing True (stageIrDir </> rootMod)

          -- Copy source files to staging directory with correct module structure
          forM srcs $ \srcText -> do
            let src = T.unpack srcText
                srcPath = srcDir </> src
                baseName = dropExtension src
                isMain = baseName == "Main"
                -- Main.lean goes at root, other files under rootModule
                destPath = if isMain || null rootMod
                           then stageDir </> src
                           else stageDir </> rootMod </> src
            createDirectoryIfMissing True (takeDirectory destPath)
            exists <- doesFileExist srcPath
            when exists $ copyFile srcPath destPath

          -- Build environment: LEAN_PATH includes our build output and Lean's stdlib
          let leanPath = stageLibDir <> ":" <> leanLib

          -- Step 1: Compile each .lean file to .olean, .ilean, .c
          -- Sources must be in dependency order (deps before dependents)
          -- Compile from stageDir so relative paths match module structure
          compileResults <- forM srcs $ \srcText -> do
            let src = T.unpack srcText
                baseName = dropExtension src
                isMain = baseName == "Main"

                -- Relative path from stageDir (what lean sees)
                relSrcPath = if isMain || null rootMod
                             then src
                             else rootMod </> src

                -- Module path for output organization
                modulePath = if null rootMod || isMain
                             then baseName
                             else rootMod </> baseName

                -- Output paths (absolute, but we compile with cwd=stageDir)
                oleanPath = stageLibDir </> modulePath <> ".olean"
                ileanPath = stageLibDir </> modulePath <> ".ilean"
                cPath = stageIrDir </> modulePath <> ".c"

            createDirectoryIfMissing True (takeDirectory oleanPath)
            createDirectoryIfMissing True (takeDirectory cPath)

            let srcPath = srcDir </> T.unpack srcText
            exists <- doesFileExist srcPath
            if not exists
              then pure $ Left $ SourceNotFound srcPath
              else do
                -- Compile: lean <relSrc> -o <olean> -i <ilean> -c <c>
                -- Run from stageDir so module paths are correct
                let compileArgs = [relSrcPath, "-o", oleanPath, "-i", ileanPath, "-c", cPath]
                    compileEnv = [("LEAN_PATH", leanPath)]

                currentEnv <- getEnvironment
                let fullEnv = compileEnv ++ filter ((/= "LEAN_PATH") . fst) currentEnv
                    process = (proc lean compileArgs)
                      { env = Just fullEnv
                      , cwd = Just stageDir
                      , std_err = CreatePipe
                      }

                (_, _, Just stderrH, ph) <- createProcess process
                exitCode <- waitForProcess ph
                stderrContent <- hGetContents stderrH

                case exitCode of
                  ExitFailure n ->
                    pure $ Left $ CompileFailed (T.pack $ unwords (lean : compileArgs)) n (T.pack stderrContent)
                  ExitSuccess ->
                    pure $ Right cPath

          -- Check if any compilation failed
          case sequence compileResults of
            Left err -> pure $ Left err
            Right cPaths -> do
              -- Step 2: Compile each .c to .o using leanc (has correct include paths)
              objResults <- forM cPaths $ \cPath -> do
                let oPath = cPath <> ".o"
                    -- leanc wraps gcc with correct Lean include paths
                    compileArgs = ["-c", "-o", oPath, cPath, "-fPIC", "-O3", "-DNDEBUG"]

                (exitCode, _, stderr) <- readProcessWithExitCode leanc compileArgs ""
                case exitCode of
                  ExitFailure n ->
                    pure $ Left $ CompileFailed (T.pack $ unwords (leanc : compileArgs)) n (T.pack stderr)
                  ExitSuccess ->
                    pure $ Right oPath

              case sequence objResults of
                Left err -> pure $ Left err
                Right oPaths -> do
                  -- Step 3: Link all .o files with leanc
                  let linkArgs = ["-o", outBin] ++ oPaths

                  (exitCode, _, stderr) <- readProcessWithExitCode leanc linkArgs ""
                  case exitCode of
                    ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
                    ExitFailure n -> pure $ Left $ LinkFailed (T.pack $ unwords (leanc : linkArgs)) n (T.pack stderr)

buildLeanLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.LeanLibrary -> IO (Either BuildError BuildResult)
buildLeanLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath

  -- Toolchain
  let lean = T.unpack tc.lean.lean.path

  -- Check for unconfigured toolchain
  if null lean
    then pure $ Left $ ToolchainError "Lean toolchain not configured (lean.lean path is empty)"
    else do
      createDirectoryIfMissing True outDir

      -- Compile each .lean to .olean
      results <- forM lib.srcs $ \src -> do
        let srcPath = srcDir </> T.unpack src
            oleanPath = outDir </> T.unpack src <> ".olean"
            cmd = [lean, "-c", oleanPath, srcPath]

        exists <- doesFileExist srcPath
        if not exists
          then pure $ Left $ SourceNotFound srcPath
          else do
            (exitCode, _, stderr) <- readProcessWithExitCode lean (tail cmd) ""
            case exitCode of
              ExitSuccess -> pure $ Right oleanPath
              ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

      case sequence results of
        Left err -> pure $ Left err
        Right oleans -> pure $ Right $ BuildSuccess oleans
