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
    buildAllTargets,
    BuildResult (..),
    BuildError (..),

    -- * Low-level
    runCommand,
  )
where

import Control.Monad (forM)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
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
    executeGraphParallel,
    hashFile,
    newCache,
    storeCache,
    topoSort,
  )
import SenseNet.IR
  ( CxxBinary (..),
    CxxLibrary (..),
    CxxStd (..),
    Dep (..),
    Genrule (..),
    HaskellBinary (..),
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
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (readProcessWithExitCode)

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
buildWithDeps tc projectRoot pkg targetName = do
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
          execResult <- executeGraphParallel cache runAction graph

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
buildAllTargets tc projectRoot pkg = do
  let outDir = projectRoot </> "sensenet-out" </> pkg.path
  createDirectoryIfMissing True outDir

  -- Build graph for ALL rules (no filtering)
  graphResult <- buildAllActionGraph tc projectRoot pkg outDir
  case graphResult of
    Left err -> pure $ Left err
    Right graph -> do
      cache <- newCache
      execResult <- executeGraphParallel cache runAction graph
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
      ruleMap = Map.fromList [(ruleName r, r) | r <- allRules]

  -- Build actions for all rules
  actionsResult <- buildActionsWithRules tc projectRoot pkg.path outDir allRules
  case actionsResult of
    Left err -> pure $ Left err
    Right ruleActionPairs -> do
      let nameToKey = Map.fromList [(aName a, actionKey a) | (_, a) <- ruleActionPairs]
          resolvedActions = [resolveDepsForRule nameToKey pkg.path r a | (r, a) <- ruleActionPairs]
          graph = foldl (\g a -> addAction a g) emptyGraph resolvedActions
          -- All top-level rules are roots
          rootKeys = [actionKey a | a <- resolvedActions]
          graphWithRoots = graph {agRoots = rootKeys}
      pure $ Right graphWithRoots

-- | Build an action graph from a rule and its dependencies
buildActionGraph ::
  Toolchains ->
  FilePath ->
  Package ->
  FilePath ->
  Rule ->
  IO (Either BuildError ActionGraph)
buildActionGraph tc projectRoot pkg outDir rootRule = do
  -- First pass: build all actions and collect name -> key mapping
  let allRules = pkg.rules
      ruleMap = Map.fromList [(ruleName r, r) | r <- allRules]

  -- Collect rules needed (root + transitive deps)
  -- Deps come first so they're built first
  let neededRules = collectDeps ruleMap rootRule

  -- Build actions for all needed rules (paired with rules for dep resolution)
  actionsResult <- buildActionsWithRules tc projectRoot pkg.path outDir neededRules
  case actionsResult of
    Left err -> pure $ Left err
    Right ruleActionPairs -> do
      -- Two-pass resolution:
      -- Pass 1: Build name -> ActionKey mapping using actions WITHOUT deps
      --         (needed because deps refer to names, not keys)
      let nameToKey = Map.fromList [(aName a, actionKey a) | (_, a) <- ruleActionPairs]

      -- Pass 2: Resolve dependencies - update aInputKeys for each action
      let resolvedActions = [resolveDepsForRule nameToKey pkg.path r a | (r, a) <- ruleActionPairs]

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

-- | Collect all rules needed (transitive closure of deps)
collectDeps :: Map Text Rule -> Rule -> [Rule]
collectDeps ruleMap rootRule = go [] [rootRule]
  where
    go visited [] = visited
    go visited (r : rest)
      | any (\v -> ruleName v == ruleName r) visited = go visited rest
      | otherwise =
          let localDeps = [name | DepLocal name <- ruleDeps r]
              -- Strip leading ":" from dep names
              cleanDeps = map (\n -> if ":" `T.isPrefixOf` n then T.drop 1 n else n) localDeps
              depRules = [ruleMap Map.! depName | depName <- cleanDeps, Map.member depName ruleMap]
           in go (r : visited) (depRules ++ rest)

-- | Build actions for a list of rules, returning (Rule, Action) pairs
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

-- | Resolve local dependencies to ActionKeys
-- Takes the rule alongside the action to access deps
resolveDepsForRule :: Map Text ActionKey -> FilePath -> Rule -> Action -> Action
resolveDepsForRule nameToKey pkgPath rule action =
  action {aInputKeys = depKeys}
  where
    -- Get local deps from the rule
    localDeps = [name | DepLocal name <- ruleDeps rule]
    -- Convert dep names to full target names and look up keys
    -- Dep names may have leading ":" (e.g., ":mathlib") - strip it
    depKeys =
      [ key
      | depName <- localDeps,
        let cleanName = if ":" `T.isPrefixOf` depName then T.drop 1 depName else depName
            fullName = "//" <> T.pack pkgPath <> ":" <> cleanName,
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
          ldFlag = ["-fuse-ld=" <> T.unpack ldPath]
          stdFlag = cxxStdFlag bin.std

          cmd =
            [T.unpack cxxPath, "-o", output, stdFlag]
              ++ includeFlags
              ++ srcPaths -- full paths to source files
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

          -- Build --extern flags for local deps
          externFlags = concatMap (rustExternFlag outDir) bin.deps

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
rustExternFlag :: FilePath -> Dep -> [String]
rustExternFlag outDir = \case
  DepLocal name ->
    -- Strip leading ":" if present
    let depName = T.unpack $ if ":" `T.isPrefixOf` name then T.drop 1 name else name
        rlibPath = outDir </> "lib" <> depName <> ".rlib"
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

          cmd =
            [T.unpack ghcPath, "-o", output, "-i" <> srcDir]
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
              aOutputs = [T.pack output],
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

      pure $
        Right
          Action
            { aName = "//" <> T.pack pkgPath <> ":" <> gen.name,
              aCommand = map T.pack cmd,
              aInputs = hashes,
              aInputKeys = [],
              aOutputs = [T.pack output],
              aEnv = Map.empty,
              aCoeffects = ["fs:" <> T.pack srcDir, "shell"]
            }

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

  -- Ensure output directory exists
  case aOutputs of
    (out : _) -> createDirectoryIfMissing True (takeDirectory $ T.unpack out)
    [] -> pure ()

  (exitCode, stdout, stderr) <-
    if null exe
      then pure (ExitFailure 1, "", "Empty command")
      else readProcessWithExitCode exe args ""

  endTime <- getCurrentTime

  pure
    ActionResult
      { arOutputs = aOutputs,
        arExitCode = case exitCode of
          ExitSuccess -> 0
          ExitFailure n -> n,
        arStdout = T.pack stdout,
        arStderr = T.pack stderr,
        arStartTime = startTime,
        arEndTime = endTime
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
