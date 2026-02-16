{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}

-- | sensenet — Direct builds with Dhall + DICE
--
-- No Buck2, no Starlark, no BUCK file generation.
-- Just: BUILD.dhall → IR → DICE → execute
module Main where

import Control.Monad (forM_)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Environment (getArgs)
import System.Directory (getCurrentDirectory)
import System.Exit (exitFailure)
import System.FilePath ((</>), takeDirectory, makeRelative)

import SenseNet.Build (build, BuildResult(..), BuildError(..))
import SenseNet.Discover (DhallFile(..), discover)
import qualified SenseNet.DICE as DICE
import qualified SenseNet.Dhall as Dhall
import SenseNet.IR (Package(..), Rule, ruleName)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> usage
    ("build" : rest) -> cmdBuild (map T.pack rest)
    ("targets" : rest) -> cmdTargets (map T.pack rest)
    ("query" : rest) -> cmdTargets (map T.pack rest)  -- alias
    ("graph" : _) -> cmdGraph
    ("--version" : _) -> version
    ("-V" : _) -> version
    ("--help" : _) -> usage
    ("-h" : _) -> usage
    (cmd : _) -> do
      TIO.putStrLn $ "Unknown command: " <> T.pack cmd
      usage

version :: IO ()
version = do
  diceVer <- DICE.diceVersion
  TIO.putStrLn $ "sensenet 0.2.0 (DICE " <> diceVer <> ")"
  putStrLn "Direct builds with Dhall + DICE — no Buck2"

usage :: IO ()
usage = putStrLn $ unlines
  [ "sensenet — Direct builds with Dhall + DICE"
  , ""
  , "Usage: sensenet <command> [options]"
  , ""
  , "Commands:"
  , "  build [target]     Build target(s)"
  , "  targets [pattern]  List available targets"
  , "  query [pattern]    Alias for targets"
  , "  graph              Show build graph"
  , ""
  , "Options:"
  , "  --version, -V      Show version"
  , "  --help, -h         Show this help"
  , ""
  , "Examples:"
  , "  sensenet build                       # build all"
  , "  sensenet build //src/examples/cxx:hello-cxx"
  , "  sensenet targets                     # list all targets"
  , ""
  , "Output goes to sensenet-out/"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Commands
-- ════════════════════════════════════════════════════════════════════════════

cmdBuild :: [Text] -> IO ()
cmdBuild args = do
  projectRoot <- getCurrentDirectory
  
  case args of
    [] -> do
      -- Build all targets
      files <- discover projectRoot
      TIO.putStrLn $ "Found " <> T.pack (show $ length files) <> " BUILD.dhall files"
      forM_ files $ \file -> do
        pkg <- Dhall.parsePackageFile projectRoot (dhallPath file)
        forM_ pkg.rules $ \rule -> do
          buildTarget projectRoot pkg (ruleName rule)
    
    (target : _) -> do
      -- Parse target like //src/examples/cxx:hello-cxx
      case parseTarget target of
        Nothing -> do
          TIO.putStrLn $ "Invalid target: " <> target
          TIO.putStrLn "Expected format: //path/to/pkg:target"
          exitFailure
        Just (pkgPath, targetName) -> do
          let dhallPath = projectRoot </> T.unpack pkgPath </> "BUILD.dhall"
          pkg <- Dhall.parsePackageFile projectRoot dhallPath
          buildTarget projectRoot pkg targetName

buildTarget :: FilePath -> Package -> Text -> IO ()
buildTarget projectRoot pkg targetName = do
  TIO.putStrLn $ "Building " <> T.pack pkg.path <> ":" <> targetName
  result <- build projectRoot pkg targetName
  case result of
    Left err -> do
      TIO.putStrLn $ "  ✗ " <> showError err
      exitFailure
    Right (BuildSuccess outputs) -> do
      TIO.putStrLn $ "  ✓ Built: " <> T.intercalate ", " (map T.pack outputs)
    Right (BuildCached outputs) -> do
      TIO.putStrLn $ "  ✓ Cached: " <> T.intercalate ", " (map T.pack outputs)

showError :: BuildError -> Text
showError = \case
  SourceNotFound path -> "Source not found: " <> T.pack path
  CompileFailed cmd code stderr -> 
    "Compile failed (exit " <> T.pack (show code) <> "): " <> stderr
  LinkFailed cmd code stderr -> 
    "Link failed (exit " <> T.pack (show code) <> "): " <> stderr
  DICEFailed err -> "DICE error: " <> T.pack (show err)
  TargetNotFound name -> "Target not found: " <> name
  UnsupportedRule rule -> "Unsupported rule type: " <> rule

-- | Parse //path/to/pkg:target
parseTarget :: Text -> Maybe (Text, Text)
parseTarget t = do
  rest <- T.stripPrefix "//" t
  case T.breakOn ":" rest of
    (_, "") -> Nothing  -- No colon found
    (pkgPath, colonTarget) -> Just (pkgPath, T.drop 1 colonTarget)

cmdTargets :: [Text] -> IO ()
cmdTargets _ = do
  projectRoot <- getCurrentDirectory
  files <- discover projectRoot
  forM_ files $ \file -> do
    pkg <- Dhall.parsePackageFile projectRoot (dhallPath file)
    forM_ pkg.rules $ \rule -> do
      TIO.putStrLn $ "//" <> T.pack pkg.path <> ":" <> ruleName rule

cmdGraph :: IO ()
cmdGraph = do
  projectRoot <- getCurrentDirectory
  files <- discover projectRoot
  forM_ files $ \file -> do
    pkg <- Dhall.parsePackageFile projectRoot (dhallPath file)
    TIO.putStrLn $ "# " <> T.pack pkg.path
    forM_ pkg.rules $ \rule -> do
      TIO.putStrLn $ "  " <> ruleName rule
