{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : SenseNet.DICE
-- Description : Pure Haskell incremental computation engine
--
-- DICE (Dynamic Incremental Computation Engine) - content-addressed builds.
--
-- Key insight: ActionKey = hash(inputs + command)
-- If inputs unchanged → outputs unchanged → skip execution.
--
-- This module provides:
--   1. Content-addressed action keys
--   2. Action graph construction and topological sort
--   3. Persistent caching via filesystem
--   4. Coeffect tracking per action (what resources are required)
--
-- No FFI. No Rust. Just Haskell.
module SenseNet.DICE
  ( -- * Keys
    ActionKey (..),
    actionKey,
    actionKeyText,

    -- * Actions
    Action (..),
    ActionResult (..),

    -- * Graph
    ActionGraph (..),
    emptyGraph,
    addAction,
    topoSort,

    -- * Execution
    ExecutionResult (..),
    executeGraph,
    executeGraphParallel,
    executeGraphWithJobs,

    -- * Progress Callbacks
    ProgressEvent (..),
    ProgressCallback,
    defaultProgressCallback,
    executeGraphWithProgress,

    -- * Cache
    ActionCache (..),
    newCache,
    checkCache,
    storeCache,

    -- * Hashing
    hashBytes,
    hashText,
    hashFile,
  )
where

import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Exception (bracket_)
import Crypto.Hash (Blake2b_256 (..), Digest, hashWith, hashlazy)
import Data.ByteArray.Encoding qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Word (Word64, Word8)
import GHC.Generics (Generic)
import SenseNet.IR.Coeffect (Coeffects, coeffectToText)
import System.Directory
  ( XdgDirectory (..),
    createDirectoryIfMissing,
    doesFileExist,
    getXdgDirectory,
  )
import System.FilePath ((</>))

-- ════════════════════════════════════════════════════════════════════════════
-- Action Keys (content-addressed)
-- ════════════════════════════════════════════════════════════════════════════

-- | Content-addressed action key (BLAKE2b-256 hash)
--
-- We use BLAKE2b-256 instead of SHA256 because:
--  - 1.5x faster than SHA256 (benchmarked: 882K vs 592K keys/sec)
--  - Cryptographically secure (unlike FNV/xxHash)
--  - Same 256-bit output, same collision resistance
--  - Already in crypton, no new dependencies
newtype ActionKey = ActionKey {unActionKey :: ByteString}
  deriving stock (Show, Eq, Ord, Generic)

-- | Compute action key from action content
-- Uses ByteString builder + hashlazy for zero-copy hashing
actionKey :: Action -> ActionKey
actionKey action =
  let !canonical = actionToCanonicalLazy action
      !hash = hashlazy canonical :: Digest Blake2b_256
   in ActionKey (BA.convertToBase BA.Base16 hash)
{-# INLINE actionKey #-}

-- | Get action key as text (hex-encoded)
actionKeyText :: ActionKey -> Text
actionKeyText = TE.decodeUtf8 . unActionKey

-- ════════════════════════════════════════════════════════════════════════════
-- Actions
-- ════════════════════════════════════════════════════════════════════════════

-- | An action in the build graph
data Action = Action
  { -- | Human-readable name "//pkg:target"
    aName :: !Text,
    -- | Command to execute
    aCommand :: ![Text],
    -- | Input file paths (hashed for key)
    aInputs :: ![Text],
    -- | Dependencies on other actions
    aInputKeys :: ![ActionKey],
    -- | Expected output paths
    aOutputs :: ![Text],
    -- | Environment variables
    aEnv :: !(Map Text Text),
    -- | Resource requirements (typed coeffects)
    aCoeffects :: !Coeffects
  }
  deriving stock (Show, Eq, Generic)

-- | Result of executing an action
data ActionResult = ActionResult
  { -- | Actual output paths
    arOutputs :: ![Text],
    -- | Exit code (0 = success)
    arExitCode :: !Int,
    -- | Captured stdout
    arStdout :: !Text,
    -- | Captured stderr
    arStderr :: !Text,
    -- | When execution started
    arStartTime :: !UTCTime,
    -- | When execution finished
    arEndTime :: !UTCTime,
    -- | Peak memory usage in kilobytes (from getrusage RUSAGE_CHILDREN)
    arPeakMemoryKB :: !Word64
  }
  deriving stock (Show, Eq, Generic)

-- ════════════════════════════════════════════════════════════════════════════
-- Canonical Serialization (for content-addressing)
-- ════════════════════════════════════════════════════════════════════════════

-- | Serialize action to lazy ByteString for hashing (zero-copy path)
-- Uses ByteString.Builder for minimal allocations
-- Returns lazy ByteString to avoid extra copy before hashing
actionToCanonicalLazy :: Action -> BL.ByteString
actionToCanonicalLazy Action {..} = BB.toLazyByteString builder
  where
    builder =
      "action:2\n"
        <> "name:"
        <> textBS aName
        <> nl
        <> "command:"
        <> mconcat [textBS c <> nul | c <- aCommand]
        <> nl
        <> "inputs:"
        <> mconcat [escapeBS (TE.encodeUtf8 i) <> nul | i <- aInputs]
        <> nl
        <> "outputs:"
        <> mconcat [textBS o <> nul | o <- aOutputs]
        <> nl
        <> "env:"
        <> serializeEnvBS aEnv
        <> nl
        <> "coeffects:"
        <> mconcat [textBS (coeffectToText c) <> comma | c <- aCoeffects]
        <> nl
    nl = BB.char7 '\n'
    nul = BB.char7 '\0'
    comma = BB.char7 ','
    textBS = BB.byteString . TE.encodeUtf8
{-# INLINE actionToCanonicalLazy #-}

-- | Escape ByteString for canonical form
-- Fast path: skip escaping if no special characters present
escapeBS :: ByteString -> BB.Builder
escapeBS bs
  | BS.null bs = mempty
  | hasSpecial bs = BS.foldl' (\b w -> b <> escapeByte w) mempty bs
  | otherwise = BB.byteString bs -- fast path: no escaping needed
  where
    hasSpecial = BS.any (\w -> w == 0 || w == 92) -- null or backslash
    escapeByte :: Word8 -> BB.Builder
    escapeByte 0 = "\\0" -- null byte
    escapeByte 92 = "\\\\" -- backslash
    escapeByte w = BB.word8 w
{-# INLINE escapeBS #-}

-- | Serialize environment map to ByteString builder
serializeEnvBS :: Map Text Text -> BB.Builder
serializeEnvBS m =
  mconcat
    [ BB.byteString (TE.encodeUtf8 k) <> BB.char7 '=' <> escapeBS (TE.encodeUtf8 v) <> BB.char7 '\0'
    | (k, v) <- Map.toAscList m
    ]
{-# INLINE serializeEnvBS #-}

-- ════════════════════════════════════════════════════════════════════════════
-- Action Graph
-- ════════════════════════════════════════════════════════════════════════════

-- | The full build graph
data ActionGraph = ActionGraph
  { -- | All actions by key
    agActions :: !(Map ActionKey Action),
    -- | Targets to build
    agRoots :: ![ActionKey]
  }
  deriving stock (Show, Generic)

-- | Empty action graph
emptyGraph :: ActionGraph
emptyGraph = ActionGraph Map.empty []

-- | Add an action to the graph
addAction :: Action -> ActionGraph -> ActionGraph
addAction action graph =
  let key = actionKey action
   in graph {agActions = Map.insert key action (agActions graph)}

-- | Topologically sort actions (dependencies before dependents)
topoSort :: ActionGraph -> [ActionKey]
topoSort ActionGraph {..} = reverse $ go Set.empty [] (Map.keys agActions)
  where
    go :: Set ActionKey -> [ActionKey] -> [ActionKey] -> [ActionKey]
    go _ sorted [] = sorted
    go visited sorted (k : ks)
      | k `Set.member` visited = go visited sorted ks
      | otherwise =
          let action = agActions Map.! k
              deps = aInputKeys action
              (visited', sorted') = foldl visitDep (Set.insert k visited, sorted) deps
           in go visited' (k : sorted') ks

    visitDep (v, s) dep
      | dep `Set.member` v = (v, s)
      | otherwise =
          case Map.lookup dep agActions of
            Nothing -> (Set.insert dep v, s) -- External dep, skip
            Just action ->
              let deps = aInputKeys action
                  (v', s') = foldl visitDep (Set.insert dep v, s) deps
               in (v', dep : s')

-- ════════════════════════════════════════════════════════════════════════════
-- Execution
-- ════════════════════════════════════════════════════════════════════════════

-- | Result of executing the entire graph
data ExecutionResult = ExecutionResult
  { -- | Results by action
    erResults :: !(Map ActionKey ActionResult),
    -- | Number of cache hits
    erCacheHits :: !Int,
    -- | Number of actions run
    erExecuted :: !Int,
    -- | Failed actions with errors
    erFailed :: ![(ActionKey, Text)]
  }
  deriving stock (Show, Generic)

-- ════════════════════════════════════════════════════════════════════════════
-- Progress Callbacks
-- ════════════════════════════════════════════════════════════════════════════

-- | Progress events emitted during build execution
--
-- These events enable rich TUI display with maximum visibility into
-- every operation: Dhall parsing, discovery, graph construction, etc.
data ProgressEvent
  = -- ════════════════════════════════════════════════════════════════════════
    -- Phase: Discovery
    -- ════════════════════════════════════════════════════════════════════════

    -- | Discovering BUILD.dhall files under a path
    ProgressDiscovering !Text -- path being scanned
  | -- | Found a BUILD.dhall file
    ProgressFoundPackage !Text -- package path (e.g., "//src/foo")
  | -- ════════════════════════════════════════════════════════════════════════
    -- Phase: Dhall Parsing
    -- ════════════════════════════════════════════════════════════════════════

    -- | Starting to parse a Dhall file
    ProgressDhallParsing !Text -- path (e.g., "src/foo/BUILD.dhall")
  | -- | Dhall file parsed successfully
    ProgressDhallParsed !Text -- path
  | -- | Resolving a Dhall import
    ProgressDhallImport !Text -- import path
  | -- | Normalizing Dhall expression
    ProgressDhallNormalizing !Text -- target name
  | -- | Dhall evaluation complete
    ProgressDhallEvaluated !Text !Int -- target, number of rules extracted
  | -- ════════════════════════════════════════════════════════════════════════
    -- Phase: Toolchains
    -- ════════════════════════════════════════════════════════════════════════

    -- | Loading toolchains
    ProgressToolchainLoading !Text -- toolchain file path
  | -- | Toolchain loaded from cache
    ProgressToolchainCached !Text -- toolchain file path
  | -- | Toolchain loaded (fresh parse)
    ProgressToolchainLoaded !Text !Int -- path, number of toolchains
  | -- ════════════════════════════════════════════════════════════════════════
    -- Phase: Dependency Resolution
    -- ════════════════════════════════════════════════════════════════════════

    -- | Resolving dependencies for a target
    ProgressResolvingDeps !Text -- target name
  | -- | Loading cross-package dependency
    ProgressCrossPackageDep !Text -- package path
  | -- | Dependencies resolved
    ProgressDepsResolved !Text !Int -- target, number of deps
  | -- ════════════════════════════════════════════════════════════════════════
    -- Phase: Nix Resolution
    -- ════════════════════════════════════════════════════════════════════════

    -- | Resolving a nix flake reference
    ProgressNixResolving !Text -- flake ref
  | -- | Nix package resolved
    ProgressNixResolved !Text !Text -- flake ref, store path
  | -- ════════════════════════════════════════════════════════════════════════
    -- Phase: Graph Construction
    -- ════════════════════════════════════════════════════════════════════════

    -- | Building action graph for target
    ProgressBuildingGraph !Text -- target name
  | -- | Adding action to graph
    ProgressGraphAction !Text -- action name
  | -- | Graph construction complete
    ProgressGraphBuilt !Int -- total actions
  | -- ════════════════════════════════════════════════════════════════════════
    -- Phase: Execution
    -- ════════════════════════════════════════════════════════════════════════

    -- | Checking cache for action
    ProgressCacheCheck !Text -- action name
  | -- | Cache hit
    ProgressCacheHit !Text -- action name
  | -- | Cache miss
    ProgressCacheMiss !Text -- action name
  | -- | Action is starting execution
    ProgressStarting !Text !Int !Int -- name, current, total
  | -- | Action completed from cache
    ProgressCached !Text !Int !Int -- name, current, total
  | -- | Action completed successfully
    ProgressCompleted !Text !Int !Int !Word64 -- name, current, total, peakMemKB
  | -- | Action failed
    ProgressFailed !Text !Int !Int !Text -- name, current, total, error
  | -- ════════════════════════════════════════════════════════════════════════
    -- Phase: Finalization
    -- ════════════════════════════════════════════════════════════════════════

    -- | Writing outputs
    ProgressWritingOutput !Text -- output path
  | -- | Storing result in cache
    ProgressCacheStore !Text -- action name
  | -- | Build phase complete
    ProgressPhaseComplete !Text !Double -- phase name, duration in seconds
  deriving stock (Show, Eq)

-- | Callback for receiving progress events
type ProgressCallback = ProgressEvent -> IO ()

-- | Default progress callback (prints to stdout with maximum visibility)
defaultProgressCallback :: ProgressCallback
defaultProgressCallback = \case
  -- Discovery
  ProgressDiscovering path ->
    TIO.putStrLn $ "◌ scanning " <> path
  ProgressFoundPackage pkg ->
    TIO.putStrLn $ "◉ found " <> pkg
  -- Dhall
  ProgressDhallParsing path ->
    TIO.putStrLn $ "◌ parsing " <> path
  ProgressDhallParsed path ->
    TIO.putStrLn $ "◉ parsed " <> path
  ProgressDhallImport imp ->
    TIO.putStrLn $ "  ↳ import " <> imp
  ProgressDhallNormalizing target ->
    TIO.putStrLn $ "◌ normalizing " <> target
  ProgressDhallEvaluated target nRules ->
    TIO.putStrLn $ "◉ evaluated " <> target <> " (" <> T.pack (show nRules) <> " rules)"
  -- Toolchains
  ProgressToolchainLoading path ->
    TIO.putStrLn $ "◌ loading toolchains " <> path
  ProgressToolchainCached path ->
    TIO.putStrLn $ "◉ toolchains (cached) " <> path
  ProgressToolchainLoaded path n ->
    TIO.putStrLn $ "◉ toolchains loaded " <> path <> " (" <> T.pack (show n) <> ")"
  -- Dependencies
  ProgressResolvingDeps target ->
    TIO.putStrLn $ "◌ resolving deps " <> target
  ProgressCrossPackageDep pkg ->
    TIO.putStrLn $ "  ↳ cross-pkg " <> pkg
  ProgressDepsResolved target n ->
    TIO.putStrLn $ "◉ deps resolved " <> target <> " (" <> T.pack (show n) <> ")"
  -- Nix
  ProgressNixResolving ref ->
    TIO.putStrLn $ "◌ nix " <> ref
  ProgressNixResolved ref _storePath ->
    TIO.putStrLn $ "◉ nix " <> ref
  -- Graph
  ProgressBuildingGraph target ->
    TIO.putStrLn $ "◌ building graph " <> target
  ProgressGraphAction action ->
    TIO.putStrLn $ "  + " <> action
  ProgressGraphBuilt n ->
    TIO.putStrLn $ "◉ graph built (" <> T.pack (show n) <> " actions)"
  -- Execution
  ProgressCacheCheck action ->
    TIO.putStrLn $ "? cache " <> action
  ProgressCacheHit action ->
    TIO.putStrLn $ "✓ cache hit " <> action
  ProgressCacheMiss action ->
    TIO.putStrLn $ "✗ cache miss " <> action
  ProgressStarting name cur total ->
    TIO.putStrLn $ "[" <> T.pack (show cur) <> "/" <> T.pack (show total) <> "] → " <> name
  ProgressCached name cur total ->
    TIO.putStrLn $ "[" <> T.pack (show cur) <> "/" <> T.pack (show total) <> "] ✓ " <> name <> " (cached)"
  ProgressCompleted name cur total peakMem ->
    let memInfo = if peakMem > 0 then " [" <> formatMemory peakMem <> "]" else ""
     in TIO.putStrLn $ "[" <> T.pack (show cur) <> "/" <> T.pack (show total) <> "] ✓ " <> name <> memInfo
  ProgressFailed name cur total err ->
    TIO.putStrLn $ "[" <> T.pack (show cur) <> "/" <> T.pack (show total) <> "] ✗ " <> name <> " - " <> err
  -- Finalization
  ProgressWritingOutput path ->
    TIO.putStrLn $ "◌ writing " <> path
  ProgressCacheStore action ->
    TIO.putStrLn $ "◌ caching " <> action
  ProgressPhaseComplete phase duration ->
    TIO.putStrLn $ "◉ " <> phase <> " (" <> T.pack (show (round (duration * 1000) :: Int)) <> "ms)"

-- | Execute an action graph
-- Returns results for all actions, with caching
executeGraph ::
  ActionCache ->
  -- | How to run an action
  (Action -> IO ActionResult) ->
  ActionGraph ->
  IO ExecutionResult
executeGraph cache runner graph = do
  let sorted = topoSort graph
  go Map.empty 0 0 [] sorted
  where
    go results hits executed failed [] =
      pure
        ExecutionResult
          { erResults = results,
            erCacheHits = hits,
            erExecuted = executed,
            erFailed = failed
          }
    go results hits executed failed (key : rest) = do
      let action = agActions graph Map.! key

      -- Check cache
      cached <- checkCache cache key
      -- Verify outputs still exist before trusting cache
      cacheValid <- case cached of
        Just result -> do
          let outputs = map T.unpack (arOutputs result)
          allExist <- and <$> mapM doesFileExist outputs
          pure $ if allExist then Just result else Nothing
        Nothing -> pure Nothing
      case cacheValid of
        Just result -> do
          -- Cache hit with valid outputs
          TIO.putStrLn $ "  ✓ " <> aName action <> " (cached)"
          go (Map.insert key result results) (hits + 1) executed failed rest
        Nothing -> do
          -- Cache miss - execute
          TIO.putStrLn $ "  → " <> aName action
          result <- runner action

          if arExitCode result == 0
            then do
              -- Success - cache and continue
              storeCache cache key result
              -- Show completion with memory usage if available
              let memInfo =
                    if arPeakMemoryKB result > 0
                      then " [" <> formatMemory (arPeakMemoryKB result) <> "]"
                      else ""
              TIO.putStrLn $ "  ✓ " <> aName action <> memInfo
              go (Map.insert key result results) hits (executed + 1) failed rest
            else do
              -- Failure
              let errMsg =
                    "exit "
                      <> T.pack (show (arExitCode result))
                      <> ": "
                      <> T.take 200 (arStderr result)
              TIO.putStrLn $ "  ✗ " <> aName action <> " - " <> errMsg
              go results hits executed ((key, errMsg) : failed) rest

-- | Execute an action graph in parallel with limited concurrency
-- Actions are executed as soon as their dependencies complete
executeGraphWithJobs ::
  -- | Max concurrent jobs (Nothing = unlimited)
  Maybe Int ->
  ActionCache ->
  -- | How to run an action
  (Action -> IO ActionResult) ->
  ActionGraph ->
  IO ExecutionResult
executeGraphWithJobs mJobs cache runner graph = do
  -- Create semaphore for job limiting (if specified)
  semMaybe <- case mJobs of
    Just n | n > 0 -> Just <$> newQSem n
    _ -> pure Nothing

  -- Shared state
  resultsVar <- newMVar Map.empty
  hitsVar <- newMVar 0
  executedVar <- newMVar 0
  failedVar <- newMVar []

  -- Track completed actions
  completedVar <- newMVar Set.empty

  -- Build reverse dep map: for each action, who depends on it?
  let allKeys = Map.keys (agActions graph)
      depCount = Map.fromList [(k, length (aInputKeys (agActions graph Map.! k))) | k <- allKeys]
      total = length allKeys

  -- Pending count for each action (how many deps not yet done)
  pendingVar <- newMVar depCount

  -- Progress counter (starts at 0)
  progressVar <- newMVar 0

  -- Find initially ready actions (no deps)
  let ready0 = [k | k <- allKeys, Map.findWithDefault 0 k depCount == 0]

  -- Process ready actions in waves
  processWaves semMaybe total progressVar cache runner graph resultsVar hitsVar executedVar failedVar completedVar pendingVar ready0

  -- Collect results
  results <- readMVar resultsVar
  hits <- readMVar hitsVar
  executed <- readMVar executedVar
  failed <- readMVar failedVar

  pure
    ExecutionResult
      { erResults = results,
        erCacheHits = hits,
        erExecuted = executed,
        erFailed = failed
      }

-- | Execute an action graph in parallel (unlimited concurrency)
-- Actions are executed as soon as their dependencies complete
executeGraphParallel ::
  ActionCache ->
  -- | How to run an action
  (Action -> IO ActionResult) ->
  ActionGraph ->
  IO ExecutionResult
executeGraphParallel cache runner graph = executeGraphWithJobs Nothing cache runner graph

-- | Process waves of ready actions
processWaves ::
  -- | Semaphore for limiting concurrency
  Maybe QSem ->
  -- | Total number of actions (for progress display)
  Int ->
  -- | Progress counter (completed so far)
  MVar Int ->
  ActionCache ->
  (Action -> IO ActionResult) ->
  ActionGraph ->
  MVar (Map ActionKey ActionResult) ->
  MVar Int ->
  MVar Int ->
  MVar [(ActionKey, Text)] ->
  MVar (Set ActionKey) ->
  MVar (Map ActionKey Int) ->
  [ActionKey] ->
  IO ()
processWaves _ _ _ _ _ _ _ _ _ _ _ _ [] = pure ()
processWaves semMaybe total progressVar cache runner graph resultsVar hitsVar executedVar failedVar completedVar pendingVar ready = do
  -- Execute all ready actions in parallel (but limited by semaphore if present)
  newlyReady <- forConcurrently ready $ \key -> do
    let action = agActions graph Map.! key

    -- Wrap in semaphore if we have one
    let runWithLimit io = case semMaybe of
          Just sem -> bracket_ (waitQSem sem) (signalQSem sem) io
          Nothing -> io

    runWithLimit $ do
      -- Get and increment progress counter atomically
      n <- modifyMVar progressVar $ \p -> pure (p + 1, p + 1)
      let progress = "[" <> T.pack (show n) <> "/" <> T.pack (show total) <> "] "

      -- Check cache first
      cached <- checkCache cache key
      -- Verify outputs still exist before trusting cache
      cacheValid <- case cached of
        Just result -> do
          let outputs = map T.unpack (arOutputs result)
          allExist <- and <$> mapM doesFileExist outputs
          pure $ if allExist then Just result else Nothing
        Nothing -> pure Nothing
      case cacheValid of
        Just result -> do
          TIO.putStrLn $ progress <> "✓ " <> aName action <> " (cached)"
          modifyMVar_ resultsVar $ pure . Map.insert key result
          modifyMVar_ hitsVar $ pure . (+ 1)
          modifyMVar_ completedVar $ pure . Set.insert key
          findNewlyReady graph completedVar pendingVar key
        Nothing -> do
          TIO.putStrLn $ progress <> "→ " <> aName action
          result <- runner action

          if arExitCode result == 0
            then do
              storeCache cache key result
              -- Show completion with memory usage if available
              let memInfo =
                    if arPeakMemoryKB result > 0
                      then " [" <> formatMemory (arPeakMemoryKB result) <> "]"
                      else ""
              TIO.putStrLn $ progress <> "✓ " <> aName action <> memInfo
              modifyMVar_ resultsVar $ pure . Map.insert key result
              modifyMVar_ executedVar $ pure . (+ 1)
              modifyMVar_ completedVar $ pure . Set.insert key
              findNewlyReady graph completedVar pendingVar key
            else do
              let errMsg = "exit " <> T.pack (show (arExitCode result)) <> ": " <> T.take 200 (arStderr result)
              TIO.putStrLn $ progress <> "✗ " <> aName action <> " - " <> errMsg
              modifyMVar_ failedVar $ pure . ((key, errMsg) :)
              pure []

  -- Flatten and dedupe newly ready actions
  let nextReady = Set.toList $ Set.fromList $ concat newlyReady

  -- Continue with next wave
  processWaves semMaybe total progressVar cache runner graph resultsVar hitsVar executedVar failedVar completedVar pendingVar nextReady

-- | Find actions that become ready after completing an action
findNewlyReady ::
  ActionGraph ->
  MVar (Set ActionKey) ->
  MVar (Map ActionKey Int) ->
  ActionKey ->
  IO [ActionKey]
findNewlyReady graph _completedVar pendingVar completedKey = do
  -- Find all actions that depend on completedKey
  let dependents = [k | (k, action) <- Map.toList (agActions graph), completedKey `elem` aInputKeys action]

  -- Decrement pending count for each dependent
  newlyReady <- modifyMVar pendingVar $ \pending -> do
    let (ready, pending') = foldr updatePending ([], pending) dependents
    pure (pending', ready)

  pure newlyReady
  where
    updatePending depKey (ready, pending) =
      let newCount = Map.findWithDefault 1 depKey pending - 1
          pending' = Map.insert depKey newCount pending
       in if newCount == 0
            then (depKey : ready, pending')
            else (ready, pending')

-- | Execute graph with progress callback
-- Like executeGraphWithJobs but emits ProgressEvents via callback
executeGraphWithProgress ::
  Maybe Int ->
  ProgressCallback ->
  ActionCache ->
  (Action -> IO ActionResult) ->
  ActionGraph ->
  IO ExecutionResult
executeGraphWithProgress mJobs callback cache runner graph = do
  -- Create semaphore for job limiting
  semMaybe <- case mJobs of
    Just n | n > 0 -> Just <$> newQSem n
    _ -> pure Nothing

  -- Shared state
  resultsVar <- newMVar Map.empty
  hitsVar <- newMVar 0
  executedVar <- newMVar 0
  failedVar <- newMVar []
  completedVar <- newMVar Set.empty

  let allKeys = Map.keys (agActions graph)
      depCount = Map.fromList [(k, length (aInputKeys (agActions graph Map.! k))) | k <- allKeys]
      total = length allKeys

  pendingVar <- newMVar depCount
  progressVar <- newMVar 0
  doneVar <- newMVar 0 -- Tracks completed count (for ordered progress display)
  let ready0 = [k | k <- allKeys, Map.findWithDefault 0 k depCount == 0]

  processWavesWithCallback semMaybe total progressVar doneVar callback cache runner graph resultsVar hitsVar executedVar failedVar completedVar pendingVar ready0

  results <- readMVar resultsVar
  hits <- readMVar hitsVar
  executed <- readMVar executedVar
  failed <- readMVar failedVar

  pure
    ExecutionResult
      { erResults = results,
        erCacheHits = hits,
        erExecuted = executed,
        erFailed = failed
      }

-- | Process waves with progress callback
processWavesWithCallback ::
  Maybe QSem ->
  Int ->
  MVar Int -> -- progressVar (started count)
  MVar Int -> -- doneVar (completed count)
  ProgressCallback ->
  ActionCache ->
  (Action -> IO ActionResult) ->
  ActionGraph ->
  MVar (Map ActionKey ActionResult) ->
  MVar Int ->
  MVar Int ->
  MVar [(ActionKey, Text)] ->
  MVar (Set ActionKey) ->
  MVar (Map ActionKey Int) ->
  [ActionKey] ->
  IO ()
processWavesWithCallback _ _ _ _ _ _ _ _ _ _ _ _ _ _ [] = pure ()
processWavesWithCallback semMaybe total progressVar doneVar callback cache runner graph resultsVar hitsVar executedVar failedVar completedVar pendingVar readyKeys = do
  newlyReady <- forConcurrently readyKeys $ \key -> do
    let action = agActions graph Map.! key
        runWithLimit = case semMaybe of
          Nothing -> id
          Just sem -> bracket_ (waitQSem sem) (signalQSem sem)

    runWithLimit $ do
      -- n is the "started" index - only used for ProgressStarting
      n <- modifyMVar progressVar $ \p -> pure (p + 1, p + 1)

      -- Emit cache check event
      callback $ ProgressCacheCheck (aName action)

      cached <- checkCache cache key
      cacheValid <- case cached of
        Just result -> do
          let outputs = map T.unpack (arOutputs result)
          allExist <- and <$> mapM doesFileExist outputs
          pure $ if allExist then Just result else Nothing
        Nothing -> pure Nothing

      case cacheValid of
        Just result -> do
          -- Emit cache hit event
          callback $ ProgressCacheHit (aName action)
          -- Increment done counter BEFORE callback for proper ordering
          done <- modifyMVar doneVar $ \d -> pure (d + 1, d + 1)
          callback $ ProgressCached (aName action) done total
          modifyMVar_ resultsVar $ pure . Map.insert key result
          modifyMVar_ hitsVar $ pure . (+ 1)
          modifyMVar_ completedVar $ pure . Set.insert key
          findNewlyReady graph completedVar pendingVar key
        Nothing -> do
          -- Emit cache miss event
          callback $ ProgressCacheMiss (aName action)
          callback $ ProgressStarting (aName action) n total
          result <- runner action

          if arExitCode result == 0
            then do
              -- Emit cache store event
              callback $ ProgressCacheStore (aName action)
              storeCache cache key result
              -- Increment done counter BEFORE callback for proper ordering
              done <- modifyMVar doneVar $ \d -> pure (d + 1, d + 1)
              callback $ ProgressCompleted (aName action) done total (arPeakMemoryKB result)
              modifyMVar_ resultsVar $ pure . Map.insert key result
              modifyMVar_ executedVar $ pure . (+ 1)
              modifyMVar_ completedVar $ pure . Set.insert key
              findNewlyReady graph completedVar pendingVar key
            else do
              -- For failures, use the started index since we didn't complete
              let errMsg = "exit " <> T.pack (show (arExitCode result)) <> ": " <> T.take 200 (arStderr result)
              callback $ ProgressFailed (aName action) n total errMsg
              modifyMVar_ failedVar $ pure . ((key, errMsg) :)
              pure []

  let nextReady = Set.toList $ Set.fromList $ concat newlyReady
  processWavesWithCallback semMaybe total progressVar doneVar callback cache runner graph resultsVar hitsVar executedVar failedVar completedVar pendingVar nextReady

-- ════════════════════════════════════════════════════════════════════════════
-- Cache (persistent, file-based)
-- ════════════════════════════════════════════════════════════════════════════

-- | Action cache handle
newtype ActionCache = ActionCache {unActionCache :: FilePath}

-- | Create or open action cache
newCache :: IO ActionCache
newCache = do
  dir <- getXdgDirectory XdgCache "sensenet/actions"
  createDirectoryIfMissing True dir
  pure (ActionCache dir)

-- | Check cache for action result
checkCache :: ActionCache -> ActionKey -> IO (Maybe ActionResult)
checkCache (ActionCache dir) key = do
  let path = dir </> T.unpack (actionKeyText key)
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      content <- TIO.readFile path
      -- Simple format: outputs on separate lines, then metadata
      let ls = T.lines content
      case ls of
        [] -> pure Nothing
        (outputsLine : _) -> do
          let outputs = filter (not . T.null) $ T.splitOn "\0" outputsLine
          now <- getCurrentTime
          pure $
            Just
              ActionResult
                { arOutputs = outputs,
                  arExitCode = 0,
                  arStdout = "",
                  arStderr = "",
                  arStartTime = now,
                  arEndTime = now,
                  arPeakMemoryKB = 0 -- Unknown for cached results
                }

-- | Store result in cache
storeCache :: ActionCache -> ActionKey -> ActionResult -> IO ()
storeCache (ActionCache dir) key result = do
  let path = dir </> T.unpack (actionKeyText key)
      content = T.intercalate "\0" (arOutputs result)
  TIO.writeFile path content

-- ════════════════════════════════════════════════════════════════════════════
-- Formatting Utilities
-- ════════════════════════════════════════════════════════════════════════════

-- | Format memory in human-readable form (KB -> MB/GB)
formatMemory :: Word64 -> Text
formatMemory kb
  | kb >= 1048576 = T.pack (show (kb `div` 1048576)) <> "GB"
  | kb >= 1024 = T.pack (show (kb `div` 1024)) <> "MB"
  | kb > 0 = T.pack (show kb) <> "KB"
  | otherwise = ""

-- ════════════════════════════════════════════════════════════════════════════
-- Hashing Utilities
-- ════════════════════════════════════════════════════════════════════════════

-- | Hash bytes to hex text (BLAKE2b-256)
hashBytes :: ByteString -> Text
hashBytes bs =
  let hash = hashWith Blake2b_256 bs
   in TE.decodeUtf8 (BA.convertToBase BA.Base16 hash)

-- | Hash text to hex text (BLAKE2b-256)
hashText :: Text -> Text
hashText = hashBytes . TE.encodeUtf8

-- | Hash a file's contents (BLAKE2b-256)
hashFile :: FilePath -> IO Text
hashFile path = do
  contents <- BS.readFile path
  pure (hashBytes contents)
