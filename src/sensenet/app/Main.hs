{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- sensenet — the best build system in the world
--
-- Pure Haskell. Content-addressed. Coeffect-tracked.
-- No FFI. No daemon. Static binary.
module Main where

-- SenseNet.DICE used by Build module

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import GHC.Conc (getNumProcessors)
import SenseNet.Build (BuildError (..), BuildResult (..), buildAllTargetsJ, buildWithDepsJ, packageDeps, sortPackagesByDeps)
import SenseNet.Dhall qualified as Dhall
import SenseNet.Discover (DhallFile (..), discover, discoverUnder)
import SenseNet.IR (Dep (..), Package (..), Rule (..), ruleDeps, ruleKind, ruleName, ruleSrcs)
import SenseNet.Toolchains qualified as TC
import System.Directory (XdgDirectory (..), doesDirectoryExist, getCurrentDirectory, getXdgDirectory, removeDirectoryRecursive)
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
    ("query" : rest) -> cmdQuery rest
    ("targets" : _) -> cmdTargets
    ("clean" : rest) -> cmdClean ("--full" `elem` rest)
    (cmd : _) -> do
      TIO.putStrLn $ "Unknown command: " <> T.pack cmd
      usage

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
        "  targets                List available targets",
        "  clean [--full]         Remove build outputs (--full: also clear cache)",
        "  query <target>#<sel>   Query the build graph",
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
        "",
        "Examples:",
        "  sensenet build //src/examples/cxx:hello",
        "  sensenet build //src/examples/... -j4",
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
    boNoTui :: !Bool -- --no-tui: disable TUI (currently no-op, no TUI yet)
  }

defaultBuildOpts :: BuildOpts
defaultBuildOpts =
  BuildOpts
    { boJobs = JobsDefault,
      boStub = False,
      boNoTui = False
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

    isPrefixOf prefix str = take (length prefix) str == prefix

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
cmdBuild args = do
  let (opts, rest) = parseBuildOpts args
  mJobs <- resolveJobs opts.boJobs
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
          TIO.putStrLn $ "Invalid target(s): " <> T.pack (unwords invalidTargets)
          TIO.putStrLn "Expected: //path/to/pkg:target, //path/to/pkg:all, or //..."
          exitFailure
        else do
          let validTargets = [p | (_, Just p) <- parsedTargets]
          -- Stub mode: just print what would be built
          if opts.boStub
            then do
              TIO.putStrLn $ "[stub] Would build " <> T.pack (show (length validTargets)) <> " target(s):"
              mapM_ (TIO.putStrLn . ("[stub]   " <>) . showPattern) validTargets
              exitSuccess
            else buildTargets mJobs validTargets

buildTargets :: Maybe Int -> [TargetPattern] -> IO ()
buildTargets mJobs patterns = case patterns of
  [] -> exitSuccess
  [pattern] -> buildSinglePattern mJobs pattern
  _ -> do
    -- Multiple targets: build each one
    projectRoot <- getCurrentDirectory
    tc <- TC.loadToolchains (TC.defaultToolchainsPath projectRoot)
    TIO.putStrLn $ "Building " <> T.pack (show (length patterns)) <> " targets"
    results <- mapM (buildPatternResult mJobs tc projectRoot) patterns
    let failures = length [() | Left _ <- results]
        successes = length [() | Right _ <- results]
    if failures > 0
      then do
        TIO.putStrLn $ "✗ " <> T.pack (show failures) <> " failed, " <> T.pack (show successes) <> " succeeded"
        exitFailure
      else do
        TIO.putStrLn $ "✓ Built " <> T.pack (show successes) <> " targets"
        exitSuccess

buildPatternResult :: Maybe Int -> TC.Toolchains -> FilePath -> TargetPattern -> IO (Either BuildError BuildResult)
buildPatternResult mJobs tc projectRoot = \case
  SingleTarget pkgPath targetName -> do
    let dhallPath = projectRoot <> "/" <> T.unpack pkgPath <> "/BUILD.dhall"
    pkg <- Dhall.parsePackageFile projectRoot dhallPath
    buildWithDepsJ mJobs tc projectRoot pkg targetName
  AllInPackage pkgPath -> do
    let dhallPath = projectRoot <> "/" <> T.unpack pkgPath <> "/BUILD.dhall"
    pkg <- Dhall.parsePackageFile projectRoot dhallPath
    result <- buildAllTargetsJ mJobs tc projectRoot pkg
    pure $ fmap (BuildSuccess . (\n -> [show n <> " targets"])) result
  Recursive _ -> do
    -- For recursive, just return success for now
    -- TODO: implement properly
    pure $ Right $ BuildSuccess ["recursive build"]

buildSinglePattern :: Maybe Int -> TargetPattern -> IO ()
buildSinglePattern mJobs pat = do
  projectRoot <- getCurrentDirectory
  tc <- TC.loadToolchains (TC.defaultToolchainsPath projectRoot)
  case pat of
    SingleTarget pkgPath targetName -> do
      let dhallPath = projectRoot <> "/" <> T.unpack pkgPath <> "/BUILD.dhall"
      pkg <- Dhall.parsePackageFile projectRoot dhallPath
      TIO.putStrLn $ "Building //" <> pkgPath <> ":" <> targetName
      result <- buildWithDepsJ mJobs tc projectRoot pkg targetName
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
    AllInPackage pkgPath -> do
      let dhallPath = projectRoot <> "/" <> T.unpack pkgPath <> "/BUILD.dhall"
      pkg <- Dhall.parsePackageFile projectRoot dhallPath
      TIO.putStrLn $ "Building //" <> pkgPath <> ":all (" <> T.pack (show (length pkg.rules)) <> " targets)"
      result <- buildAllTargetsJ mJobs tc projectRoot pkg
      case result of
        Left err -> do
          TIO.putStrLn $ "✗ " <> showError err
          exitFailure
        Right n -> do
          TIO.putStrLn $ "✓ Built " <> T.pack (show n) <> " targets"
          exitSuccess
    Recursive subPath -> do
      let startDir = if T.null subPath then projectRoot else projectRoot <> "/" <> T.unpack subPath
      files <- discoverUnder projectRoot startDir
      if null files
        then do
          TIO.putStrLn $ "No BUILD.dhall files found under //" <> subPath <> "..."
          exitFailure
        else do
          pkgs <- mapM (\f -> Dhall.parsePackageFile projectRoot (dhallPath f)) files
          let totalTargets = sum [length pkg.rules | pkg <- pkgs]
              pathPrefix = if T.null subPath then "//" else "//" <> subPath <> "/"
          TIO.putStrLn $ "Building " <> pathPrefix <> "... (" <> T.pack (show (length pkgs)) <> " packages, " <> T.pack (show totalTargets) <> " targets)"
          let sortedPkgs = sortPackagesByDeps pkgs
              pkgPaths = map (T.pack . (.path)) pkgs
          results <- buildPackageWaves mJobs tc projectRoot pkgPaths sortedPkgs
          let failures = [(p, e) | (p, Left e) <- results]
              successes = [n | (_, Right n) <- results]
          if null failures
            then do
              TIO.putStrLn $ "✓ Built " <> T.pack (show (sum successes)) <> " targets across " <> T.pack (show (length pkgs)) <> " packages"
              exitSuccess
            else do
              TIO.putStrLn $ "✗ " <> T.pack (show (length failures)) <> " package(s) failed:"
              mapM_ (\(p, e) -> TIO.putStrLn $ "  " <> T.pack p <> ": " <> showError e) failures
              exitFailure

-- | Build packages in waves, respecting cross-package dependencies
-- Packages are executed in parallel within each wave, but waves are sequential
buildPackageWaves ::
  Maybe Int ->
  TC.Toolchains ->
  FilePath ->
  [Text] -> -- All package paths in our build set
  [Package] -> -- Packages sorted by deps (deps first)
  IO [(FilePath, Either BuildError Int)]
buildPackageWaves mJobs tc projectRoot allPkgPaths pkgs = go [] [] pkgs
  where
    go results _ [] = pure results
    go results completed (pkg : rest) = do
      -- Check if all deps in our set are completed
      let deps = filter (`elem` allPkgPaths) (packageDeps pkg)
          depsReady = all (`elem` completed) deps

      if depsReady
        then do
          -- Build this package
          result <- buildAllTargetsJ mJobs tc projectRoot pkg
          case result of
            Left err -> do
              -- Package failed, but continue with others
              go ((pkg.path, Left err) : results) completed rest
            Right n -> do
              TIO.putStrLn $ "  ✓ //" <> T.pack pkg.path <> " (" <> T.pack (show n) <> " targets)"
              go ((pkg.path, Right n) : results) (T.pack pkg.path : completed) rest
        else do
          -- Deps not ready - this shouldn't happen with proper topo sort
          -- but handle it gracefully by putting pkg at end
          go results completed (rest ++ [pkg])

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

cmdClean :: Bool -> IO ()
cmdClean full = do
  -- Remove build outputs
  let outDir = "sensenet-out"
  outExists <- doesDirectoryExist outDir
  if outExists
    then do
      TIO.putStrLn "Removing sensenet-out/"
      removeDirectoryRecursive outDir
    else TIO.putStrLn "sensenet-out/ does not exist"

  -- With --full, also remove the action cache
  if full
    then do
      cacheDir <- getXdgDirectory XdgCache "sensenet"
      cacheExists <- doesDirectoryExist cacheDir
      if cacheExists
        then do
          TIO.putStrLn $ "Removing " <> T.pack cacheDir <> "/"
          removeDirectoryRecursive cacheDir
        else TIO.putStrLn $ T.pack cacheDir <> "/ does not exist"
    else pure ()

  TIO.putStrLn "✓ Clean"

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
cmdQuery args = do
  let (opts, rest) = parseQueryOpts args
  case rest of
    [] -> do
      TIO.putStrLn "Usage: sensenet query //path/to/pkg:target#selector"
      exitFailure
    queries -> do
      projectRoot <- getCurrentDirectory
      -- Parse all packages
      files <- discover projectRoot
      pkgs <- mapM (\f -> Dhall.parsePackageFile projectRoot (dhallPath f)) files
      -- Process each query
      results <- mapM (runQuery opts pkgs) queries
      -- Merge results
      let merged = mergeQueryResults results
      -- Output
      outputQueryResult opts merged

mergeQueryResults :: [QueryResult] -> QueryResult
mergeQueryResults rs = case rs of
  [] -> QRStrings []
  (QRGraph _ : _) -> QRGraph [(f, t) | QRGraph es <- rs, (f, t) <- es]
  (QRValues _ : _) -> QRValues [v | QRValues vs <- rs, v <- vs]
  _ -> QRStrings [s | QRStrings ss <- rs, s <- ss]

outputQueryResult :: QueryOpts -> QueryResult -> IO ()
outputQueryResult opts = \case
  QRStrings strs ->
    if qoJson opts
      then TIO.putStrLn $ TE.decodeUtf8 $ BL.toStrict $ Aeson.encode strs
      else mapM_ TIO.putStrLn strs
  QRValues vals ->
    if qoJson opts
      then TIO.putStrLn $ TE.decodeUtf8 $ BL.toStrict $ Aeson.encode vals
      else mapM_ (TIO.putStrLn . TE.decodeUtf8 . BL.toStrict . Aeson.encode) vals
  QRGraph edges -> do
    TIO.putStrLn "digraph deps {"
    TIO.putStrLn "  rankdir=LR;"
    TIO.putStrLn "  node [shape=box];"
    mapM_ (\(f, t) -> TIO.putStrLn $ "  \"" <> sanitize f <> "\" -> \"" <> sanitize t <> "\";") edges
    TIO.putStrLn "}"
  where
    -- Sanitize label for graphviz
    sanitize = T.replace "\"" "\\\""

runQuery :: QueryOpts -> [Package] -> String -> IO QueryResult
runQuery opts pkgs queryStr = do
  case parseQueryExpr (T.pack queryStr) of
    Nothing -> do
      TIO.putStrLn $ "Invalid query: " <> T.pack queryStr
      pure $ QRStrings []
    Just (pat, mSel) -> do
      -- Find matching targets
      let targets = findTargets pkgs pat
      case mSel of
        Nothing -> pure $ QRStrings $ map (formatTarget pkgs) targets
        Just sel -> executeSelector opts pkgs targets sel

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
