{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

{- |
Module      : Main
Description : SENSE // NET — The invisible build system

sensenet wraps Buck2 with Dhall configuration, running Buck2 in a
namespace with a constructed filesystem view. No Starlark, no prelude
complexity — just Dhall and DICE.

Usage:
  sensenet build //target       Build a target
  sensenet build                Build current directory's targets
  sensenet run //target         Build and run
  sensenet clean                Clean build outputs

The magic: Buck2 runs in a Linux namespace where toolchains, prelude,
and BUCK files appear to exist, generated from Dhall on the fly.
-}
module Main where

import Control.Monad (forM_, when)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Shelly
import System.Environment (getArgs, lookupEnv)
import System.IO.Temp (withSystemTempDirectory)

import SenseNet.Config
import SenseNet.Discover (DhallFile(..), discover)
import SenseNet.Emit (emitBuck)
import SenseNet.Generate
import SenseNet.IR (Package(..), ruleName)
import SenseNet.Namespace
import qualified SenseNet.Dhall as Dhall

default (Text)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> usage
    ("build" : rest) -> cmdBuild (map T.pack rest)
    ("run" : rest) -> cmdRun (map T.pack rest)
    ("clean" : _) -> cmdClean
    ("targets" : rest) -> cmdTargets (map T.pack rest)
    ("query" : rest) -> cmdQuery (map T.pack rest)
    ("emit-buck" : rest) -> cmdEmitBuck rest
    ("graph" : rest) -> cmdGraph rest
    ("--version" : _) -> version
    ("-V" : _) -> version
    ("--help" : _) -> usage
    ("-h" : _) -> usage
    (c : _) -> do
      putStrLn $ "Unknown command: " <> c
      usage

version :: IO ()
version = do
  putStrLn "sensenet 0.1.0"
  putStrLn "SENSE // NET — Dhall + DICE build system"

usage :: IO ()
usage = putStrLn $ unlines
  [ "sensenet — SENSE // NET"
  , ""
  , "Usage: sensenet <command> [options]"
  , ""
  , "Commands:"
  , "  build [target]     Build target(s)"
  , "  run <target>       Build and run"
  , "  clean              Clean build outputs"
  , "  targets [pattern]  List targets"
  , "  query <expr>       Query the build graph (buck2 cquery)"
  , "  emit-buck <file>   Emit BUCK from BUILD.dhall (new format)"
  , "  graph [pattern]    Show build graph"
  , ""
  , "Options:"
  , "  --version, -V      Show version"
  , "  --help, -h         Show this help"
  , ""
  , "Examples:"
  , "  sensenet build                    # build all"
  , "  sensenet build //src/foo:bar      # build specific target"
  , "  sensenet run //src/hello:hello    # build and run"
  , "  sensenet query //...              # list all targets"
  , "  sensenet query 'deps(//foo:bar)'  # query dependencies"
  , "  sensenet emit-buck src/foo/BUILD.dhall"
  ]

-- | Build command
cmdBuild :: [Text] -> IO ()
cmdBuild args = withNamespace $ \cfg files -> do
  let targets = if null args then [":"] else args
  execInNamespace cfg files "buck2" ("build" : targets)

-- | Run command  
cmdRun :: [Text] -> IO ()
cmdRun args = withNamespace $ \cfg files -> do
  case args of
    [] -> errorExit "Usage: sensenet run <target>"
    (target : rest) -> execInNamespace cfg files "buck2" ("run" : target : rest)

-- | Clean command
cmdClean :: IO ()
cmdClean = shelly $ run_ "buck2" ["clean"]

-- | Targets command
cmdTargets :: [Text] -> IO ()
cmdTargets args = withNamespace $ \cfg files -> do
  let pattern = case args of
        [] -> "//..."
        (p : _) -> p
  execInNamespace cfg files "buck2" ["targets", pattern]

-- | Query command (wraps buck2 cquery)
cmdQuery :: [Text] -> IO ()
cmdQuery args = withNamespace $ \cfg files -> do
  let queryArgs = if null args then ["//..."] else args
  execInNamespace cfg files "buck2" ("cquery" : queryArgs)

-- | Emit BUCK from a BUILD.dhall file (new format)
cmdEmitBuck :: [String] -> IO ()
cmdEmitBuck args = case args of
  [] -> putStrLn "Usage: sensenet emit-buck <BUILD.dhall>"
  (path : _) -> do
    cwd <- shelly pwd
    let projectRoot = T.unpack $ toTextIgnore cwd
    pkg <- Dhall.parsePackageFile projectRoot path
    TIO.putStr $ emitBuck pkg

-- | Show build graph
cmdGraph :: [String] -> IO ()
cmdGraph args = case args of
  [] -> do
    cwd <- shelly pwd
    let projectRoot = T.unpack $ toTextIgnore cwd
    files <- discover projectRoot
    forM_ files $ \file -> do
      when (isBuildDhallNew (dhallPath file)) $ do
        pkg <- Dhall.parsePackageFile projectRoot (dhallPath file)
        putStrLn $ "# " <> pkg.path
        forM_ pkg.rules $ \rule -> do
          putStrLn $ "  " <> T.unpack (ruleName rule)
  (path : _) -> do
    cwd <- shelly pwd
    let projectRoot = T.unpack $ toTextIgnore cwd
    pkg <- Dhall.parsePackageFile projectRoot path
    putStrLn $ "# " <> pkg.path
    forM_ pkg.rules $ \rule -> do
      putStrLn $ "  " <> T.unpack (ruleName rule)
  where
    isBuildDhallNew :: FilePath -> Bool
    isBuildDhallNew p = "BUILD.dhall.new" `T.isSuffixOf` T.pack p

-- | Set up the namespace and run an action
withNamespace :: (Config -> [DhallFile] -> Sh ()) -> IO ()
withNamespace action = do
  -- Get paths from environment (set by nix develop)
  prelude <- lookupEnv "SENSENET_PRELUDE" >>= \case
    Just p -> pure p
    Nothing -> fail "SENSENET_PRELUDE not set. Run from nix develop."
  
  toolchains <- lookupEnv "SENSENET_TOOLCHAINS" >>= \case
    Just t -> pure t
    Nothing -> fail "SENSENET_TOOLCHAINS not set. Run from nix develop."
  
  -- Create temp directory for generated files
  withSystemTempDirectory "sensenet" $ \tmp -> do
    cwd <- shelly pwd
    
    let cfg = Config
          { projectRoot = T.unpack $ toTextIgnore cwd
          , preludePath = prelude
          , toolchainsPath = toolchains
          , tmpDir = tmp
          }
    
    shelly $ do
      -- Discover BUILD.dhall files
      files <- liftIO $ discover (projectRoot cfg)
      echo $ "found " <> T.pack (show $ length files) <> " BUILD.dhall files"
      
      -- Generate project structure
      generate cfg files
      
      -- Execute in namespace (pass files for BUCK mounts)
      action cfg files
