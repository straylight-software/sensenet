{-# LANGUAGE CApiFFI #-}
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
    BuildResult (..),
    BuildError (..),

    -- * Package-level dependencies
    packageDeps,
    sortPackagesByDeps,

    -- * Low-level
    runCommand,
  )
where

import Control.Exception (evaluate)
import Control.Monad (forM)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
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
    actionKey,
    actionKeyText,
    addAction,
    checkCache,
    emptyGraph,
    executeGraphWithJobs,
    hashFile,
    newCache,
    storeCache,
    topoSort,
  )
import SenseNet.Dhall qualified as Dhall
import SenseNet.IR
  ( CxxBinary (..),
    CxxLibrary (..),
    CxxStd (..),
    Dep (..),
    Genrule (..),
    HaskellBinary (..),
    HaskellLibrary (..),
    LeanBinary (..),
    Package (..),
    Rule (..),
    RustBinary (..),
    RustEdition (..),
    RustLibrary (..),
    ruleDeps,
    ruleName,
  )
import SenseNet.Toolchains (Toolchains (..))
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hGetContents)
import System.IO.Error (tryIOError)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, readProcessWithExitCode, waitForProcess)

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
  deriving (Show, Eq)

-- | Build errors
data BuildError
  = TargetNotFound Text
  | CommandFailed Text Int Text
  | DependencyFailed Text Text
  | SourceNotFound FilePath
  deriving (Show, Eq)

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
buildWithDeps = buildWithDepsJ Nothing

-- | Build a target with job limit
buildWithDepsJ ::
  -- | Max concurrent jobs (Nothing = unlimited)
  Maybe Int ->
  Toolchains ->
  -- | Project root
  FilePath ->
  -- | Package containing the target
  Package ->
  -- | Target name
  Text ->
  IO (Either BuildError BuildResult)
buildWithDepsJ mJobs tc projectRoot pkg targetName = do
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ TargetNotFound targetName
    Just rootRule -> do
      let outDir = projectRoot </> "sensenet-out" </> pkg.path
      createDirectoryIfMissing True outDir

      -- Build action graph with dependencies
      graphResult <- buildActionGraph tc projectRoot pkg outDir rootRule
      case graphResult of
        Left err -> pure $ Left err
        Right graph -> do
          cache <- newCache

          -- Execute graph in parallel (actions run as soon as deps complete)
          execResult <- executeGraphWithJobs mJobs cache runAction graph

          -- Check for failures
          case erFailed execResult of
            ((_, err) : _) -> pure $ Left $ CommandFailed "graph" 1 err
            [] -> do
              -- Find the root action's outputs
              case agRoots graph of
                [] -> pure $ Left $ CommandFailed "graph" 1 "no root action"
                (rootKey : _) -> case Map.lookup rootKey (erResults execResult) of
                  Just result -> pure $ Right $ BuildSuccess (map T.unpack $ arOutputs result)
                  Nothing -> pure $ Left $ CommandFailed "graph" 1 "root action not in results"

-- | Build all targets in a package in parallel
buildAllTargets ::
  Toolchains ->
  FilePath ->
  Package ->
  IO (Either BuildError Int)
buildAllTargets = buildAllTargetsJ Nothing

-- | Build all targets with job limit
buildAllTargetsJ ::
  -- | Max concurrent jobs (Nothing = unlimited)
  Maybe Int ->
  Toolchains ->
  FilePath ->
  Package ->
  IO (Either BuildError Int)
buildAllTargetsJ mJobs tc projectRoot pkg = do
  let outDir = projectRoot </> "sensenet-out" </> pkg.path
  createDirectoryIfMissing True outDir

  -- Build graph for ALL rules (no filtering)
  graphResult <- buildAllActionGraph tc projectRoot pkg outDir
  case graphResult of
    Left err -> pure $ Left err
    Right graph -> do
      cache <- newCache
      execResult <- executeGraphWithJobs mJobs cache runAction graph
      case erFailed execResult of
        ((_, err) : _) -> pure $ Left $ CommandFailed "graph" 1 err
        [] -> pure $ Right (erExecuted execResult + erCacheHits execResult)

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
  -- Each rule builds into its own package's output dir
  actionsResult <- buildActionsWithPackages tc projectRoot neededRules
  case actionsResult of
    Left err -> pure $ Left err
    Right pkgRuleActionTriples -> do
      -- Two-pass resolution:
      -- Pass 1: Build name -> ActionKey mapping using actions WITHOUT deps
      --         (needed because deps refer to names, not keys)
      let nameToKey = Map.fromList [(aName a, actionKey a) | (_, _, a) <- pkgRuleActionTriples]

      -- Pass 2: Resolve dependencies - update aInputKeys for each action
      let resolvedActions = [resolveDepsForRule nameToKey p r a | (p, r, a) <- pkgRuleActionTriples]

      -- Build graph with RESOLVED actions (keys will be recalculated by addAction)
      let graph = foldl (\g a -> addAction a g) emptyGraph resolvedActions
          -- Find root action (matches rootRule name)
          rootName = "//" <> T.pack pkg.path <> ":" <> ruleName rootRule
          rootKey = case [actionKey a | a <- resolvedActions, aName a == rootName] of
            (k : _) -> k
            [] -> case resolvedActions of
              (a : _) -> actionKey a
              [] -> error "buildActionGraph: no actions" -- should never happen
          graphWithRoot = graph {agRoots = [rootKey]}

      pure $ Right graphWithRoot

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
collectDeps :: Map Text Rule -> Rule -> [Rule]
collectDeps ruleMap rootRule = go [] [rootRule]
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
  RLeanBinary bin -> leanBinaryAction tc projectRoot pkgPath outDir bin
  RGenrule gen -> genruleAction projectRoot pkgPath outDir gen
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
              aCoeffects = ["fs:" <> T.pack srcDir]
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
              aCoeffects = ["fs:" <> T.pack srcDir]
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
              aCoeffects = ["fs:" <> T.pack srcDir]
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
              aCoeffects = ["fs:" <> T.pack srcDir]
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
      let TC.Haskell {ghc = TC.Tool ghcPath} = tc.haskell
          mainSrc = srcDir </> T.unpack (headOr "Main.hs" bin.srcs)
          pkgFlags = concatMap (\p -> ["-package", T.unpack p]) bin.packages
          extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions

          -- Build -i flags for library dependencies
          depFlags = concatMap (haskellDepFlag projectRoot outDir) bin.deps

          -- Temporary directory for .hi/.o files during binary compilation
          -- This prevents polluting the source tree
          tmpDir = outDir </> T.unpack bin.name <> "-tmp"

          cmd =
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
              aCoeffects = ["fs:" <> T.pack srcDir]
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
      let TC.Haskell {ghc = TC.Tool ghcPath} = tc.haskell
          pkgFlags = concatMap (\p -> ["-package", T.unpack p]) lib.packages
          extFlags = map (\e -> "-X" <> T.unpack e) lib.languageExtensions

          -- Build -i flags for library dependencies
          depFlags = concatMap (haskellDepFlag projectRoot outDir) lib.deps

          -- Compile to interface files and object files
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
              aCoeffects = ["fs:" <> T.pack srcDir]
            }

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
          mainSrc = srcDir </> T.unpack (headOr "Main.lean" bin.srcs)
          cFile = output <> ".c"
          -- Lean requires two steps: lean -c file.c file.lean && leanc -o binary file.c
          shellCmd =
            T.unpack leanPath
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
              aCoeffects = ["fs:" <> T.pack srcDir]
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
              aCoeffects = ["fs:" <> T.pack srcDir, "shell"]
            }

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

  let (exe, args) = case map T.unpack aCommand of
        [] -> ("", [])
        (e : as) -> (e, as)

  -- Ensure output directories exist (for all outputs)
  mapM_ (createDirectoryIfMissing True . takeDirectory . T.unpack) aOutputs

  -- Track peak memory before execution
  startMaxRss <- getChildrenMaxRss

  result <-
    if null exe
      then pure $ Left "Empty command"
      else do
        -- Merge action env with inherited environment
        baseEnv <- getEnvironment
        let actionEnv = [(T.unpack k, T.unpack v) | (k, v) <- Map.toList aEnv]
            fullEnv = actionEnv ++ baseEnv -- Action env takes precedence
        let cp =
              (proc exe args)
                { std_out = CreatePipe,
                  std_err = CreatePipe,
                  env = Just fullEnv
                }

        r <- tryIOError $ do
          (_, Just hOut, Just hErr, ph) <- createProcess cp
          stdout <- hGetContents hOut
          stderr <- hGetContents hErr
          -- Force evaluation before waiting
          _ <- evaluate (length stdout)
          _ <- evaluate (length stderr)
          exitCode <- waitForProcess ph
          pure (exitCode, stdout, stderr)

        case r of
          Left ioErr -> pure $ Left (show ioErr)
          Right res -> pure $ Right res

  -- Track peak memory after execution
  endMaxRss <- getChildrenMaxRss
  let peakMemoryKB = if endMaxRss > startMaxRss then endMaxRss - startMaxRss else endMaxRss

  endTime <- getCurrentTime

  case result of
    Left errMsg ->
      pure
        ActionResult
          { arOutputs = aOutputs,
            arExitCode = 127, -- Command not found
            arStdout = "",
            arStderr = T.pack errMsg,
            arStartTime = startTime,
            arEndTime = endTime,
            arPeakMemoryKB = peakMemoryKB
          }
    Right (exitCode, stdout, stderr) ->
      pure
        ActionResult
          { arOutputs = aOutputs,
            arExitCode = case exitCode of
              ExitSuccess -> 0
              ExitFailure n -> n,
            arStdout = T.pack stdout,
            arStderr = T.pack stderr,
            arStartTime = startTime,
            arEndTime = endTime,
            arPeakMemoryKB = peakMemoryKB
          }

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

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

-- | Hash source files, return error if any don't exist
hashSourceFiles :: [FilePath] -> IO (Either BuildError [Text])
hashSourceFiles paths = do
  results <- forM paths $ \path -> do
    exists <- doesFileExist path
    if exists
      then Right . (T.pack path <>) . (":" <>) <$> hashFile path
      else pure $ Left $ SourceNotFound path
  pure $ sequence results

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
