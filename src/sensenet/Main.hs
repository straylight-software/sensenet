{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | sensenet — Direct builds with Dhall + DICE
--
-- No Buck2, no Starlark, no BUCK file generation.
-- Just: BUILD.dhall → IR → DICE → execute
module Main where

import Control.Concurrent.Async (forConcurrently, mapConcurrently)
import Control.Monad (forM_)
import Data.List (partition, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import SenseNet.Build (BuildError (..), BuildResult (..), build, buildWithConsole, buildWithDeps)
import SenseNet.DICE qualified as DICE
import SenseNet.Dhall qualified as Dhall
import SenseNet.Discover (DhallFile (..), discover)
import SenseNet.Emit qualified as Emit
import SenseNet.IR (Package (..), Rule, ruleName)
import SenseNet.Remote qualified as Remote
import SenseNet.Toolchains qualified as TC
import System.Directory (doesDirectoryExist, getCurrentDirectory, removeDirectoryRecursive)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (makeRelative, takeDirectory, (</>))
import System.Process (callProcess)

-- | Command-line options
data Options = Options
  { optRemote :: Bool,
    optRemoteHost :: String,
    optRemotePort :: Int,
    optWithDeps :: Bool, -- Use DICE-based dependency resolution
    optTUI :: Bool -- Use superconsole TUI
  }

defaultOptions :: Options
defaultOptions =
  Options
    { optRemote = False,
      optRemoteHost = "localhost",
      optRemotePort = 50051,
      optWithDeps = True, -- DICE-based dependency resolution is now the default
      optTUI = True -- Superconsole TUI is now the default (falls back gracefully)
    }

-- | Parse options from args, returning (options, remaining args)
parseOptions :: [String] -> (Options, [String])
parseOptions = go defaultOptions
  where
    go opts [] = (opts, [])
    go opts ("--remote" : rest) = go opts {optRemote = True} rest
    go opts ("--remote-host" : h : rest) = go opts {optRemoteHost = h} rest
    go opts ("--remote-port" : p : rest) = go opts {optRemotePort = read p} rest
    go opts ("--deps" : rest) = go opts {optWithDeps = True} rest
    go opts ("--no-deps" : rest) = go opts {optWithDeps = False} rest
    go opts ("--tui" : rest) = go opts {optTUI = True, optWithDeps = True} rest
    go opts ("--no-tui" : rest) = go opts {optTUI = False} rest
    go opts (x : rest) =
      let (opts', rest') = go opts rest
       in (opts', x : rest')

main :: IO ()
main = do
  args <- getArgs
  let (opts, args') = parseOptions args
  case args' of
    [] -> usage
    ("build" : rest) -> cmdBuild opts (map T.pack rest)
    ("run" : rest) -> cmdRun opts (map T.pack rest)
    ("clean" : _) -> cmdClean
    ("targets" : rest) -> cmdTargets (map T.pack rest)
    ("query" : rest) -> cmdTargets (map T.pack rest) -- alias
    ("graph" : _) -> cmdGraph
    ("emit" : rest) -> cmdEmit (map T.pack rest)
    ("test-remote" : _) -> cmdTestRemote opts
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
usage =
  putStrLn $
    unlines
      [ "sensenet — Direct builds with Dhall + DICE",
        "",
        "Usage: sensenet <command> [options]",
        "",
        "Commands:",
        "  build [target]     Build target(s)",
        "  run <target> [--]  Build and run a target",
        "  clean              Remove build outputs (sensenet-out/)",
        "  targets [pattern]  List available targets",
        "  query [pattern]    Alias for targets",
        "  graph              Show build graph",
        "  emit [pkg]         Emit BUCK file for Buck2 fiction",
        "  test-remote        Test connection to remote executor",
        "",
        "Options:",
        "  --no-tui           Disable superconsole TUI (use plain text output)",
        "  --no-deps          Disable dependency resolution (legacy mode)",
        "  --remote           Execute builds remotely via NativeLink",
        "  --remote-host H    Remote executor host (default: localhost)",
        "  --remote-port P    Remote executor port (default: 50051)",
        "  --version, -V      Show version",
        "  --help, -h         Show this help",
        "",
        "Examples:",
        "  sensenet build                       # build all locally",
        "  sensenet build //src/examples/cxx:hello-cxx",
        "  sensenet build --no-tui //pkg:target  # build with plain text output",
        "  sensenet build --no-deps //pkg:target # legacy build without dep resolution",
        "  sensenet build --remote //pkg:target # build remotely",
        "  sensenet run //src/examples/rust:math_demo",
        "  sensenet clean                       # remove sensenet-out/",
        "  sensenet targets                     # list all targets",
        "",
        "Output goes to sensenet-out/"
      ]

-- ════════════════════════════════════════════════════════════════════════════
-- Commands
-- ════════════════════════════════════════════════════════════════════════════

cmdBuild :: Options -> [Text] -> IO ()
cmdBuild opts args = do
  projectRoot <- getCurrentDirectory

  -- Load toolchains
  let tcPath = TC.defaultToolchainsPath projectRoot
  tc <- TC.loadToolchains tcPath

  -- Remote config if --remote flag set
  let remoteCfg =
        if opts.optRemote
          then
            Just
              Remote.RemoteConfig
                { Remote.host = opts.optRemoteHost,
                  Remote.port = opts.optRemotePort,
                  Remote.useTLS = False,
                  Remote.instanceName = "main"
                }
          else Nothing

  case args of
    [] -> do
      -- Build all targets
      files <- discover projectRoot
      TIO.putStrLn $ "Found " <> T.pack (show $ length files) <> " BUILD.dhall files"
      -- Parse all BUILD.dhall files in parallel
      pkgs <- mapConcurrently (\file -> Dhall.parsePackageFile projectRoot (dhallPath file)) files
      forM_ pkgs $ \pkg -> do
        forM_ pkg.rules $ \rule -> do
          buildTarget opts remoteCfg tc projectRoot pkg (ruleName rule)
    targets -> do
      -- Build each specified target - parse in parallel
      let parseOne target = case parseTarget target of
            Nothing -> do
              TIO.putStrLn $ "Invalid target: " <> target
              TIO.putStrLn "Expected format: //path/to/pkg:target"
              exitFailure
            Just (pkgPath, targetName) -> do
              let dhallPath' = projectRoot </> T.unpack pkgPath </> "BUILD.dhall"
              pkg <- Dhall.parsePackageFile projectRoot dhallPath'
              pure (pkg, targetName)
      parsed <- mapConcurrently parseOne targets
      forM_ parsed $ \(pkg, targetName) -> do
        buildTarget opts remoteCfg tc projectRoot pkg targetName

buildTarget :: Options -> Maybe Remote.RemoteConfig -> TC.Toolchains -> FilePath -> Package -> Text -> IO ()
buildTarget opts remoteCfg tc projectRoot pkg targetName = do
  case remoteCfg of
    Just cfg -> do
      TIO.putStrLn $ "Building (remote) " <> T.pack pkg.path <> ":" <> targetName
      result <- Remote.remoteBuild cfg tc projectRoot pkg targetName
      case result of
        Left err -> do
          TIO.putStrLn $ "  x " <> err
          exitFailure
        Right outputs -> do
          TIO.putStrLn $ "  v Built: " <> T.intercalate ", " (map T.pack outputs)
    Nothing -> do
      if opts.optTUI
        then do
          -- Use superconsole TUI with DICE dependency resolution
          result <- buildWithConsole tc projectRoot pkg targetName
          case result of
            Left err -> do
              TIO.putStrLn $ "  x " <> showError err
              exitFailure
            Right (BuildSuccess outputs) -> do
              TIO.putStrLn $ "  v Built: " <> T.intercalate ", " (map T.pack outputs)
            Right (BuildCached outputs) -> do
              TIO.putStrLn $ "  v Cached: " <> T.intercalate ", " (map T.pack outputs)
        else
          if opts.optWithDeps
            then do
              -- Use DICE-based dependency resolution (text output)
              TIO.putStrLn $ "Building (with deps) " <> T.pack pkg.path <> ":" <> targetName
              result <- buildWithDeps tc projectRoot pkg targetName
              case result of
                Left err -> do
                  TIO.putStrLn $ "  x " <> showError err
                  exitFailure
                Right (BuildSuccess outputs) -> do
                  TIO.putStrLn $ "  v Built: " <> T.intercalate ", " (map T.pack outputs)
                Right (BuildCached outputs) -> do
                  TIO.putStrLn $ "  v Cached: " <> T.intercalate ", " (map T.pack outputs)
            else do
              -- Legacy build (no dep resolution)
              TIO.putStrLn $ "Building " <> T.pack pkg.path <> ":" <> targetName
              result <- build tc projectRoot pkg targetName
              case result of
                Left err -> do
                  TIO.putStrLn $ "  x " <> showError err
                  exitFailure
                Right (BuildSuccess outputs) -> do
                  TIO.putStrLn $ "  v Built: " <> T.intercalate ", " (map T.pack outputs)
                Right (BuildCached outputs) -> do
                  TIO.putStrLn $ "  v Cached: " <> T.intercalate ", " (map T.pack outputs)

cmdTestRemote :: Options -> IO ()
cmdTestRemote opts = do
  let cfg =
        Remote.RemoteConfig
          { Remote.host = opts.optRemoteHost,
            Remote.port = opts.optRemotePort,
            Remote.useTLS = False,
            Remote.instanceName = "main"
          }
  TIO.putStrLn $ "Testing connection to " <> T.pack opts.optRemoteHost <> ":" <> T.pack (show opts.optRemotePort)
  result <- Remote.testConnection cfg
  case result of
    Left err -> do
      TIO.putStrLn $ "  x Connection failed: " <> err
      exitFailure
    Right caps -> do
      TIO.putStrLn "  v Connected!"
      TIO.putStrLn $ "  Capabilities: " <> caps

showError :: BuildError -> Text
showError = \case
  SourceNotFound path -> "Source not found: " <> T.pack path
  CompileFailed _cmd code stderr ->
    "Compile failed (exit " <> T.pack (show code) <> "): " <> stderr
  LinkFailed _cmd code stderr ->
    "Link failed (exit " <> T.pack (show code) <> "): " <> stderr
  DICEFailed err -> "DICE error: " <> T.pack (show err)
  TargetNotFound name -> "Target not found: " <> name
  UnsupportedRule rule -> "Unsupported rule type: " <> rule
  PackageNotFound pkgPath -> "Package not found: " <> pkgPath <> " (no BUILD.dhall)"

-- | Parse //path/to/pkg:target
parseTarget :: Text -> Maybe (Text, Text)
parseTarget t = do
  rest <- T.stripPrefix "//" t
  case T.breakOn ":" rest of
    (_, "") -> Nothing -- No colon found
    (pkgPath, colonTarget) -> Just (pkgPath, T.drop 1 colonTarget)

cmdTargets :: [Text] -> IO ()
cmdTargets _ = do
  projectRoot <- getCurrentDirectory
  files <- discover projectRoot
  -- Parse all BUILD.dhall files in parallel
  pkgs <- mapConcurrently (\file -> Dhall.parsePackageFile projectRoot (dhallPath file)) files
  -- Print targets in sorted order for deterministic output
  let targets =
        sortOn
          id
          [ "//" <> T.pack pkg.path <> ":" <> ruleName rule
          | pkg <- pkgs,
            rule <- pkg.rules
          ]
  mapM_ TIO.putStrLn targets

cmdGraph :: IO ()
cmdGraph = do
  projectRoot <- getCurrentDirectory
  files <- discover projectRoot
  -- Parse all BUILD.dhall files in parallel
  pkgs <- mapConcurrently (\file -> Dhall.parsePackageFile projectRoot (dhallPath file)) files
  -- Print in sorted order for deterministic output
  forM_ (sortOn (.path) pkgs) $ \pkg -> do
    TIO.putStrLn $ "# " <> T.pack pkg.path
    forM_ pkg.rules $ \rule -> do
      TIO.putStrLn $ "  " <> ruleName rule

cmdClean :: IO ()
cmdClean = do
  projectRoot <- getCurrentDirectory
  let outDir = projectRoot </> "sensenet-out"
  exists <- doesDirectoryExist outDir
  if exists
    then do
      TIO.putStrLn $ "Removing " <> T.pack outDir
      removeDirectoryRecursive outDir
      TIO.putStrLn "  v Clean complete"
    else do
      TIO.putStrLn "Nothing to clean (sensenet-out/ does not exist)"

-- | Emit BUCK file for a package (the "Buck2 fiction")
cmdEmit :: [Text] -> IO ()
cmdEmit args = do
  projectRoot <- getCurrentDirectory
  let (flags, targets) = partition (\a -> T.isPrefixOf "--" a || T.isPrefixOf "-" a) args
      writeMode = "--write" `elem` flags || "-w" `elem` flags

  -- Discover all packages or use specified targets
  files <- discover projectRoot
  pkgs <- mapConcurrently (\file -> Dhall.parsePackageFile projectRoot (dhallPath file)) files

  let targetPkgs = case targets of
        [] -> pkgs
        ts -> filter (\pkg -> any (matchesTarget pkg) ts) pkgs

  forM_ (sortOn (.path) targetPkgs) $ \pkg -> do
    let buckContent = Emit.emitBuck pkg
        buckPath = projectRoot </> pkg.path </> "BUCK"
    if writeMode
      then do
        TIO.writeFile buckPath buckContent
        TIO.putStrLn $ "Wrote " <> T.pack buckPath
      else do
        TIO.putStrLn $ "# " <> T.pack pkg.path <> "/BUCK"
        TIO.putStrLn buckContent
        TIO.putStrLn ""
  where
    matchesTarget pkg target =
      T.pack pkg.path == target
        || T.pack pkg.path == T.dropWhile (== '/') target
        || T.pack ("//" <> pkg.path) == target

cmdRun :: Options -> [Text] -> IO ()
cmdRun opts args = do
  case args of
    [] -> do
      TIO.putStrLn "Usage: sensenet run //path/to/pkg:target [-- args...]"
      exitFailure
    (target : rest) -> do
      projectRoot <- getCurrentDirectory

      -- Parse target
      case parseTarget target of
        Nothing -> do
          TIO.putStrLn $ "Invalid target: " <> target
          TIO.putStrLn "Expected format: //path/to/pkg:target"
          exitFailure
        Just (pkgPath, targetName) -> do
          -- Load toolchains
          let tcPath = TC.defaultToolchainsPath projectRoot
          tc <- TC.loadToolchains tcPath

          -- Build the target first (always with deps for run)
          let dhallPath' = projectRoot </> T.unpack pkgPath </> "BUILD.dhall"
          pkg <- Dhall.parsePackageFile projectRoot dhallPath'

          result <-
            if opts.optTUI
              then buildWithConsole tc projectRoot pkg targetName
              else do
                TIO.putStrLn $ "Building " <> T.pack pkg.path <> ":" <> targetName
                buildWithDeps tc projectRoot pkg targetName

          case result of
            Left err -> do
              TIO.putStrLn $ "  x " <> showError err
              exitFailure
            Right (BuildSuccess outputs) -> runOutput projectRoot outputs rest
            Right (BuildCached outputs) -> runOutput projectRoot outputs rest

-- | Run the first output binary with optional arguments
runOutput :: FilePath -> [FilePath] -> [Text] -> IO ()
runOutput projectRoot outputs args = do
  case outputs of
    [] -> do
      TIO.putStrLn "  x No outputs to run"
      exitFailure
    (output : _) -> do
      let execPath = projectRoot </> output
      TIO.putStrLn $ "  v Built: " <> T.pack output
      TIO.putStrLn $ "Running: " <> T.pack execPath
      TIO.putStrLn ""
      -- Filter out "--" if present at the start of args
      let execArgs = map T.unpack $ filter (/= "--") args
      callProcess execPath execArgs
