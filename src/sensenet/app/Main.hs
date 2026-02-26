{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- sensenet — the best build system in the world
--
-- Pure Haskell. Content-addressed. Coeffect-tracked.
-- No FFI. No daemon. Static binary.
module Main where

-- SenseNet.DICE used by Build module

import Control.Concurrent.Async (forConcurrently)
import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.Either (partitionEithers)
import Data.List (isInfixOf, isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import GHC.Conc (getNumProcessors)
import SenseNet.Build (BuildError (..), BuildResult (..), ProgressCallback, ProgressEvent (..), buildAllPackagesWithProgress, buildAllTargetsWithProgress, buildWithProgress)
import SenseNet.Complete qualified as Complete
import SenseNet.Dhall qualified as Dhall
import SenseNet.Discover (DhallFile (..), discover, discoverUnder)
import SenseNet.IR (Dep (..), Package (..), Rule (..), ruleDeps, ruleKind, ruleName, ruleSrcs)
import SenseNet.Output qualified as Output
import SenseNet.Toolchains qualified as TC
import System.Directory (XdgDirectory (..), doesDirectoryExist, getCurrentDirectory, getXdgDirectory, removeDirectoryRecursive)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess, exitWith)
import System.IO (BufferMode (..), hSetBuffering, stderr, stdout)
import System.Process (rawSystem)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  args <- getArgs
  case args of
    [] -> usage >> exitFailure -- No command specified
    ["--version"] -> version
    ["-V"] -> version
    ["--help"] -> usage -- Explicit help request exits 0
    ["-h"] -> usage
    ("--complete" : rest) -> cmdComplete rest
    ("complete" : rest) -> cmdCompleteScript rest
    ("build" : rest) -> cmdBuild rest
    ("run" : rest) -> cmdRun rest
    ("query" : rest) -> cmdQuery rest
    ("targets" : _) -> cmdTargets
    ("clean" : rest) -> cmdClean ("--full" `elem` rest)
    (cmd : _) -> do
      TIO.putStrLn $ "Unknown command: " <> T.pack cmd
      usage
      exitFailure

version :: IO ()
version = do
  TIO.putStrLn "sensenet 0.4.0"
  TIO.putStrLn "Pure Haskell • Content-addressed • Coeffect-tracked"

usage :: IO ()
usage = do
  numCores <- getNumProcessors
  let defaultJobs = max 1 (numCores * 4 `div` 5) -- 80% of cores
  TIO.putStrLn $
    T.unlines
      [ "sensenet — the best build system in the world",
        "",
        "Usage: sensenet <command> [options]",
        "",
        "Commands:",
        "  build <target> [-j N]  Build target(s) with N parallel jobs",
        "  run <target> [-- args] Build and run a target, passing args to it",
        "  targets                List available targets",
        "  clean [--full]         Remove build outputs (--full: also clear cache)",
        "  query <target>#<sel>   Query the build graph",
        "  complete <shell>       Generate shell completion script (bash/zsh/fish)",
        "",
        "Query selectors:",
        "  #deps                  Transitive dependencies",
        "  #rdeps                 Reverse dependencies (what depends on this)",
        "  #inputs                Source files",
        "  #kind/<type>           Filter by rule kind (e.g. #kind/rust_binary)",
        "  #attrs                 All attributes",
        "",
        "Query options:",
        "  --limit N              Limit dependency traversal depth",
        "  --json                 Output as JSON",
        "  --dot                  Output as GraphViz dot (for #deps, #rdeps)",
        "",
        "Target patterns:",
        "  //path/to/pkg:target   Single target",
        "  //path/to/pkg:all      All targets in package",
        "  //path/...             All targets recursively",
        "  //...                  All targets in project",
        "",
        "Build options:",
        "  -j N, --jobs=N         Limit parallel jobs (default: " <> T.pack (show defaultJobs) <> ", 80% of cores)",
        "  --all-cores            Use all cores (unlimited parallelism)",
        "  --stub                 Dry run: show what would be built",
        "  --no-tui               Disable TUI output (plain text only)",
        "  -v, --verbose          Enable structured logging (Katip JSON output)",
        "",
        "Shell completion:",
        "  eval \"$(sensenet complete bash)\"   # Add to ~/.bashrc",
        "  eval \"$(sensenet complete zsh)\"    # Add to ~/.zshrc",
        "  sensenet complete fish | source     # Add to ~/.config/fish/config.fish",
        "",
        "Examples:",
        "  sensenet build //src/examples/cxx:hello",
        "  sensenet build //src/examples/... -j4",
        "  sensenet run //src/examples/cxx:hello -- arg1 arg2",
        "  sensenet targets"
      ]

-- ════════════════════════════════════════════════════════════════════════════
-- Commands
-- ════════════════════════════════════════════════════════════════════════════

-- | Job limit specification
data JobsSpec
  = JobsDefault -- Use 80% of cores
  | JobsUnlimited -- --all-cores: no limit
  | JobsExact Int -- -j N: exactly N jobs
  deriving (Eq, Show)

-- | Build options parsed from command line
data BuildOpts = BuildOpts
  { boJobs :: !JobsSpec,
    boStub :: !Bool, -- --stub: dry run, don't actually build
    boNoTui :: !Bool, -- --no-tui: disable TUI (currently no-op, no TUI yet)
    boVerbose :: !Bool -- --verbose/-v: enable structured logging
  }

defaultBuildOpts :: BuildOpts
defaultBuildOpts =
  BuildOpts
    { boJobs = JobsDefault,
      boStub = False,
      boNoTui = False,
      boVerbose = False
    }

-- | Parse build options from args
-- Returns (BuildOpts, remaining args)
parseBuildOpts :: [String] -> (BuildOpts, [String])
parseBuildOpts = go defaultBuildOpts
  where
    go opts [] = (opts, [])
    go opts ("--all-cores" : rest) = go opts {boJobs = JobsUnlimited} rest
    go opts ("--stub" : rest) = go opts {boStub = True} rest
    go opts ("--no-tui" : rest) = go opts {boNoTui = True} rest
    go opts ("--verbose" : rest) = go opts {boVerbose = True} rest
    go opts ("-v" : rest) = go opts {boVerbose = True} rest
    go opts ("-j" : n : rest)
      | all isDigit n = go opts {boJobs = JobsExact (read n)} rest
    go opts (arg : rest)
      | "-j" `isPrefixOf` arg && all isDigit (drop 2 arg) =
          go opts {boJobs = JobsExact (read (drop 2 arg))} rest
      | "--jobs=" `isPrefixOf` arg && all isDigit (drop 7 arg) =
          go opts {boJobs = JobsExact (read (drop 7 arg))} rest
    go opts (arg : rest) =
      let (opts', rest') = go opts rest
       in (opts', arg : rest')

-- | Resolve JobsSpec to Maybe Int for the executor
resolveJobs :: JobsSpec -> IO (Maybe Int)
resolveJobs JobsDefault = do
  numCores <- getNumProcessors
  pure $ Just $ max 1 (numCores * 4 `div` 5) -- 80% of cores
resolveJobs JobsUnlimited = pure Nothing
resolveJobs (JobsExact n) = pure $ Just n

cmdBuild :: [String] -> IO ()
cmdBuild [] = do
  TIO.putStrLn "Usage: sensenet build //path/to/pkg:target [-j N]"
  exitFailure
cmdBuild args = Output.withAutoPresenter $ \presenter -> do
  let (opts, rest) = parseBuildOpts args
  mJobs <- resolveJobs opts.boJobs
  -- Note: Katip logging (--verbose) is deprecated in favor of typed output
  -- The presenter now handles all output formatting based on context
  case rest of
    [] -> do
      TIO.putStrLn "Usage: sensenet build //path/to/pkg:target [-j N]"
      exitFailure
    targets -> do
      -- Parse all targets
      let parsedTargets = [(t, parseTarget (T.pack t)) | t <- targets]
          invalidTargets = [t | (t, Nothing) <- parsedTargets]
      if not (null invalidTargets)
        then do
          Output.emitErrorIO presenter $
            Output.ConfigError $
              "Invalid target(s): " <> T.pack (unwords invalidTargets) <> "\nExpected: //path/to/pkg:target, //path/to/pkg:all, or //..."
          exitFailure
        else do
          let validTargets = [p | (_, Just p) <- parsedTargets]
          -- Stub mode: just print what would be built
          if opts.boStub
            then do
              TIO.putStrLn $ "[stub] Would build " <> T.pack (show (length validTargets)) <> " target(s):"
              mapM_ (TIO.putStrLn . ("[stub]   " <>) . showPattern) validTargets
              exitSuccess
            else buildTargets presenter mJobs validTargets

buildTargets :: Output.Presenter -> Maybe Int -> [TargetPattern] -> IO ()
buildTargets presenter mJobs patterns = case patterns of
  [] -> exitSuccess
  [pattern] -> buildSinglePattern presenter mJobs pattern
  _ -> do
    -- Multiple targets: build each one
    projectRoot <- getCurrentDirectory
    tc <- TC.loadToolchains (TC.defaultToolchainsPath projectRoot)
    let callback = progressToOutput presenter
    Output.emitProgressIO presenter $ Output.ProgressCount 0 (length patterns)
    results <- mapM (buildPatternResult mJobs callback tc projectRoot) patterns
    let failures = length [() | Left _ <- results]
        successes = length [() | Right _ <- results]
    if failures > 0
      then do
        Output.emitErrorIO presenter $
          Output.BuildFailed
            "multi"
            (T.pack (show failures) <> " failed, " <> T.pack (show successes) <> " succeeded")
            Nothing
        exitFailure
      else do
        Output.emitResultIO presenter $
          Output.TextResult $
            "Built " <> T.pack (show successes) <> " targets"
        exitSuccess

buildPatternResult :: Maybe Int -> ProgressCallback -> TC.Toolchains -> FilePath -> TargetPattern -> IO (Either BuildError BuildResult)
buildPatternResult mJobs callback tc projectRoot = \case
  SingleTarget pkgPath targetName -> do
    let dhallPath = projectRoot <> "/" <> T.unpack pkgPath <> "/BUILD.dhall"
    pkg <- Dhall.parsePackageFile projectRoot dhallPath
    buildWithProgress mJobs callback tc projectRoot pkg targetName
  AllInPackage pkgPath -> do
    let dhallPath = projectRoot <> "/" <> T.unpack pkgPath <> "/BUILD.dhall"
    pkg <- Dhall.parsePackageFile projectRoot dhallPath
    result <- buildAllTargetsWithProgress mJobs callback tc projectRoot pkg
    pure $ fmap (BuildSuccess . (\n -> [show n <> " targets"])) result
  Recursive subPath -> do
    -- Build all packages under this path with progress
    let startDir = if T.null subPath then projectRoot else projectRoot <> "/" <> T.unpack subPath
    files <- discoverUnder projectRoot startDir
    if null files
      then pure $ Left $ CommandFailed "recursive" 1 $ "No BUILD.dhall files found under //" <> subPath <> "..."
      else do
        pkgs <- forConcurrently files $ \f -> Dhall.parsePackageFile projectRoot (dhallPath f)
        result <- buildAllPackagesWithProgress mJobs callback tc projectRoot pkgs
        pure $ fmap (BuildSuccess . (\n -> [show n <> " targets"])) result

buildSinglePattern :: Output.Presenter -> Maybe Int -> TargetPattern -> IO ()
buildSinglePattern presenter mJobs pat = do
  projectRoot <- getCurrentDirectory
  tc <- TC.loadToolchains (TC.defaultToolchainsPath projectRoot)
  case pat of
    SingleTarget pkgPath targetName -> do
      let target = "//" <> pkgPath <> ":" <> targetName
          dhallPath = projectRoot <> "/" <> T.unpack pkgPath <> "/BUILD.dhall"
      pkgResult <- try $ Dhall.parsePackageFile projectRoot dhallPath
      case pkgResult of
        Left (e :: IOException) -> do
          Output.emitErrorIO presenter $
            Output.ConfigError $
              "Cannot read package: " <> T.pack (show e)
          exitFailure
        Right pkg -> do
          Output.emitProgressIO presenter $ Output.Building target
          -- Use buildWithProgress for typed progress output
          let callback = progressToOutput presenter
          result <- buildWithProgress mJobs callback tc projectRoot pkg targetName
          case result of
            Left err -> do
              Output.emitErrorIO presenter $ buildErrorToOutput target err
              exitFailure
            Right (BuildSuccess outputs) -> do
              Output.emitResultIO presenter $ Output.BuildSuccess target (map T.pack outputs) 0
              exitSuccess
            Right (BuildCached outputs) -> do
              Output.emitProgressIO presenter $ Output.Cached target
              Output.emitResultIO presenter $ Output.BuildSuccess target (map T.pack outputs) 0
              exitSuccess
    AllInPackage pkgPath -> do
      let target = "//" <> pkgPath <> ":all"
          dhallPath' = projectRoot <> "/" <> T.unpack pkgPath <> "/BUILD.dhall"
          callback = progressToOutput presenter
      pkgResult <- try $ Dhall.parsePackageFile projectRoot dhallPath'
      case pkgResult of
        Left (e :: IOException) -> do
          Output.emitErrorIO presenter $
            Output.ConfigError $
              "Cannot read package: " <> T.pack (show e)
          exitFailure
        Right pkg -> do
          Output.emitProgressIO presenter $ Output.Building target
          result <- buildAllTargetsWithProgress mJobs callback tc projectRoot pkg
          case result of
            Left err -> do
              Output.emitErrorIO presenter $ buildErrorToOutput target err
              exitFailure
            Right n -> do
              Output.emitResultIO presenter $
                Output.BuildSuccess
                  target
                  [T.pack (show n) <> " targets"]
                  0
              exitSuccess
    Recursive subPath -> do
      let startDir = if T.null subPath then projectRoot else projectRoot <> "/" <> T.unpack subPath
          target = if T.null subPath then "//..." else "//" <> subPath <> "..."
          callback = progressToOutput presenter
      files <- discoverUnder projectRoot startDir
      if null files
        then do
          Output.emitErrorIO presenter $
            Output.ConfigError $
              "No BUILD.dhall files found under " <> target
          exitFailure
        else do
          -- Parse all BUILD.dhall files in parallel for better performance
          pkgs <- forConcurrently files $ \f -> Dhall.parsePackageFile projectRoot (dhallPath f)
          Output.emitProgressIO presenter $ Output.Building target
          -- Build all packages with a unified action graph for maximum parallelism
          result <- buildAllPackagesWithProgress mJobs callback tc projectRoot pkgs
          case result of
            Left err -> do
              Output.emitErrorIO presenter $ buildErrorToOutput target err
              exitFailure
            Right n -> do
              Output.emitResultIO presenter $
                Output.BuildSuccess
                  target
                  [T.pack (show n) <> " targets across " <> T.pack (show (length pkgs)) <> " packages"]
                  0
              exitSuccess

-- | Convert BuildError to typed Output.Error
buildErrorToOutput :: Text -> BuildError -> Output.Error
buildErrorToOutput target = \case
  TargetNotFound name -> Output.BuildFailed target ("Target not found: " <> name) Nothing
  CommandFailed cmd code err ->
    Output.BuildFailed
      target
      ("Command failed: " <> cmd <> " (exit " <> T.pack (show code) <> ")")
      (Just err)
  DependencyFailed dep err -> Output.BuildFailed target ("Dependency failed: " <> dep) (Just err)
  SourceNotFound path -> Output.BuildFailed target ("Source not found: " <> T.pack path) Nothing
  PackageError err -> Output.BuildFailed target "Package error" (Just err)

-- | Create a ProgressCallback that emits typed Output via presenter
progressToOutput :: Output.Presenter -> ProgressCallback
progressToOutput presenter = \case
  ProgressStarting _name cur total ->
    Output.emitProgressIO presenter $ Output.ProgressCount cur total
  ProgressCached name _cur _total ->
    Output.emitProgressIO presenter $ Output.Cached name
  ProgressCompleted name _cur _total _memKB ->
    -- Note: duration not available here, would need to track
    Output.emitProgressIO presenter $ Output.Built name 0
  ProgressFailed name _cur _total err ->
    Output.emitErrorIO presenter $ Output.BuildFailed name err Nothing

-- | Run command: build target then execute it
cmdRun :: [String] -> IO ()
cmdRun [] = do
  TIO.putStrLn "Usage: sensenet run //path/to/pkg:target [-- args...]"
  exitFailure
cmdRun args = Output.withAutoPresenter $ \presenter -> do
  -- Split args at "--" to separate target from program args
  let (targetArgs, progArgs) = case break (== "--") args of
        (before, []) -> (before, [])
        (before, _ : after) -> (before, after)
  case targetArgs of
    [] -> do
      TIO.putStrLn "Usage: sensenet run //path/to/pkg:target [-- args...]"
      exitFailure
    [targetStr] -> do
      case parseTarget (T.pack targetStr) of
        Nothing -> do
          Output.emitErrorIO presenter $
            Output.ConfigError $
              "Invalid target: " <> T.pack targetStr
          exitFailure
        Just (SingleTarget pkgPath targetName) -> do
          let target = "//" <> pkgPath <> ":" <> targetName
              callback = progressToOutput presenter
          projectRoot <- getCurrentDirectory
          tc <- TC.loadToolchains (TC.defaultToolchainsPath projectRoot)
          let dhallPath' = projectRoot <> "/" <> T.unpack pkgPath <> "/BUILD.dhall"
          pkg <- Dhall.parsePackageFile projectRoot dhallPath'
          -- Build the target first
          Output.emitProgressIO presenter $ Output.Building target
          result <- buildWithProgress Nothing callback tc projectRoot pkg targetName
          case result of
            Left err -> do
              Output.emitErrorIO presenter $ buildErrorToOutput target err
              exitFailure
            Right (BuildSuccess outputs) -> runBinary outputs progArgs
            Right (BuildCached outputs) -> runBinary outputs progArgs
        Just _ -> do
          Output.emitErrorIO presenter $
            Output.ConfigError
              "run requires a single target (//pkg:target), not a pattern"
          exitFailure
    _ -> do
      Output.emitErrorIO presenter $
        Output.ConfigError
          "run requires exactly one target"
      exitFailure
  where
    runBinary :: [FilePath] -> [String] -> IO ()
    runBinary [] _ = do
      -- Note: this runs outside presenter scope, use direct output
      TIO.putStrLn "✗ No output binary found"
      exitFailure
    runBinary (bin : _) progArgs' = do
      -- Execute the binary with the given arguments
      exitCode <- rawSystem bin progArgs'
      exitWith exitCode

cmdTargets :: IO ()
cmdTargets = Output.withAutoPresenter $ \presenter -> do
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
  Output.emitResultIO presenter $ Output.TextResult $ T.intercalate "\n" targets

cmdClean :: Bool -> IO ()
cmdClean full = Output.withAutoPresenter $ \presenter -> do
  -- Remove build outputs
  let outDir = "sensenet-out"
  outExists <- doesDirectoryExist outDir
  if outExists
    then do
      Output.emitProgressIO presenter $ Output.ProgressMsg "Removing sensenet-out/"
      removeDirectoryRecursive outDir
    else Output.emitProgressIO presenter $ Output.ProgressMsg "sensenet-out/ does not exist"

  -- With --full, also remove the action cache
  if full
    then do
      cacheDir <- getXdgDirectory XdgCache "sensenet"
      cacheExists <- doesDirectoryExist cacheDir
      if cacheExists
        then do
          Output.emitProgressIO presenter $ Output.ProgressMsg $ "Removing " <> T.pack cacheDir <> "/"
          removeDirectoryRecursive cacheDir
        else Output.emitProgressIO presenter $ Output.ProgressMsg $ T.pack cacheDir <> "/ does not exist"
    else pure ()

  Output.emitResultIO presenter $ Output.TextResult "Clean"

-- ════════════════════════════════════════════════════════════════════════════
-- Query Command
-- ════════════════════════════════════════════════════════════════════════════

-- | Query selector (parsed from #fragment)
data QuerySelector
  = QDeps
  | QRdeps
  | QInputs
  | QKind Text
  | QAttrs
  deriving (Show, Eq)

-- | Query options
data QueryOpts = QueryOpts
  { qoLimit :: Maybe Int,
    qoJson :: Bool,
    qoDot :: Bool
  }

defaultQueryOpts :: QueryOpts
defaultQueryOpts = QueryOpts {qoLimit = Nothing, qoJson = False, qoDot = False}

-- | Parse query options from args
parseQueryOpts :: [String] -> (QueryOpts, [String])
parseQueryOpts = go defaultQueryOpts
  where
    go opts [] = (opts, [])
    go opts ("--json" : rest) = go opts {qoJson = True} rest
    go opts ("--dot" : rest) = go opts {qoDot = True} rest
    go opts ("--limit" : n : rest)
      | all isDigit n = go opts {qoLimit = Just (read n)} rest
    go opts (arg : rest) =
      let (opts', rest') = go opts rest
       in (opts', arg : rest')

-- | Parse a query expression: //pkg:target#selector
parseQueryExpr :: Text -> Maybe (TargetPattern, Maybe QuerySelector)
parseQueryExpr t = case T.breakOn "#" t of
  (targetPart, fragment)
    | T.null fragment -> do
        pat <- parseTarget targetPart
        pure (pat, Nothing)
    | otherwise -> do
        pat <- parseTarget targetPart
        sel <- parseSelector (T.drop 1 fragment) -- drop the #
        pure (pat, Just sel)

parseSelector :: Text -> Maybe QuerySelector
parseSelector t = case T.breakOn "/" t of
  ("deps", _) -> Just QDeps
  ("rdeps", _) -> Just QRdeps
  ("inputs", _) -> Just QInputs
  ("attrs", _) -> Just QAttrs
  ("kind", rest) -> Just $ QKind (T.drop 1 rest) -- drop the /
  _ -> Nothing

-- | Query result can be strings, structured JSON values, or graph edges
data QueryResult
  = QRStrings [Text]
  | QRValues [Value]
  | QRGraph [(Text, Text)] -- (from, to) edges for dot output

cmdQuery :: [String] -> IO ()
cmdQuery [] = do
  TIO.putStrLn "Usage: sensenet query //path/to/pkg:target#selector"
  TIO.putStrLn ""
  TIO.putStrLn "Selectors: #deps, #rdeps, #inputs, #kind/<type>, #attrs"
  exitFailure
cmdQuery args = Output.withAutoPresenter $ \presenter -> do
  let (opts, rest) = parseQueryOpts args
  case rest of
    [] -> do
      TIO.putStrLn "Usage: sensenet query //path/to/pkg:target#selector"
      exitFailure
    queries -> do
      projectRoot <- getCurrentDirectory
      -- Parse all packages in parallel for better performance
      files <- discover projectRoot
      pkgs <- forConcurrently files $ \f -> Dhall.parsePackageFile projectRoot (dhallPath f)
      -- Process each query, tracking errors
      results <- mapM (runQuery presenter opts pkgs) queries
      let (errors, successes) = partitionEithers results
      -- Emit errors
      mapM_ (Output.emitErrorIO presenter) errors
      -- Output successful results (if any)
      unless (null successes) $ do
        let merged = mergeQueryResults successes
        outputQueryResult presenter opts merged
      -- Exit with failure if any errors occurred
      unless (null errors) exitFailure

mergeQueryResults :: [QueryResult] -> QueryResult
mergeQueryResults rs = case rs of
  [] -> QRStrings []
  (QRGraph _ : _) -> QRGraph [(f, t) | QRGraph es <- rs, (f, t) <- es]
  (QRValues _ : _) -> QRValues [v | QRValues vs <- rs, v <- vs]
  _ -> QRStrings [s | QRStrings ss <- rs, s <- ss]

outputQueryResult :: Output.Presenter -> QueryOpts -> QueryResult -> IO ()
outputQueryResult presenter opts = \case
  QRStrings strs ->
    if qoJson opts
      then Output.emitResultIO presenter $ Output.JsonResult $ Aeson.toJSON strs
      else Output.emitResultIO presenter $ Output.TextResult $ T.intercalate "\n" strs
  QRValues vals ->
    if qoJson opts
      then Output.emitResultIO presenter $ Output.JsonResult $ Aeson.toJSON vals
      else mapM_ (\v -> Output.emitResultIO presenter $ Output.TextResult $ TE.decodeUtf8 $ BL.toStrict $ Aeson.encode v) vals
  QRGraph edges -> do
    -- GraphViz dot output - emit as text
    let dotOutput =
          T.unlines
            [ "digraph deps {",
              "  rankdir=LR;",
              "  node [shape=box];",
              T.unlines $ map (\(f, t) -> "  \"" <> sanitize f <> "\" -> \"" <> sanitize t <> "\";") edges,
              "}"
            ]
    Output.emitResultIO presenter $ Output.TextResult dotOutput
  where
    -- Sanitize label for graphviz
    sanitize = T.replace "\"" "\\\""

runQuery :: Output.Presenter -> QueryOpts -> [Package] -> String -> IO (Either Output.Error QueryResult)
runQuery _presenter opts pkgs queryStr = do
  case parseQueryExpr (T.pack queryStr) of
    Nothing ->
      pure $ Left $ Output.ConfigError $ "Invalid query: " <> T.pack queryStr
    Just (pat, mSel) -> do
      -- Find matching targets
      let targets = findTargets pkgs pat
      case mSel of
        Nothing -> pure $ Right $ QRStrings $ map (formatTarget pkgs) targets
        Just sel -> Right <$> executeSelector opts pkgs targets sel

-- | Find targets matching a pattern
findTargets :: [Package] -> TargetPattern -> [(Package, Rule)]
findTargets pkgs = \case
  SingleTarget pkgPath targetName ->
    [ (pkg, rule)
    | pkg <- pkgs,
      T.pack pkg.path == pkgPath,
      rule <- pkg.rules,
      ruleName rule == targetName
    ]
  AllInPackage pkgPath ->
    [ (pkg, rule)
    | pkg <- pkgs,
      T.pack pkg.path == pkgPath,
      rule <- pkg.rules
    ]
  Recursive subPath ->
    [ (pkg, rule)
    | pkg <- pkgs,
      T.null subPath || T.pack pkg.path `T.isPrefixOf` subPath || subPath `T.isPrefixOf` T.pack pkg.path,
      rule <- pkg.rules
    ]

-- | Format a target as a label
formatTarget :: [Package] -> (Package, Rule) -> Text
formatTarget _ (pkg, rule) = "//" <> T.pack pkg.path <> ":" <> ruleName rule

-- | Execute a query selector
executeSelector :: QueryOpts -> [Package] -> [(Package, Rule)] -> QuerySelector -> IO QueryResult
executeSelector opts pkgs targets = \case
  QDeps
    | qoDot opts -> do
        let limit = qoLimit opts
        pure $ QRGraph $ concatMap (getDepEdges limit pkgs) targets
    | otherwise -> do
        let limit = qoLimit opts
        pure $ QRStrings $ concatMap (getDeps limit pkgs) targets
  QRdeps
    | qoDot opts -> do
        let targetLabels = map (\(p, r) -> "//" <> T.pack p.path <> ":" <> ruleName r) targets
        pure $
          QRGraph
            [ (formatTarget pkgs (pkg, rule), targetLabel)
            | pkg <- pkgs,
              rule <- pkg.rules,
              targetLabel <- targetLabels,
              any (depMatches targetLabel (T.pack pkg.path)) (ruleDeps rule)
            ]
    | otherwise -> do
        let targetLabels = map (\(p, r) -> "//" <> T.pack p.path <> ":" <> ruleName r) targets
        pure $
          QRStrings
            [ formatTarget pkgs (pkg, rule)
            | pkg <- pkgs,
              rule <- pkg.rules,
              any (depMatchesAny targetLabels (T.pack pkg.path)) (ruleDeps rule)
            ]
  QInputs ->
    pure $ QRStrings $ concatMap (\(pkg, rule) -> map (\s -> T.pack pkg.path <> "/" <> s) (ruleSrcs rule)) targets
  QKind kindPattern ->
    pure $
      QRStrings
        [ formatTarget pkgs t
        | t@(_, rule) <- targets,
          kindPattern `T.isInfixOf` ruleKind rule
        ]
  QAttrs ->
    if qoJson opts
      then pure $ QRValues $ map ruleToJson targets
      else pure $ QRStrings $ map (\(_, rule) -> T.pack (show rule)) targets

-- | Convert a rule to JSON-encodable representation
ruleToJson :: (Package, Rule) -> Value
ruleToJson (pkg, rule) =
  object
    [ "label" .= formatTarget [] (pkg, rule),
      "kind" .= ruleKind rule,
      "srcs" .= ruleSrcs rule,
      "deps" .= map (depToLabel (T.pack pkg.path)) (ruleDeps rule)
    ]

-- | Get dependencies for a target (with optional depth limit)
getDeps :: Maybe Int -> [Package] -> (Package, Rule) -> [Text]
getDeps limit pkgs (pkg, rule) = go 0 [] (ruleDeps rule)
  where
    go _ acc [] = acc
    go depth acc deps
      | Just l <- limit, depth >= l = acc
      | otherwise =
          let depLabels = map (depToLabel (T.pack pkg.path)) deps
              newAcc = acc ++ depLabels
              -- Find transitive deps
              transDeps =
                [ dep
                | label <- depLabels,
                  (p, r) <- findTargetByLabel pkgs label,
                  dep <- ruleDeps r,
                  depToLabel (T.pack p.path) dep `notElem` newAcc
                ]
           in go (depth + 1) newAcc transDeps

-- | Get dependency edges for a target as (from, to) pairs for graphviz
getDepEdges :: Maybe Int -> [Package] -> (Package, Rule) -> [(Text, Text)]
getDepEdges limit pkgs (pkg, rule) = go 0 [] (formatTarget [] (pkg, rule)) (ruleDeps rule)
  where
    go _ acc _ [] = acc
    go depth acc fromLabel deps
      | Just l <- limit, depth >= l = acc
      | otherwise =
          let depLabels = map (depToLabel (T.pack pkg.path)) deps
              newEdges = map (fromLabel,) depLabels
              newAcc = acc ++ newEdges
              -- Find transitive deps
              transitiveEdges =
                [ (depLabel, transDepLabel)
                | depLabel <- depLabels,
                  (p, r) <- findTargetByLabel pkgs depLabel,
                  transDep <- ruleDeps r,
                  let transDepLabel = depToLabel (T.pack p.path) transDep,
                  (depLabel, transDepLabel) `notElem` newAcc
                ]
           in go (depth + 1) (newAcc ++ transitiveEdges) fromLabel []

-- | Convert a Dep to a label
depToLabel :: Text -> Dep -> Text
depToLabel pkgPath = \case
  DepLocal name
    | ":" `T.isPrefixOf` name -> "//" <> pkgPath <> name
    | "//" `T.isPrefixOf` name -> name
    | otherwise -> "//" <> pkgPath <> ":" <> name
  DepFlake ref -> ref

-- | Check if a dep matches any of the target labels
depMatchesAny :: [Text] -> Text -> Dep -> Bool
depMatchesAny labels pkgPath dep = depToLabel pkgPath dep `elem` labels

-- | Check if a dep matches a specific target label
depMatches :: Text -> Text -> Dep -> Bool
depMatches label pkgPath dep = depToLabel pkgPath dep == label

-- | Find a target by label
findTargetByLabel :: [Package] -> Text -> [(Package, Rule)]
findTargetByLabel pkgs label = case parseTarget label of
  Just (SingleTarget p t) -> findTargets pkgs (SingleTarget p t)
  _ -> []

-- ════════════════════════════════════════════════════════════════════════════
-- Shell Completion
-- ════════════════════════════════════════════════════════════════════════════

-- | Fast inline completion (called by shell completion functions)
-- Usage: sensenet --complete <word> [context...]
-- Outputs completions one per line, optimized for speed
cmdComplete :: [String] -> IO ()
cmdComplete args = case args of
  [] -> completeCommands ""
  [word] -> completeCommands word
  [cmd, word] -> completeForCommand cmd word
  (cmd : word : _) -> completeForCommand cmd word

-- | Complete top-level commands
completeCommands :: String -> IO ()
completeCommands prefix = do
  let commands = ["build", "run", "query", "targets", "clean", "complete", "--help", "--version"]
      matches = filter (prefix `isPrefixOf`) commands
  mapM_ putStrLn matches

-- | Complete arguments for a specific command
completeForCommand :: String -> String -> IO ()
completeForCommand cmd word
  | cmd == "build" = completeBuild word
  | cmd == "run" = completeRun word
  | cmd == "query" = completeQuery word
  | cmd == "clean" = completeClean word
  | cmd == "complete" = completeShells word
  | otherwise = pure ()

-- | Complete build command (targets and options)
completeBuild :: String -> IO ()
completeBuild word
  | "-" `isPrefixOf` word = completeBuildOpts word
  | "//" `isPrefixOf` word = completeTargets word
  | otherwise = completeTargets ("//" ++ word)

-- | Complete build options
completeBuildOpts :: String -> IO ()
completeBuildOpts prefix = do
  let opts = ["-j", "--jobs=", "--all-cores", "--stub", "--no-tui", "-v", "--verbose"]
      matches = filter (prefix `isPrefixOf`) opts
  mapM_ putStrLn matches

-- | Complete run command (single target only)
completeRun :: String -> IO ()
completeRun word
  | "-" `isPrefixOf` word = pure () -- run doesn't have options before target
  | "//" `isPrefixOf` word = completeTargets word
  | otherwise = completeTargets ("//" ++ word)

-- | Complete query command (targets with selectors)
completeQuery :: String -> IO ()
completeQuery word
  | "#" `isInfixOf` word = completeQuerySelector word
  | "--" `isPrefixOf` word = completeQueryOpts word
  | "//" `isPrefixOf` word = completeTargets word
  | otherwise = completeTargets ("//" ++ word)

-- | Complete query selectors after #
completeQuerySelector :: String -> IO ()
completeQuerySelector word = do
  let (targetPart, fragment) = break (== '#') word
      selectorPrefix = drop 1 fragment -- drop the #
      selectors = ["deps", "rdeps", "inputs", "attrs", "kind/"]
      matches = filter (selectorPrefix `isPrefixOf`) selectors
  mapM_ (\s -> putStrLn $ targetPart ++ "#" ++ s) matches

-- | Complete query options
completeQueryOpts :: String -> IO ()
completeQueryOpts prefix = do
  let opts = ["--json", "--dot", "--limit"]
      matches = filter (prefix `isPrefixOf`) opts
  mapM_ putStrLn matches

-- | Complete clean options
completeClean :: String -> IO ()
completeClean prefix = do
  let opts = ["--full"]
      matches = filter (prefix `isPrefixOf`) opts
  mapM_ putStrLn matches

-- | Complete shell names for complete command
completeShells :: String -> IO ()
completeShells prefix = do
  let shells = ["bash", "zsh", "fish"]
      matches = filter (prefix `isPrefixOf`) shells
  mapM_ putStrLn matches

-- | Complete targets (//path:target)
-- Uses cached target discovery for speed (< 50ms vs 4+ seconds)
completeTargets :: String -> IO ()
completeTargets prefix = do
  projectRoot <- getCurrentDirectory
  completions <- Complete.completeTargetsCached projectRoot (T.pack prefix)
  mapM_ (putStrLn . T.unpack) completions

-- | Generate shell completion scripts
cmdCompleteScript :: [String] -> IO ()
cmdCompleteScript args = case args of
  ["bash"] -> TIO.putStrLn bashCompletion
  ["zsh"] -> TIO.putStrLn zshCompletion
  ["fish"] -> TIO.putStrLn fishCompletion
  _ -> do
    TIO.putStrLn "Usage: sensenet complete <shell>"
    TIO.putStrLn "Supported shells: bash, zsh, fish"
    exitFailure

-- | Bash completion script
bashCompletion :: Text
bashCompletion =
  T.unlines
    [ "# sensenet bash completion",
      "# Add to ~/.bashrc: eval \"$(sensenet complete bash)\"",
      "",
      "_sensenet_complete() {",
      "    local cur prev words cword",
      "    _init_completion || return",
      "",
      "    # Get completions from sensenet",
      "    local IFS=$'\\n'",
      "    local cmd=\"\"",
      "    if [[ $cword -ge 2 ]]; then",
      "        cmd=\"${words[1]}\"",
      "    fi",
      "",
      "    COMPREPLY=( $(sensenet --complete \"$cmd\" \"$cur\" 2>/dev/null) )",
      "",
      "    # Handle special characters in target paths",
      "    if [[ ${#COMPREPLY[@]} -eq 1 && ${COMPREPLY[0]} == */: ]]; then",
      "        # Don't add space after colon",
      "        compopt -o nospace",
      "    elif [[ ${#COMPREPLY[@]} -eq 1 && ${COMPREPLY[0]} == *... ]]; then",
      "        # Don't add space after ...",
      "        compopt -o nospace",
      "    fi",
      "}",
      "",
      "complete -F _sensenet_complete sensenet"
    ]

-- | Zsh completion script
zshCompletion :: Text
zshCompletion =
  T.unlines
    [ "#compdef sensenet",
      "# sensenet zsh completion",
      "# Add to ~/.zshrc: eval \"$(sensenet complete zsh)\"",
      "",
      "_sensenet() {",
      "    local -a completions",
      "    local cmd=\"\"",
      "    ",
      "    if (( CURRENT >= 3 )); then",
      "        cmd=\"${words[2]}\"",
      "    fi",
      "",
      "    # Get completions from sensenet",
      "    completions=(${(f)\"$(sensenet --complete \"$cmd\" \"${words[CURRENT]}\" 2>/dev/null)\"})",
      "",
      "    if (( ${#completions[@]} > 0 )); then",
      "        _describe -t completions 'sensenet' completions",
      "    fi",
      "}",
      "",
      "_sensenet"
    ]

-- | Fish completion script
fishCompletion :: Text
fishCompletion =
  T.unlines
    [ "# sensenet fish completion",
      "# Add to ~/.config/fish/config.fish: sensenet complete fish | source",
      "",
      "function __sensenet_complete",
      "    set -l tokens (commandline -opc)",
      "    set -l current (commandline -ct)",
      "    set -l cmd \"\"",
      "    ",
      "    if test (count $tokens) -ge 2",
      "        set cmd $tokens[2]",
      "    end",
      "",
      "    sensenet --complete \"$cmd\" \"$current\" 2>/dev/null",
      "end",
      "",
      "# Disable file completion for sensenet",
      "complete -c sensenet -f",
      "",
      "# Add dynamic completions",
      "complete -c sensenet -a '(__sensenet_complete)'"
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

-- | Target pattern types
data TargetPattern
  = -- | Single target: //path/to/pkg:target
    SingleTarget Text Text
  | -- | All targets in package: //path/to/pkg:all
    AllInPackage Text
  | -- | Recursive: //... or //path/...
    Recursive Text
  deriving (Show, Eq)

-- | Parse target pattern
parseTarget :: Text -> Maybe TargetPattern
parseTarget t = do
  rest <- T.stripPrefix "//" t
  -- Check for recursive pattern first
  case T.stripSuffix "..." rest of
    Just prefix ->
      -- //... or //path/to/...
      let path = T.dropWhileEnd (== '/') prefix
       in Just $ Recursive path
    Nothing ->
      -- Regular target: //path:target
      case T.breakOn ":" rest of
        (_, "") -> Nothing
        (pkgPath, colonTarget) ->
          let target = T.drop 1 colonTarget
           in if target == "all"
                then Just $ AllInPackage pkgPath
                else Just $ SingleTarget pkgPath target

showError :: BuildError -> Text
showError = \case
  TargetNotFound name -> "Target not found: " <> name
  CommandFailed cmd code err ->
    "Command failed: " <> cmd <> " (exit " <> T.pack (show code) <> ")\n" <> err
  DependencyFailed dep err -> "Dependency failed: " <> dep <> " - " <> err
  SourceNotFound path -> "Source not found: " <> T.pack path
  PackageError err -> "Package error: " <> err

showPattern :: TargetPattern -> Text
showPattern = \case
  SingleTarget pkgPath targetName -> "//" <> pkgPath <> ":" <> targetName
  AllInPackage pkgPath -> "//" <> pkgPath <> ":all"
  Recursive subPath -> "//" <> subPath <> "..."
