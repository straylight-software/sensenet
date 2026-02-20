{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : SenseNet.Build
-- Description : Build execution with Shelly
--
-- Clean build execution using:
--   - SenseNet.DICE for incremental computation
--   - Shelly for shell commands
--   - SenseNet.CAS for artifact storage
--
-- No Brick, no TUI, no FFI. Just builds.
module SenseNet.Build
  ( -- * Build
    build,
    buildTarget,
    BuildResult (..),
    BuildError (..),

    -- * Runners
    runAction,
    runCommand,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import SenseNet.DICE
  ( Action (..),
    ActionResult (..),
  )
import SenseNet.IR
  ( CxxBinary (..),
    CxxLibrary (..),
    Genrule (..),
    Package (..),
    Rule (..),
    ruleName,
  )
import SenseNet.Toolchains (Toolchains)
import Shelly (errExit, lastExitCode, lastStderr, shelly, silently)
import Shelly qualified as Sh
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory, (</>))

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

-- | Build result
data BuildResult
  = -- | Output paths
    BuildSuccess [FilePath]
  | -- | Outputs from cache
    BuildCached [FilePath]
  deriving (Show, Eq)

-- | Build errors
data BuildError
  = TargetNotFound Text
  | -- | command, exit code, stderr
    CommandFailed Text Int Text
  | -- | dep name, error
    DependencyFailed Text Text
  | SourceNotFound FilePath
  deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Build Entry Points
-- ════════════════════════════════════════════════════════════════════════════

-- | Build a target from a package
build ::
  Toolchains ->
  -- | Project root
  FilePath ->
  -- | Package containing the target
  Package ->
  -- | Target name
  Text ->
  IO (Either BuildError BuildResult)
build tc projectRoot pkg targetName = do
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ TargetNotFound targetName
    Just rule -> buildRule tc projectRoot pkg.path rule

-- | Build a single target (for external use)
buildTarget ::
  Toolchains ->
  FilePath ->
  Package ->
  Text ->
  IO (Either BuildError BuildResult)
buildTarget = build

-- ════════════════════════════════════════════════════════════════════════════
-- Rule Building
-- ════════════════════════════════════════════════════════════════════════════

-- | Build a rule
buildRule ::
  Toolchains ->
  -- | Project root
  FilePath ->
  -- | Package path
  FilePath ->
  -- | Rule to build
  Rule ->
  IO (Either BuildError BuildResult)
buildRule tc projectRoot pkgPath rule = do
  let outDir = projectRoot </> "sensenet-out" </> pkgPath
  createDirectoryIfMissing True outDir

  case rule of
    RCxxBinary bin -> buildCxx tc projectRoot pkgPath outDir bin
    RCxxLibrary lib -> buildCxxLib tc projectRoot pkgPath outDir lib
    RGenrule gen -> buildGenrule projectRoot pkgPath outDir gen
    _ -> pure $ Left $ CommandFailed "unsupported" 1 "Rule type not yet implemented"

-- | Build C++ binary
buildCxx :: Toolchains -> FilePath -> FilePath -> FilePath -> CxxBinary -> IO (Either BuildError BuildResult)
buildCxx _tc projectRoot pkgPath outDir bin = do
  let srcDir = projectRoot </> pkgPath
      output = outDir </> T.unpack bin.name
      srcs = map (\s -> srcDir </> T.unpack s) bin.srcs
      cmd = ["clang++", "-o", T.pack output] ++ map T.pack srcs ++ ["-std=c++23"]

  result <- runCommand cmd
  case result of
    Left err -> pure $ Left err
    Right _ -> pure $ Right $ BuildSuccess [output]

-- | Build C++ library (static)
buildCxxLib :: Toolchains -> FilePath -> FilePath -> FilePath -> CxxLibrary -> IO (Either BuildError BuildResult)
buildCxxLib _tc projectRoot pkgPath outDir lib = do
  let srcDir = projectRoot </> pkgPath
      output = outDir </> "lib" <> T.unpack lib.name <> ".a"
      srcs = map (\s -> srcDir </> T.unpack s) lib.srcs

  -- Compile each source to .o
  objResults <- mapM (compileObj outDir) srcs
  case sequence objResults of
    Left err -> pure $ Left err
    Right objs -> do
      -- Archive
      let arCmd = ["ar", "rcs", T.pack output] ++ map T.pack objs
      result <- runCommand arCmd
      case result of
        Left err -> pure $ Left err
        Right _ -> pure $ Right $ BuildSuccess [output]
  where
    compileObj :: FilePath -> FilePath -> IO (Either BuildError FilePath)
    compileObj outDir' src = do
      let obj = outDir' </> takeBaseName src <> ".o"
          cmd = ["clang++", "-c", "-o", T.pack obj, T.pack src, "-std=c++23"]
      result <- runCommand cmd
      case result of
        Left err -> pure $ Left err
        Right _ -> pure $ Right obj

    takeBaseName p = reverse $ takeWhile (/= '/') $ drop 1 $ dropWhile (/= '.') $ reverse p

-- | Build genrule
buildGenrule :: FilePath -> FilePath -> FilePath -> Genrule -> IO (Either BuildError BuildResult)
buildGenrule _projectRoot _pkgPath outDir gen = do
  let output = outDir </> T.unpack gen.out
      cmd = ["sh", "-c", gen.cmd]

  createDirectoryIfMissing True (takeDirectory output)
  result <- runCommand cmd
  case result of
    Left err -> pure $ Left err
    Right _ -> pure $ Right $ BuildSuccess [output]

-- ════════════════════════════════════════════════════════════════════════════
-- Command Execution
-- ════════════════════════════════════════════════════════════════════════════

-- | Run a command, return error or success
runCommand :: [Text] -> IO (Either BuildError ())
runCommand [] = pure $ Left $ CommandFailed "" 1 "Empty command"
runCommand (exe : args) = do
  (code, err) <- shelly $ silently $ errExit False $ do
    Sh.run_ (Sh.fromText exe) args
    code' <- lastExitCode
    err' <- lastStderr
    pure (code', err')

  if code == 0
    then pure $ Right ()
    else pure $ Left $ CommandFailed exe code err

-- | Run an action (for DICE integration)
runAction :: Action -> IO ActionResult
runAction Action {..} = do
  startTime <- getCurrentTime
  result <- runCommand aCommand
  endTime <- getCurrentTime

  case result of
    Left (CommandFailed _ code err) ->
      pure
        ActionResult
          { arOutputs = [],
            arExitCode = code,
            arStdout = "",
            arStderr = err,
            arStartTime = startTime,
            arEndTime = endTime
          }
    Left _ ->
      pure
        ActionResult
          { arOutputs = [],
            arExitCode = 1,
            arStdout = "",
            arStderr = "Unknown error",
            arStartTime = startTime,
            arEndTime = endTime
          }
    Right () ->
      pure
        ActionResult
          { arOutputs = aOutputs,
            arExitCode = 0,
            arStdout = "",
            arStderr = "",
            arStartTime = startTime,
            arEndTime = endTime
          }

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

findRule :: Text -> [Rule] -> Maybe Rule
findRule name = foldr check Nothing
  where
    check r acc
      | ruleName r == name = Just r
      | otherwise = acc
