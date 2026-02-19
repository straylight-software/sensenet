{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Direct build execution using DICE
--
-- No Buck2, no Starlark, no BUCK files. Just:
--   BUILD.dhall → IR → DICE → execute
module SenseNet.Build
  ( build,
    buildWithDeps,
    buildWithConsole,
    buildWithBrickTUI,
    buildMultipleWithBrickTUI,
    buildMultipleStub,
    BuildResult (..),
    BuildError (..),
  )
where

import Brick.BChan (BChan, writeBChan)
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally)
import Control.Monad (forM, forM_, forever, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (ToJSON (..), encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate, isPrefixOf, nub, stripPrefix)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Word (Word64)
import Foreign.C.Types (CInt (..), CLong (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekByteOff)
import GHC.Generics (Generic)
import GHC.IO.Handle (hGetContents)
import SenseNet.Console qualified as Console
import SenseNet.DICE (DICE, DICEError, clearTargets, compute, computeMany, inject, registerTarget, runDICE, sha256, tryCompute)
import SenseNet.Dhall qualified as Dhall
import SenseNet.IR qualified as IR
import SenseNet.TUI qualified as TUI
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Posix.IO (stdOutput)
import System.Posix.Process (getProcessID)
import System.Posix.Terminal (queryTerminal)
import System.Process (CreateProcess (..), ProcessHandle, StdStream (..), createProcess, cwd, env, proc, readProcessWithExitCode, std_err, std_out, waitForProcess)

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

data BuildResult
  = BuildSuccess [FilePath] -- Output files
  | BuildCached [FilePath] -- Already up to date
  deriving (Show, Eq)

data BuildError
  = SourceNotFound FilePath
  | CompileFailed Text Int Text -- cmd, exit code, stderr
  | LinkFailed Text Int Text
  | DICEFailed DICEError
  | TargetNotFound Text
  | UnsupportedRule Text
  | PackageNotFound Text
  deriving (Show, Eq)

-- | Cache for loaded packages to avoid re-parsing BUILD.dhall
-- MILE MARKER: In Path B, this becomes part of the coeffect discharge state
type PackageCache = IORef (Map FilePath IR.Package)

-- | State for cross-package dependency resolution
data BuildContext = BuildContext
  { bcProjectRoot :: !FilePath,
    bcToolchains :: !TC.Toolchains,
    bcPkgCache :: !PackageCache,
    bcProcessed :: !(IORef (Set Text)), -- Fully qualified target names already registered
    bcRuleMap :: !(IORef (Map Text (IR.Rule, FilePath))) -- target -> (rule, pkgPath)
  }

-- ════════════════════════════════════════════════════════════════════════════
-- Build Entry Point
-- ════════════════════════════════════════════════════════════════════════════

-- | Build a target from a package (legacy - no dependency resolution)
build :: TC.Toolchains -> FilePath -> IR.Package -> Text -> IO (Either BuildError BuildResult)
build tc projectRoot pkg targetName = do
  -- Find the target
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ TargetNotFound targetName
    Just rule -> buildRule tc projectRoot pkg.path rule

-- | Build a target with full dependency resolution via DICE
--
-- This is the primary entry point for dependency-aware builds:
-- 1. Discovers all transitive dependencies (including cross-package)
-- 2. Registers all required rules with DICE
-- 3. Requests computation of the target
-- 4. DICE auto-resolves deps in the correct order
--
-- Supports cross-package dependencies like "//src/foo:bar" by lazily
-- loading packages as they're discovered.
--
-- @
-- buildWithDeps toolchains "." pkg "mybin"
-- @
buildWithDeps :: TC.Toolchains -> FilePath -> IR.Package -> Text -> IO (Either BuildError BuildResult)
buildWithDeps tc projectRoot pkg targetName = do
  -- Find the target first
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ TargetNotFound targetName
    Just _rule -> do
      -- Initialize build context for lazy loading
      pkgCache <- newIORef (Map.singleton pkg.path pkg)
      processedRef <- newIORef Set.empty
      ruleMapRef <- newIORef Map.empty

      let ctx =
            BuildContext
              { bcProjectRoot = projectRoot,
                bcToolchains = tc,
                bcPkgCache = pkgCache,
                bcProcessed = processedRef,
                bcRuleMap = ruleMapRef
              }

      -- Discover and register all transitive dependencies
      liftIO $ TIO.putStrLn $ "Discovering dependencies for " <> targetName <> "..."
      discoverResult <- discoverAndRegisterDeps ctx pkg targetName

      case discoverResult of
        Left err -> pure $ Left err
        Right () -> do
          -- Get the complete rule map
          ruleMap <- readIORef ruleMapRef

          -- Run DICE to compute
          result <- runDICE $ do
            clearTargets

            -- Register all discovered rules
            let allRules = Map.toList ruleMap
            liftIO $ TIO.putStrLn $ "Registering " <> T.pack (show $ length allRules) <> " targets..."

            forM_ allRules $ \(fqName, (rule, pkgPath)) -> do
              let deps = extractDepNames (IR.ruleDeps rule)
                  -- Qualify local deps with package path
                  qualifiedDeps = map (qualifyDep pkgPath) deps
              liftIO $ TIO.putStrLn $ "  " <> fqName <> " -> " <> T.pack (show qualifiedDeps)
              registerTarget fqName qualifiedDeps (makeCallbackWithContext ctx fqName)

            -- Compute the target (qualify it too)
            let fqTarget = "//" <> T.pack pkg.path <> ":" <> targetName
            liftIO $ TIO.putStrLn $ "\nComputing target: " <> fqTarget
            compute fqTarget

          case result of
            Left err -> pure $ Left $ DICEFailed err
            Right outputs -> pure $ Right $ BuildSuccess (map T.unpack outputs)

-- | Qualify a dep name with package path if it's local
qualifyDep :: FilePath -> Text -> Text
qualifyDep pkgPath dep
  | "//" `T.isPrefixOf` dep = dep -- Already fully qualified
  | otherwise = "//" <> T.pack pkgPath <> ":" <> dep

-- | Discover all transitive dependencies and register them
-- Uses a worklist algorithm to lazily load packages
discoverAndRegisterDeps :: BuildContext -> IR.Package -> Text -> IO (Either BuildError ())
discoverAndRegisterDeps ctx pkg targetName = do
  -- Initialize worklist with the initial target
  let initialFqName = "//" <> T.pack pkg.path <> ":" <> targetName
  worklistRef <- newIORef [initialFqName]

  let processWorklist = do
        worklist <- readIORef worklistRef
        case worklist of
          [] -> pure $ Right ()
          (fqName : rest) -> do
            writeIORef worklistRef rest

            -- Check if already processed
            processed <- readIORef (bcProcessed ctx)
            if fqName `Set.member` processed
              then processWorklist
              else do
                -- Parse the fully qualified name
                case parseFqName fqName of
                  Nothing -> pure $ Left $ TargetNotFound fqName
                  Just (pkgPath, tgtName) -> do
                    -- Load the package (cached)
                    pkgResult <- loadPackageCached ctx (T.unpack pkgPath)
                    case pkgResult of
                      Left err -> pure $ Left err
                      Right depPkg -> do
                        -- Find the rule
                        case findRule tgtName depPkg.rules of
                          Nothing -> pure $ Left $ TargetNotFound fqName
                          Just rule -> do
                            -- Mark as processed
                            modifyIORef' (bcProcessed ctx) (Set.insert fqName)

                            -- Add to rule map
                            modifyIORef' (bcRuleMap ctx) (Map.insert fqName (rule, depPkg.path))

                            -- Add deps to worklist
                            let deps = extractDepNames (IR.ruleDeps rule)
                                qualifiedDeps = map (qualifyDep depPkg.path) deps
                            modifyIORef' worklistRef (++ qualifiedDeps)

                            processWorklist

  processWorklist

-- | Parse "//pkg/path:target" into (pkgPath, targetName)
parseFqName :: Text -> Maybe (Text, Text)
parseFqName t
  | "//" `T.isPrefixOf` t = do
      let withoutSlashes = T.drop 2 t
      case T.breakOn ":" withoutSlashes of
        (pkgPath, rest)
          | T.null rest -> Nothing
          | otherwise -> Just (pkgPath, T.drop 1 rest)
  | otherwise = Nothing

-- | Load a package, using cache to avoid re-parsing
loadPackageCached :: BuildContext -> FilePath -> IO (Either BuildError IR.Package)
loadPackageCached ctx pkgPath = do
  cache <- readIORef (bcPkgCache ctx)
  case Map.lookup pkgPath cache of
    Just pkg -> pure $ Right pkg
    Nothing -> do
      let dhallPath = bcProjectRoot ctx </> pkgPath </> "BUILD.dhall"
      exists <- doesFileExist dhallPath
      if not exists
        then pure $ Left $ PackageNotFound (T.pack pkgPath)
        else do
          pkg <- Dhall.parsePackageFile (bcProjectRoot ctx) dhallPath
          modifyIORef' (bcPkgCache ctx) (Map.insert pkgPath pkg)
          pure $ Right pkg

-- | Make a callback that uses BuildContext for rule lookup
makeCallbackWithContext :: BuildContext -> Text -> Text -> Text -> IO Text
makeCallbackWithContext ctx fqName _targetName depsJson = do
  ruleMap <- readIORef (bcRuleMap ctx)
  case Map.lookup fqName ruleMap of
    Nothing -> pure $ mkResultJson [] 1 ("Target not found in context: " <> fqName) emptyProfile
    Just (rule, pkgPath) -> do
      let depOutputs = parseDepOutputs depsJson
      (result, profile) <-
        withProfiling $
          buildRuleWithDeps (bcToolchains ctx) (bcProjectRoot ctx) pkgPath rule depOutputs
      case result of
        Left err -> pure $ mkResultJson [] 1 (T.pack $ show err) profile
        Right (BuildSuccess outputs) -> pure $ mkResultJson outputs 0 "" profile
        Right (BuildCached outputs) -> pure $ mkResultJson outputs 0 "cached" emptyProfile

-- | Build state for console progress tracking
data BuildState = BuildState
  { bsTotal :: !Int,
    bsCompleted :: !Int,
    bsRunning :: !Int,
    bsCached :: !Int,
    bsActions :: ![(Word64, Text)], -- (action ID, name)
    bsNextId :: !Word64,
    bsLogs :: ![Text] -- Collected log messages to emit
  }

initialBuildState :: Int -> BuildState
initialBuildState total =
  BuildState
    { bsTotal = total,
      bsCompleted = 0,
      bsRunning = 0,
      bsCached = 0,
      bsActions = [],
      bsNextId = 1,
      bsLogs = []
    }

-- | Build a target with dependency resolution and superconsole TUI
buildWithConsole :: TC.Toolchains -> FilePath -> IR.Package -> Text -> IO (Either BuildError BuildResult)
buildWithConsole tc projectRoot pkg targetName = do
  -- Check if console is available
  isCompatible <- Console.compatible
  -- Debug: show compatibility check result
  -- TIO.putStrLn $ "[debug] Console.compatible = " <> T.pack (show isCompatible)
  if not isCompatible
    then do
      -- Fall back to non-console build (stderr not a tty)
      buildWithDeps tc projectRoot pkg targetName
    else do
      -- Run with console
      mResult <- Console.withBuildConsole $ \console progress -> do
        buildWithConsoleInner tc projectRoot pkg targetName console progress
      case mResult of
        Nothing -> do
          TIO.putStrLn "(Console initialization failed, using text output)"
          buildWithDeps tc projectRoot pkg targetName
        Just result -> pure result

-- | Inner function that runs with an initialized console
buildWithConsoleInner ::
  TC.Toolchains ->
  FilePath ->
  IR.Package ->
  Text ->
  Console.Console ->
  Console.BuildProgress ->
  IO (Either BuildError BuildResult)
buildWithConsoleInner tc projectRoot pkg targetName console progress = do
  -- Find the target first
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ TargetNotFound targetName
    Just _rule -> do
      -- Initialize build context for lazy loading
      pkgCache <- newIORef (Map.singleton pkg.path pkg)
      processedRef <- newIORef Set.empty
      ruleMapRef <- newIORef Map.empty

      let ctx =
            BuildContext
              { bcProjectRoot = projectRoot,
                bcToolchains = tc,
                bcPkgCache = pkgCache,
                bcProcessed = processedRef,
                bcRuleMap = ruleMapRef
              }

      -- Discover all transitive dependencies (silent, no console output during discovery)
      discoverResult <- discoverAndRegisterDeps ctx pkg targetName

      case discoverResult of
        Left err -> pure $ Left err
        Right () -> do
          -- Get the complete rule map
          ruleMap <- readIORef ruleMapRef
          let totalTargets = Map.size ruleMap

          -- Initialize build state
          stateRef <- newIORef (initialBuildState totalTargets)

          -- Initialize progress display
          Console.updateProgress
            progress
            (fromIntegral totalTargets)
            0
            0
            0

          -- Start render thread (updates display at ~10 Hz)
          renderDone <- newEmptyMVar
          renderThread <- forkIO $ renderLoop console progress stateRef renderDone

          -- Run the build
          result <- runDICE $ do
            clearTargets

            -- Register all discovered rules
            let allRules = Map.toList ruleMap
            forM_ allRules $ \(fqName, (rule, rulePkgPath)) -> do
              let deps = extractDepNames (IR.ruleDeps rule)
                  qualifiedDeps = map (qualifyDep rulePkgPath) deps
              registerTarget
                fqName
                qualifiedDeps
                (makeConsoleCallbackWithContext ctx console progress stateRef fqName)

            -- Compute the target (qualify it)
            let fqTarget = "//" <> T.pack pkg.path <> ":" <> targetName
            compute fqTarget

          -- Stop render thread
          putMVar renderDone ()
          killThread renderThread

          -- Final render to show completion
          state <- readIORef stateRef
          Console.updateProgress
            progress
            (fromIntegral $ bsTotal state)
            (fromIntegral $ bsCompleted state)
            0
            (fromIntegral $ bsCached state)
          _ <- Console.renderProgress console progress

          case result of
            Left err -> pure $ Left $ DICEFailed err
            Right outputs -> pure $ Right $ BuildSuccess (map T.unpack outputs)

-- | Build a target with the Brick TUI (replaces superconsole)
--
-- This provides a native Haskell TUI experience using Brick, with:
-- - Real-time progress bar
-- - Live list of running actions
-- - Scrollable log of completed actions
-- - Keyboard controls (q to quit, arrows to scroll)
--
-- Falls back to text output if not running in a TTY.
buildWithBrickTUI :: TC.Toolchains -> FilePath -> IR.Package -> Text -> IO (Either BuildError BuildResult)
buildWithBrickTUI tc projectRoot pkg targetName = do
  -- Check if stdout is a TTY
  isTTY <- queryTerminal stdOutput
  if not isTTY
    then buildWithDeps tc projectRoot pkg targetName -- Fall back to text mode
    else buildWithBrickTUIInner tc projectRoot pkg targetName

-- | Inner TUI build function (assumes TTY is available)
buildWithBrickTUIInner :: TC.Toolchains -> FilePath -> IR.Package -> Text -> IO (Either BuildError BuildResult)
buildWithBrickTUIInner tc projectRoot pkg targetName = do
  -- Find the target first
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ TargetNotFound targetName
    Just _rule -> do
      -- Initialize build context for lazy loading
      pkgCache <- newIORef (Map.singleton pkg.path pkg)
      processedRef <- newIORef Set.empty
      ruleMapRef <- newIORef Map.empty

      let ctx =
            BuildContext
              { bcProjectRoot = projectRoot,
                bcToolchains = tc,
                bcPkgCache = pkgCache,
                bcProcessed = processedRef,
                bcRuleMap = ruleMapRef
              }

      -- Discover all transitive dependencies (silent)
      discoverResult <- discoverAndRegisterDeps ctx pkg targetName

      case discoverResult of
        Left err -> pure $ Left err
        Right () -> do
          -- Get the complete rule map
          ruleMap <- readIORef ruleMapRef
          let totalTargets = Map.size ruleMap
              fqTarget = "//" <> T.pack pkg.path <> ":" <> targetName

          -- Action ID counter for unique IDs
          actionIdRef <- newIORef (1 :: Word64)

          -- Run with Brick TUI
          tuiResult <- TUI.runBuildWithTUI $ \chan -> do
            -- Send build started event
            writeBChan chan (TUI.EventBuildStarted totalTargets)

            -- Run DICE build
            result <- runDICE $ do
              clearTargets

              -- Register all discovered rules with TUI-aware callbacks
              let allRules = Map.toList ruleMap
              forM_ allRules $ \(fqName, (rule, rulePkgPath)) -> do
                let deps = extractDepNames (IR.ruleDeps rule)
                    qualifiedDeps = map (qualifyDep rulePkgPath) deps
                registerTarget
                  fqName
                  qualifiedDeps
                  (makeTUICallbackWithContext ctx chan actionIdRef fqName)

              -- Compute the target
              compute fqTarget

            case result of
              Left err -> pure $ Left $ T.pack $ show err
              Right outputs -> pure $ Right $ map T.unpack outputs

          -- Convert TUI result back to BuildResult
          case tuiResult of
            Left err -> pure $ Left $ DICEFailed $ error $ T.unpack err -- Should be a DICEError but we just have Text
            Right outputs -> pure $ Right $ BuildSuccess outputs

-- | Build multiple targets with a single TUI session
--
-- This collects all targets from all packages and builds them together,
-- showing unified progress across all targets.
buildMultipleWithBrickTUI ::
  TC.Toolchains ->
  FilePath ->
  [(IR.Package, Text)] -> -- List of (package, targetName) pairs
  IO (Either BuildError [BuildResult])
buildMultipleWithBrickTUI tc projectRoot targets = do
  -- Check if stdout is a TTY
  isTTY <- queryTerminal stdOutput
  if not isTTY
    then do
      -- Fall back to sequential text mode
      results <- forM targets $ \(pkg, targetName) ->
        buildWithDeps tc projectRoot pkg targetName
      pure $ sequence results
    else buildMultipleWithBrickTUIInner tc projectRoot targets

-- | Inner function for building multiple targets with TUI
buildMultipleWithBrickTUIInner ::
  TC.Toolchains ->
  FilePath ->
  [(IR.Package, Text)] ->
  IO (Either BuildError [BuildResult])
buildMultipleWithBrickTUIInner tc projectRoot targets = do
  -- Initialize shared build context
  pkgCache <- newIORef Map.empty
  processedRef <- newIORef Set.empty
  ruleMapRef <- newIORef Map.empty

  let ctx =
        BuildContext
          { bcProjectRoot = projectRoot,
            bcToolchains = tc,
            bcPkgCache = pkgCache,
            bcProcessed = processedRef,
            bcRuleMap = ruleMapRef
          }

  -- Pre-populate package cache and discover all deps for all targets
  allFqTargets <- forM targets $ \(pkg, targetName) -> do
    modifyIORef' pkgCache (Map.insert pkg.path pkg)
    discoverResult <- discoverAndRegisterDeps ctx pkg targetName
    case discoverResult of
      Left err -> pure $ Left err
      Right () -> pure $ Right $ "//" <> T.pack pkg.path <> ":" <> targetName

  -- Check for discovery errors
  case sequence allFqTargets of
    Left err -> pure $ Left err
    Right fqTargets -> do
      -- Get the complete rule map (all deps from all targets)
      ruleMap <- readIORef ruleMapRef
      let totalTargets = Map.size ruleMap

      -- Counters for tracking results
      actionIdRef <- newIORef (1 :: Word64)
      successCountRef <- newIORef (0 :: Int)

      -- Run with Brick TUI
      tuiResult <- TUI.runBuildWithTUI $ \chan -> do
        -- Send build started event with total count
        writeBChan chan (TUI.EventBuildStarted totalTargets)

        -- Run DICE build for all targets
        result <- runDICE $ do
          clearTargets

          -- Register all discovered rules
          let allRules = Map.toList ruleMap
          forM_ allRules $ \(fqName, (rule, rulePkgPath)) -> do
            let deps = extractDepNames (IR.ruleDeps rule)
                qualifiedDeps = map (qualifyDep rulePkgPath) deps
            registerTarget
              fqName
              qualifiedDeps
              (makeTUICallbackWithContext ctx chan actionIdRef fqName)

          -- Compute ALL targets with a SINGLE shared transaction
          -- computeMany provides keep-going semantics and proper memoization
          allResults <- computeMany fqTargets

          -- Count successes and collect outputs
          let successes = length [() | (_, Right _) <- allResults]
              allOutputs = concat [outs | (_, Right outs) <- allResults]
          liftIO $ writeIORef successCountRef successes
          pure allOutputs

        case result of
          Left err -> pure $ Left $ T.pack $ show err
          Right outputs -> pure $ Right $ map T.unpack outputs

      -- Get success count
      successCount <- readIORef successCountRef

      -- Convert TUI result - one BuildResult per successful target
      case tuiResult of
        Left err -> pure $ Left $ DICEFailed $ error $ T.unpack err
        Right outputs ->
          -- Return successCount number of BuildSuccess results
          pure $ Right $ replicate successCount (BuildSuccess outputs)

-- | Stub build for TUI development - creates empty outputs instantly
--
-- This mode is for iterating on TUI/build logic without waiting for real compilation.
-- Each target gets a random delay (50-500ms) to simulate realistic timing.
buildMultipleStub ::
  TC.Toolchains ->
  FilePath ->
  [(IR.Package, Text)] ->
  IO (Either BuildError [BuildResult])
buildMultipleStub tc projectRoot targets = do
  -- Check if stdout is a TTY
  isTTY <- queryTerminal stdOutput
  if not isTTY
    then do
      -- Text mode stub
      forM_ targets $ \(pkg, targetName) -> do
        let fqName = "//" <> T.pack pkg.path <> ":" <> targetName
        TIO.putStrLn $ "  [stub] " <> fqName
        threadDelay 100000 -- 100ms
      pure $ Right [BuildSuccess []]
    else buildMultipleStubWithTUI tc projectRoot targets

buildMultipleStubWithTUI ::
  TC.Toolchains ->
  FilePath ->
  [(IR.Package, Text)] ->
  IO (Either BuildError [BuildResult])
buildMultipleStubWithTUI tc projectRoot targets = do
  -- Initialize shared build context
  pkgCache <- newIORef Map.empty
  processedRef <- newIORef Set.empty
  ruleMapRef <- newIORef Map.empty

  let ctx =
        BuildContext
          { bcProjectRoot = projectRoot,
            bcToolchains = tc, -- Pass real toolchains (won't be used in stub mode)
            bcPkgCache = pkgCache,
            bcProcessed = processedRef,
            bcRuleMap = ruleMapRef
          }

  -- Pre-populate package cache and discover all deps for all targets
  allFqTargets <- forM targets $ \(pkg, targetName) -> do
    modifyIORef' pkgCache (Map.insert pkg.path pkg)
    discoverResult <- discoverAndRegisterDeps ctx pkg targetName
    case discoverResult of
      Left err -> pure $ Left err
      Right () -> pure $ Right $ "//" <> T.pack pkg.path <> ":" <> targetName

  -- Check for discovery errors
  case sequence allFqTargets of
    Left err -> pure $ Left err
    Right _fqTargets -> do
      -- Get the complete rule map (all deps from all targets)
      ruleMap <- readIORef ruleMapRef
      let totalTargets = Map.size ruleMap
          allRules = Map.toList ruleMap

      -- Action ID counter
      actionIdRef <- newIORef (1 :: Word64)

      -- Run with Brick TUI
      tuiResult <- TUI.runBuildWithTUI $ \chan -> do
        -- Send build started event
        writeBChan chan (TUI.EventBuildStarted totalTargets)

        -- Start all targets "in parallel" (send all start events first)
        -- Then complete them with staggered delays
        let rulesWithIds = zip [1 ..] allRules

        -- Send all start events
        forM_ rulesWithIds $ \(actionId, (fqName, _)) -> do
          writeBChan chan (TUI.EventActionStarted actionId fqName)
          threadDelay 50000 -- 50ms stagger between starts

        -- Complete them with varying delays (simulating different build times)
        forM_ rulesWithIds $ \(actionId, (fqName, _)) -> do
          -- Delay based on target name hash (200-800ms)
          let nameHash = sum (map fromEnum (T.unpack fqName)) `mod` 600
              delay = 200000 + nameHash * 1000

          threadDelay delay

          -- All targets succeed in stub mode
          let outputs = [projectRoot </> "sensenet-out" </> T.unpack fqName]
          writeBChan chan (TUI.EventActionCompleted actionId fqName outputs)

        pure $ Right []

      case tuiResult of
        Left err -> pure $ Left $ DICEFailed $ error $ T.unpack err
        Right _ -> pure $ Right [BuildSuccess []]

-- | TUI-aware callback for DICE with BuildContext
makeTUICallbackWithContext ::
  BuildContext ->
  BChan TUI.BuildEvent ->
  IORef Word64 -> -- Action ID counter
  Text -> -- Fully qualified target name (//pkg:target)
  Text -> -- Target name (from DICE, same as fqName here)
  Text -> -- Deps JSON
  IO Text -- Result JSON
makeTUICallbackWithContext ctx chan actionIdRef fqName _targetName depsJson = do
  -- Generate unique action ID
  actionId <- atomicModifyIORef' actionIdRef (\n -> (n + 1, n))

  -- Send action started event
  writeBChan chan (TUI.EventActionStarted actionId fqName)

  -- Build the target
  ruleMap <- readIORef (bcRuleMap ctx)
  resultJson <- case Map.lookup fqName ruleMap of
    Nothing -> do
      writeBChan chan (TUI.EventActionFailed actionId fqName "Target not found")
      pure $ mkResultJson [] 1 ("Target not found in context: " <> fqName) emptyProfile
    Just (rule, pkgPath) -> do
      let depOutputs = parseDepOutputs depsJson
      (result, profile) <-
        withProfiling $
          buildRuleWithDeps (bcToolchains ctx) (bcProjectRoot ctx) pkgPath rule depOutputs
      case result of
        Left err -> do
          writeBChan chan (TUI.EventActionFailed actionId fqName (T.pack $ show err))
          pure $ mkResultJson [] 1 (T.pack $ show err) profile
        Right (BuildSuccess outputs) -> do
          writeBChan chan (TUI.EventActionCompleted actionId fqName outputs)
          pure $ mkResultJson outputs 0 "" profile
        Right (BuildCached outputs) -> do
          writeBChan chan (TUI.EventActionCached actionId fqName outputs)
          pure $ mkResultJson outputs 0 "cached" emptyProfile

  pure resultJson

-- | Render loop that updates the console display
renderLoop :: Console.Console -> Console.BuildProgress -> IORef BuildState -> MVar () -> IO ()
renderLoop console progress stateRef done = go
  where
    go = do
      -- Check if we should stop
      -- Use a short delay for ~10 Hz refresh
      threadDelay 100000 -- 100ms

      -- Read current state
      state <- readIORef stateRef

      -- Emit any pending log messages
      forM_ (bsLogs state) $ \msg ->
        Console.emitLine console msg

      -- Clear emitted logs
      when (not $ null $ bsLogs state) $
        modifyIORef' stateRef $
          \s -> s {bsLogs = []}

      -- Update progress
      Console.updateProgress
        progress
        (fromIntegral $ bsTotal state)
        (fromIntegral $ bsCompleted state)
        (fromIntegral $ bsRunning state)
        (fromIntegral $ bsCached state)

      -- Render
      _ <- Console.renderProgress console progress

      -- Continue loop
      go

-- | Console-aware callback for DICE
makeConsoleCallback ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  Map Text IR.Rule ->
  Console.Console ->
  Console.BuildProgress ->
  IORef BuildState ->
  Text -> -- Target name
  Text -> -- Deps JSON
  IO Text -- Result JSON
makeConsoleCallback tc projectRoot pkgPath ruleMap console progress stateRef targetName depsJson = do
  -- Record action start
  actionId <- modifyIORefRet stateRef $ \s ->
    let newId = bsNextId s
        newActions = (newId, targetName) : bsActions s
     in (s {bsNextId = newId + 1, bsActions = newActions, bsRunning = bsRunning s + 1}, newId)

  -- Add action to progress display
  Console.addAction progress actionId targetName 0

  -- Build the target with profiling
  resultJson <- case Map.lookup targetName ruleMap of
    Nothing -> pure $ mkResultJson [] 1 ("Target not found: " <> targetName) emptyProfile
    Just rule -> do
      let depOutputs = parseDepOutputs depsJson
      (result, profile) <- withProfiling $ buildRuleWithDeps tc projectRoot pkgPath rule depOutputs
      case result of
        Left err -> pure $ mkResultJson [] 1 (T.pack $ show err) profile
        Right (BuildSuccess outputs) -> pure $ mkResultJson outputs 0 "" profile
        Right (BuildCached outputs) -> pure $ mkResultJson outputs 0 "cached" emptyProfile

  -- Record action completion
  Console.removeAction progress actionId

  -- Parse result to determine success/cached
  let isCached = "\"log\":\"cached\"" `T.isInfixOf` resultJson
      isSuccess = "\"exit_code\":0" `T.isInfixOf` resultJson

  modifyIORef' stateRef $ \s ->
    let newActions = filter ((/= actionId) . fst) (bsActions s)
        logMsg =
          if isSuccess
            then "  ✓ " <> targetName
            else "  ✗ " <> targetName
     in s
          { bsCompleted = bsCompleted s + 1,
            bsRunning = bsRunning s - 1,
            bsCached = if isCached then bsCached s + 1 else bsCached s,
            bsActions = newActions,
            bsLogs = bsLogs s ++ [logMsg]
          }

  pure resultJson

-- | Console-aware callback for DICE with BuildContext (supports cross-package deps)
makeConsoleCallbackWithContext ::
  BuildContext ->
  Console.Console ->
  Console.BuildProgress ->
  IORef BuildState ->
  Text -> -- Fully qualified target name (//pkg:target)
  Text -> -- Target name (from DICE, same as fqName here)
  Text -> -- Deps JSON
  IO Text -- Result JSON
makeConsoleCallbackWithContext ctx console progress stateRef fqName _targetName depsJson = do
  -- Record action start
  actionId <- modifyIORefRet stateRef $ \s ->
    let newId = bsNextId s
        newActions = (newId, fqName) : bsActions s
     in (s {bsNextId = newId + 1, bsActions = newActions, bsRunning = bsRunning s + 1}, newId)

  -- Add action to progress display
  Console.addAction progress actionId fqName 0

  -- Build the target with profiling
  ruleMap <- readIORef (bcRuleMap ctx)
  resultJson <- case Map.lookup fqName ruleMap of
    Nothing -> pure $ mkResultJson [] 1 ("Target not found in context: " <> fqName) emptyProfile
    Just (rule, pkgPath) -> do
      let depOutputs = parseDepOutputs depsJson
      (result, profile) <-
        withProfiling $
          buildRuleWithDeps (bcToolchains ctx) (bcProjectRoot ctx) pkgPath rule depOutputs
      case result of
        Left err -> pure $ mkResultJson [] 1 (T.pack $ show err) profile
        Right (BuildSuccess outputs) -> pure $ mkResultJson outputs 0 "" profile
        Right (BuildCached outputs) -> pure $ mkResultJson outputs 0 "cached" emptyProfile

  -- Record action completion
  Console.removeAction progress actionId

  -- Parse result to determine success/cached
  let isCached = "\"log\":\"cached\"" `T.isInfixOf` resultJson
      isSuccess = "\"exit_code\":0" `T.isInfixOf` resultJson

  modifyIORef' stateRef $ \s ->
    let newActions = filter ((/= actionId) . fst) (bsActions s)
        logMsg =
          if isSuccess
            then "  ✓ " <> fqName
            else "  ✗ " <> fqName
     in s
          { bsCompleted = bsCompleted s + 1,
            bsRunning = bsRunning s - 1,
            bsCached = if isCached then bsCached s + 1 else bsCached s,
            bsActions = newActions,
            bsLogs = bsLogs s ++ [logMsg]
          }

  pure resultJson

-- | Modify an IORef and return a value
modifyIORefRet :: IORef a -> (a -> (a, b)) -> IO b
modifyIORefRet ref f = do
  old <- readIORef ref
  let (new, ret) = f old
  writeIORef ref new
  pure ret

-- ════════════════════════════════════════════════════════════════════════════
-- Dependency Parsing
-- ════════════════════════════════════════════════════════════════════════════

-- | A parsed dependency reference
-- MILE MARKER: This will become part of BuildCoeffect.deps in Path B
data ParsedDep
  = LocalDep !Text -- Same-package dep: ":foo" or "foo"
  | CrossPkgDep !Text !Text -- Cross-package: "//pkg/path:target"
  deriving (Show, Eq)

-- | Parse a dependency string into structured form
--
-- Formats:
--   ":foo"           -> LocalDep "foo"
--   "foo"            -> LocalDep "foo"
--   "//pkg/path:bar" -> CrossPkgDep "pkg/path" "bar"
parseDep :: IR.Dep -> Maybe ParsedDep
parseDep (IR.DepLocal t)
  | "//" `T.isPrefixOf` t = parseCrossPkgDep t
  | ":" `T.isPrefixOf` t = Just $ LocalDep (T.drop 1 t)
  | otherwise = Just $ LocalDep t
parseDep (IR.DepFlake _) = Nothing -- External flake deps, not DICE targets

-- | Parse "//pkg/path:target" format
parseCrossPkgDep :: Text -> Maybe ParsedDep
parseCrossPkgDep t = do
  let withoutSlashes = T.drop 2 t -- Remove "//"
  case T.breakOn ":" withoutSlashes of
    (pkgPath, rest)
      | T.null rest -> Nothing -- No ":" found
      | otherwise -> Just $ CrossPkgDep pkgPath (T.drop 1 rest) -- Drop the ":"

-- | Partition deps into local and cross-package
partitionDeps :: [IR.Dep] -> ([Text], [(Text, Text)])
partitionDeps deps = foldr go ([], []) (mapMaybe parseDep deps)
  where
    go (LocalDep name) (locals, cross) = (name : locals, cross)
    go (CrossPkgDep pkg tgt) (locals, cross) = (locals, (pkg, tgt) : cross)

-- | Extract all dependency names (for DICE registration)
-- Cross-package deps use fully qualified names: "//pkg:target"
extractDepNames :: [IR.Dep] -> [Text]
extractDepNames = mapMaybe toDepName
  where
    toDepName (IR.DepLocal t)
      | "//" `T.isPrefixOf` t = Just t -- Already fully qualified
      | ":" `T.isPrefixOf` t = Just (T.drop 1 t) -- Strip leading ":"
      | otherwise = Just t
    toDepName (IR.DepFlake _) = Nothing

-- | Extract local dependency names from Dep list (legacy, same-package only)
-- Strips the leading ":" from ":foo" style deps
extractLocalDepNames :: [IR.Dep] -> [Text]
extractLocalDepNames = concatMap extract
  where
    extract (IR.DepLocal name)
      | "//" `T.isPrefixOf` name = [] -- Skip cross-package deps
      | ":" `T.isPrefixOf` name = [T.drop 1 name]
      | otherwise = [name]
    extract (IR.DepFlake _) = [] -- Flake deps are external, not DICE targets

-- | Get all cross-package dependencies from a list of deps
extractCrossPkgDeps :: [IR.Dep] -> [(Text, Text)]
extractCrossPkgDeps = snd . partitionDeps

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
-- On Linux x86_64: ru_maxrss is at offset 16 (after ru_utime and ru_stime, each 16 bytes)
-- This is the 3rd field: struct timeval ru_utime (16), struct timeval ru_stime (16), long ru_maxrss
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

-- | Run a build action with profiling (time and memory)
--
-- Memory tracking uses getrusage(RUSAGE_CHILDREN) to get the peak RSS of
-- waited-for child processes. Note that ru_maxrss reports the MAXIMUM RSS
-- across all children (not cumulative), so this approach works best when:
--
-- 1. Running builds sequentially (first profiling build)
-- 2. Each subsequent action spawns a child with higher memory usage
--
-- If a child uses less memory than a previous one, the reported memory will
-- be the delta from the previous max, which may be 0. This is acceptable for
-- the "first profiling build" use case where we run sequentially.
--
-- For accurate per-action tracking in parallel builds, we would need to use
-- cgroups or poll /proc/<pid>/status during execution.
--
-- Memory is tracked in kilobytes and converted to bytes for the result.
withProfiling :: IO a -> IO (a, ProfileData)
withProfiling action = do
  startTime <- getCurrentTime
  startMaxRss <- getChildrenMaxRss
  result <- action
  endTime <- getCurrentTime
  endMaxRss <- getChildrenMaxRss
  let elapsedMs = round (diffUTCTime endTime startTime * 1000) :: Word64
      -- Delta in KB, convert to bytes
      -- This captures the peak RSS if the child exceeded the previous max.
      -- If the child used less memory, delta will be 0 (see note above).
      peakMemoryKb = if endMaxRss > startMaxRss then endMaxRss - startMaxRss else 0
      peakMemoryBytes = peakMemoryKb * 1024
  pure (result, ProfileData elapsedMs peakMemoryBytes)

-- | Create a callback for a rule that builds it when invoked
-- The callback receives the target name and resolved dep outputs as JSON
makeCallback ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  Map Text IR.Rule ->
  Text -> -- Target name
  Text -> -- Deps JSON: [{"name": "dep1", "outputs": [...]}, ...]
  IO Text -- Result JSON: {"outputs": [...], "exit_code": N, "log": "...", "time_ms": N, "peak_memory_bytes": N}
makeCallback tc projectRoot pkgPath ruleMap targetName depsJson = do
  -- Debug output disabled to keep TUI clean
  -- TIO.putStrLn $ "  Building: " <> targetName
  -- TIO.putStrLn $ "    Deps: " <> depsJson

  case Map.lookup targetName ruleMap of
    Nothing -> pure $ mkResultJson [] 1 ("Target not found: " <> targetName) emptyProfile
    Just rule -> do
      -- Parse dep outputs for use in linking
      let depOutputs = parseDepOutputs depsJson

      -- Build the rule with profiling
      (result, profile) <- withProfiling $ buildRuleWithDeps tc projectRoot pkgPath rule depOutputs
      case result of
        Left err -> pure $ mkResultJson [] 1 (T.pack $ show err) profile
        Right (BuildSuccess outputs) -> pure $ mkResultJson outputs 0 "" profile
        Right (BuildCached outputs) -> pure $ mkResultJson outputs 0 "cached" emptyProfile

-- | Build a rule with resolved dependency outputs
buildRuleWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.Rule ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildRuleWithDeps tc projectRoot pkgPath rule depOutputs = case rule of
  IR.RCxxBinary r -> buildCxxBinaryWithDeps tc projectRoot pkgPath r depOutputs
  IR.RCxxLibrary r -> buildCxxLibrary tc projectRoot pkgPath r
  IR.RRustBinary r -> buildRustBinaryWithDeps tc projectRoot pkgPath r depOutputs
  IR.RRustLibrary r -> buildRustLibrary tc projectRoot pkgPath r
  IR.RHaskellBinary r -> buildHaskellBinaryWithDeps tc projectRoot pkgPath r depOutputs
  IR.RHaskellLibrary r -> buildHaskellLibrary tc projectRoot pkgPath r
  IR.RHaskellFFIBinary r -> buildHaskellFFIBinary tc projectRoot pkgPath r
  IR.RLeanBinary r -> buildLeanBinary tc projectRoot pkgPath r
  IR.RLeanLibrary r -> buildLeanLibrary tc projectRoot pkgPath r
  IR.RNvBinary r -> buildNvBinary tc projectRoot pkgPath r
  IR.RNvLibrary r -> buildNvLibrary tc projectRoot pkgPath r
  IR.RPureScriptApp r -> buildPureScriptApp tc projectRoot pkgPath r
  IR.RPureScriptBinary r -> buildPureScriptBinary tc projectRoot pkgPath r
  IR.RGenrule r -> buildGenrule tc projectRoot pkgPath r
  IR.RNixCxxBinary r -> buildNixCxxBinary tc projectRoot pkgPath r
  other -> pure $ Left $ UnsupportedRule $ T.pack $ show other

-- | Parse dep outputs JSON: [{"name": "dep1", "outputs": ["path1", ...]}, ...]
parseDepOutputs :: Text -> [(Text, [FilePath])]
parseDepOutputs json = case parseDepArray (T.unpack json) of
  Just deps -> deps
  Nothing -> []

-- | Simple JSON parser for dep array (avoids aeson dependency in hot path)
parseDepArray :: String -> Maybe [(Text, [FilePath])]
parseDepArray s = do
  -- Very simple parser - find each {"name": "...", "outputs": [...]}
  let entries = findDepEntries s
  pure entries

-- | Find all dep entries in the JSON string
findDepEntries :: String -> [(Text, [FilePath])]
findDepEntries s = go s []
  where
    go [] acc = reverse acc
    go str acc = case findNextEntry str of
      Nothing -> reverse acc
      Just (entry, rest) -> go rest (entry : acc)

    findNextEntry str =
      case dropWhile (/= '{') str of
        [] -> Nothing
        (_ : after) ->
          let (inside, rest) = span (/= '}') after
              mName = extractFieldString "name" inside
              mOutputs = extractFieldArray "outputs" inside
           in case (mName, mOutputs) of
                (Just name, Just outputs) -> Just ((T.pack name, outputs), drop 1 rest)
                _ -> Nothing

    extractFieldString field str =
      let pattern = "\"" ++ field ++ "\":\""
       in case findSubstring pattern str of
            Nothing -> Nothing
            Just after ->
              let (value, _) = span (/= '"') after
               in Just value

    extractFieldArray field str =
      let pattern = "\"" ++ field ++ "\":["
       in case findSubstring pattern str of
            Nothing -> Nothing
            Just after ->
              let (arrayContent, _) = span (/= ']') after
               in Just $ extractStrings arrayContent

    extractStrings s' = go' s' []
      where
        go' [] acc = reverse acc
        go' ('"' : rest) acc =
          let (val, rest') = span (/= '"') rest
           in go' (drop 1 rest') (val : acc)
        go' (_ : rest) acc = go' rest acc

    findSubstring needle haystack =
      case dropWhile (\h -> not $ needle `isPrefixOf` h) (tails haystack) of
        [] -> Nothing
        (match : _) -> Just $ drop (length needle) match

    tails [] = [[]]
    tails xs@(_ : xs') = xs : tails xs'

-- | Build profile data for memory-aware scheduling
-- This is returned from DICE and cached for future scheduling decisions
data ProfileData = ProfileData
  { profileTimeMs :: !Word64, -- Wall clock time in milliseconds
    profilePeakMemoryBytes :: !Word64 -- Peak resident set size in bytes
  }
  deriving (Show, Eq, Generic)

-- | Empty profile (for cached/skipped builds)
emptyProfile :: ProfileData
emptyProfile = ProfileData 0 0

-- | Result JSON structure for DICE callback
-- Uses explicit field names to match DICE FFI expectations
data DiceResult = DiceResult
  { dr_outputs :: [FilePath],
    dr_exit_code :: Int,
    dr_output_hash :: Text,
    dr_log :: Text,
    dr_time_ms :: Word64,
    dr_peak_memory_bytes :: Word64
  }
  deriving (Show, Eq, Generic)

-- Custom ToJSON to emit the expected field names without "dr_" prefix
instance ToJSON DiceResult where
  toJSON r =
    object
      [ "outputs" .= dr_outputs r,
        "exit_code" .= dr_exit_code r,
        "output_hash" .= dr_output_hash r,
        "log" .= dr_log r,
        "time_ms" .= dr_time_ms r,
        "peak_memory_bytes" .= dr_peak_memory_bytes r
      ]

-- | Create result JSON with profile data for DICE
mkResultJson :: [FilePath] -> Int -> Text -> ProfileData -> Text
mkResultJson outs exitCode logMsg profile =
  TE.decodeUtf8 $
    BL.toStrict $
      encode $
        DiceResult
          { dr_outputs = outs,
            dr_exit_code = exitCode,
            dr_output_hash = "",
            dr_log = logMsg,
            dr_time_ms = profileTimeMs profile,
            dr_peak_memory_bytes = profilePeakMemoryBytes profile
          }

findRule :: Text -> [IR.Rule] -> Maybe IR.Rule
findRule name = foldr (\r acc -> if IR.ruleName r == name then Just r else acc) Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- Rule Dispatch
-- ════════════════════════════════════════════════════════════════════════════

buildRule :: TC.Toolchains -> FilePath -> FilePath -> IR.Rule -> IO (Either BuildError BuildResult)
buildRule tc projectRoot pkgPath = \case
  IR.RCxxBinary r -> buildCxxBinary tc projectRoot pkgPath r
  IR.RCxxLibrary r -> buildCxxLibrary tc projectRoot pkgPath r
  IR.RRustBinary r -> buildRustBinary tc projectRoot pkgPath r
  IR.RRustLibrary r -> buildRustLibrary tc projectRoot pkgPath r
  IR.RHaskellBinary r -> buildHaskellBinary tc projectRoot pkgPath r
  IR.RHaskellLibrary r -> buildHaskellLibrary tc projectRoot pkgPath r
  IR.RHaskellFFIBinary r -> buildHaskellFFIBinary tc projectRoot pkgPath r
  IR.RLeanBinary r -> buildLeanBinary tc projectRoot pkgPath r
  IR.RLeanLibrary r -> buildLeanLibrary tc projectRoot pkgPath r
  IR.RNvBinary r -> buildNvBinary tc projectRoot pkgPath r
  IR.RNvLibrary r -> buildNvLibrary tc projectRoot pkgPath r
  IR.RPureScriptApp r -> buildPureScriptApp tc projectRoot pkgPath r
  IR.RPureScriptBinary r -> buildPureScriptBinary tc projectRoot pkgPath r
  IR.RGenrule r -> buildGenrule tc projectRoot pkgPath r
  IR.RNixCxxBinary r -> buildNixCxxBinary tc projectRoot pkgPath r
  rule -> pure $ Left $ UnsupportedRule $ T.pack $ show rule

-- ════════════════════════════════════════════════════════════════════════════
-- C++ Build
-- ════════════════════════════════════════════════════════════════════════════

buildCxxBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.CxxBinary -> IO (Either BuildError BuildResult)
buildCxxBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      ld = T.unpack tc.cxx.ld.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      cxxLibs = map T.unpack tc.cxx.paths.libs
      sysroot = T.unpack tc.cxx.sysroot

  -- Ensure output directory exists
  createDirectoryIfMissing True outDir

  -- Hash sources and inject into DICE
  diceResult <- runDICE $ do
    forM_ bin.srcs $ \src -> do
      let srcPath = srcDir </> T.unpack src
      exists <- liftIO $ doesFileExist srcPath
      if exists
        then do
          contents <- liftIO $ BS.readFile srcPath
          hash <- sha256 contents
          size <- liftIO $ fromIntegral <$> getFileSize srcPath
          inject (T.pack srcPath) hash size
        else pure () -- Will fail later
    pure ()

  case diceResult of
    Left err -> pure $ Left $ DICEFailed err
    Right () -> do
      -- Check all sources exist
      missingCheck <- checkSources srcDir bin.srcs
      case missingCheck of
        Just missing -> pure $ Left $ SourceNotFound missing
        Nothing -> do
          -- Compile
          let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs
              cflags = map T.unpack bin.cflags
              ldflags = map T.unpack bin.ldflags
              stdFlag = cxxStdFlag bin.std
              includeFlags = concatMap (\i -> ["-isystem", i]) cxxIncludes
              -- -B tells linker where to find crt*.o files, -L/-rpath for libraries
              libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) cxxLibs
              sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
              linkFlag = ["-fuse-ld=" <> ld]
              cmd = [cxx, stdFlag] ++ sysrootFlag ++ includeFlags ++ cflags ++ srcs ++ ["-o", outBin] ++ linkFlag ++ libFlags ++ ldflags

          -- TIO.putStrLn $ "  compile: " <> T.pack (unwords cmd)
          (exitCode, _stdout, stderr) <- readProcessWithExitCode cxx (tail cmd) ""

          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildCxxLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.CxxLibrary -> IO (Either BuildError BuildResult)
buildCxxLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      sysroot = T.unpack tc.cxx.sysroot

  createDirectoryIfMissing True outDir

  -- Compile each source to .o
  results <- forM lib.srcs $ \src -> do
    let srcPath = srcDir </> T.unpack src
        objPath = outDir </> T.unpack src <> ".o"
        stdFlag = cxxStdFlag lib.std
        cflags = map T.unpack lib.cflags
        includeFlags = concatMap (\i -> ["-isystem", i]) cxxIncludes
        sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
        cmd = [cxx, "-c", stdFlag] ++ sysrootFlag ++ includeFlags ++ cflags ++ [srcPath, "-o", objPath]

    exists <- doesFileExist srcPath
    if not exists
      then pure $ Left $ SourceNotFound srcPath
      else do
        -- TIO.putStrLn $ "  compile: " <> T.pack (unwords cmd)
        (exitCode, _, stderr) <- readProcessWithExitCode cxx (tail cmd) ""
        case exitCode of
          ExitSuccess -> pure $ Right objPath
          ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

  case sequence results of
    Left err -> pure $ Left err
    Right objs -> pure $ Right $ BuildSuccess objs

-- | Build C++ binary with resolved dependency outputs
-- Dep outputs (e.g., .o files from libraries) are linked in
buildCxxBinaryWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.CxxBinary ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildCxxBinaryWithDeps tc projectRoot pkgPath bin depOutputs = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      ld = T.unpack tc.cxx.ld.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      cxxLibs = map T.unpack tc.cxx.paths.libs
      sysroot = T.unpack tc.cxx.sysroot

  createDirectoryIfMissing True outDir

  -- Check all sources exist
  missingCheck <- checkSources srcDir bin.srcs
  case missingCheck of
    Just missing -> pure $ Left $ SourceNotFound missing
    Nothing -> do
      -- Compile and link
      let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs
          cflags = map T.unpack bin.cflags
          ldflags = map T.unpack bin.ldflags
          stdFlag = cxxStdFlag bin.std
          includeFlags = concatMap (\i -> ["-isystem", i]) cxxIncludes
          libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) cxxLibs
          sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
          linkFlag = ["-fuse-ld=" <> ld]
          -- Add dep outputs (.o files) to link line
          depObjs = concatMap snd depOutputs
          cmd =
            [cxx, stdFlag]
              ++ sysrootFlag
              ++ includeFlags
              ++ cflags
              ++ srcs
              ++ depObjs
              ++ ["-o", outBin]
              ++ linkFlag
              ++ libFlags
              ++ ldflags

      -- Debug: TIO.putStrLn $ "  compile (with deps): " <> T.pack (unwords cmd)
      (exitCode, _stdout, stderr) <- readProcessWithExitCode cxx (tail cmd) ""

      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- ════════════════════════════════════════════════════════════════════════════
-- Nix C++ Build
-- ════════════════════════════════════════════════════════════════════════════

buildNixCxxBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.NixCxxBinary -> IO (Either BuildError BuildResult)
buildNixCxxBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      ld = T.unpack tc.cxx.ld.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      cxxLibs = map T.unpack tc.cxx.paths.libs
      sysroot = T.unpack tc.cxx.sysroot

  createDirectoryIfMissing True outDir

  -- Resolve nix dependencies to get include/lib paths
  nixPaths <- resolveNixDeps bin.nixDeps
  case nixPaths of
    Left err -> pure $ Left $ CompileFailed "nix eval" 1 err
    Right (nixIncludes, nixLibPaths, nixLinkFlags) -> do
      -- Check all sources exist
      missingCheck <- checkSources srcDir bin.srcs
      case missingCheck of
        Just missing -> pure $ Left $ SourceNotFound missing
        Nothing -> do
          -- Compile
          let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs
              cflags = map T.unpack bin.compilerFlags
              ldflags = map T.unpack bin.linkerFlags
              includeFlags = concatMap (\i -> ["-isystem", i]) (cxxIncludes ++ nixIncludes)
              libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) (cxxLibs ++ nixLibPaths)
              sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
              linkFlag = ["-fuse-ld=" <> ld]
              cmd = [cxx, "-std=c++17"] ++ sysrootFlag ++ includeFlags ++ cflags ++ srcs ++ ["-o", outBin] ++ linkFlag ++ libFlags ++ nixLinkFlags ++ ldflags

          -- TIO.putStrLn $ "  compile: " <> T.pack (unwords cmd)
          (exitCode, _stdout, stderr) <- readProcessWithExitCode cxx (tail cmd) ""

          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- | Resolve nix flake refs to include/lib paths
-- Returns (includes, libPaths, linkFlags)
resolveNixDeps :: [Text] -> IO (Either Text ([FilePath], [FilePath], [String]))
resolveNixDeps deps = do
  results <- forM deps $ \dep -> do
    -- Get dev output for headers (fallback to out, then default)
    let flakeRef = T.unpack dep
        -- Extract package name for -l flag (e.g., "nixpkgs#zlib" -> "z")
        pkgName = extractPkgName dep

    -- Try dev output first for headers
    (devExit, devOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".dev.outPath"] ""
    devPath <-
      if devExit == ExitSuccess
        then pure devOut
        else do
          -- Fall back to out output
          (outExit, outOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".out.outPath"] ""
          if outExit == ExitSuccess
            then pure outOut
            else do
              -- Fall back to default output
              (mainExit, mainOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".outPath"] ""
              pure $ if mainExit == ExitSuccess then mainOut else ""

    -- Get out output for libs (not default, which may be bin)
    (outExit, outOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".out.outPath"] ""
    libPath <-
      if outExit == ExitSuccess
        then pure outOut
        else do
          -- Fall back to default output
          (mainExit, mainOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".outPath"] ""
          pure $ if mainExit == ExitSuccess then mainOut else ""

    if null devPath && null libPath
      then pure $ Left $ "Failed to resolve nix dep: " <> dep
      else pure $ Right (devPath, libPath, pkgName)

  case sequence results of
    Left err -> pure $ Left err
    Right paths -> do
      let includes = [p </> "include" | (p, _, _) <- paths, not (null p)]
          libPaths = [p </> "lib" | (_, p, _) <- paths, not (null p)]
          linkFlags = ["-l" <> n | (_, _, n) <- paths, not (null n)]
      pure $ Right (includes, libPaths, linkFlags)

-- | Extract library name from flake ref for -l flag
-- "nixpkgs#zlib" -> "z", "nixpkgs#openssl" -> "ssl"
extractPkgName :: Text -> String
extractPkgName ref = case T.splitOn "#" ref of
  [_, pkg] -> libNameFor (T.unpack pkg)
  _ -> ""
  where
    -- Common mappings
    libNameFor "zlib" = "z"
    libNameFor "openssl" = "ssl"
    libNameFor "sqlite" = "sqlite3"
    libNameFor "curl" = "curl"
    libNameFor "libpng" = "png"
    libNameFor "libjpeg" = "jpeg"
    libNameFor name = name

-- ════════════════════════════════════════════════════════════════════════════
-- Genrule Build
-- ════════════════════════════════════════════════════════════════════════════

buildGenrule :: TC.Toolchains -> FilePath -> FilePath -> IR.Genrule -> IO (Either BuildError BuildResult)
buildGenrule _tc projectRoot pkgPath gen = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outPath = outDir </> T.unpack gen.out

  createDirectoryIfMissing True outDir

  -- Substitute $SRCS and $OUT in command
  let srcs = T.intercalate " " $ map (\s -> T.pack $ srcDir </> T.unpack s) gen.srcs
      cmd = T.replace "$SRCS" srcs $ T.replace "$OUT" (T.pack outPath) gen.cmd

  -- TIO.putStrLn $ "  run: " <> cmd
  (exitCode, _, stderr) <- readProcessWithExitCode "sh" ["-c", T.unpack cmd] ""

  case exitCode of
    ExitSuccess -> pure $ Right $ BuildSuccess [outPath]
    ExitFailure n -> pure $ Left $ CompileFailed cmd n (T.pack stderr)

-- ════════════════════════════════════════════════════════════════════════════
-- Rust Build
-- ════════════════════════════════════════════════════════════════════════════

buildRustBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.RustBinary -> IO (Either BuildError BuildResult)
buildRustBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let rustc = T.unpack tc.rust.rustc.path
      target = T.unpack tc.rust.target

  createDirectoryIfMissing True outDir

  -- For single-file Rust, compile directly
  -- For multi-file, we'd need proper crate handling
  case bin.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag bin.edition
          cmd = [rustc, "--edition", edition, "--target", target, srcPath, "-o", outBin]

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          -- TIO.putStrLn $ "  rustc: " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    srcs -> do
      -- Multi-file: use first as main, compile all
      let mainSrc = srcDir </> T.unpack (head srcs)
          edition = rustEditionFlag bin.edition
          cmd = [rustc, "--edition", edition, "--target", target, mainSrc, "-o", outBin]

      -- TIO.putStrLn $ "  rustc: " <> T.pack (unwords cmd)
      (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildRustLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.RustLibrary -> IO (Either BuildError BuildResult)
buildRustLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      crateName = maybe (T.unpack lib.name) T.unpack lib.crateName
      outLib = outDir </> ("lib" <> crateName <> ".rlib")

  -- Toolchain
  let rustc = T.unpack tc.rust.rustc.path
      target = T.unpack tc.rust.target

  createDirectoryIfMissing True outDir

  case lib.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag lib.edition
          cmd =
            [ rustc,
              "--edition",
              edition,
              "--target",
              target,
              "--crate-type",
              "rlib",
              "--crate-name",
              crateName,
              srcPath,
              "-o",
              outLib
            ]

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          -- TIO.putStrLn $ "  rustc: " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outLib]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    _ -> pure $ Left $ UnsupportedRule "Multi-file Rust library"

-- | Build a Rust binary with resolved dependency outputs
buildRustBinaryWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.RustBinary ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildRustBinaryWithDeps tc projectRoot pkgPath bin depOutputs = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let rustc = T.unpack tc.rust.rustc.path
      target = T.unpack tc.rust.target

  createDirectoryIfMissing True outDir

  -- Extract .rlib files from deps and generate --extern flags
  let rlibFiles = concatMap snd depOutputs
      -- Get unique directories for -L flags
      libDirs = nub $ map takeDirectory rlibFiles
      libDirFlags = concatMap (\d -> ["-L", d]) libDirs
      -- Generate --extern cratename=path.rlib for each dep
      externFlags = concatMap mkExternFlag depOutputs

  case bin.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag bin.edition
          cmd =
            [rustc, "--edition", edition, "--target", target]
              ++ externFlags
              ++ libDirFlags
              ++ [srcPath, "-o", outBin]

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          -- TIO.putStrLn $ "  rustc (with deps): " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    srcs -> do
      -- Multi-file: use first as main
      let mainSrc = srcDir </> T.unpack (head srcs)
          edition = rustEditionFlag bin.edition
          cmd =
            [rustc, "--edition", edition, "--target", target]
              ++ externFlags
              ++ libDirFlags
              ++ [mainSrc, "-o", outBin]

      -- TIO.putStrLn $ "  rustc (with deps): " <> T.pack (unwords cmd)
      (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
  where
    -- Convert dep name + rlib path to --extern flag
    -- e.g., ("mathlib", [".../libmathlib.rlib"]) -> ["--extern", "mathlib=.../libmathlib.rlib"]
    mkExternFlag :: (Text, [FilePath]) -> [String]
    mkExternFlag (depName, paths) = case paths of
      [rlib] -> ["--extern", T.unpack depName <> "=" <> rlib]
      _ -> [] -- Skip if not exactly one .rlib

-- ════════════════════════════════════════════════════════════════════════════
-- Haskell Build
-- ════════════════════════════════════════════════════════════════════════════

buildHaskellBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.HaskellBinary -> IO (Either BuildError BuildResult)
buildHaskellBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let ghc = T.unpack tc.haskell.ghc.path
      pkgDb = tc.haskell.paths.includes -- Package DB paths
      libPaths = map T.unpack tc.haskell.paths.libs

  createDirectoryIfMissing True outDir

  -- Use srcs list, not main (main is the module name, not file)
  let srcFiles = map (\s -> srcDir </> T.unpack s) bin.srcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) bin.packages
      extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions
      ghcOpts = map T.unpack bin.ghcOptions
      mainFlag = ["-main-is", T.unpack bin.main]
      pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb
      libFlags = concatMap (\l -> ["-L" <> l]) libPaths
      includeFlags = ["-i" <> srcDir, "-i" <> outDir]
      cmd = [ghc] ++ pkgDbFlags ++ includeFlags ++ extFlags ++ pkgFlags ++ ghcOpts ++ mainFlag ++ srcFiles ++ ["-o", outBin] ++ libFlags

  -- Check first source exists
  case srcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (mainSrc : _) -> do
      exists <- doesFileExist mainSrc
      if not exists
        then pure $ Left $ SourceNotFound mainSrc
        else do
          -- TIO.putStrLn $ "  ghc: " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildHaskellLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.HaskellLibrary -> IO (Either BuildError BuildResult)
buildHaskellLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath

  -- Toolchain
  let ghc = T.unpack tc.haskell.ghc.path
      pkgDb = tc.haskell.paths.includes
      libPaths = map T.unpack tc.haskell.paths.libs

  createDirectoryIfMissing True outDir

  -- Create output subdirectories for nested modules
  forM_ lib.srcs $ \src -> do
    let objPath = outDir </> T.unpack src <> ".o"
    createDirectoryIfMissing True (takeDirectory objPath)

  -- Use --make mode to compile all sources at once (handles dependency order automatically)
  let srcFiles = map (\s -> srcDir </> T.unpack s) lib.srcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) lib.packages
      extFlags = map (\e -> "-X" <> T.unpack e) lib.languageExtensions
      ghcOpts = map T.unpack lib.ghcOptions
      pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb
      libFlags = concatMap (\l -> ["-L" <> l]) libPaths
      includeFlags = ["-i" <> srcDir, "-i" <> outDir]
      -- Use --make to handle dependency ordering, -no-link to avoid linking
      cmd =
        [ghc, "--make", "-no-link"]
          ++ pkgDbFlags
          ++ includeFlags
          ++ extFlags
          ++ pkgFlags
          ++ ghcOpts
          ++ ["-odir", outDir, "-hidir", outDir]
          ++ libFlags
          ++ srcFiles

  -- Check first source exists
  case srcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (firstSrc : _) -> do
      exists <- doesFileExist firstSrc
      if not exists
        then pure $ Left $ SourceNotFound firstSrc
        else do
          -- TIO.putStrLn $ "  ghc (lib): " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
          case exitCode of
            ExitSuccess -> do
              -- Return all .o files as outputs
              -- GHC --make puts .o at module path (e.g., SenseNet/IR.o not SenseNet/IR.hs.o)
              let srcToObj s = outDir </> dropHsExt (T.unpack s) <> ".o"
                  dropHsExt p = if ".hs" `isSuffixOf` p then take (length p - 3) p else p
                  isSuffixOf suf str = suf == drop (length str - length suf) str
                  objs = map srcToObj lib.srcs
              pure $ Right $ BuildSuccess objs
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- | Build Haskell binary with resolved dependency outputs
-- Dep outputs (.o and .hi files) are added to the compilation
buildHaskellBinaryWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.HaskellBinary ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildHaskellBinaryWithDeps tc projectRoot pkgPath bin depOutputs = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let ghc = T.unpack tc.haskell.ghc.path
      pkgDb = tc.haskell.paths.includes
      libPaths = map T.unpack tc.haskell.paths.libs

  createDirectoryIfMissing True outDir

  -- Use srcs list
  let srcFiles = map (\s -> srcDir </> T.unpack s) bin.srcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) bin.packages
      extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions
      ghcOpts = map T.unpack bin.ghcOptions
      mainFlag = ["-main-is", T.unpack bin.main]
      pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb
      libFlags = concatMap (\l -> ["-L" <> l]) libPaths
      -- Add dep output .o files to link line
      depObjs = concatMap snd depOutputs
      -- Add dep output directories to -i search path (for .hi files)
      depDirs = nub $ map takeDirectory $ concatMap snd depOutputs
      -- Include source dir and output dir plus dep dirs for module discovery
      searchFlags = ["-i" <> srcDir, "-i" <> outDir] ++ map (\d -> "-i" <> d) depDirs
      cmd =
        [ghc]
          ++ pkgDbFlags
          ++ extFlags
          ++ pkgFlags
          ++ ghcOpts
          ++ searchFlags
          ++ mainFlag
          ++ srcFiles
          ++ depObjs
          ++ ["-o", outBin]
          ++ libFlags

  -- Check first source exists
  case srcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (mainSrc : _) -> do
      exists <- doesFileExist mainSrc
      if not exists
        then pure $ Left $ SourceNotFound mainSrc
        else do
          -- TIO.putStrLn $ "  ghc (with deps): " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
  where
    nub = map head . groupBy (==) . sort
    sort = foldr insert []
    insert x [] = [x]
    insert x (y : ys) = if x <= y then x : y : ys else y : insert x ys
    groupBy _ [] = []
    groupBy eq (x : xs) = let (ys, zs) = span (eq x) xs in (x : ys) : groupBy eq zs

-- | Build a Haskell binary that links against C/Rust FFI libraries
-- This is for binaries like sensenet itself that need dice_ffi, superconsole_ffi
buildHaskellFFIBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.HaskellFFIBinary -> IO (Either BuildError BuildResult)
buildHaskellFFIBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let ghc = T.unpack tc.haskell.ghc.path
      pkgDb = tc.haskell.paths.includes
      libPaths = map T.unpack tc.haskell.paths.libs

  createDirectoryIfMissing True outDir

  -- Source files
  let hsSrcFiles = map (\s -> srcDir </> T.unpack s) bin.hsSrcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) bin.packages
      extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions
      ghcOpts = map T.unpack bin.ghcOptions
      pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb

      -- Standard lib paths from toolchain
      libFlags = concatMap (\l -> ["-L" <> l]) libPaths

      -- Extra lib dirs for FFI libs (e.g., dice_ffi, superconsole_ffi)
      extraLibDirFlags = concatMap (\l -> ["-L" <> T.unpack l]) bin.extraLibDirs

      -- Extra libs to link (e.g., -ldice_ffi -lsuperconsole_ffi)
      extraLibFlags = concatMap (\l -> ["-l" <> T.unpack l]) bin.extraLibs

      -- Extra linker flags
      linkerFlags = map T.unpack bin.linkerFlags

      -- Include dirs for C headers
      includeFlags = concatMap (\i -> ["-I" <> T.unpack i]) bin.includeDirs

      -- Search paths
      searchFlags = ["-i" <> srcDir, "-i" <> outDir]

      -- Threaded runtime for FFI
      rtFlags = ["-threaded", "-rtsopts", "-with-rtsopts=-N"]

      cmd =
        [ghc]
          ++ pkgDbFlags
          ++ searchFlags
          ++ extFlags
          ++ pkgFlags
          ++ ghcOpts
          ++ rtFlags
          ++ includeFlags
          ++ hsSrcFiles
          ++ ["-o", outBin]
          ++ libFlags
          ++ extraLibDirFlags
          ++ extraLibFlags
          ++ linkerFlags

  -- Check first source exists
  case hsSrcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (mainSrc : _) -> do
      exists <- doesFileExist mainSrc
      if not exists
        then pure $ Left $ SourceNotFound mainSrc
        else do
          -- TIO.putStrLn $ "  ghc (ffi): " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- ════════════════════════════════════════════════════════════════════════════
-- Lean Build
-- ════════════════════════════════════════════════════════════════════════════

buildLeanBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.LeanBinary -> IO (Either BuildError BuildResult)
buildLeanBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name
      outC = outDir </> T.unpack bin.name <> ".c"

  -- Toolchain
  let lean = T.unpack tc.lean.lean.path
      leanc = T.unpack tc.lean.leanc.path

  createDirectoryIfMissing True outDir

  -- Single file Lean compilation: lean -c -> leanc
  case bin.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          -- Step 1: Generate C code
          let genCCmd = [lean, "-c", outC, srcPath]
          -- TIO.putStrLn $ "  lean -c: " <> T.pack (unwords genCCmd)
          (exitCode1, _, stderr1) <- readProcessWithExitCode lean (tail genCCmd) ""
          case exitCode1 of
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords genCCmd) n (T.pack stderr1)
            ExitSuccess -> do
              -- Step 2: Compile C to executable with leanc
              let compileCmd = [leanc, "-o", outBin, outC]
              -- TIO.putStrLn $ "  leanc: " <> T.pack (unwords compileCmd)
              (exitCode2, _, stderr2) <- readProcessWithExitCode leanc (tail compileCmd) ""
              case exitCode2 of
                ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
                ExitFailure n -> pure $ Left $ LinkFailed (T.pack $ unwords compileCmd) n (T.pack stderr2)
    _ -> pure $ Left $ UnsupportedRule "Multi-file Lean binary"

buildLeanLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.LeanLibrary -> IO (Either BuildError BuildResult)
buildLeanLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath

  -- Toolchain
  let lean = T.unpack tc.lean.lean.path

  createDirectoryIfMissing True outDir

  -- Compile each .lean to .olean
  results <- forM lib.srcs $ \src -> do
    let srcPath = srcDir </> T.unpack src
        oleanPath = outDir </> T.unpack src <> ".olean"
        cmd = [lean, "-c", oleanPath, srcPath]

    exists <- doesFileExist srcPath
    if not exists
      then pure $ Left $ SourceNotFound srcPath
      else do
        -- TIO.putStrLn $ "  lean: " <> T.pack (unwords cmd)
        (exitCode, _, stderr) <- readProcessWithExitCode lean (tail cmd) ""
        case exitCode of
          ExitSuccess -> pure $ Right oleanPath
          ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

  case sequence results of
    Left err -> pure $ Left err
    Right oleans -> pure $ Right $ BuildSuccess oleans

-- ════════════════════════════════════════════════════════════════════════════
-- NVIDIA/CUDA Build
-- ════════════════════════════════════════════════════════════════════════════

buildNvBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.NvBinary -> IO (Either BuildError BuildResult)
buildNvBinary tc projectRoot pkgPath bin = do
  case tc.nv of
    Nothing -> pure $ Left $ UnsupportedRule "NvBinary requires NVIDIA toolchain (not configured)"
    Just nv -> do
      let srcDir = projectRoot </> pkgPath
          outDir = projectRoot </> "sensenet-out" </> pkgPath
          outBin = outDir </> T.unpack bin.name

      createDirectoryIfMissing True outDir

      -- Use toolchain paths (nv contains its own cxx toolchain for stdlib)
      let clang = T.unpack nv.clang.path
          cudaPath = T.unpack nv.sdk_path
          cudaIncludes = map T.unpack nv.sdk.includes
          cudaLibs = map T.unpack nv.sdk.libs
          cxxIncludes = map T.unpack nv.cxx.paths.includes
          cxxLibs = map T.unpack nv.cxx.paths.libs
          ld = T.unpack nv.cxx.ld.path
          sysroot = T.unpack nv.cxx.sysroot

      -- Source files
      let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs

      -- Architecture flags (from rule or toolchain defaults)
      let ruleArchs = bin.archs
          tcArchs = nv.archs
          archs = if null ruleArchs then tcArchs else ruleArchs
          archFlags = concatMap (\a -> ["--cuda-gpu-arch=" <> T.unpack a, "--cuda-include-ptx=" <> T.unpack a]) archs

      -- Compile flags
      let cudaFlags =
            [ "-x",
              "cuda",
              "--cuda-path=" <> cudaPath,
              "-std=c++23",
              "-Wno-unknown-cuda-version"
            ]
              ++ concatMap (\i -> ["-isystem", i]) cudaIncludes
              ++ concatMap (\i -> ["-isystem", i]) cxxIncludes
              ++ (if null sysroot then [] else ["--sysroot=" <> sysroot])

      -- Link flags (-B tells linker where to find crt*.o files)
      let linkFlags =
            [ "-fuse-ld=" <> ld,
              "-lcudart"
            ]
              ++ concatMap (\l -> ["-L" <> l, "-Wl,-rpath," <> l]) cudaLibs
              ++ concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) cxxLibs

      let cmd = [clang] ++ cudaFlags ++ archFlags ++ srcs ++ ["-o", outBin] ++ linkFlags

      -- TIO.putStrLn $ "  clang++ (cuda): " <> T.pack (unwords cmd)
      (exitCode, _, stderr) <- readProcessWithExitCode clang (tail cmd) ""
      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildNvLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.NvLibrary -> IO (Either BuildError BuildResult)
buildNvLibrary tc projectRoot pkgPath lib = do
  case tc.nv of
    Nothing -> pure $ Left $ UnsupportedRule "NvLibrary requires NVIDIA toolchain (not configured)"
    Just nv -> do
      let srcDir = projectRoot </> pkgPath
          outDir = projectRoot </> "sensenet-out" </> pkgPath

      createDirectoryIfMissing True outDir

      -- Use toolchain paths (nv contains its own cxx toolchain for stdlib)
      let clang = T.unpack nv.clang.path
          cudaPath = T.unpack nv.sdk_path
          cudaIncludes = map T.unpack nv.sdk.includes
          cxxIncludes = map T.unpack nv.cxx.paths.includes
          sysroot = T.unpack nv.cxx.sysroot

      -- Architecture flags
      let ruleArchs = lib.archs
          tcArchs = nv.archs
          archs = if null ruleArchs then tcArchs else ruleArchs
          archFlags = concatMap (\a -> ["--cuda-gpu-arch=" <> T.unpack a, "--cuda-include-ptx=" <> T.unpack a]) archs

      -- Compile flags
      let cudaFlags =
            [ "-x",
              "cuda",
              "--cuda-path=" <> cudaPath,
              "-std=c++23",
              "-Wno-unknown-cuda-version",
              "-fPIC",
              "-c"
            ]
              ++ concatMap (\i -> ["-isystem", i]) cudaIncludes
              ++ concatMap (\i -> ["-isystem", i]) cxxIncludes
              ++ (if null sysroot then [] else ["--sysroot=" <> sysroot])

      -- Compile each source to .o
      results <- forM lib.srcs $ \src -> do
        let srcPath = srcDir </> T.unpack src
            objPath = outDir </> T.unpack src <> ".o"
            cmd = [clang] ++ cudaFlags ++ archFlags ++ [srcPath, "-o", objPath]

        exists <- doesFileExist srcPath
        if not exists
          then pure $ Left $ SourceNotFound srcPath
          else do
            -- TIO.putStrLn $ "  clang++ (cuda): " <> T.pack (unwords cmd)
            (exitCode, _, stderr) <- readProcessWithExitCode clang (tail cmd) ""
            case exitCode of
              ExitSuccess -> pure $ Right objPath
              ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

      case sequence results of
        Left err -> pure $ Left err
        Right objs -> pure $ Right $ BuildSuccess objs

-- ════════════════════════════════════════════════════════════════════════════
-- PureScript Build
-- ════════════════════════════════════════════════════════════════════════════

buildPureScriptApp :: TC.Toolchains -> FilePath -> FilePath -> IR.PureScriptApp -> IO (Either BuildError BuildResult)
buildPureScriptApp tc projectRoot pkgPath app = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBundle = outDir </> "app.js"

  -- Toolchain - spago needs purs, node, esbuild in PATH
  let spago = T.unpack tc.purescript.spago.path
      purs = takeDirectory $ T.unpack tc.purescript.purs.path
      node = takeDirectory $ T.unpack tc.purescript.node.path
      esbuild = takeDirectory $ T.unpack tc.purescript.esbuild.path
      extraPaths = [purs, node, esbuild]

  createDirectoryIfMissing True outDir

  -- Use spago to build and bundle (must run from project directory)
  let args = ["bundle", "--outfile", outBundle]
      cmd = spago : args

  -- TIO.putStrLn $ "  spago: " <> T.pack (unwords cmd)
  (exitCode, stderr) <- runProcessWithPath srcDir extraPaths spago args
  case exitCode of
    ExitSuccess -> do
      -- Copy index.html and style.css if present
      case app.indexHtml of
        Just html -> do
          let src = srcDir </> T.unpack html
              dst = outDir </> T.unpack html
          exists <- doesFileExist src
          if exists then copyFile src dst else pure ()
        Nothing -> pure ()
      case app.styleCss of
        Just css -> do
          let src = srcDir </> T.unpack css
              dst = outDir </> T.unpack css
          exists <- doesFileExist src
          if exists then copyFile src dst else pure ()
        Nothing -> pure ()
      pure $ Right $ BuildSuccess [outBundle]
    ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildPureScriptBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.PureScriptBinary -> IO (Either BuildError BuildResult)
buildPureScriptBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBundle = outDir </> T.unpack bin.name <> ".js"

  -- Toolchain - spago needs purs, node, esbuild in PATH
  let spago = T.unpack tc.purescript.spago.path
      purs = takeDirectory $ T.unpack tc.purescript.purs.path
      node = takeDirectory $ T.unpack tc.purescript.node.path
      esbuild = takeDirectory $ T.unpack tc.purescript.esbuild.path
      extraPaths = [purs, node, esbuild]

  createDirectoryIfMissing True outDir

  -- Use spago to build and bundle for Node (must run from project directory)
  let args = ["bundle", "--platform", "node", "--outfile", outBundle]
      cmd = spago : args

  -- TIO.putStrLn $ "  spago: " <> T.pack (unwords cmd)
  (exitCode, stderr) <- runProcessWithPath srcDir extraPaths spago args
  case exitCode of
    ExitSuccess -> pure $ Right $ BuildSuccess [outBundle]
    ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

-- | Copy a file
copyFile :: FilePath -> FilePath -> IO ()
copyFile src dst = BS.readFile src >>= BS.writeFile dst

-- | Run a process in a specific directory, returning exit code and stderr
runProcessInDir :: FilePath -> String -> [String] -> IO (ExitCode, String)
runProcessInDir dir prog args = do
  let p = (proc prog args) {cwd = Just dir, std_out = CreatePipe, std_err = CreatePipe}
  (_, _, Just herr, ph) <- createProcess p
  stderr <- hGetContents herr
  exitCode <- waitForProcess ph
  pure (exitCode, stderr)

-- | Run a process with modified PATH, returning exit code and stderr
runProcessWithPath :: FilePath -> [FilePath] -> String -> [String] -> IO (ExitCode, String)
runProcessWithPath dir extraPaths prog args = do
  currentEnv <- getEnvironment
  let currentPath = fromMaybe "" $ lookup "PATH" currentEnv
      newPath = intercalate ":" extraPaths <> ":" <> currentPath
      newEnv = ("PATH", newPath) : filter ((/= "PATH") . fst) currentEnv
      p = (proc prog args) {cwd = Just dir, std_out = CreatePipe, std_err = CreatePipe, env = Just newEnv}
  (_, _, Just herr, ph) <- createProcess p
  stderr <- hGetContents herr
  exitCode <- waitForProcess ph
  pure (exitCode, stderr)

checkSources :: FilePath -> [Text] -> IO (Maybe FilePath)
checkSources srcDir = go
  where
    go [] = pure Nothing
    go (s : rest) = do
      let path = srcDir </> T.unpack s
      exists <- doesFileExist path
      if exists then go rest else pure $ Just path

cxxStdFlag :: IR.CxxStd -> String
cxxStdFlag = \case
  IR.Cxx11 -> "-std=c++11"
  IR.Cxx14 -> "-std=c++14"
  IR.Cxx17 -> "-std=c++17"
  IR.Cxx20 -> "-std=c++20"
  IR.Cxx23 -> "-std=c++23"

rustEditionFlag :: IR.RustEdition -> String
rustEditionFlag = \case
  IR.E2015 -> "2015"
  IR.E2018 -> "2018"
  IR.E2021 -> "2021"
  IR.E2024 -> "2024"
