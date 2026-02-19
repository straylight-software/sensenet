{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Memory-aware build scheduler
--
-- Throttles parallel builds based on predicted memory usage to prevent OOM.
-- Uses cached profile data from previous builds to estimate memory requirements.
--
-- = Architecture
--
-- DICE fires callbacks in parallel. We wrap each callback with:
--
-- 1. 'acquireMemory' - blocks if adding this job would exceed memory limit
-- 2. actual build (with profiling)
-- 3. 'releaseMemory' - frees budget and wakes waiting jobs
--
-- = Profile Sources
--
-- 1. Profile cache (.sensenet/profiles.json) - persisted across builds
-- 2. Rule-based heuristics - Rust=2GB, Haskell=1GB, C++=512MB, etc.
--
-- = MILE MARKERS for Path B (Full Coeffect Formalism)
--
-- - SchedulerState.ssActiveJobs -> coeffect discharge evidence
-- - ProfileCache -> learned BuildCoeffect database
-- - acquireMemory/releaseMemory -> linear resource protocol
module SenseNet.Scheduler
  ( -- * Scheduler State
    SchedulerState,
    newSchedulerState,

    -- * Memory Acquisition
    acquireMemory,
    releaseMemory,
    withMemoryBudget,

    -- * Profile Cache
    ProfileCache,
    ProfileEntry (..),
    loadProfileCache,
    saveProfileCache,
    lookupProfile,
    updateProfile,

    -- * Defaults and Heuristics
    defaultProfileForRule,
    getSystemMemoryBytes,

    -- * Types
    MemoryLimit (..),
    parseMemoryLimit,
  )
where

import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (bracket, finally)
import Control.Monad (when)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict', encodeFile)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Word (Word64)
import GHC.Generics (Generic)
import SenseNet.IR qualified as IR
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory)
import Text.Read (readMaybe)

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

-- | Memory limit specification
data MemoryLimit
  = -- | Absolute limit in bytes
    MemoryBytes !Word64
  | -- | Percentage of total RAM (1-100)
    MemoryPercent !Int
  deriving (Show, Eq)

-- | Parse memory limit from string
-- Examples: "32G", "8192M", "80%"
parseMemoryLimit :: String -> Maybe MemoryLimit
parseMemoryLimit s
  | "%" `T.isSuffixOf` t = do
      pct <- readMaybe (T.unpack $ T.dropEnd 1 t)
      if pct >= 1 && pct <= 100
        then Just $ MemoryPercent pct
        else Nothing
  | "G" `T.isSuffixOf` t || "g" `T.isSuffixOf` t = do
      gb <- readMaybe (T.unpack $ T.dropEnd 1 t)
      Just $ MemoryBytes (gb * 1024 * 1024 * 1024)
  | "M" `T.isSuffixOf` t || "m" `T.isSuffixOf` t = do
      mb <- readMaybe (T.unpack $ T.dropEnd 1 t)
      Just $ MemoryBytes (mb * 1024 * 1024)
  | "K" `T.isSuffixOf` t || "k" `T.isSuffixOf` t = do
      kb <- readMaybe (T.unpack $ T.dropEnd 1 t)
      Just $ MemoryBytes (kb * 1024)
  | otherwise = do
      bytes <- readMaybe s
      Just $ MemoryBytes bytes
  where
    t = T.pack s

-- ════════════════════════════════════════════════════════════════════════════
-- Profile Cache
-- ════════════════════════════════════════════════════════════════════════════

-- | Persistent profile cache
data ProfileCache = ProfileCache
  { pcVersion :: !Int,
    pcProfiles :: !(Map Text ProfileEntry)
  }
  deriving (Show, Generic)

instance FromJSON ProfileCache

instance ToJSON ProfileCache

-- | Single profile entry
data ProfileEntry = ProfileEntry
  { -- | Peak RSS in kilobytes
    peakMemoryKb :: !Word64,
    -- | Wall time in milliseconds
    wallTimeMs :: !Word64,
    -- | When this profile was recorded
    lastUpdated :: !UTCTime
  }
  deriving (Show, Generic)

instance FromJSON ProfileEntry

instance ToJSON ProfileEntry

-- | Empty profile cache
emptyProfileCache :: ProfileCache
emptyProfileCache =
  ProfileCache
    { pcVersion = 1,
      pcProfiles = Map.empty
    }

-- | Load profile cache from disk
loadProfileCache :: FilePath -> IO ProfileCache
loadProfileCache path = do
  exists <- doesFileExist path
  if not exists
    then pure emptyProfileCache
    else do
      result <- eitherDecodeFileStrict' path
      case result of
        Left _err -> pure emptyProfileCache -- Corrupt cache, start fresh
        Right cache -> pure cache

-- | Save profile cache to disk
saveProfileCache :: FilePath -> ProfileCache -> IO ()
saveProfileCache path cache = do
  createDirectoryIfMissing True (takeDirectory path)
  encodeFile path cache

-- | Look up a profile, returning Nothing if not found
lookupProfile :: ProfileCache -> Text -> Maybe ProfileEntry
lookupProfile cache target = Map.lookup target cache.pcProfiles

-- | Update a profile entry
updateProfile :: ProfileCache -> Text -> ProfileEntry -> ProfileCache
updateProfile cache target entry =
  cache {pcProfiles = Map.insert target entry cache.pcProfiles}

-- ════════════════════════════════════════════════════════════════════════════
-- Scheduler State
-- ════════════════════════════════════════════════════════════════════════════

-- | Scheduler state (protected by MVar)
data SchedulerState = SchedulerState
  { -- | Bytes currently committed
    ssActiveMemory :: !Word64,
    -- | Limit from --max-memory or auto
    ssMaxMemory :: !Word64,
    -- | target -> estimated bytes
    ssActiveJobs :: !(Map Text Word64),
    -- | Persistent profile data
    ssProfileCache :: !ProfileCache,
    -- | Jobs waiting for memory
    ssWaiters :: !(TQueue Waiter),
    -- | Path to profiles.json
    ssCachePath :: !FilePath
  }

-- | A job waiting for memory budget
data Waiter = Waiter
  { wNeededBytes :: !Word64,
    wTarget :: !Text,
    wWakeVar :: !(MVar ())
  }

-- | Create a new scheduler state
newSchedulerState ::
  -- | Max memory in bytes
  Word64 ->
  -- | Path to profile cache
  FilePath ->
  IO (MVar SchedulerState)
newSchedulerState maxMem cachePath = do
  cache <- loadProfileCache cachePath
  waitQueue <- newTQueueIO
  newMVar
    SchedulerState
      { ssActiveMemory = 0,
        ssMaxMemory = maxMem,
        ssActiveJobs = Map.empty,
        ssProfileCache = cache,
        ssWaiters = waitQueue,
        ssCachePath = cachePath
      }

-- ════════════════════════════════════════════════════════════════════════════
-- Memory Acquisition
-- ════════════════════════════════════════════════════════════════════════════

-- | Acquire memory budget for a job. Blocks if budget exceeded.
acquireMemory :: MVar SchedulerState -> Text -> Word64 -> IO ()
acquireMemory stateVar target neededBytes = do
  -- Try to acquire immediately
  canProceed <- modifyMVar stateVar $ \ss ->
    if ssActiveMemory ss + neededBytes <= ssMaxMemory ss
      then
        pure
          ( ss
              { ssActiveMemory = ssActiveMemory ss + neededBytes,
                ssActiveJobs = Map.insert target neededBytes (ssActiveJobs ss)
              },
            True
          )
      else pure (ss, False)

  if canProceed
    then pure ()
    else do
      -- Must wait - add to queue
      wakeVar <- newEmptyMVar
      ss <- readMVar stateVar
      atomically $
        writeTQueue
          (ssWaiters ss)
          Waiter
            { wNeededBytes = neededBytes,
              wTarget = target,
              wWakeVar = wakeVar
            }
      -- Block until woken
      takeMVar wakeVar

-- | Release memory budget after job completes
releaseMemory :: MVar SchedulerState -> Text -> Word64 -> ProfileEntry -> IO ()
releaseMemory stateVar target _actualBytes profile = do
  modifyMVar_ stateVar $ \ss -> do
    let released = fromMaybe 0 (Map.lookup target (ssActiveJobs ss))
    let ss' =
          ss
            { ssActiveMemory = ssActiveMemory ss - released,
              ssActiveJobs = Map.delete target (ssActiveJobs ss),
              ssProfileCache = updateProfile (ssProfileCache ss) target profile
            }
    -- Wake waiting jobs if possible
    wakeWaiters ss'

-- | Wake jobs that now fit in memory budget
wakeWaiters :: SchedulerState -> IO SchedulerState
wakeWaiters ss = do
  mWaiter <- atomically $ tryReadTQueue (ssWaiters ss)
  case mWaiter of
    Nothing -> pure ss
    Just waiter
      | ssActiveMemory ss + wNeededBytes waiter <= ssMaxMemory ss -> do
          -- This job can proceed
          modifyMVar_ (wWakeVar waiter) $ \_ -> pure ()
          putMVar (wWakeVar waiter) ()
          let ss' =
                ss
                  { ssActiveMemory = ssActiveMemory ss + wNeededBytes waiter,
                    ssActiveJobs = Map.insert (wTarget waiter) (wNeededBytes waiter) (ssActiveJobs ss)
                  }
          wakeWaiters ss'
      | otherwise -> do
          -- Put it back, can't wake yet
          atomically $ unGetTQueue (ssWaiters ss) waiter
          pure ss

-- | Bracket for memory acquisition
--
-- Acquires memory budget, runs the action, then releases.
-- The action must return both its result and the actual ProfileEntry.
withMemoryBudget ::
  MVar SchedulerState ->
  -- | Target name
  Text ->
  -- | Estimated bytes
  Word64 ->
  -- | Action that returns result and actual profile
  IO (a, ProfileEntry) ->
  IO a
withMemoryBudget stateVar target estimatedBytes action = do
  acquireMemory stateVar target estimatedBytes
  -- We need to handle exceptions properly - use bracket pattern
  result <-
    bracket
      (pure ()) -- acquire (already done above)
      ( \_ -> do
          -- release (on success or exception)
          now <- getCurrentTime
          let defaultProfile =
                ProfileEntry
                  { peakMemoryKb = estimatedBytes `div` 1024,
                    wallTimeMs = 0,
                    lastUpdated = now
                  }
          releaseMemory stateVar target 0 defaultProfile
      )
      ( \_ -> do
          -- action
          (r, profile) <- action
          -- Update with actual profile before release
          modifyMVar_ stateVar $ \ss ->
            pure ss {ssProfileCache = updateProfile (ssProfileCache ss) target profile}
          pure r
      )
  pure result

-- ════════════════════════════════════════════════════════════════════════════
-- Rule-Based Heuristics
-- ════════════════════════════════════════════════════════════════════════════

-- | Default memory estimate for a rule type (in kilobytes)
-- Based on empirical observation of typical builds
defaultProfileForRule :: IR.Rule -> Word64
defaultProfileForRule = \case
  -- Rust is memory-hungry, especially linking
  IR.RRustBinary _ -> 2 * 1024 * 1024 -- 2 GB
  IR.RRustLibrary _ -> 1 * 1024 * 1024 -- 1 GB

  -- Haskell compilation is moderate
  IR.RHaskellBinary _ -> 1 * 1024 * 1024 -- 1 GB
  IR.RHaskellLibrary _ -> 512 * 1024 -- 512 MB
  IR.RHaskellFFIBinary _ -> 1 * 1024 * 1024 -- 1 GB

  -- Lean is very memory-hungry
  IR.RLeanBinary _ -> 4 * 1024 * 1024 -- 4 GB
  IR.RLeanLibrary _ -> 2 * 1024 * 1024 -- 2 GB

  -- C++ is moderate
  IR.RCxxBinary _ -> 512 * 1024 -- 512 MB
  IR.RCxxLibrary _ -> 256 * 1024 -- 256 MB

  -- CUDA compilation
  IR.RNvBinary _ -> 1 * 1024 * 1024 -- 1 GB
  IR.RNvLibrary _ -> 512 * 1024 -- 512 MB

  -- PureScript (spago/esbuild)
  IR.RPureScriptApp _ -> 512 * 1024 -- 512 MB
  IR.RPureScriptBinary _ -> 256 * 1024 -- 256 MB
  IR.RPureScriptLibrary _ -> 128 * 1024 -- 128 MB

  -- Generic rules - conservative default
  IR.RGenrule _ -> 256 * 1024 -- 256 MB
  IR.RNixCxxBinary _ -> 512 * 1024 -- 512 MB
  IR.RCratesIo _ -> 128 * 1024 -- 128 MB (just fetching)
  IR.RHttpArchive _ -> 64 * 1024 -- 64 MB (just fetching)

-- ════════════════════════════════════════════════════════════════════════════
-- System Memory
-- ════════════════════════════════════════════════════════════════════════════

-- | Get total system memory in bytes
-- Reads from /proc/meminfo on Linux
getSystemMemoryBytes :: IO Word64
getSystemMemoryBytes = do
  contents <- readFile "/proc/meminfo"
  let lines' = lines contents
  case filter ("MemTotal:" `isPrefixOf`) lines' of
    (line : _) -> do
      let parts = words line
      case parts of
        [_, kb, "kB"] -> pure $ (read kb :: Word64) * 1024
        _ -> pure defaultSystemMemory
    [] -> pure defaultSystemMemory
  where
    isPrefixOf prefix str = take (length prefix) str == prefix
    -- Fallback: assume 16 GB
    defaultSystemMemory = 16 * 1024 * 1024 * 1024
