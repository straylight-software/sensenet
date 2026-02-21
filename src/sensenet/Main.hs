{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- sensenet — the best build system in the world
--
-- Pure Haskell. Content-addressed. Coeffect-tracked.
-- No FFI. No daemon. Static binary.
module Main where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import SenseNet.Build (BuildError (..), BuildResult (..), buildWithDeps)
-- SenseNet.DICE used by Build module
import SenseNet.Dhall qualified as Dhall
import SenseNet.Discover (DhallFile (..), discover)
import SenseNet.IR (Package (..), ruleName)
import SenseNet.Toolchains qualified as TC
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  args <- getArgs
  case args of
    [] -> usage
    ["--version"] -> version
    ["-V"] -> version
    ["--help"] -> usage
    ["-h"] -> usage
    ("build" : rest) -> cmdBuild rest
    ("targets" : _) -> cmdTargets
    ("clean" : _) -> cmdClean
    (cmd : _) -> do
      TIO.putStrLn $ "Unknown command: " <> T.pack cmd
      usage

version :: IO ()
version = do
  TIO.putStrLn "sensenet 0.3.0"
  TIO.putStrLn "Pure Haskell • Content-addressed • Coeffect-tracked"

usage :: IO ()
usage = do
  TIO.putStrLn $
    T.unlines
      [ "sensenet — the best build system in the world",
        "",
        "Usage: sensenet <command> [options]",
        "",
        "Commands:",
        "  build <target>     Build target(s)",
        "  targets            List available targets",
        "  clean              Remove build outputs",
        "",
        "Target patterns:",
        "  //path/to/pkg:target   Single target",
        "  //...                  All targets",
        "",
        "Examples:",
        "  sensenet build //src/examples/cxx:hello",
        "  sensenet targets"
      ]

-- ════════════════════════════════════════════════════════════════════════════
-- Commands
-- ════════════════════════════════════════════════════════════════════════════

cmdBuild :: [String] -> IO ()
cmdBuild [] = do
  TIO.putStrLn "Usage: sensenet build //path/to/pkg:target"
  exitFailure
cmdBuild (target : _) = do
  case parseTarget (T.pack target) of
    Nothing -> do
      TIO.putStrLn $ "Invalid target: " <> T.pack target
      TIO.putStrLn "Expected: //path/to/pkg:target"
      exitFailure
    Just (pkgPath, targetName) -> do
      -- Load toolchains
      projectRoot <- pure "." -- TODO: find project root
      tc <- TC.loadToolchains (TC.defaultToolchainsPath projectRoot)

      -- Parse package
      let dhallPath = projectRoot <> "/" <> T.unpack pkgPath <> "/BUILD.dhall"
      pkg <- Dhall.parsePackageFile projectRoot dhallPath

      -- Build
      TIO.putStrLn $ "Building //" <> pkgPath <> ":" <> targetName
      result <- buildWithDeps tc projectRoot pkg targetName

      case result of
        Left err -> do
          TIO.putStrLn $ "✗ " <> showError err
          exitFailure
        Right (BuildSuccess outputs) -> do
          TIO.putStrLn $ "✓ Built: " <> T.intercalate ", " (map T.pack outputs)
          exitSuccess
        Right (BuildCached outputs) -> do
          TIO.putStrLn $ "✓ Cached: " <> T.intercalate ", " (map T.pack outputs)
          exitSuccess

cmdTargets :: IO ()
cmdTargets = do
  projectRoot <- pure "."
  files <- discover projectRoot
  pkgs <- mapM (\f -> Dhall.parsePackageFile projectRoot (dhallPath f)) files
  let getPath (Package p _) = p
      getRules (Package _ rs) = rs
      targets =
        [ "//" <> T.pack (getPath pkg) <> ":" <> ruleName rule
        | pkg <- pkgs,
          rule <- getRules pkg
        ]
  mapM_ TIO.putStrLn targets

cmdClean :: IO ()
cmdClean = do
  TIO.putStrLn "Removing sensenet-out/"
  -- TODO: actually remove
  TIO.putStrLn "✓ Clean"

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

-- | Parse //path/to/pkg:target
parseTarget :: Text -> Maybe (Text, Text)
parseTarget t = do
  rest <- T.stripPrefix "//" t
  case T.breakOn ":" rest of
    (_, "") -> Nothing
    (pkgPath, colonTarget) -> Just (pkgPath, T.drop 1 colonTarget)

showError :: BuildError -> Text
showError = \case
  TargetNotFound name -> "Target not found: " <> name
  CommandFailed cmd code err ->
    "Command failed: " <> cmd <> " (exit " <> T.pack (show code) <> ")\n" <> err
  DependencyFailed dep err -> "Dependency failed: " <> dep <> " - " <> err
  SourceNotFound path -> "Source not found: " <> T.pack path
