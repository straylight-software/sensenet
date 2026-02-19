{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | sensenet — Direct builds with Dhall + DICE
--
-- No Buck2, no Starlark, no BUCK file generation.
-- Just: BUILD.dhall → IR → DICE → execute
module Main where

import Control.Concurrent.Async (forConcurrently, mapConcurrently)
import Control.Exception (SomeException, catch)
import Control.Monad (forM, forM_, when)
import Data.List (partition, sortOn)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import SenseNet.Build (BuildError (..), BuildResult (..), build, buildMultipleStub, buildMultipleWithBrickTUI, buildWithBrickTUI, buildWithConsole, buildWithDeps)
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
    optTUI :: Bool, -- Use superconsole TUI
    optStub :: Bool -- Stub mode: create empty outputs instantly (for TUI development)
  }

defaultOptions :: Options
defaultOptions =
  Options
    { optRemote = False,
      optRemoteHost = "localhost",
      optRemotePort = 50051,
      optWithDeps = True, -- DICE-based dependency resolution is now the default
      optTUI = True, -- Superconsole TUI is now the default (falls back gracefully)
      optStub = False -- Real builds by default
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
    go opts ("--stub" : rest) = go opts {optStub = True} rest
    go opts (x : rest) =
      let (opts', rest') = go opts rest
       in (opts', x : rest')

main :: IO ()
main = mainBody `catch` handleException
  where
    handleException :: SomeException -> IO ()
    handleException e = do
      -- Check if it's a user interrupt (Ctrl+C)
      let msg = show e
      if "user interrupt" `isInfixOf` msg || "AsyncCancelled" `isInfixOf` msg
        then do
          TIO.putStrLn "\nBuild interrupted."
        else do
          TIO.putStrLn $ "\nError: " <> T.pack msg
      exitFailure

    isInfixOf needle haystack = needle `elem` (map (take (length needle)) $ tails haystack)
    tails [] = [[]]
    tails xs@(_ : xs') = xs : tails xs'

mainBody :: IO ()
mainBody = do
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
    ("--complete" : rest) -> cmdComplete (map T.pack rest)
    ("--completion-script" : "bash" : _) -> TIO.putStrLn bashCompletionScript
    ("--completion-script" : "zsh" : _) -> TIO.putStrLn zshCompletionScript
    ("--completion-script" : _) -> do
      TIO.putStrLn "Usage: sensenet --completion-script <bash|zsh>"
      exitFailure
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
        "  build <target>     Build target(s)",
        "  run <target> [--]  Build and run a target",
        "  clean              Remove build outputs (sensenet-out/)",
        "  targets [pattern]  List available targets",
        "  query [pattern]    Alias for targets",
        "  graph              Show build graph",
        "  emit [pkg]         Emit BUCK file for Buck2 fiction",
        "  test-remote        Test connection to remote executor",
        "",
        "Target patterns:",
        "  //path/to/pkg:target   Single target",
        "  //...                  All targets in project",
        "  //path/to/...          All targets under path",
        "",
        "Options:",
        "  --no-tui           Disable TUI (use plain text output)",
        "  --no-deps          Disable dependency resolution (legacy mode)",
        "  --remote           Execute builds remotely via NativeLink",
        "  --remote-host H    Remote executor host (default: localhost)",
        "  --remote-port P    Remote executor port (default: 50051)",
        "  --version, -V      Show version",
        "  --help, -h         Show this help",
        "",
        "Examples:",
        "  sensenet build //src/examples/cxx:hello-cxx",
        "  sensenet build //...                 # build all targets",
        "  sensenet build //src/examples/...    # build all examples",
        "  sensenet build --no-tui //pkg:target # build with plain text output",
        "  sensenet build --remote //pkg:target # build remotely",
        "  sensenet run //src/examples/rust:math_demo",
        "  sensenet clean                       # remove sensenet-out/",
        "  sensenet targets                     # list all targets",
        "",
        "Shell completion:",
        "  eval \"$(sensenet --completion-script bash)\"  # bash",
        "  eval \"$(sensenet --completion-script zsh)\"   # zsh",
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
      -- No args = show usage hint
      TIO.putStrLn "Usage: sensenet build //path/to/pkg:target"
      TIO.putStrLn "       sensenet build //...              (build all)"
      TIO.putStrLn "       sensenet build //path/...         (build all in path)"
    patterns -> do
      -- Parse all patterns and expand them
      allTargets <- fmap concat $ forM patterns $ \pattern -> do
        case parseTargetPattern pattern of
          Nothing -> do
            TIO.putStrLn $ "Invalid target pattern: " <> pattern
            TIO.putStrLn "Expected: //path/to/pkg:target, //..., or //path/..."
            exitFailure
          Just PatternAll -> do
            -- Build all targets in the project
            files <- discover projectRoot
            pkgs <- mapConcurrently (\file -> Dhall.parsePackageFile projectRoot (dhallPath file)) files
            pure [(pkg, ruleName rule) | pkg <- pkgs, rule <- pkg.rules]
          Just (PatternPath pathPrefix) -> do
            -- Build all targets under a path prefix
            files <- discover projectRoot
            let prefix = T.unpack pathPrefix
                matchingFiles = filter (\f -> prefix `isPrefixOf` makeRelative projectRoot (dhallPath f)) files
            pkgs <- mapConcurrently (\file -> Dhall.parsePackageFile projectRoot (dhallPath file)) matchingFiles
            pure [(pkg, ruleName rule) | pkg <- pkgs, rule <- pkg.rules]
          Just (PatternSingle pkgPath targetName) -> do
            let dhallPath' = projectRoot </> T.unpack pkgPath </> "BUILD.dhall"
            pkg <- Dhall.parsePackageFile projectRoot dhallPath'
            pure [(pkg, targetName)]

      -- Report what we're building
      let targetCount = length allTargets
      when (targetCount > 1) $
        TIO.putStrLn $
          "Building " <> T.pack (show targetCount) <> " targets..."

      -- Build all targets
      case remoteCfg of
        Just _ -> do
          -- Remote builds are still sequential
          forM_ allTargets $ \(pkg, targetName) -> do
            buildTarget opts remoteCfg tc projectRoot pkg targetName
        Nothing -> do
          if opts.optStub && targetCount > 0
            then do
              -- Stub mode: instant fake builds for TUI development
              result <- buildMultipleStub tc projectRoot allTargets
              case result of
                Left err -> do
                  TIO.putStrLn $ "Build failed: " <> showError err
                  exitFailure
                Right _ -> do
                  TIO.putStrLn $ "[stub] Built " <> T.pack (show targetCount) <> " targets"
            else
              if opts.optTUI && targetCount > 0
                then do
                  -- Use single TUI session for all targets (parallel)
                  result <- buildMultipleWithBrickTUI tc projectRoot allTargets
                  case result of
                    Left err -> do
                      TIO.putStrLn $ "Build failed: " <> showError err
                      exitFailure
                    Right results -> do
                      -- Count successes
                      let successes = length [() | BuildSuccess _ <- results]
                          cached = length [() | BuildCached _ <- results]
                      TIO.putStrLn $ "Built " <> T.pack (show successes) <> " targets, " <> T.pack (show cached) <> " cached"
                else do
                  -- Non-TUI: build sequentially
                  forM_ allTargets $ \(pkg, targetName) -> do
                    buildTarget opts remoteCfg tc projectRoot pkg targetName
  where
    isPrefixOf prefix str = take (length prefix) str == prefix

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
          -- Use Brick TUI with DICE dependency resolution
          result <- buildWithBrickTUI tc projectRoot pkg targetName
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

-- | Target pattern types
data TargetPattern
  = -- | Build all targets: //...
    PatternAll
  | -- | Build all in path: //path/to/...
    PatternPath Text
  | -- | Single target: //path/to/pkg:target
    PatternSingle Text Text
  deriving (Show, Eq)

-- | Parse target pattern (supports //..., //path/..., //path:target)
parseTargetPattern :: Text -> Maybe TargetPattern
parseTargetPattern t = do
  rest <- T.stripPrefix "//" t
  if rest == "..."
    then Just PatternAll
    else
      if "..." `T.isSuffixOf` rest
        then Just $ PatternPath (T.dropEnd 3 rest) -- drop "..."
        else case T.breakOn ":" rest of
          (_, "") -> Nothing -- No colon found
          (pkgPath, colonTarget) -> Just $ PatternSingle pkgPath (T.drop 1 colonTarget)

-- | Parse //path/to/pkg:target (legacy, for backward compat)
parseTarget :: Text -> Maybe (Text, Text)
parseTarget t = case parseTargetPattern t of
  Just (PatternSingle pkg target) -> Just (pkg, target)
  _ -> Nothing

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
              then buildWithBrickTUI tc projectRoot pkg targetName
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

-- ════════════════════════════════════════════════════════════════════════════
-- Shell Completion
-- ════════════════════════════════════════════════════════════════════════════

-- | Generate completions for shell integration
-- Usage: sensenet --complete <word> [prev-word]
cmdComplete :: [Text] -> IO ()
cmdComplete args = do
  projectRoot <- getCurrentDirectory
  let (word, prevWord) = case args of
        [] -> ("", "")
        [w] -> (w, "")
        (w : p : _) -> (w, p)

  case prevWord of
    -- After "build" or "run", complete targets
    "build" -> completeTargets projectRoot word
    "run" -> completeTargets projectRoot word
    -- Default: complete commands or targets if starts with //
    _ ->
      if "//" `T.isPrefixOf` word
        then completeTargets projectRoot word
        else completeCommands word

-- | Complete available commands
completeCommands :: Text -> IO ()
completeCommands prefix = do
  let commands = ["build", "run", "clean", "targets", "query", "graph", "emit", "test-remote", "--version", "--help"]
      matches = filter (prefix `T.isPrefixOf`) commands
  mapM_ TIO.putStrLn matches

-- | Complete targets (supports partial paths)
completeTargets :: FilePath -> Text -> IO ()
completeTargets projectRoot prefix = do
  files <- discover projectRoot
  pkgs <- mapConcurrently (\file -> Dhall.parsePackageFile projectRoot (dhallPath file)) files

  let allTargets =
        [ "//" <> T.pack pkg.path <> ":" <> ruleName rule
        | pkg <- pkgs,
          rule <- pkg.rules
        ]
      -- Also add //... and path patterns
      allPaths = nub ["//" <> T.pack pkg.path <> "/..." | pkg <- pkgs]
      allCompletions = "//..." : sortOn id (allTargets ++ allPaths)
      matches = filter (prefix `T.isPrefixOf`) allCompletions

  mapM_ TIO.putStrLn matches
  where
    nub [] = []
    nub (x : xs) = x : nub (filter (/= x) xs)

-- | Print shell completion script
-- Usage: sensenet --completion-script bash
--        sensenet --completion-script zsh
bashCompletionScript :: Text
bashCompletionScript =
  T.unlines
    [ "# Bash completion for sensenet",
      "# Add to ~/.bashrc: eval \"$(sensenet --completion-script bash)\"",
      "_sensenet_completions() {",
      "    local cur prev",
      "    cur=\"${COMP_WORDS[COMP_CWORD]}\"",
      "    prev=\"${COMP_WORDS[COMP_CWORD-1]}\"",
      "",
      "    COMPREPLY=($(compgen -W \"$(sensenet --complete \"$cur\" \"$prev\" 2>/dev/null)\" -- \"$cur\"))",
      "}",
      "",
      "complete -F _sensenet_completions sensenet",
      "complete -F _sensenet_completions sense"
    ]

zshCompletionScript :: Text
zshCompletionScript =
  T.unlines
    [ "# Zsh completion for sensenet",
      "# Add to ~/.zshrc: eval \"$(sensenet --completion-script zsh)\"",
      "_sensenet() {",
      "    local -a completions",
      "    completions=($(sensenet --complete \"${words[CURRENT]}\" \"${words[CURRENT-1]}\" 2>/dev/null))",
      "    _describe 'sensenet' completions",
      "}",
      "",
      "compdef _sensenet sensenet",
      "compdef _sensenet sense"
    ]
