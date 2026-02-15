{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : sense - the invisible build system

sense wraps Buck2 with Dhall configuration, making builds declarative
and typed while Buck2 handles execution invisibly.

Usage:
  sense build //target       Build a target
  sense build                Build current directory's targets
  sense run //target         Build and run
  sense gen                  Generate BUCK files from BUILD.dhall
  sense clean                Clean build outputs
  sense query <expr>         Query the build graph

Bootstrap:
  cabal build sense
-}
module Main where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, when)
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (fromMaybe)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode, spawnProcess, waitForProcess)

main :: IO ()
main = do
    args <- getArgs
    case args of
        [] -> usage
        ("build" : rest) -> cmdBuild rest
        ("run" : rest) -> cmdRun rest
        ("gen" : rest) -> cmdGen rest
        ("clean" : _) -> cmdClean
        ("query" : rest) -> cmdQuery rest
        ("targets" : rest) -> cmdTargets rest
        ("--version" : _) -> version
        ("-V" : _) -> version
        ("--help" : _) -> usage
        ("-h" : _) -> usage
        (cmd : _) -> do
            putStrLn $ "Unknown command: " <> cmd
            usage
            exitFailure

-- | Show version
version :: IO ()
version = do
    putStrLn "sense 0.1.0"
    putStrLn "Dhall + Buck2 build system"

-- | Show usage
usage :: IO ()
usage = do
    putStrLn "sense - typed builds with Dhall + Buck2"
    putStrLn ""
    putStrLn "Usage: sense <command> [options]"
    putStrLn ""
    putStrLn "Commands:"
    putStrLn "  build [target]     Build target(s)"
    putStrLn "  run <target>       Build and run"
    putStrLn "  gen [dir]          Generate BUCK from BUILD.dhall"
    putStrLn "  clean              Clean build outputs"
    putStrLn "  query <expr>       Query build graph"
    putStrLn "  targets [dir]      List targets in directory"
    putStrLn ""
    putStrLn "Options:"
    putStrLn "  --version, -V      Show version"
    putStrLn "  --help, -h         Show this help"
    putStrLn ""
    putStrLn "Examples:"
    putStrLn "  sense build                    # build all in current dir"
    putStrLn "  sense build //src/foo:bar      # build specific target"
    putStrLn "  sense run //src/hello:hello    # build and run"
    putStrLn "  sense gen src/                 # generate BUCK files"

-- | Build command
cmdBuild :: [String] -> IO ()
cmdBuild args = do
    let targets = if null args then [":"] else args

    -- First, regenerate BUCK files for any BUILD.dhall that changed
    forM_ targets $ \t -> do
        let dir = targetDir t
        genIfNeeded dir

    -- Then call buck2
    callBuck2 ("build" : targets)

-- | Run command
cmdRun :: [String] -> IO ()
cmdRun args = case args of
    [] -> do
        putStrLn "Usage: sense run <target>"
        exitFailure
    (target : rest) -> do
        let dir = targetDir target
        genIfNeeded dir
        callBuck2 ("run" : target : rest)

-- | Generate BUCK files from BUILD.dhall
cmdGen :: [String] -> IO ()
cmdGen args = do
    let dirs = if null args then ["."] else args
    forM_ dirs $ \dir -> genDir dir

-- | Clean build outputs
cmdClean :: IO ()
cmdClean = callBuck2 ["clean"]

-- | Query build graph
cmdQuery :: [String] -> IO ()
cmdQuery args = callBuck2 ("query" : args)

-- | List targets
cmdTargets :: [String] -> IO ()
cmdTargets args = do
    let dir = case args of
            [] -> "."
            (d : _) -> d
    genIfNeeded dir
    let pattern = "//" <> dir <> ":*"
    callBuck2 ["targets", pattern]

-- | Extract directory from target pattern
targetDir :: String -> FilePath
targetDir t
    | "//" `isPrefixOf` t =
        let withoutSlash = drop 2 t
            beforeColon = takeWhile (/= ':') withoutSlash
         in if null beforeColon then "." else beforeColon
    | ":" `isPrefixOf` t = "."
    | otherwise = "."

-- | Generate BUCK if BUILD.dhall exists and is newer
genIfNeeded :: FilePath -> IO ()
genIfNeeded dir = do
    let dhall = dir </> "BUILD.dhall"
        buck = dir </> "BUCK"
    hasDhall <- doesFileExist dhall
    when hasDhall $ do
        hasBuck <- doesFileExist buck
        if hasBuck
            then do
                -- Check if BUILD.dhall is newer
                -- For now, always regenerate (TODO: proper mtime check)
                genFile dhall buck
            else genFile dhall buck

-- | Generate BUCK file from BUILD.dhall
genFile :: FilePath -> FilePath -> IO ()
genFile dhallPath buckPath = do
    putStrLn $ "gen: " <> dhallPath <> " -> " <> buckPath
    
    -- First, check the dhall type to determine format
    (typeCode, typeOut, _) <- readProcessWithExitCode "dhall" ["type", "--file", dhallPath] ""
    
    case typeCode of
        ExitFailure _ -> do
            putStrLn $ "error: failed to type-check " <> dhallPath
            exitFailure
        ExitSuccess -> do
            let isNewFormat = "rules" `isInfixOf` typeOut && "header" `isInfixOf` typeOut
            
            if isNewFormat
                then genNewFormat dhallPath buckPath
                else genLegacyFormat dhallPath buckPath

-- | Generate BUCK from new format: { rules : List Text, header : Text }
genNewFormat :: FilePath -> FilePath -> IO ()
genNewFormat dhallPath buckPath = do
    -- Extract header using bash to handle dhall's path resolution
    (_, header, _) <- readProcessWithExitCode "bash" ["-c", 
        "dhall text <<< '(./" <> dhallPath <> ").header'"] ""
    
    -- Extract and join rules  
    let rulesCmd = "dhall text <<< 'let P = ./dhall/prelude/Prelude.dhall in P.Text.concatSep \"\\n\" (./" <> dhallPath <> ").rules'"
    (rulesCode, rules, rulesErr) <- readProcessWithExitCode "bash" ["-c", rulesCmd] ""
    
    case rulesCode of
        ExitFailure _ -> do
            putStrLn $ "error: failed to extract rules from " <> dhallPath
            putStrLn rulesErr
            exitFailure
        ExitSuccess -> do
            let content = unlines
                    [ "# Generated from " <> dhallPath
                    , header
                    , rules
                    ]
            writeFile buckPath content

-- | Generate BUCK from legacy format (fallback to dhall-to-buck script)
genLegacyFormat :: FilePath -> FilePath -> IO ()
genLegacyFormat dhallPath buckPath = do
    -- For legacy format, fall back to the bash script if it exists
    scriptExists <- doesFileExist "./dhall-to-buck"
    if scriptExists
        then do
            (code, out, err) <- readProcessWithExitCode "./dhall-to-buck" [dhallPath] ""
            case code of
                ExitSuccess -> writeFile buckPath out
                ExitFailure _ -> do
                    putStrLn $ "error: legacy dhall-to-buck failed for " <> dhallPath
                    putStrLn err
                    exitFailure
        else do
            putStrLn $ "error: legacy BUILD.dhall format not supported without dhall-to-buck script"
            putStrLn $ "  convert " <> dhallPath <> " to new format: { rules : List Text, header : Text }"
            exitFailure

-- | Generate all BUILD.dhall in a directory tree
genDir :: FilePath -> IO ()
genDir dir = do
    let dhall = dir </> "BUILD.dhall"
    hasDhall <- doesFileExist dhall
    when hasDhall $ do
        let buck = dir </> "BUCK"
        genFile dhall buck

    -- Recurse into subdirectories
    entries <- listDirectory dir
    forM_ entries $ \entry -> do
        let path = dir </> entry
        isDir <- doesDirectoryExist path
        when isDir $ genDir path

-- | Call buck2 with arguments
callBuck2 :: [String] -> IO ()
callBuck2 args = do
    -- Check for BUCK2 env var, otherwise use "buck2"
    buck2 <- fromMaybe "buck2" <$> lookupEnv "BUCK2"
    -- Check if buck2 exists
    result <- try $ spawnProcess buck2 args
    case result of
        Left (_ :: SomeException) -> do
            putStrLn "error: buck2 not found"
            putStrLn ""
            putStrLn "sense requires buck2 in PATH. Either:"
            putStrLn "  1. Run from devshell: nix develop"
            putStrLn "  2. Set BUCK2 env var: BUCK2=/path/to/buck2 sense build"
            exitFailure
        Right ph -> do
            code <- waitForProcess ph
            exitWith code
