{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : SenseNet.Build
-- Description : Build execution with DICE caching
--
-- Builds targets using content-addressed caching via DICE.
-- If inputs (sources + command) haven't changed, skip execution.
--
-- Cross-target dependencies are resolved within the same package,
-- actions are topologically sorted, and executed with caching.
--
-- No FFI. No daemon. Just builds.
module SenseNet.Build
  ( -- * Build
    build,
    buildWithDeps,
    buildWithDepsJ,
    buildAllTargets,
    buildAllTargetsJ,
    buildAllPackagesJ,
    BuildResult (..),
    BuildError (..),

    -- * Build with Progress
    buildWithProgress,
    buildAllTargetsWithProgress,
    buildAllPackagesWithProgress,
    ProgressCallback,
    ProgressEvent (..),

    -- * Build Configuration
    BuildConfig (..),
    defaultBuildConfig,

    -- * Package-level dependencies
    packageDeps,
    sortPackagesByDeps,

    -- * Logging
    BuildLog (..),
    noLog,
    withLogging,

    -- * Low-level
    runCommand,
    runAction,
  )
where

import Control.Exception (evaluate)
import Control.Monad (forM)
import Data.List (intercalate, isSuffixOf)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Clock qualified as Time
import Data.Word (Word64)
import Foreign.C.Types (CInt (..), CLong (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekByteOff)
import SenseNet.DICE
  ( Action (..),
    ActionCache,
    ActionGraph (..),
    ActionKey,
    ActionResult (..),
    ExecutionResult (..),
    ProgressCallback,
    ProgressEvent (..),
    actionKey,
    addAction,
    checkCache,
    emptyGraph,
    executeGraphWithJobs,
    executeGraphWithProgress,
    newCache,
    storeCache,
  )
import SenseNet.Dhall qualified as Dhall
import SenseNet.IR
  ( CratesIo (..),
    CxxBinary (..),
    CxxLibrary (..),
    CxxStd (..),
    Dep (..),
    Genrule (..),
    HaskellBinary (..),
    HaskellFFIBinary (..),
    HaskellLibrary (..),
    LeanBinary (..),
    NixCxxBinary (..),
    NvBinary (..),
    Package (..),
    PureScriptApp (..),
    PureScriptBinary (..),
    PureScriptWebApp (..),
    Rule (..),
    RustBinary (..),
    RustEdition (..),
    RustLibrary (..),
    SrcSpec (..),
    ruleDeps,
    ruleName,
  )
import SenseNet.IR.Coeffect
  ( Coeffect (..),
  )
import SenseNet.IR.Triple
  ( Gpu,
    gpuToArch,
    textToGpu,
  )
import SenseNet.Log qualified as Log
import SenseNet.Nix qualified as Nix
import SenseNet.PureScript qualified as PS
import SenseNet.RustCrate qualified as RC
import SenseNet.Toolchains (Toolchains (..))
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing, doesFileExist, getModificationTime, listDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hGetContents)
import System.IO.Error (tryIOError)
import System.Posix.Files (fileSize, getFileStatus)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, readCreateProcessWithExitCode, readProcessWithExitCode, waitForProcess)

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

-- | Safe head with default - avoids partial function warning
headOr :: a -> [a] -> a
headOr def [] = def
headOr _ (x : _) = x

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

-- | Build result
data BuildResult
  = BuildSuccess [FilePath]
  | BuildCached [FilePath]
  deriving stock (Show, Eq)

-- | Build errors
data BuildError
  = TargetNotFound Text
  | CommandFailed Text Int Text
  | DependencyFailed Text Text
  | SourceNotFound FilePath
  | PackageError Text -- PureScript package fetch/resolve errors
  deriving stock (Show, Eq)

-- | Build configuration
--
-- Controls execution behavior:
--   - bcUseRemote: If True and -fremote is enabled, eligible actions run remotely
data BuildConfig = BuildConfig
  { -- | Enable remote execution for eligible actions
    bcUseRemote :: !Bool
  }
  deriving stock (Show, Eq)

-- | Default build config (local execution only)
defaultBuildConfig :: BuildConfig
defaultBuildConfig = BuildConfig {bcUseRemote = False}

-- ════════════════════════════════════════════════════════════════════════════
-- Logging
-- ════════════════════════════════════════════════════════════════════════════

-- | Optional build logging context
--
-- When 'Just', structured logs are emitted via Katip.
-- When 'Nothing', no logging occurs (default behavior).
newtype BuildLog = BuildLog {unBuildLog :: Maybe Log.LogEnv}

-- | No logging (default)
noLog :: BuildLog
noLog = BuildLog Nothing

-- | Create logging context from LogEnv
withLogging :: Log.LogEnv -> BuildLog
withLogging = BuildLog . Just

-- ════════════════════════════════════════════════════════════════════════════
-- Build Entry Point
-- ════════════════════════════════════════════════════════════════════════════

-- | Build a target from a package with DICE caching (no dep resolution)
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
    Just rule -> do
      cache <- newCache
      buildRuleWithCache cache tc projectRoot pkg.path rule

-- | Build a target and all its dependencies using DICE graph execution
buildWithDeps ::
  Toolchains ->
  -- | Project root
  FilePath ->
  -- | Package containing the target
  Package ->
  -- | Target name
  Text ->
  IO (Either BuildError BuildResult)
buildWithDeps = buildWithDepsJ Nothing noLog

-- | Build a target with job limit
buildWithDepsJ ::
  -- | Max concurrent jobs (Nothing = unlimited)
  Maybe Int ->
  -- | Logging context
  BuildLog ->
  Toolchains ->
  -- | Project root
  FilePath ->
  -- | Package containing the target
  Package ->
  -- | Target name
  Text ->
  IO (Either BuildError BuildResult)
buildWithDepsJ mJobs blog tc projectRoot pkg targetName
  | Nothing <- findRule targetName pkg.rules = pure $ Left $ TargetNotFound targetName
  | Just rootRule <- findRule targetName pkg.rules = do
      -- Log build start
      logMaybe blog $ \env -> Log.logBuildStart env targetName 1
      let outDir = projectRoot </> "sensenet-out" </> pkg.path
      createDirectoryIfMissing True outDir
      graphResult <- buildActionGraph tc projectRoot pkg outDir rootRule
      result <- either (pure . Left) (executeAndExtract mJobs) graphResult
      -- Log completion or failure
      case result of
        Left err -> logMaybe blog $ \env -> Log.logBuildFailed env targetName (T.pack (show err))
        Right _ -> logMaybe blog $ \env -> Log.logBuildComplete env targetName 0 -- TODO: track actual duration
      pure result
  where
    executeAndExtract :: Maybe Int -> ActionGraph -> IO (Either BuildError BuildResult)
    executeAndExtract jobs graph = do
      cache <- newCache
      execResult <- executeGraphWithJobs jobs cache runAction graph
      pure $ extractResult graph execResult

    extractResult :: ActionGraph -> ExecutionResult -> Either BuildError BuildResult
    extractResult graph execResult
      | ((_, err) : _) <- erFailed execResult = Left $ CommandFailed "graph" 1 err
      | [] <- erFailed execResult = extractRootOutput graph (erResults execResult)

    extractRootOutput :: ActionGraph -> Map ActionKey ActionResult -> Either BuildError BuildResult
    extractRootOutput graph results
      | [] <- agRoots graph = Left $ CommandFailed "graph" 1 "no root action"
      | (rootKey : _) <- agRoots graph =
          maybe
            (Left $ CommandFailed "graph" 1 "root action not in results")
            (Right . BuildSuccess . map T.unpack . arOutputs)
            (Map.lookup rootKey results)

-- | Helper to conditionally log
logMaybe :: BuildLog -> (Log.LogEnv -> IO ()) -> IO ()
logMaybe (BuildLog Nothing) _ = pure ()
logMaybe (BuildLog (Just env)) action = action env

-- | Build a target with progress callback
-- This version uses a callback for progress events instead of direct stdout
buildWithProgress ::
  Maybe Int ->
  ProgressCallback ->
  Toolchains ->
  FilePath ->
  Package ->
  Text ->
  IO (Either BuildError BuildResult)
buildWithProgress mJobs callback tc projectRoot pkg targetName
  | Nothing <- findRule targetName pkg.rules = pure $ Left $ TargetNotFound targetName
  | Just rootRule <- findRule targetName pkg.rules = do
      let outDir = projectRoot </> "sensenet-out" </> pkg.path
          target = "//" <> T.pack pkg.path <> ":" <> targetName
      createDirectoryIfMissing True outDir
      
      -- Emit graph building start event
      callback $ ProgressBuildingGraph target
      
      graphResult <- buildActionGraph tc projectRoot pkg outDir rootRule
      
      -- Emit events for each action in the graph
      case graphResult of
        Left err -> pure $ Left err
        Right graph -> do
          -- Emit ProgressGraphAction for each action in the graph
          mapM_ (\a -> callback $ ProgressGraphAction (aName a)) (Map.elems (agActions graph))
          -- Emit graph built event
          callback $ ProgressGraphBuilt (Map.size (agActions graph))
          -- Execute the graph
          executeAndExtract mJobs callback graph
  where
    executeAndExtract :: Maybe Int -> ProgressCallback -> ActionGraph -> IO (Either BuildError BuildResult)
    executeAndExtract jobs cb graph = do
      cache <- newCache
      execResult <- executeGraphWithProgress jobs cb cache runAction graph
      pure $ extractResult graph execResult

    extractResult :: ActionGraph -> ExecutionResult -> Either BuildError BuildResult
    extractResult graph execResult
      | ((_, err) : _) <- erFailed execResult = Left $ CommandFailed "graph" 1 err
      | [] <- erFailed execResult = extractRootOutput graph (erResults execResult)

    extractRootOutput :: ActionGraph -> Map ActionKey ActionResult -> Either BuildError BuildResult
    extractRootOutput graph results
      | [] <- agRoots graph = Left $ CommandFailed "graph" 1 "no root action"
      | (rootKey : _) <- agRoots graph =
          maybe
            (Left $ CommandFailed "graph" 1 "root action not in results")
            (Right . BuildSuccess . map T.unpack . arOutputs)
            (Map.lookup rootKey results)

-- | Build all targets in a package with progress callback
buildAllTargetsWithProgress ::
  Maybe Int ->
  ProgressCallback ->
  Toolchains ->
  FilePath ->
  Package ->
  IO (Either BuildError Int)
buildAllTargetsWithProgress mJobs callback tc projectRoot pkg = do
  let outDir = projectRoot </> "sensenet-out" </> pkg.path
      target = "//" <> T.pack pkg.path <> ":all"
  createDirectoryIfMissing True outDir

  -- Emit graph building start event
  callback $ ProgressBuildingGraph target
  
  graphResult <- buildAllActionGraph tc projectRoot pkg outDir
  case graphResult of
    Left err -> pure $ Left err
    Right graph -> do
      -- Emit ProgressGraphAction for each action
      mapM_ (\a -> callback $ ProgressGraphAction (aName a)) (Map.elems (agActions graph))
      -- Emit graph built event
      callback $ ProgressGraphBuilt (Map.size (agActions graph))
      
      cache <- newCache
      execResult <- executeGraphWithProgress mJobs callback cache runAction graph
      case erFailed execResult of
        ((_, err) : _) -> pure $ Left $ CommandFailed "graph" 1 err
        [] -> pure $ Right $ erExecuted execResult + erCacheHits execResult

-- | Build all packages with progress callback
buildAllPackagesWithProgress ::
  Maybe Int ->
  ProgressCallback ->
  Toolchains ->
  FilePath ->
  [Package] ->
  IO (Either BuildError Int)
buildAllPackagesWithProgress mJobs callback tc projectRoot pkgs = do
  -- Emit graph building start event for all packages
  callback $ ProgressBuildingGraph "//..."
  
  -- Build unresolved actions for all packages
  actionResults <- forM pkgs $ \pkg -> do
    let outDir = projectRoot </> "sensenet-out" </> pkg.path
    createDirectoryIfMissing True outDir
    buildAllActionsUnresolved tc projectRoot pkg outDir

  case [err | Left err <- actionResults] of
    (err : _) -> pure $ Left err
    [] -> do
      let allTriples = concat [triples | Right triples <- actionResults]
          nameToKey = Map.fromList [(aName a, actionKey a) | (_, _, a) <- allTriples]
          resolvedActions = [resolveDepsForRule nameToKey pkg r a | (pkg, r, a) <- allTriples]
          graph = foldl (\g a -> addAction a g) emptyGraph resolvedActions
          rootKeys = [actionKey a | a <- resolvedActions]
          unifiedGraph = graph {agRoots = rootKeys}

      -- Emit ProgressGraphAction for each action
      mapM_ (\a -> callback $ ProgressGraphAction (aName a)) resolvedActions
      -- Emit graph built event
      callback $ ProgressGraphBuilt (length resolvedActions)

      cache <- newCache
      execResult <- executeGraphWithProgress mJobs callback cache runAction unifiedGraph
      case erFailed execResult of
        ((_, err) : _) -> pure $ Left $ CommandFailed "graph" 1 err
        [] -> pure $ Right $ erExecuted execResult + erCacheHits execResult

-- | Build all targets in a package in parallel
buildAllTargets ::
  Toolchains ->
  FilePath ->
  Package ->
  IO (Either BuildError Int)
buildAllTargets = buildAllTargetsJ Nothing noLog

-- | Build all targets with job limit
buildAllTargetsJ ::
  -- | Max concurrent jobs (Nothing = unlimited)
  Maybe Int ->
  -- | Logging context
  BuildLog ->
  Toolchains ->
  FilePath ->
  Package ->
  IO (Either BuildError Int)
buildAllTargetsJ mJobs blog tc projectRoot pkg = do
  let pkgName = T.pack pkg.path
      targetCount = length pkg.rules
  logMaybe blog $ \env -> Log.logBuildStart env pkgName targetCount

  let outDir = projectRoot </> "sensenet-out" </> pkg.path
  createDirectoryIfMissing True outDir

  -- Build graph for ALL rules (no filtering)
  graphResult <- buildAllActionGraph tc projectRoot pkg outDir
  case graphResult of
    Left err -> do
      logMaybe blog $ \env -> Log.logBuildFailed env pkgName (T.pack (show err))
      pure $ Left err
    Right graph -> do
      cache <- newCache
      execResult <- executeGraphWithJobs mJobs cache runAction graph
      case erFailed execResult of
        ((_, err) : _) -> do
          logMaybe blog $ \env -> Log.logBuildFailed env pkgName err
          pure $ Left $ CommandFailed "graph" 1 err
        [] -> do
          let total = erExecuted execResult + erCacheHits execResult
          logMaybe blog $ \env -> Log.logBuildComplete env pkgName 0 -- TODO: track duration
          pure $ Right total

-- | Build ALL packages with a unified action graph
-- This enables maximum parallelism by creating a single graph across all packages
-- and letting DICE execute everything in parallel (subject to dependencies).
buildAllPackagesJ ::
  -- | Max concurrent jobs (Nothing = unlimited)
  Maybe Int ->
  -- | Logging context
  BuildLog ->
  Toolchains ->
  FilePath ->
  [Package] ->
  IO (Either BuildError Int)
buildAllPackagesJ mJobs blog tc projectRoot pkgs = do
  let totalTargets = sum [length pkg.rules | pkg <- pkgs]
  logMaybe blog $ \env -> Log.logBuildStart env "//..." totalTargets

  -- Build unresolved actions for all packages
  actionResults <- forM pkgs $ \pkg -> do
    let outDir = projectRoot </> "sensenet-out" </> pkg.path
    createDirectoryIfMissing True outDir
    buildAllActionsUnresolved tc projectRoot pkg outDir

  -- Check for errors in action building
  case [err | Left err <- actionResults] of
    (err : _) -> do
      logMaybe blog $ \env -> Log.logBuildFailed env "//..." (T.pack (show err))
      pure $ Left err
    [] -> do
      -- Flatten all (Package, Rule, Action) triples
      let allTriples = concat [triples | Right triples <- actionResults]

      -- Build unified nameToKey map across ALL packages
      -- This is crucial for cross-package dependency resolution
      let nameToKey = Map.fromList [(aName a, actionKey a) | (_, _, a) <- allTriples]

      -- Resolve dependencies for all actions using unified map
      let resolvedActions = [resolveDepsForRule nameToKey pkg r a | (pkg, r, a) <- allTriples]

      -- Build unified graph from resolved actions
      let graph = foldl (\g a -> addAction a g) emptyGraph resolvedActions
          rootKeys = [actionKey a | a <- resolvedActions]
          unifiedGraph = graph {agRoots = rootKeys}

      -- Execute the unified graph with DICE
      cache <- newCache
      execResult <- executeGraphWithJobs mJobs cache runAction unifiedGraph
      case erFailed execResult of
        ((_, err) : _) -> do
          logMaybe blog $ \env -> Log.logBuildFailed env "//..." err
          pure $ Left $ CommandFailed "graph" 1 err
        [] -> do
          let total = erExecuted execResult + erCacheHits execResult
          logMaybe blog $ \env -> Log.logBuildComplete env "//..." 0
          pure $ Right total

-- | Build action graph for ALL rules in a package
buildAllActionGraph ::
  Toolchains ->
  FilePath ->
  Package ->
  FilePath ->
  IO (Either BuildError ActionGraph)
buildAllActionGraph tc projectRoot pkg outDir = do
  let allRules = pkg.rules

  -- Build actions for all rules
  actionsResult <- buildActionsWithRules tc projectRoot pkg.path outDir allRules
  case actionsResult of
    Left err -> pure $ Left err
    Right ruleActionPairs -> do
      let nameToKey = Map.fromList [(aName a, actionKey a) | (_, a) <- ruleActionPairs]
          resolvedActions = [resolveDepsForRule nameToKey pkg r a | (r, a) <- ruleActionPairs]
          graph = foldl (\g a -> addAction a g) emptyGraph resolvedActions
          -- All top-level rules are roots
          rootKeys = [actionKey a | a <- resolvedActions]
          graphWithRoots = graph {agRoots = rootKeys}
      pure $ Right graphWithRoots

-- | Build unresolved actions for all rules in a package
-- Returns (Package, Rule, Action) triples with aInputKeys = []
-- Cross-package dependencies are resolved later with a unified nameToKey map
buildAllActionsUnresolved ::
  Toolchains ->
  FilePath ->
  Package ->
  FilePath ->
  IO (Either BuildError [(Package, Rule, Action)])
buildAllActionsUnresolved tc projectRoot pkg outDir = do
  let allRules = pkg.rules
  actionsResult <- buildActionsWithRules tc projectRoot pkg.path outDir allRules
  pure $ case actionsResult of
    Left err -> Left err
    Right ruleActionPairs -> Right [(pkg, r, a) | (r, a) <- ruleActionPairs]

-- | Build an action graph from a rule and its dependencies
-- Supports both local (:target) and cross-package (//pkg:target) deps
buildActionGraph ::
  Toolchains ->
  FilePath ->
  Package ->
  FilePath ->
  Rule ->
  IO (Either BuildError ActionGraph)
buildActionGraph tc projectRoot pkg _outDir rootRule = do
  -- Collect rules needed (root + transitive deps), including cross-package
  (_, neededRules) <- collectDepsWithPackages projectRoot Map.empty pkg rootRule
  -- Build actions for all needed rules (paired with package+rule for dep resolution)
  actionsResult <- buildActionsWithPackages tc projectRoot neededRules
  pure $ buildGraph pkg rootRule =<< actionsResult
  where
    buildGraph :: Package -> Rule -> [(Package, Rule, Action)] -> Either BuildError ActionGraph
    buildGraph p rule pkgRuleActionTriples = Right graphWithRoot
      where
        -- Pass 1: Build name -> ActionKey mapping
        nameToKey = Map.fromList [(aName a, actionKey a) | (_, _, a) <- pkgRuleActionTriples]
        -- Pass 2: Resolve dependencies
        resolvedActions = [resolveDepsForRule nameToKey pkg' r a | (pkg', r, a) <- pkgRuleActionTriples]
        -- Build graph with resolved actions
        graph = foldl (\g a -> addAction a g) emptyGraph resolvedActions
        rootName = "//" <> T.pack p.path <> ":" <> ruleName rule
        rootKey = findRootKey resolvedActions rootName
        graphWithRoot = graph {agRoots = [rootKey]}

    findRootKey :: [Action] -> Text -> ActionKey
    findRootKey actions rootName
      | (k : _) <- [actionKey a | a <- actions, aName a == rootName] = k
      | (a : _) <- actions = actionKey a
      | otherwise = error "buildActionGraph: no actions" -- should never happen

-- | Parse a dependency reference
-- Returns (Maybe pkgPath, targetName)
-- ":foo" -> (Nothing, "foo")
-- "//pkg/path:foo" -> (Just "pkg/path", "foo")
parseDep :: Text -> (Maybe Text, Text)
parseDep dep
  | "//" `T.isPrefixOf` dep =
      -- Cross-package: //pkg/path:target
      let rest = T.drop 2 dep
       in case T.breakOn ":" rest of
            (pkgPath, colonTarget)
              | not (T.null colonTarget) ->
                  (Just pkgPath, T.drop 1 colonTarget)
            _ -> (Nothing, dep) -- malformed, treat as local
  | ":" `T.isPrefixOf` dep =
      -- Local: :target
      (Nothing, T.drop 1 dep)
  | otherwise =
      -- Bare name (legacy)
      (Nothing, dep)

-- | Collect all rules needed (transitive closure of deps)
-- Now handles cross-package deps by loading external packages
-- Returns (Package, Rule) pairs to preserve package info for each rule
collectDepsWithPackages ::
  FilePath -> -- project root
  Map Text Package -> -- cache of loaded packages
  Package -> -- current package
  Rule -> -- root rule
  IO (Map Text Package, [(Package, Rule)]) -- updated cache, rules in dependency order
collectDepsWithPackages projectRoot pkgCache pkg rootRule =
  go pkgCache [] [(pkg, rootRule)]
  where
    -- visited is [(Package, Rule)] pairs
    go cache visited [] = pure (cache, visited)
    go cache visited ((currentPkg, r) : rest)
      | any (\(p, v) -> ruleName v == ruleName r && p.path == currentPkg.path) visited =
          go cache visited rest
      | otherwise = do
          -- Get deps for this rule
          let deps = [dep | DepLocal dep <- ruleDeps r]

          -- Partition into local and cross-package
          let parsed = map parseDep deps
              localDeps = [(currentPkg, targetName) | (Nothing, targetName) <- parsed]
              crossPkgDeps = [(pkgPath, targetName) | (Just pkgPath, targetName) <- parsed]

          -- Load cross-package deps
          (cache', crossRules) <- loadCrossPackageDeps projectRoot cache crossPkgDeps

          -- Resolve local deps
          let ruleMap = Map.fromList [(ruleName rule, rule) | rule <- currentPkg.rules]
              localRules = [(currentPkg, ruleMap Map.! name) | (_, name) <- localDeps, Map.member name ruleMap]

          -- Continue with all deps - keep (currentPkg, r) pair in visited
          go cache' ((currentPkg, r) : visited) (localRules ++ crossRules ++ rest)

-- | Load cross-package dependencies
loadCrossPackageDeps ::
  FilePath ->
  Map Text Package ->
  [(Text, Text)] -> -- (pkgPath, targetName)
  IO (Map Text Package, [(Package, Rule)])
loadCrossPackageDeps projectRoot cache deps = go cache [] deps
  where
    go c rules [] = pure (c, rules)
    go c rules ((pkgPath, targetName) : rest) = do
      -- Check cache first
      (c', pkg) <- case Map.lookup pkgPath c of
        Just p -> pure (c, p)
        Nothing -> do
          -- Load package
          let dhallPath = projectRoot </> T.unpack pkgPath </> "BUILD.dhall"
          p <- Dhall.parsePackageFile projectRoot dhallPath
          pure (Map.insert pkgPath p c, p)

      -- Find the rule
      let ruleMap = Map.fromList [(ruleName rule, rule) | rule <- pkg.rules]
      case Map.lookup targetName ruleMap of
        Just rule -> go c' ((pkg, rule) : rules) rest
        Nothing -> go c' rules rest -- Skip missing (will error later)

-- | Collect deps for local-only case (backward compat)
_collectDeps :: Map Text Rule -> Rule -> [Rule]
_collectDeps ruleMap rootRule = go [] [rootRule]
  where
    go visited [] = visited
    go visited (r : rest)
      | any (\v -> ruleName v == ruleName r) visited = go visited rest
      | otherwise =
          let localDeps = [name | DepLocal name <- ruleDeps r]
              -- Strip leading ":" from dep names, ignore cross-package for now
              cleanDeps = [T.drop 1 n | n <- localDeps, ":" `T.isPrefixOf` n, not ("//" `T.isPrefixOf` n)]
              depRules = [ruleMap Map.! depName | depName <- cleanDeps, Map.member depName ruleMap]
           in go (r : visited) (depRules ++ rest)

-- | Build actions for a list of rules, returning (Rule, Action) pairs
-- Used for single-package builds (backward compat)
buildActionsWithRules ::
  Toolchains ->
  FilePath ->
  FilePath ->
  FilePath ->
  [Rule] ->
  IO (Either BuildError [(Rule, Action)])
buildActionsWithRules tc projectRoot pkgPath outDir rules = do
  results <- forM rules $ \rule -> do
    actionResult <- ruleToAction tc projectRoot pkgPath outDir rule
    pure (rule, actionResult)
  case [(r, e) | (r, Left e) <- results] of
    ((_, err) : _) -> pure $ Left err
    [] -> pure $ Right [(r, a) | (r, Right a) <- results]

-- | Build actions for rules from potentially different packages
-- Each rule builds into its own package's output dir
buildActionsWithPackages ::
  Toolchains ->
  FilePath ->
  [(Package, Rule)] ->
  IO (Either BuildError [(Package, Rule, Action)])
buildActionsWithPackages tc projectRoot pkgRules = do
  results <- forM pkgRules $ \(pkg, rule) -> do
    let outDir = projectRoot </> "sensenet-out" </> pkg.path
    createDirectoryIfMissing True outDir
    actionResult <- ruleToAction tc projectRoot pkg.path outDir rule
    pure (pkg, rule, actionResult)
  case [(p, r, e) | (p, r, Left e) <- results] of
    ((_, _, err) : _) -> pure $ Left err
    [] -> pure $ Right [(p, r, a) | (p, r, Right a) <- results]

-- | Resolve dependencies to ActionKeys
-- Takes the package and rule alongside the action to access deps
-- Handles both local (:target) and cross-package (//pkg:target) deps
resolveDepsForRule :: Map Text ActionKey -> Package -> Rule -> Action -> Action
resolveDepsForRule nameToKey pkg rule action =
  action {aInputKeys = depKeys}
  where
    -- Get deps from the rule
    allDeps = [name | DepLocal name <- ruleDeps rule]
    -- Convert dep names to full target names and look up keys
    depKeys =
      [ key
      | depName <- allDeps,
        let (maybePkg, targetName) = parseDep depName
            fullName = case maybePkg of
              Just pkgPath -> "//" <> pkgPath <> ":" <> targetName
              Nothing -> "//" <> T.pack pkg.path <> ":" <> targetName,
        Just key <- [Map.lookup fullName nameToKey]
      ]

-- ════════════════════════════════════════════════════════════════════════════
-- Cached Build
-- ════════════════════════════════════════════════════════════════════════════

-- | Build a rule with DICE caching
buildRuleWithCache ::
  ActionCache ->
  Toolchains ->
  FilePath ->
  FilePath ->
  Rule ->
  IO (Either BuildError BuildResult)
buildRuleWithCache cache tc projectRoot pkgPath rule = do
  let outDir = projectRoot </> "sensenet-out" </> pkgPath
  createDirectoryIfMissing True outDir

  -- Convert rule to action
  actionResult <- ruleToAction tc projectRoot pkgPath outDir rule
  case actionResult of
    Left err -> pure $ Left err
    Right action -> do
      let key = actionKey action

      -- Check cache
      cached <- checkCache cache key
      case cached of
        Just result -> do
          -- Verify outputs still exist
          let outputs = map T.unpack (arOutputs result)
          allExist <- and <$> mapM doesFileExist outputs
          if allExist
            then pure $ Right $ BuildCached outputs
            else executeAndCache cache key action outDir
        Nothing -> executeAndCache cache key action outDir

-- | Execute action and store in cache
executeAndCache :: ActionCache -> ActionKey -> Action -> FilePath -> IO (Either BuildError BuildResult)
executeAndCache cache key action outDir = do
  createDirectoryIfMissing True outDir
  result <- runAction action
  if arExitCode result == 0
    then do
      storeCache cache key result
      pure $ Right $ BuildSuccess (map T.unpack $ arOutputs result)
    else
      pure $
        Left $
          CommandFailed
            (T.intercalate " " $ take 2 $ aCommand action)
            (arExitCode result)
            (arStderr result)

-- ════════════════════════════════════════════════════════════════════════════
-- Rule to Action Conversion
-- ════════════════════════════════════════════════════════════════════════════

-- | Convert a rule to a DICE action (includes hashing sources)
ruleToAction ::
  Toolchains ->
  FilePath ->
  FilePath ->
  FilePath ->
  Rule ->
  IO (Either BuildError Action)
ruleToAction tc projectRoot pkgPath outDir = \case
  RCxxBinary bin -> cxxBinaryAction tc projectRoot pkgPath outDir bin
  RCxxLibrary lib -> cxxLibraryAction tc projectRoot pkgPath outDir lib
  RRustBinary bin -> rustBinaryAction tc projectRoot pkgPath outDir bin
  RRustLibrary lib -> rustLibraryAction tc projectRoot pkgPath outDir lib
  RHaskellBinary bin -> haskellBinaryAction tc projectRoot pkgPath outDir bin
  RHaskellLibrary lib -> haskellLibraryAction tc projectRoot pkgPath outDir lib
  RHaskellFFIBinary bin -> haskellFFIBinaryAction tc projectRoot pkgPath outDir bin
  RLeanBinary bin -> leanBinaryAction tc projectRoot pkgPath outDir bin
  RNixCxxBinary bin -> nixCxxBinaryAction tc projectRoot pkgPath outDir bin
  RNvBinary bin -> nvBinaryAction tc projectRoot pkgPath outDir bin
  RPureScriptApp app -> pureScriptAppAction tc projectRoot pkgPath outDir app
  RPureScriptBinary bin -> pureScriptBinaryAction tc projectRoot pkgPath outDir bin
  RPureScriptWebApp app -> pureScriptWebAppAction tc projectRoot pkgPath outDir app
  RGenrule gen -> genruleAction projectRoot pkgPath outDir gen
  RCratesIo crate -> cratesIoAction tc projectRoot pkgPath outDir crate
  _ -> pure $ Left $ CommandFailed "unsupported" 1 "Rule type not yet implemented"

-- ════════════════════════════════════════════════════════════════════════════
-- C++ Actions
-- ════════════════════════════════════════════════════════════════════════════

cxxBinaryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> CxxBinary -> IO (Either BuildError Action)
cxxBinaryAction tc projectRoot pkgPath outDir bin = do
  let srcDir = projectRoot </> pkgPath
      output = outDir </> T.unpack bin.name
      srcPaths = map (\s -> srcDir </> T.unpack s) bin.srcs

  -- Hash source files for cache key
  inputHashes <- hashSourceFiles srcPaths
  case inputHashes of
    Left err -> pure $ Left err
    Right hashes -> do
      let TC.Cxx {cxx = TC.Tool cxxPath, ld = TC.Tool ldPath, paths = TC.Paths incPaths libPaths} = tc.cxx
          includeFlags = concatMap (\i -> ["-isystem", i]) (map T.unpack incPaths)
          libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l]) (map T.unpack libPaths)
          -- Only use -fuse-ld= if ldPath is a known linker name (lld, gold, mold, etc.)
          -- Skip if it's a compiler path like "c++" or contains slashes
          ldFlag = case T.unpack ldPath of
            "lld" -> ["-fuse-ld=lld"]
            "gold" -> ["-fuse-ld=gold"]
            "mold" -> ["-fuse-ld=mold"]
            "bfd" -> ["-fuse-ld=bfd"]
            _ -> [] -- Use default linker (compiler's built-in)
          stdFlag = cxxStdFlag bin.std

          -- Build include and link flags for local deps
          (depIncludes, depLibs) = cxxDepFlags projectRoot outDir bin.deps

          cmd =
            [T.unpack cxxPath, "-o", output, stdFlag]
              ++ includeFlags
              ++ depIncludes
              ++ srcPaths -- full paths to source files
              ++ depLibs
              ++ libFlags
              ++ ldFlag

      pure $
        Right
          Action
            { aName = "//" <> T.pack pkgPath <> ":" <> bin.name,
              aCommand = map T.pack cmd,
              aInputs = hashes,
              aInputKeys = [],
              aOutputs = [T.pack output],
              aEnv = Map.empty,
              aCoeffects = [Filesystem (T.pack srcDir)]
            }

cxxLibraryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> CxxLibrary -> IO (Either BuildError Action)
cxxLibraryAction tc projectRoot pkgPath outDir lib = do
  let srcDir = projectRoot </> pkgPath
      output = outDir </> "lib" <> T.unpack lib.name <> ".a"
      srcPaths = map (\s -> srcDir </> T.unpack s) lib.srcs

  inputHashes <- hashSourceFiles srcPaths
  case inputHashes of
    Left err -> pure $ Left err
    Right hashes -> do
      let TC.Cxx {cxx = TC.Tool cxxPath, ar = TC.Tool arPath, paths = TC.Paths incPaths _} = tc.cxx
          includeFlags = concatMap (\i -> ["-isystem", i]) (map T.unpack incPaths)
          stdFlag = cxxStdFlag lib.std

          -- For library: compile to .o then archive
          -- Simplified: compile all sources directly
          cmd =
            [T.unpack cxxPath, "-c", stdFlag]
              ++ includeFlags
              ++ srcPaths -- full paths to source files
              ++ ["-o", output] -- This won't work for multi-source, but we handle it in runAction
      pure $
        Right
          Action
            { aName = "//" <> T.pack pkgPath <> ":" <> lib.name,
              aCommand = map T.pack cmd,
              aInputs = hashes,
              aInputKeys = [],
              aOutputs = [T.pack output],
              aEnv = Map.singleton "AR" (T.pack $ T.unpack arPath),
              aCoeffects = [Filesystem (T.pack srcDir)]
            }

cxxStdFlag :: CxxStd -> String
cxxStdFlag = \case
  Cxx11 -> "-std=c++11"
  Cxx14 -> "-std=c++14"
  Cxx17 -> "-std=c++17"
  Cxx20 -> "-std=c++20"
  Cxx23 -> "-std=c++23"

-- | Generate include and link flags for C++ dependencies
-- Returns (include flags, library paths)
cxxDepFlags :: FilePath -> FilePath -> [Dep] -> ([String], [String])
cxxDepFlags projectRoot outDir deps =
  let flags = map (cxxDepFlag projectRoot outDir) deps
   in (concatMap fst flags, concatMap snd flags)

-- | Generate flags for a single C++ dependency
cxxDepFlag :: FilePath -> FilePath -> Dep -> ([String], [String])
cxxDepFlag projectRoot outDir = \case
  DepLocal name ->
    let (maybePkg, targetName) = parseDep name
     in case maybePkg of
          Just pkgPath ->
            -- Cross-package dep: //pkg/path:target
            let depSrcDir = projectRoot </> T.unpack pkgPath
                depOutDir = projectRoot </> "sensenet-out" </> T.unpack pkgPath
                libPath = depOutDir </> "lib" <> T.unpack targetName <> ".a"
             in (["-I" <> depSrcDir], [libPath])
          Nothing ->
            -- Local dep: :target
            let depName = T.unpack targetName
                libPath = outDir </> "lib" <> depName <> ".a"
             in ([], [libPath]) -- Same package, no extra include needed
  DepFlake _ -> ([], []) -- TODO: handle flake deps

-- | Build a C++ binary with Nix flake dependencies
-- Resolves nixDeps using nix-analyze at planning time
nixCxxBinaryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> NixCxxBinary -> IO (Either BuildError Action)
nixCxxBinaryAction tc projectRoot pkgPath outDir bin = do
  inputHashes <- hashSourceFiles srcPaths
  nixFlags <- resolveNixDeps bin.nixDeps
  pure $ mkAction <$> inputHashes <*> nixFlags
  where
    srcDir = projectRoot </> pkgPath
    output = outDir </> T.unpack bin.name
    srcPaths = map (\s -> srcDir </> T.unpack s) bin.srcs
    TC.Cxx {cxx = TC.Tool cxxPath, ld = TC.Tool ldPath, paths = TC.Paths incPaths libPaths} = tc.cxx
    includeFlags = concatMap (\i -> ["-isystem", i]) (map T.unpack incPaths)
    libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l]) (map T.unpack libPaths)
    ldFlag = linkerFlag (T.unpack ldPath)

    mkAction :: [Text] -> [String] -> Action
    mkAction hashes flags =
      Action
        { aName = "//" <> T.pack pkgPath <> ":" <> bin.name,
          aCommand = map T.pack cmd,
          aInputs = hashes,
          aInputKeys = [],
          aOutputs = [T.pack output],
          aEnv = Map.empty,
          aCoeffects = [Filesystem (T.pack srcDir), Environment "NIX_PATH"]
        }
      where
        cmd =
          [T.unpack cxxPath, "-o", output]
            ++ includeFlags
            ++ flags
            ++ map T.unpack bin.compilerFlags
            ++ srcPaths
            ++ libFlags
            ++ ldFlag
            ++ map T.unpack bin.linkerFlags

    linkerFlag :: String -> [String]
    linkerFlag ld
      | ld == "lld" = ["-fuse-ld=lld"]
      | ld == "gold" = ["-fuse-ld=gold"]
      | ld == "mold" = ["-fuse-ld=mold"]
      | ld == "bfd" = ["-fuse-ld=bfd"]
      | otherwise = []

-- | Resolve Nix flake dependencies to compiler/linker flags
-- Uses SenseNet.Nix directly instead of an external binary
resolveNixDeps :: [Text] -> IO (Either BuildError [String])
resolveNixDeps deps = do
  result <- Nix.resolveNixDeps deps
  case result of
    Left err -> pure $ Left $ CommandFailed "nix" 1 err
    Right flags -> pure $ Right flags

-- ════════════════════════════════════════════════════════════════════════════
-- NVIDIA/CUDA Actions
-- ════════════════════════════════════════════════════════════════════════════

-- | Build an NVIDIA/CUDA binary using clang with CUDA support
-- Uses the Nv toolchain which provides clang with --cuda-gpu-arch flags
nvBinaryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> NvBinary -> IO (Either BuildError Action)
nvBinaryAction tc projectRoot pkgPath outDir bin = do
  case tc.nv of
    Nothing ->
      pure $ Left $ CommandFailed "nv" 1 "NVIDIA toolchain not configured in .sensenet/toolchains.dhall"
    Just nv -> do
      let srcDir = projectRoot </> pkgPath
          output = outDir </> T.unpack bin.name
          srcPaths = map (\s -> srcDir </> T.unpack s) bin.srcs

      inputHashes <- hashSourceFiles srcPaths
      case inputHashes of
        Left err -> pure $ Left err
        Right hashes -> do
          let TC.Tool clangPath = nv.clang
              TC.Paths sdkIncludes sdkLibs = nv.sdk
              sdkPath = T.unpack nv.sdk_path

              -- Use archs from the rule if specified, otherwise from toolchain
              -- nv.archs is [Text], bin.archs is [Gpu], so convert nv.archs
              nvArchsTyped = mapMaybe textToGpu nv.archs
              targetArchs :: [Gpu]
              targetArchs = if null bin.archs then nvArchsTyped else bin.archs

              -- CUDA flags for clang
              cudaFlags =
                [ "--cuda-path=" <> sdkPath,
                  "-x",
                  "cuda" -- Treat input as CUDA
                ]

              -- Architecture flags: --cuda-gpu-arch=sm_XX for each arch
              archFlags = concatMap (\gpu -> ["--cuda-gpu-arch=" <> T.unpack (gpuToArch gpu)]) targetArchs

              -- CUDA SDK include paths (including CCCL for cuda::std::mdspan etc.)
              ccclPath = sdkPath </> "include" </> "cccl"
              cudaIncludes =
                concatMap (\i -> ["-isystem", T.unpack i]) sdkIncludes
                  ++ ["-isystem", ccclPath]

              -- CUDA SDK library paths (need -B for crt files, -L for libs)
              cudaLibs = concatMap (\l -> ["-B" <> T.unpack l, "-L" <> T.unpack l]) sdkLibs

              -- Link against CUDA runtime
              linkFlags = ["-lcudart"]

              -- Get C++ stdlib paths from the cxx toolchain embedded in nv
              -- Use -B for crt startup files (Scrt1.o, crti.o, etc.) and -L for libraries
              TC.Paths cxxIncludes cxxLibs = nv.cxx.paths
              cxxIncludeFlags = concatMap (\i -> ["-isystem", T.unpack i]) cxxIncludes
              cxxLibFlags = concatMap (\l -> ["-B" <> T.unpack l, "-L" <> T.unpack l]) cxxLibs

              cmd =
                [T.unpack clangPath]
                  ++ cudaFlags
                  ++ archFlags
                  ++ cudaIncludes
                  ++ cxxIncludeFlags
                  ++ srcPaths
                  ++ cudaLibs
                  ++ cxxLibFlags
                  ++ linkFlags
                  ++ ["-o", output]

          pure $
            Right
              Action
                { aName = "//" <> T.pack pkgPath <> ":" <> bin.name,
                  aCommand = map T.pack cmd,
                  aInputs = hashes,
                  aInputKeys = [],
                  aOutputs = [T.pack output],
                  aEnv = Map.empty,
                  aCoeffects = [Filesystem (T.pack srcDir), CoeffectGpu (T.intercalate "," (map gpuToArch targetArchs))]
                }

-- ════════════════════════════════════════════════════════════════════════════
-- Rust Actions
-- ════════════════════════════════════════════════════════════════════════════

rustBinaryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> RustBinary -> IO (Either BuildError Action)
rustBinaryAction tc projectRoot pkgPath outDir bin = do
  let srcDir = projectRoot </> pkgPath
      output = outDir </> T.unpack bin.name
      srcPaths = map (\s -> srcDir </> T.unpack s) bin.srcs

  inputHashes <- hashSourceFiles srcPaths
  case inputHashes of
    Left err -> pure $ Left err
    Right hashes -> do
      let TC.Rust {rustc = TC.Tool rustcPath} = tc.rust
          editionFlag = "--edition=" <> rustEdition bin.edition
          mainSrc = T.unpack $ headOr "main.rs" bin.srcs

          -- Build --extern flags for deps (local and cross-package)
          externFlags = concatMap (rustExternFlag projectRoot outDir) bin.deps

          cmd =
            [T.unpack rustcPath, editionFlag]
              ++ externFlags
              ++ ["-o", output, srcDir </> mainSrc]

      pure $
        Right
          Action
            { aName = "//" <> T.pack pkgPath <> ":" <> bin.name,
              aCommand = map T.pack cmd,
              aInputs = hashes,
              aInputKeys = [],
              aOutputs = [T.pack output],
              aEnv = Map.empty,
              aCoeffects = [Filesystem (T.pack srcDir)]
            }

-- | Generate --extern flag for a Rust dependency
-- Handles both local (:target) and cross-package (//pkg:target) deps
rustExternFlag :: FilePath -> FilePath -> Dep -> [String]
rustExternFlag projectRoot outDir = \case
  DepLocal name ->
    let (maybePkg, targetName) = parseDep name
        depName = T.unpack targetName
     in case maybePkg of
          Just pkgPath ->
            -- Cross-package dep: //pkg/path:target
            let depOutDir = projectRoot </> "sensenet-out" </> T.unpack pkgPath
                rlibPath = depOutDir </> "lib" <> depName <> ".rlib"
             in ["--extern", depName <> "=" <> rlibPath]
          Nothing ->
            -- Local dep: :target
            let rlibPath = outDir </> "lib" <> depName <> ".rlib"
             in ["--extern", depName <> "=" <> rlibPath]
  DepFlake _ -> [] -- TODO: handle flake deps

rustLibraryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> RustLibrary -> IO (Either BuildError Action)
rustLibraryAction tc projectRoot pkgPath outDir lib = do
  let srcDir = projectRoot </> pkgPath
      output = outDir </> "lib" <> T.unpack lib.name <> ".rlib"
      srcPaths = map (\s -> srcDir </> T.unpack s) lib.srcs

  inputHashes <- hashSourceFiles srcPaths
  case inputHashes of
    Left err -> pure $ Left err
    Right hashes -> do
      let TC.Rust {rustc = TC.Tool rustcPath} = tc.rust
          editionFlag = "--edition=" <> rustEdition lib.edition
          mainSrc = T.unpack $ headOr "lib.rs" lib.srcs

          cmd = [T.unpack rustcPath, "--crate-type=rlib", editionFlag, "-o", output, srcDir </> mainSrc]

      pure $
        Right
          Action
            { aName = "//" <> T.pack pkgPath <> ":" <> lib.name,
              aCommand = map T.pack cmd,
              aInputs = hashes,
              aInputKeys = [],
              aOutputs = [T.pack output],
              aEnv = Map.empty,
              aCoeffects = [Filesystem (T.pack srcDir)]
            }

rustEdition :: RustEdition -> String
rustEdition = \case
  E2015 -> "2015"
  E2018 -> "2018"
  E2021 -> "2021"
  E2024 -> "2024"

-- ════════════════════════════════════════════════════════════════════════════
-- Haskell Actions
-- ════════════════════════════════════════════════════════════════════════════

haskellBinaryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> HaskellBinary -> IO (Either BuildError Action)
haskellBinaryAction tc projectRoot pkgPath outDir bin = do
  let srcDir = projectRoot </> pkgPath
      output = outDir </> T.unpack bin.name
      srcPaths = map (\s -> srcDir </> T.unpack s) bin.srcs

  inputHashes <- hashSourceFiles srcPaths
  case inputHashes of
    Left err -> pure $ Left err
    Right hashes -> do
      let TC.Haskell {ghc = TC.Tool ghcPath, ghc_pkg = TC.Tool ghcPkgPath} = tc.haskell
          mainSrc = srcDir </> T.unpack (headOr "Main.hs" bin.srcs)
          extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions

          -- Build -i flags for library dependencies
          depFlags = concatMap (haskellDepFlag projectRoot outDir) bin.deps

          -- Temporary directory for .hi/.o files during binary compilation
          -- This prevents polluting the source tree
          tmpDir = outDir </> T.unpack bin.name <> "-tmp"

      -- Resolve package names to IDs (fixes vector-benchmarks conflict)
      pkgFlags <- resolvePackageIds (T.unpack ghcPkgPath) bin.packages

      let cmd =
            [T.unpack ghcPath, "-o", output, "-hidir", tmpDir, "-odir", tmpDir, "-i" <> srcDir]
              ++ depFlags
              ++ pkgFlags
              ++ extFlags
              ++ map T.unpack bin.ghcOptions
              ++ [mainSrc]

      pure $
        Right
          Action
            { aName = "//" <> T.pack pkgPath <> ":" <> bin.name,
              aCommand = map T.pack cmd,
              aInputs = hashes,
              aInputKeys = [],
              -- Include tmpDir/.keep to ensure the temp directory is created
              aOutputs = [T.pack output, T.pack (tmpDir </> ".keep")],
              aEnv = Map.empty,
              aCoeffects = [Filesystem (T.pack srcDir)]
            }

-- | Generate -i flag for a Haskell dependency
-- Returns both the source path (for module lookup) and hi path (for interface reuse)
haskellDepFlag :: FilePath -> FilePath -> Dep -> [String]
haskellDepFlag projectRoot outDir = \case
  DepLocal name ->
    let (maybePkg, targetName) = parseDep name
        depName = T.unpack targetName
     in case maybePkg of
          Just pkgPath ->
            -- Cross-package dep: //pkg/path:target
            let srcDir = projectRoot </> T.unpack pkgPath
                depOutDir = projectRoot </> "sensenet-out" </> T.unpack pkgPath
                hiDir = depOutDir </> depName <> "-hi"
             in ["-i" <> srcDir, "-i" <> hiDir]
          Nothing ->
            -- Local dep: :target (same package, source is already in -i)
            let hiDir = outDir </> depName <> "-hi"
             in ["-i" <> hiDir]
  DepFlake _ -> [] -- TODO: handle flake deps

haskellLibraryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> HaskellLibrary -> IO (Either BuildError Action)
haskellLibraryAction tc projectRoot pkgPath outDir lib = do
  let srcDir = projectRoot </> pkgPath
      -- Output is a .hi/.o directory (we use package name as dir)
      hiDir = outDir </> T.unpack lib.name <> "-hi"
      srcPaths = map (\s -> srcDir </> T.unpack s) lib.srcs

  inputHashes <- hashSourceFiles srcPaths
  case inputHashes of
    Left err -> pure $ Left err
    Right hashes -> do
      let TC.Haskell {ghc = TC.Tool ghcPath, ghc_pkg = TC.Tool ghcPkgPath} = tc.haskell
          extFlags = map (\e -> "-X" <> T.unpack e) lib.languageExtensions

          -- Build -i flags for library dependencies
          depFlags = concatMap (haskellDepFlag projectRoot outDir) lib.deps

      -- Resolve package names to IDs (fixes vector-benchmarks conflict)
      pkgFlags <- resolvePackageIds (T.unpack ghcPkgPath) lib.packages

      let -- Compile to interface files and object files
          -- --make mode allows GHC to reuse existing .hi files and handle deps
          cmd =
            [T.unpack ghcPath, "--make", "-c", "-hidir", hiDir, "-odir", hiDir, "-i" <> srcDir]
              ++ depFlags
              ++ pkgFlags
              ++ extFlags
              ++ map T.unpack lib.ghcOptions
              ++ srcPaths

      pure $
        Right
          Action
            { aName = "//" <> T.pack pkgPath <> ":" <> lib.name,
              aCommand = map T.pack cmd,
              aInputs = hashes,
              aInputKeys = [],
              aOutputs = [T.pack hiDir],
              aEnv = Map.empty,
              aCoeffects = [Filesystem (T.pack srcDir)]
            }

-- | Build a Haskell binary with C++ FFI
-- This compiles C++ sources to object files, then links them with GHC
haskellFFIBinaryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> HaskellFFIBinary -> IO (Either BuildError Action)
haskellFFIBinaryAction tc projectRoot pkgPath outDir bin = do
  inputHashes <- hashSourceFiles (hsSrcPaths ++ cxxSrcPaths ++ cxxHeaderPaths)
  pkgFlags <- resolvePackageIds (T.unpack ghcPkgPath) bin.packages
  pure $ mkAction pkgFlags <$> inputHashes
  where
    srcDir = projectRoot </> pkgPath
    output = outDir </> T.unpack bin.name
    hsSrcPaths = map (\s -> srcDir </> T.unpack s) bin.hsSrcs
    cxxSrcPaths = map (\s -> srcDir </> T.unpack s) bin.cxxSrcs
    cxxHeaderPaths = map (\s -> srcDir </> T.unpack s) bin.cxxHeaders
    tmpDir = outDir </> T.unpack bin.name <> "-tmp"

    TC.Haskell {ghc = TC.Tool ghcPath, ghc_pkg = TC.Tool ghcPkgPath} = tc.haskell
    TC.Cxx {cxx = TC.Tool cxxPath, paths = TC.Paths incPaths _} = tc.cxx

    -- Find Main.hs in sources, or use the first source if no Main.hs
    mainSrcFile = headOr "Main.hs" $ filter (T.isSuffixOf "Main.hs") bin.hsSrcs ++ bin.hsSrcs
    mainSrc = srcDir </> T.unpack mainSrcFile
    extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions
    depFlags = concatMap (haskellDepFlag projectRoot outDir) bin.deps

    -- C++ compilation flags
    cxxIncludeFlags = concatMap (\i -> ["-isystem", i]) (map T.unpack incPaths)
    localIncludeFlags = concatMap (\i -> ["-I", srcDir </> T.unpack i]) bin.includeDirs
    allIncludeFlags = ["-I", srcDir] ++ localIncludeFlags ++ cxxIncludeFlags

    -- Extra library flags
    extraLibFlags = concatMap (\l -> ["-l" <> T.unpack l]) bin.extraLibs
    extraLibDirFlags = concatMap (\d -> ["-L" <> T.unpack d]) bin.extraLibDirs
    linkerFlagsStr = map T.unpack bin.linkerFlags

    -- Object file paths
    cxxObjFiles = map (\s -> tmpDir </> takeBaseName s <> ".o") cxxSrcPaths

    mkAction :: [String] -> [Text] -> Action
    mkAction pkgFlags hashes =
      Action
        { aName = "//" <> T.pack pkgPath <> ":" <> bin.name,
          aCommand = map T.pack cmd,
          aInputs = hashes,
          aInputKeys = [],
          aOutputs = [T.pack output, T.pack (tmpDir </> ".keep")],
          aEnv = Map.empty,
          aCoeffects = [Filesystem (T.pack srcDir)]
        }
      where
        mkCxxCompileCmd src obj =
          unwords $
            [T.unpack cxxPath, "-c", "-fPIC", "-o", obj] ++ allIncludeFlags ++ [src]
        cxxCompileCmds = zipWith mkCxxCompileCmd cxxSrcPaths cxxObjFiles
        ghcCmd =
          unwords $
            [T.unpack ghcPath, "-o", output, "-hidir", tmpDir, "-odir", tmpDir, "-i" <> srcDir]
              ++ depFlags
              ++ pkgFlags
              ++ extFlags
              ++ map T.unpack bin.ghcOptions
              ++ [mainSrc]
              ++ cxxObjFiles
              ++ extraLibDirFlags
              ++ extraLibFlags
              ++ concatMap (\f -> ["-optl", f]) linkerFlagsStr
              ++ ["-lstdc++"]
        shellCmd = "mkdir -p " <> tmpDir <> " && " <> intercalate " && " cxxCompileCmds <> " && " <> ghcCmd
        cmd = ["sh", "-c", shellCmd]

    takeBaseName :: FilePath -> String
    takeBaseName path = fst $ break (== '.') $ reverse $ takeWhile (/= '/') $ reverse path

-- ════════════════════════════════════════════════════════════════════════════
-- Lean Actions
-- ════════════════════════════════════════════════════════════════════════════

leanBinaryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> LeanBinary -> IO (Either BuildError Action)
leanBinaryAction tc projectRoot pkgPath outDir bin = do
  let srcDir = projectRoot </> pkgPath
      output = outDir </> T.unpack bin.name
      srcPaths = map (\s -> srcDir </> T.unpack s) bin.srcs

  inputHashes <- hashSourceFiles srcPaths
  case inputHashes of
    Left err -> pure $ Left err
    Right hashes -> do
      let TC.Lean {lean = TC.Tool leanPath, leanc = TC.Tool leancPath} = tc.lean
          buildDir = outDir </> "build"

          -- For multi-file projects with a root module, we need to:
          -- 1. Create a directory structure matching the module hierarchy
          -- 2. Symlink source files into that structure
          -- 3. Compile each module to .olean AND .c in dependency order
          -- 4. Link all .c files together
          shellCmd = case bin.rootModule of
            Nothing ->
              -- Single file: simple compile
              let mainSrc = srcDir </> T.unpack (headOr "Main.lean" bin.srcs)
                  cFile = output <> ".c"
               in T.unpack leanPath
                    <> " -c "
                    <> cFile
                    <> " "
                    <> mainSrc
                    <> " && "
                    <> T.unpack leancPath
                    <> " -o "
                    <> output
                    <> " "
                    <> cFile
            Just rootMod ->
              -- Multi-file: create module structure, compile, link
              let rootModStr = T.unpack rootMod
                  moduleDir = buildDir </> rootModStr

                  -- Copy source file into the module directory structure
                  -- Derivation.lean -> build/Straylight/Derivation.lean
                  copyFile src =
                    let srcFile = srcDir </> T.unpack src
                        targetFile = moduleDir </> T.unpack src
                     in "cp -f " <> srcFile <> " " <> targetFile

                  -- Compile each source file (now in proper location)
                  -- Produces both .olean and .c
                  compileModule src =
                    let baseName = takeWhile (/= '.') (T.unpack src)
                        targetFile = moduleDir </> T.unpack src
                        oleanFile = moduleDir </> baseName <> ".olean"
                        cFile = moduleDir </> baseName <> ".c"
                     in "LEAN_PATH="
                          <> buildDir
                          <> " "
                          <> T.unpack leanPath
                          <> " -o "
                          <> oleanFile
                          <> " -c "
                          <> cFile
                          <> " -R "
                          <> buildDir
                          <> " "
                          <> targetFile

                  -- Get C file path for each source
                  getCFile src =
                    let baseName = takeWhile (/= '.') (T.unpack src)
                     in moduleDir </> baseName <> ".c"

                  -- Build commands
                  mkdirCmd = "mkdir -p " <> moduleDir
                  copyCmds = map copyFile bin.srcs
                  compileCmds = map compileModule bin.srcs
                  cFiles = map getCFile bin.srcs
                  linkCmd = T.unpack leancPath <> " -o " <> output <> " " <> unwords cFiles

                  -- Chain all commands
                  allCmds = [mkdirCmd] ++ copyCmds ++ compileCmds ++ [linkCmd]
               in intercalate " && " allCmds

          cmd = ["sh", "-c", shellCmd]

      pure $
        Right
          Action
            { aName = "//" <> T.pack pkgPath <> ":" <> bin.name,
              aCommand = map T.pack cmd,
              aInputs = hashes,
              aInputKeys = [],
              aOutputs = [T.pack output],
              aEnv = Map.empty,
              aCoeffects = [Filesystem (T.pack srcDir)]
            }

-- ════════════════════════════════════════════════════════════════════════════
-- Genrule Actions
-- ════════════════════════════════════════════════════════════════════════════

genruleAction :: FilePath -> FilePath -> FilePath -> Genrule -> IO (Either BuildError Action)
genruleAction projectRoot pkgPath outDir gen = do
  let srcDir = projectRoot </> pkgPath
      output = outDir </> T.unpack gen.out
      srcPaths = map (\s -> srcDir </> T.unpack s) gen.srcs

  inputHashes <- hashSourceFiles srcPaths
  case inputHashes of
    Left err -> pure $ Left err
    Right hashes -> do
      let cmd = ["sh", "-c", T.unpack gen.cmd]
          -- Set $OUT, $SRCS, $SRCDIR for use in the command
          env =
            Map.fromList
              [ ("OUT", T.pack output),
                ("SRCDIR", T.pack srcDir),
                ("SRCS", T.unwords (map T.pack srcPaths))
              ]

      pure $
        Right
          Action
            { aName = "//" <> T.pack pkgPath <> ":" <> gen.name,
              aCommand = map T.pack cmd,
              aInputs = hashes,
              aInputKeys = [],
              aOutputs = [T.pack output],
              aEnv = env,
              aCoeffects = [Filesystem (T.pack srcDir), Sandbox "shell"]
            }

-- ════════════════════════════════════════════════════════════════════════════
-- PureScript Actions
-- ════════════════════════════════════════════════════════════════════════════

-- | Build a PureScript web application
-- Uses spago to compile and bundle, then copies assets to output
pureScriptAppAction :: Toolchains -> FilePath -> FilePath -> FilePath -> PureScriptApp -> IO (Either BuildError Action)
pureScriptAppAction tc projectRoot pkgPath outDir app = do
  pkgSetResult <- PS.fetchPackageSet app.packageSet
  either (pure . Left . toPkgError) (buildWithPkgSet app) pkgSetResult
  where
    srcDir = projectRoot </> pkgPath
    appDir = outDir </> T.unpack app.name
    pursOutputDir = srcDir </> "output"
    mainModule = T.unpack app.main
    TC.PureScript {purs = TC.Tool pursPath, esbuild = TC.Tool esbuildPath} = tc.purescript

    toPkgError :: PS.PureScriptError -> BuildError
    toPkgError err = PackageError $ "//" <> T.pack pkgPath <> ":" <> app.name <> ": " <> T.pack (show err)

    srcGlobs :: [String]
    srcGlobs = srcSpecToGlobs app.srcs
      where
        srcSpecToGlobs (SrcExplicit files) = map T.unpack files
        srcSpecToGlobs (SrcGlob pattern) = [T.unpack pattern]
        srcSpecToGlobs (SrcGlobs patterns) = map T.unpack patterns

    buildWithPkgSet :: PureScriptApp -> PS.PackageSet -> IO (Either BuildError Action)
    buildWithPkgSet app' pkgSet
      | Left err <- PS.resolveDeps pkgSet app'.deps = pure $ Left $ toPkgError err
      | Right allDeps <- PS.resolveDeps pkgSet app'.deps = do
          fetchResult <- PS.fetchPackages pkgSet allDeps
          either (pure . Left . toPkgError) buildWithCache fetchResult

    buildWithCache :: FilePath -> IO (Either BuildError Action)
    buildWithCache pkgCacheDir = do
      pkgDirs <- listDirectory pkgCacheDir
      let depGlobs = map (\d -> pkgCacheDir </> d </> "src/**/*.purs") pkgDirs
          pursGlobs = filter (".purs" `isSuffixOf`) srcGlobs ++ depGlobs
          configFiles =
            maybe [] (\h -> [srcDir </> T.unpack h]) app.indexHtml
              ++ maybe [] (\c -> [srcDir </> T.unpack c]) app.styleCss
      inputHashes <- hashSourceFiles configFiles
      pure $ mkAction pursGlobs <$> inputHashes

    mkAction :: [String] -> [Text] -> Action
    mkAction pursGlobs hashes =
      Action
        { aName = "//" <> T.pack pkgPath <> ":" <> app.name,
          aCommand = map T.pack cmd,
          aInputs = hashes,
          aInputKeys = [],
          aOutputs = [T.pack appDir],
          aEnv = Map.empty,
          aCoeffects = [Filesystem (T.pack srcDir)]
        }
      where
        quotedGlobs = unwords $ map (\g -> "'" <> g <> "'") pursGlobs
        shellCmd =
          unwords
            [ "mkdir -p",
              appDir,
              "&&",
              "cd",
              srcDir,
              "&&",
              T.unpack pursPath,
              "compile",
              quotedGlobs,
              "-o",
              pursOutputDir,
              "&&",
              T.unpack esbuildPath,
              pursOutputDir </> mainModule </> "index.js",
              "--bundle",
              "--outfile=" <> appDir </> "app.js"
            ]
            ++ maybe "" (\h -> " && cp " <> T.unpack h <> " " <> appDir </> T.unpack h) app.indexHtml
            ++ maybe "" (\c -> " && cp " <> T.unpack c <> " " <> appDir </> T.unpack c) app.styleCss
        cmd = ["sh", "-c", shellCmd]

-- | Build a PureScript Node.js binary using spago
-- Uses the project's spago.yaml for dependency management
pureScriptBinaryAction :: Toolchains -> FilePath -> FilePath -> FilePath -> PureScriptBinary -> IO (Either BuildError Action)
pureScriptBinaryAction tc projectRoot pkgPath outDir bin = do
  let srcDir = projectRoot </> pkgPath
      binName = T.unpack bin.name
      bundleJs = outDir </> binName <> ".js"
      wrapper = outDir </> binName
      mainModule = T.unpack bin.main
      spagoYaml = srcDir </> T.unpack bin.spagoYaml
      TC.PureScript {spago = mSpago, node = mNode, purs = mPurs, esbuild = mEsbuild} = tc.purescript

  case mSpago of
    TC.Tool "" -> pure $ Left $ PackageError "spago not configured in toolchain"
    TC.Tool spagoPath -> do
      let nodePath = case mNode of
            TC.Tool "" -> "node"
            TC.Tool n -> T.unpack n
          pursDir = case mPurs of
            TC.Tool "" -> ""
            TC.Tool p -> takeDirectory (T.unpack p)
          esbuildDir = case mEsbuild of
            TC.Tool "" -> ""
            TC.Tool e -> takeDirectory (T.unpack e)
          -- Add purs and esbuild to PATH so spago can find them
          pathSetup = "export PATH=\"" <> pursDir <> ":" <> esbuildDir <> ":$PATH\""
          -- spago bundle builds and bundles in one step
          wrapperScript =
            unlines
              [ "#!/usr/bin/env bash",
                "exec " <> nodePath <> " \"$(dirname \"$0\")/" <> binName <> ".js\" \"$@\""
              ]
          shellCmd =
            unwords
              [ pathSetup,
                "&&",
                "cd",
                srcDir,
                "&&",
                T.unpack spagoPath,
                "build",
                "&&",
                T.unpack spagoPath,
                "bundle",
                "--module",
                mainModule,
                "--platform",
                "node",
                "--outfile",
                bundleJs,
                "&&",
                "mkdir -p",
                outDir,
                "&&",
                "printf '%s'",
                "'" <> wrapperScript <> "'",
                ">",
                wrapper,
                "&&",
                "chmod +x",
                wrapper
              ]
          cmd = ["sh", "-c", shellCmd]

      inputHashes <- hashSourceFiles [spagoYaml]
      pure $ case inputHashes of
        Left err -> Left err
        Right hashes ->
          Right
            Action
              { aName = "//" <> T.pack pkgPath <> ":" <> bin.name,
                aCommand = map T.pack cmd,
                aInputs = hashes,
                aInputKeys = [],
                aOutputs = [T.pack wrapper, T.pack bundleJs],
                aEnv = Map.empty,
                aCoeffects = [Filesystem (T.pack srcDir)]
              }

-- | Build a PureScript web application using spago (browser platform)
-- Like pureScriptBinaryAction but bundles for browser and copies static assets
pureScriptWebAppAction :: Toolchains -> FilePath -> FilePath -> FilePath -> PureScriptWebApp -> IO (Either BuildError Action)
pureScriptWebAppAction tc projectRoot pkgPath outDir app = do
  let srcDir = projectRoot </> pkgPath
      appName = T.unpack app.name
      appDir = outDir </> appName
      bundleJs = appDir </> "app.js"
      mainModule = T.unpack app.main
      spagoYaml = srcDir </> T.unpack app.spagoYaml
      TC.PureScript {spago = mSpago, purs = mPurs, esbuild = mEsbuild} = tc.purescript

  case mSpago of
    TC.Tool "" -> pure $ Left $ PackageError "spago not configured in toolchain"
    TC.Tool spagoPath -> do
      let pursDir = case mPurs of
            TC.Tool "" -> ""
            TC.Tool p -> takeDirectory (T.unpack p)
          esbuildDir = case mEsbuild of
            TC.Tool "" -> ""
            TC.Tool e -> takeDirectory (T.unpack e)
          -- Add purs and esbuild to PATH so spago can find them
          pathSetup = "export PATH=\"" <> pursDir <> ":" <> esbuildDir <> ":$PATH\""
          -- Copy static files
          copyIndex = maybe "" (\h -> " && cp " <> T.unpack h <> " " <> appDir <> "/") app.indexHtml
          copyStyle = maybe "" (\c -> " && cp " <> T.unpack c <> " " <> appDir <> "/") app.styleCss
          shellCmd =
            unwords
              [ pathSetup,
                "&&",
                "cd",
                srcDir,
                "&&",
                T.unpack spagoPath,
                "build",
                "&&",
                T.unpack spagoPath,
                "bundle",
                "--module",
                mainModule,
                "--platform",
                "browser",
                "--outfile",
                bundleJs,
                "&&",
                "mkdir -p",
                appDir
              ]
              <> copyIndex
              <> copyStyle
          cmd = ["sh", "-c", shellCmd]

      inputHashes <- hashSourceFiles [spagoYaml]
      pure $ case inputHashes of
        Left err -> Left err
        Right hashes ->
          Right
            Action
              { aName = "//" <> T.pack pkgPath <> ":" <> app.name,
                aCommand = map T.pack cmd,
                aInputs = hashes,
                aInputKeys = [],
                aOutputs = [T.pack appDir],
                aEnv = Map.empty,
                aCoeffects = [Filesystem (T.pack srcDir)]
              }

-- ════════════════════════════════════════════════════════════════════════════
-- Rust Crates.io Actions
-- ════════════════════════════════════════════════════════════════════════════

-- | Build a Rust crate from crates.io
--
-- This fetches the crate, its dependencies, and compiles using rustc directly.
-- Produces an rlib that can be used by other Rust targets.
cratesIoAction :: Toolchains -> FilePath -> FilePath -> FilePath -> CratesIo -> IO (Either BuildError Action)
cratesIoAction tc projectRoot pkgPath outDir crate = do
  -- Fetch the crate from crates.io
  fetchResult <- RC.fetchCrate crate.name crate.version crate.sha256
  case fetchResult of
    Left err -> pure $ Left $ PackageError $ "//" <> T.pack pkgPath <> ":" <> crate.name <> ": " <> T.pack (show err)
    Right crateDir -> do
      -- Find the lib.rs or main.rs
      let srcPath = crateDir </> "src" </> "lib.rs"
          -- Normalize crate name: hyphens -> underscores (Rust convention)
          crateName = T.replace "-" "_" crate.name
          -- Output path uses lib{name}.rlib convention (matches rustLibraryAction and rustExternFlag)
          output = outDir </> "lib" <> T.unpack crateName <> ".rlib"

          -- Build rustc command
          TC.Rust {rustc = TC.Tool rustcPath} = tc.rust

          edition = "2021" -- Default to 2021, could be parsed from Cargo.toml

          -- For proc-macro crates, use --crate-type=proc-macro
          crateType = if crate.procMacro then "proc-macro" else "rlib"

          -- Feature flags: --cfg 'feature="name"' for each enabled feature
          -- Shell escaping: wrap in single quotes for sh -c
          featureFlags = concatMap (\f -> ["--cfg", "'feature=\"" <> T.unpack f <> "\"'"]) crate.features

          -- Build --extern flags for deps (same-package crate deps)
          -- Deps are target names like ":once_cell" or "once_cell"
          externFlags = concatMap (crateExternFlag projectRoot outDir pkgPath) crate.deps

          -- Build command
          shellCmd =
            unwords $
              [ "mkdir -p",
                outDir,
                "&&",
                T.unpack rustcPath,
                "--crate-name",
                T.unpack crateName,
                "--crate-type",
                crateType,
                "--edition",
                edition
              ]
                ++ featureFlags
                ++ externFlags
                ++ [ srcPath,
                     "-o",
                     output
                   ]

          cmd = ["sh", "-c", shellCmd]

      -- For input hashing, we use the crate checksum (format: "name-version:sha256")
      let inputHash = [crate.name <> "-" <> crate.version <> ":" <> crate.sha256]

      pure $
        Right
          Action
            { aName = "//" <> T.pack pkgPath <> ":" <> crate.name,
              aCommand = map T.pack cmd,
              aInputs = inputHash,
              aInputKeys = [],
              aOutputs = [T.pack output],
              aEnv = Map.empty,
              aCoeffects = [] -- Crate already fetched
            }

-- | Generate --extern flag for a crate dependency
-- Deps are Text target names: ":foo", "foo", or "//pkg:foo"
crateExternFlag :: FilePath -> FilePath -> FilePath -> Text -> [String]
crateExternFlag _projectRoot outDir _pkgPath dep =
  let -- Strip leading ":" if present
      cleanDep = if ":" `T.isPrefixOf` dep then T.drop 1 dep else dep
      -- Normalize: hyphens -> underscores
      crateName = T.replace "-" "_" cleanDep
      -- For now, assume same package (TODO: cross-package crate deps)
      rlibPath = outDir </> "lib" <> T.unpack crateName <> ".rlib"
   in ["--extern", T.unpack crateName <> "=" <> rlibPath]

-- ════════════════════════════════════════════════════════════════════════════
-- Memory Profiling via getrusage(2)
-- ════════════════════════════════════════════════════════════════════════════

-- | RUSAGE_CHILDREN = -1 (wait for terminated children)
foreign import capi "sys/resource.h value RUSAGE_CHILDREN"
  c_RUSAGE_CHILDREN :: CInt

-- | struct rusage size (conservatively large, actual is ~144 bytes on Linux x86_64)
rusageSize :: Int
rusageSize = 256

-- | Offset of ru_maxrss in struct rusage
-- On Linux x86_64: ru_maxrss is at offset 32 (after ru_utime and ru_stime, each 16 bytes)
-- struct timeval ru_utime (16), struct timeval ru_stime (16), long ru_maxrss
ruMaxrssOffset :: Int
ruMaxrssOffset = 32

-- | FFI import for getrusage(2)
foreign import capi "sys/resource.h getrusage"
  c_getrusage :: CInt -> Ptr () -> IO CInt

-- | Get peak memory (ru_maxrss) of all waited-for child processes in kilobytes
-- Returns 0 on error
getChildrenMaxRss :: IO Word64
getChildrenMaxRss = allocaBytes rusageSize $ \ptr -> do
  rc <- c_getrusage c_RUSAGE_CHILDREN ptr
  if rc == 0
    then do
      -- ru_maxrss is a long, in kilobytes on Linux
      maxrss <- peekByteOff ptr ruMaxrssOffset :: IO CLong
      pure $ fromIntegral maxrss
    else pure 0

-- ════════════════════════════════════════════════════════════════════════════
-- Action Execution
-- ════════════════════════════════════════════════════════════════════════════

-- | Execute an action
runAction :: Action -> IO ActionResult
runAction Action {..} = do
  startTime <- getCurrentTime
  mapM_ (createDirectoryIfMissing True . takeDirectory . T.unpack) aOutputs
  startMaxRss <- getChildrenMaxRss
  result <- executeCommand (parseCommand aCommand) aEnv
  endMaxRss <- getChildrenMaxRss
  endTime <- getCurrentTime
  let peakMemoryKB = if endMaxRss > startMaxRss then endMaxRss - startMaxRss else endMaxRss
  pure $ mkResult aOutputs startTime endTime peakMemoryKB result
  where
    parseCommand :: [Text] -> (String, [String])
    parseCommand cmds
      | [] <- map T.unpack cmds = ("", [])
      | (e : as) <- map T.unpack cmds = (e, as)

    executeCommand :: (String, [String]) -> Map Text Text -> IO (Either String (ExitCode, String, String))
    executeCommand (exe, _) _
      | null exe = pure $ Left "Empty command"
    executeCommand (exe, args) envMap = do
      baseEnv <- getEnvironment
      let actionEnv = [(T.unpack k, T.unpack v) | (k, v) <- Map.toList envMap]
          fullEnv = actionEnv ++ baseEnv
          cp =
            (proc exe args)
              { std_in = NoStream,
                std_out = CreatePipe,
                std_err = CreatePipe,
                env = Just fullEnv
              }
      r <- tryIOError $ readCreateProcessWithExitCode cp ""
      pure $ either (Left . show) Right r

    mkResult :: [Text] -> Time.UTCTime -> Time.UTCTime -> Word64 -> Either String (ExitCode, String, String) -> ActionResult
    mkResult outputs start end peakMem result =
      ActionResult
        { arOutputs = outputs,
          arExitCode = exitCodeInt result,
          arStdout = either (const "") (\(_, o, _) -> T.pack o) result,
          arStderr = either T.pack (\(_, _, e) -> T.pack e) result,
          arStartTime = start,
          arEndTime = end,
          arPeakMemoryKB = peakMem
        }

    exitCodeInt :: Either String (ExitCode, String, String) -> Int
    exitCodeInt (Left _) = 127
    exitCodeInt (Right (ExitSuccess, _, _)) = 0
    exitCodeInt (Right (ExitFailure n, _, _)) = n

-- ════════════════════════════════════════════════════════════════════════════
-- Command Execution (low-level)
-- ════════════════════════════════════════════════════════════════════════════

-- | Run a command, return error or success
runCommand :: String -> [String] -> IO (Either BuildError ())
runCommand exe args = do
  (exitCode, _stdout, stderr) <- readProcessWithExitCode exe args ""
  case exitCode of
    ExitSuccess -> pure $ Right ()
    ExitFailure code ->
      pure $ Left $ CommandFailed (T.pack exe) code (T.pack stderr)

-- | Resolve package names to package IDs using ghc-pkg
-- This fixes issues with multiple packages having the same name (e.g., vector and vector-benchmarks)
resolvePackageIds :: FilePath -> [Text] -> IO [String]
resolvePackageIds ghcPkgPath packages = do
  ids <- forM packages $ \pkg -> do
    (exitCode, stdout, _stderr) <- readProcessWithExitCode ghcPkgPath ["--simple-output", "field", T.unpack pkg, "id"] ""
    case exitCode of
      ExitSuccess ->
        -- Take first line, trim whitespace
        let pkgId = takeWhile (/= '\n') $ dropWhile (== ' ') stdout
         in pure ["-package-id", pkgId]
      ExitFailure _ ->
        -- Fallback to -package if ghc-pkg fails
        pure ["-package", T.unpack pkg]
  pure $ concat ids

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

-- | Hash source files using mtime+size (fast) instead of SHA256 (slow)
-- This reduces per-file overhead from ~5ms to ~0.1ms
-- Cache invalidation is correct: mtime changes on any file modification
hashSourceFiles :: [FilePath] -> IO (Either BuildError [Text])
hashSourceFiles paths = do
  results <- forM paths $ \path -> do
    exists <- doesFileExist path
    if exists
      then Right . (T.pack path <>) . (":" <>) <$> hashFileFast path
      else pure $ Left $ SourceNotFound path
  pure $ sequence results

-- | Fast file hash using mtime + size (not content)
-- ~100x faster than SHA256 for small files
hashFileFast :: FilePath -> IO Text
hashFileFast path = do
  mtime <- getModificationTime path
  size <- getFileSize path
  pure $ T.pack (show mtime) <> ":" <> T.pack (show size)

-- | Get file size without reading content
getFileSize :: FilePath -> IO Integer
getFileSize path = do
  stat <- getFileStatus path
  pure $ fromIntegral $ fileSize stat

findRule :: Text -> [Rule] -> Maybe Rule
findRule name = foldr check Nothing
  where
    check r acc
      | ruleName r == name = Just r
      | otherwise = acc

-- ════════════════════════════════════════════════════════════════════════════
-- Package-level Dependencies
-- ════════════════════════════════════════════════════════════════════════════

-- | Get cross-package dependencies for a package
-- Returns list of package paths that this package depends on
packageDeps :: Package -> [Text]
packageDeps pkg =
  let allDeps = concatMap extractCrossPkgDeps pkg.rules
   in nub allDeps
  where
    -- Extract cross-package deps from a rule
    extractCrossPkgDeps :: Rule -> [Text]
    extractCrossPkgDeps rule =
      [ pkgPath
      | DepLocal name <- ruleDeps rule,
        let (maybePkg, _) = parseDep name,
        Just pkgPath <- [maybePkg]
      ]

    -- Simple nub (could use Set for efficiency but lists are small)
    nub [] = []
    nub (x : xs) = x : nub (filter (/= x) xs)

-- | Sort packages by dependencies (topological sort)
-- Packages with no deps come first, packages depending on others come later
-- Returns packages in build order (dependencies before dependents)
sortPackagesByDeps :: [Package] -> [Package]
sortPackagesByDeps pkgs = reverse $ go [] pkgSet pkgs
  where
    pkgSet = map (T.pack . (.path)) pkgs
    pkgMap = Map.fromList [(T.pack p.path, p) | p <- pkgs]

    go sorted _ [] = sorted
    go sorted remaining (p : rest)
      | T.pack p.path `elem` map (T.pack . (.path)) sorted = go sorted remaining rest
      | otherwise =
          -- Get deps that are in our package set
          let deps = filter (`elem` remaining) (packageDeps p)
              -- Recursively sort deps first
              depPkgs = [pkgMap Map.! d | d <- deps, Map.member d pkgMap]
              sorted' = foldl (\s dp -> if T.pack dp.path `elem` map (T.pack . (.path)) s then s else go s remaining [dp]) sorted depPkgs
           in go (p : sorted') remaining rest
