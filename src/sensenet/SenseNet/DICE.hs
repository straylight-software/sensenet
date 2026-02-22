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
import Control.Monad (forM_, when)
import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteArray.Encoding qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, getCurrentTime)
import GHC.Generics (Generic)
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

-- | Content-addressed action key (SHA256 hash)
newtype ActionKey = ActionKey {unActionKey :: ByteString}
  deriving stock (Show, Eq, Ord, Generic)

-- | Compute action key from action content
actionKey :: Action -> ActionKey
actionKey action =
  let content = actionToCanonical action
      hash = hashWith SHA256 (TE.encodeUtf8 content)
   in ActionKey (BA.convertToBase BA.Base16 hash)

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
    -- | Resource requirements (pure, network, fs:path, etc)
    aCoeffects :: ![Text]
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
    arEndTime :: !UTCTime
  }
  deriving stock (Show, Eq, Generic)

-- ════════════════════════════════════════════════════════════════════════════
-- Canonical Serialization (for content-addressing)
-- ════════════════════════════════════════════════════════════════════════════

-- | Serialize action to canonical form for hashing
-- Deterministic: sorted keys, consistent formatting
actionToCanonical :: Action -> Text
actionToCanonical Action {..} =
  T.unlines
    [ "action:1", -- version tag for future compatibility
      "name:" <> aName,
      "command:" <> T.intercalate "\0" aCommand,
      "inputs:" <> T.intercalate "\0" (map escapeText aInputs),
      "input_keys:" <> T.intercalate "\0" (map actionKeyText aInputKeys),
      "outputs:" <> T.intercalate "\0" aOutputs,
      "env:" <> serializeEnv aEnv,
      "coeffects:" <> T.intercalate "," aCoeffects
    ]

serializeEnv :: Map Text Text -> Text
serializeEnv m =
  T.intercalate
    "\0"
    [ k <> "=" <> escapeText v
    | (k, v) <- Map.toAscList m -- sorted for determinism
    ]

escapeText :: Text -> Text
escapeText = T.concatMap $ \case
  '\0' -> "\\0"
  '\\' -> "\\\\"
  c -> T.singleton c

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
      case cached of
        Just result -> do
          -- Cache hit
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

-- | Execute an action graph in parallel
-- Actions are executed as soon as their dependencies complete
executeGraphParallel ::
  ActionCache ->
  -- | How to run an action
  (Action -> IO ActionResult) ->
  ActionGraph ->
  IO ExecutionResult
executeGraphParallel cache runner graph = do
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

  -- Pending count for each action (how many deps not yet done)
  pendingVar <- newMVar depCount

  -- Find initially ready actions (no deps)
  let ready0 = [k | k <- allKeys, Map.findWithDefault 0 k depCount == 0]

  -- Process ready actions in waves
  processWaves cache runner graph resultsVar hitsVar executedVar failedVar completedVar pendingVar ready0

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

-- | Process waves of ready actions
processWaves ::
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
processWaves _ _ _ _ _ _ _ _ _ [] = pure ()
processWaves cache runner graph resultsVar hitsVar executedVar failedVar completedVar pendingVar ready = do
  -- Execute all ready actions in parallel
  newlyReady <- forConcurrently ready $ \key -> do
    let action = agActions graph Map.! key

    -- Check cache first
    cached <- checkCache cache key
    case cached of
      Just result -> do
        TIO.putStrLn $ "  ✓ " <> aName action <> " (cached)"
        modifyMVar_ resultsVar $ pure . Map.insert key result
        modifyMVar_ hitsVar $ pure . (+ 1)
        modifyMVar_ completedVar $ pure . Set.insert key
        findNewlyReady graph completedVar pendingVar key
      Nothing -> do
        TIO.putStrLn $ "  → " <> aName action
        result <- runner action

        if arExitCode result == 0
          then do
            storeCache cache key result
            modifyMVar_ resultsVar $ pure . Map.insert key result
            modifyMVar_ executedVar $ pure . (+ 1)
            modifyMVar_ completedVar $ pure . Set.insert key
            findNewlyReady graph completedVar pendingVar key
          else do
            let errMsg = "exit " <> T.pack (show (arExitCode result)) <> ": " <> T.take 200 (arStderr result)
            TIO.putStrLn $ "  ✗ " <> aName action <> " - " <> errMsg
            modifyMVar_ failedVar $ pure . ((key, errMsg) :)
            pure []

  -- Flatten and dedupe newly ready actions
  let nextReady = Set.toList $ Set.fromList $ concat newlyReady

  -- Continue with next wave
  processWaves cache runner graph resultsVar hitsVar executedVar failedVar completedVar pendingVar nextReady

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
                  arEndTime = now
                }

-- | Store result in cache
storeCache :: ActionCache -> ActionKey -> ActionResult -> IO ()
storeCache (ActionCache dir) key result = do
  let path = dir </> T.unpack (actionKeyText key)
      content = T.intercalate "\0" (arOutputs result)
  TIO.writeFile path content

-- ════════════════════════════════════════════════════════════════════════════
-- Hashing Utilities
-- ════════════════════════════════════════════════════════════════════════════

-- | Hash bytes to hex text
hashBytes :: ByteString -> Text
hashBytes bs =
  let hash = hashWith SHA256 bs
   in TE.decodeUtf8 (BA.convertToBase BA.Base16 hash)

-- | Hash text to hex text
hashText :: Text -> Text
hashText = hashBytes . TE.encodeUtf8

-- | Hash a file's contents
hashFile :: FilePath -> IO Text
hashFile path = do
  contents <- BS.readFile path
  pure (hashBytes contents)
