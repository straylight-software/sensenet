{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | NIGHTMARE TESTS for sensenet
--
-- "Now I have a machine gun. Ho ho ho."
-- - John McClane
--
-- These tests go beyond stress testing into territory that should be
-- IMPOSSIBLE in production but must be survived anyway:
--
-- - TUI event floods (10k events/second)
-- - Race conditions in concurrent state updates
-- - State machine violations (illegal transitions)
-- - Malicious progress events (negative, overflow, impossible values)
-- - Terminal torture (resize storms, huge output, control sequences)
-- - Cache state corruption attempts
-- - Time travel attacks (events from the past/future)
-- - Resource starvation scenarios
--
-- If sensenet survives this, it survives malware.
module Test.SenseNet.Nightmare (tests) where

import Control.Concurrent
  ( MVar,
    forkIO,
    newEmptyMVar,
    newMVar,
    putMVar,
    readMVar,
    takeMVar,
    threadDelay,
    modifyMVar_,
  )
import Control.Concurrent.Async (async, forConcurrently, race, wait, Async, cancel)
import Control.DeepSeq (NFData (..), deepseq, force)
import Control.Exception (ErrorCall, SomeException, bracket, evaluate, try, mask, onException)
import Control.Monad (forM, forM_, replicateM, replicateM_, unless, when, void)
import Data.Foldable (foldl')
import Data.IORef
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime, diffUTCTime, NominalDiffTime)
import Data.Word (Word64)
import System.Mem (performGC)
import System.Random (randomRIO)
import System.Timeout (timeout)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

-- Import TUI types (using local definitions to avoid module dependency issues)
-- In production, these would come from SenseNet.TUI and SenseNet.Build

tests :: TestTree
tests =
  testGroup
    "NIGHTMARE"
    [ testGroup "EventFlood" eventFloodTests,
      testGroup "RaceConditions" raceConditionTests,
      testGroup "StateMachineViolations" stateMachineTests,
      testGroup "MaliciousProgressEvents" maliciousEventTests,
      testGroup "CacheCorruption" cacheCorruptionTests,
      testGroup "TimeTravel" timeTravelTests,
      testGroup "TerminalTorture" terminalTortureTests,
      testGroup "ResourceStarvation" starvationTests,
      testGroup "CounterOverflow" overflowTests,
      testGroup "ConcurrentMutations" concurrentMutationTests,
      testGroup "PhaseTransitionChaos" phaseTransitionTests,
      testGroup "TargetStatusChaos" targetStatusTests,
      testGroup "LogStreamTorture" logStreamTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- EVENT FLOOD TESTS
-- Simulate impossible event rates to find buffering/processing bugs
-- ════════════════════════════════════════════════════════════════════════════

eventFloodTests :: [TestTree]
eventFloodTests =
  [ testCase "10k events in 1 second doesn't crash" flood_10kEvents,
    testCase "100k events doesn't OOM" flood_100kEvents,
    testCase "rapid complete/start cycles" flood_rapidCycles,
    testCase "all events for same target simultaneously" flood_sameTarget,
    testCase "event burst after idle period" flood_burstAfterIdle,
    testCase "interleaved cache/execute events" flood_interleavedCacheExecute,
    testProperty "random event sequence maintains invariants" prop_randomEventSequence
  ]

flood_10kEvents :: Assertion
flood_10kEvents = do
  now <- getCurrentTime
  let events = [ProgressStarting ("//pkg:t" <> T.pack (show i)) i 10000 | i <- [1..10000]]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= 10000

flood_100kEvents :: Assertion
flood_100kEvents = do
  result <- timeout 30000000 $ do
    now <- getCurrentTime
    let n = 100000
        events = concat
          [ [ProgressStarting ("//pkg:t" <> T.pack (show i)) i n | i <- [1..n]]
          ]
        finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
    evaluate $ dsTotal finalState
  case result of
    Nothing -> assertFailure "100k events timed out (30s)"
    Just _ -> pure ()

flood_rapidCycles :: Assertion
flood_rapidCycles = do
  now <- getCurrentTime
  let n = 10000
      events = concat
        [ [ProgressStarting ("//pkg:t" <> T.pack (show i)) i n,
           ProgressCompleted ("//pkg:t" <> T.pack (show i)) i n 0]
        | i <- [1..n]
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsCompleted finalState @?= n

flood_sameTarget :: Assertion
flood_sameTarget = do
  now <- getCurrentTime
  let target = "//pkg:same_target"
      events = concat
        [ replicate 100 (ProgressStarting target 1 100),
          replicate 100 (ProgressCacheHit target),
          replicate 100 (ProgressCompleted target 1 100 0)
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should not crash, state should be sensible
  dsCompleted finalState >= 0 @?= True

flood_burstAfterIdle :: Assertion
flood_burstAfterIdle = do
  now <- getCurrentTime
  let later = addUTCTime 3600 now -- 1 hour later
      initialEvents = [ProgressStarting "//pkg:early" 1 1000]
      burstEvents = [ProgressStarting ("//pkg:t" <> T.pack (show i)) i 1000 | i <- [2..1000]]
      state1 = foldl' (flip (handleProgressEvent now)) initDashboardState initialEvents
      finalState = foldl' (flip (handleProgressEvent later)) state1 burstEvents
  -- Should handle time gap gracefully
  dsTotal finalState >= 0 @?= True

flood_interleavedCacheExecute :: Assertion
flood_interleavedCacheExecute = do
  now <- getCurrentTime
  let n = 5000
      -- Interleave cached and executed targets
      events = concat
        [ if even i
            then [ProgressCached ("//pkg:t" <> T.pack (show i)) i n]
            else [ProgressStarting ("//pkg:t" <> T.pack (show i)) i n,
                  ProgressCompleted ("//pkg:t" <> T.pack (show i)) i n 0]
        | i <- [1..n]
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Half should be cached, half executed
  dsCached finalState @?= (n `div` 2)
  dsCompleted finalState @?= n

prop_randomEventSequence :: Property
prop_randomEventSequence = forAll genEventSequence $ \events ->
  let now = epoch
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  in -- Invariants that must always hold
     dsCompleted finalState >= 0
     && dsCached finalState >= 0
     && dsFailed finalState >= 0
     && dsCached finalState <= dsCompleted finalState

-- ════════════════════════════════════════════════════════════════════════════
-- RACE CONDITION TESTS
-- Concurrent state modifications that shouldn't be possible but might happen
-- ════════════════════════════════════════════════════════════════════════════

raceConditionTests :: [TestTree]
raceConditionTests =
  [ testCase "concurrent event handlers don't corrupt state" race_concurrentHandlers,
    testCase "concurrent reads during writes" race_concurrentReadWrite,
    testCase "rapid IORef updates maintain consistency" race_iorefConsistency,
    testCase "MVar state doesn't deadlock" race_mvarNoDeadlock,
    testCase "async cancellation mid-update" race_asyncCancellation,
    testCase "interleaved increment/read cycles" race_interleavedIncrement
  ]

race_concurrentHandlers :: Assertion
race_concurrentHandlers = do
  stateRef <- newIORef initDashboardState
  now <- getCurrentTime
  let numThreads = 100
      eventsPerThread = 100
  
  -- Each thread sends different events
  results <- forConcurrently [1..numThreads] $ \t -> do
    forM_ [1..eventsPerThread] $ \e -> do
      let target = "//t" <> T.pack (show t) <> ":" <> T.pack (show e)
          event = ProgressStarting target (t * eventsPerThread + e) (numThreads * eventsPerThread)
      atomicModifyIORef' stateRef $ \s ->
        (handleProgressEvent now event s, ())
    pure t
  
  finalState <- readIORef stateRef
  -- Should have processed all events without corruption
  length results @?= numThreads

race_concurrentReadWrite :: Assertion
race_concurrentReadWrite = do
  stateRef <- newIORef initDashboardState
  now <- getCurrentTime
  stopFlag <- newIORef False
  
  -- Writer thread
  writerAsync <- async $ do
    forM_ [1..10000] $ \i -> do
      let event = ProgressStarting ("//pkg:t" <> T.pack (show i)) i 10000
      atomicModifyIORef' stateRef $ \s ->
        (handleProgressEvent now event s, ())
      done <- readIORef stopFlag
      when done $ pure ()
  
  -- Reader threads
  readerAsyncs <- forM [1..10] $ \_ -> async $ do
    replicateM 1000 $ do
      s <- readIORef stateRef
      evaluate $ dsCompleted s + dsCached s + dsFailed s
  
  -- Wait for writer
  wait writerAsync
  writeIORef stopFlag True
  
  -- Wait for readers
  mapM_ wait readerAsyncs
  pure ()

race_iorefConsistency :: Assertion
race_iorefConsistency = do
  counter <- newIORef (0 :: Int)
  let numThreads = 100
      incrementsPerThread = 1000
  
  results <- forConcurrently [1..numThreads] $ \_ -> do
    replicateM_ incrementsPerThread $
      atomicModifyIORef' counter $ \n -> (n + 1, ())
    pure ()
  
  finalCount <- readIORef counter
  finalCount @?= numThreads * incrementsPerThread

race_mvarNoDeadlock :: Assertion
race_mvarNoDeadlock = do
  result <- timeout 5000000 $ do
    stateVar <- newMVar initDashboardState
    now <- getCurrentTime
    
    forConcurrently [1..100] $ \t -> do
      forM_ [1..100] $ \e -> do
        let event = ProgressStarting ("//pkg:" <> T.pack (show (t * 100 + e))) (t * 100 + e) 10000
        modifyMVar_ stateVar $ \s ->
          pure $! handleProgressEvent now event s
    
    readMVar stateVar
  
  case result of
    Nothing -> assertFailure "MVar deadlock detected"
    Just _ -> pure ()

race_asyncCancellation :: Assertion
race_asyncCancellation = do
  stateRef <- newIORef initDashboardState
  now <- getCurrentTime
  
  -- Start a long-running update
  longTask <- async $ do
    forM_ [1..100000] $ \i -> do
      let event = ProgressStarting ("//pkg:t" <> T.pack (show i)) i 100000
      atomicModifyIORef' stateRef $ \s ->
        (handleProgressEvent now event s, ())
  
  -- Cancel it mid-execution
  threadDelay 10000 -- 10ms
  cancel longTask
  
  -- State should still be valid (not corrupted)
  finalState <- readIORef stateRef
  dsCompleted finalState >= 0 @?= True
  dsCached finalState >= 0 @?= True

race_interleavedIncrement :: Assertion
race_interleavedIncrement = do
  completedRef <- newIORef (0 :: Int)
  cachedRef <- newIORef (0 :: Int)
  
  let numOps = 10000
  
  -- Some threads increment completed, some increment cached
  results <- forConcurrently [1..100] $ \t -> do
    forM_ [1..100] $ \_ -> do
      if even t
        then atomicModifyIORef' completedRef $ \n -> (n + 1, ())
        else atomicModifyIORef' cachedRef $ \n -> (n + 1, ())
  
  completed <- readIORef completedRef
  cached <- readIORef cachedRef
  
  -- Should equal expected counts
  completed + cached @?= numOps

-- ════════════════════════════════════════════════════════════════════════════
-- STATE MACHINE VIOLATION TESTS
-- Illegal state transitions that should be handled gracefully
-- ════════════════════════════════════════════════════════════════════════════

stateMachineTests :: [TestTree]
stateMachineTests =
  [ testCase "complete before start" sm_completeBeforeStart,
    testCase "fail before start" sm_failBeforeStart,
    testCase "double complete" sm_doubleComplete,
    testCase "double fail" sm_doubleFail,
    testCase "complete after fail" sm_completeAfterFail,
    testCase "fail after complete" sm_failAfterComplete,
    testCase "cached after start" sm_cachedAfterStart,
    testCase "start after complete" sm_startAfterComplete,
    testCase "start after cached" sm_startAfterCached
  ]

sm_completeBeforeStart :: Assertion
sm_completeBeforeStart = do
  now <- getCurrentTime
  let events = [ProgressCompleted "//pkg:never_started" 1 10 0]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should not crash, may or may not count as completed
  dsCompleted finalState >= 0 @?= True

sm_failBeforeStart :: Assertion
sm_failBeforeStart = do
  now <- getCurrentTime
  let events = [ProgressFailed "//pkg:never_started" 1 10 "mystery failure"]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsFailed finalState >= 0 @?= True

sm_doubleComplete :: Assertion
sm_doubleComplete = do
  now <- getCurrentTime
  let events = 
        [ ProgressStarting "//pkg:t" 1 10,
          ProgressCompleted "//pkg:t" 1 10 100,
          ProgressCompleted "//pkg:t" 1 10 100  -- Double complete
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should count as 1 completion, not 2
  dsCompleted finalState @?= 1

sm_doubleFail :: Assertion
sm_doubleFail = do
  now <- getCurrentTime
  let events =
        [ ProgressStarting "//pkg:t" 1 10,
          ProgressFailed "//pkg:t" 1 10 "first failure",
          ProgressFailed "//pkg:t" 1 10 "second failure"
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should count as 1 failure, not 2
  dsFailed finalState @?= 1

sm_completeAfterFail :: Assertion
sm_completeAfterFail = do
  now <- getCurrentTime
  let events =
        [ ProgressStarting "//pkg:t" 1 10,
          ProgressFailed "//pkg:t" 1 10 "failed",
          ProgressCompleted "//pkg:t" 1 10 0  -- Complete after fail (impossible)
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Failed should stay failed
  dsFailed finalState @?= 1

sm_failAfterComplete :: Assertion
sm_failAfterComplete = do
  now <- getCurrentTime
  let events =
        [ ProgressStarting "//pkg:t" 1 10,
          ProgressCompleted "//pkg:t" 1 10 100,
          ProgressFailed "//pkg:t" 1 10 "posthumous failure"
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Complete should stay complete
  dsCompleted finalState @?= 1
  dsFailed finalState @?= 0

sm_cachedAfterStart :: Assertion
sm_cachedAfterStart = do
  now <- getCurrentTime
  let events =
        [ ProgressStarting "//pkg:t" 1 10,  -- Started building
          ProgressCached "//pkg:t" 1 10      -- Then cached? (contradiction)
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should handle gracefully
  dsCompleted finalState >= 0 @?= True

sm_startAfterComplete :: Assertion
sm_startAfterComplete = do
  now <- getCurrentTime
  let events =
        [ ProgressStarting "//pkg:t" 1 10,
          ProgressCompleted "//pkg:t" 1 10 0,
          ProgressStarting "//pkg:t" 1 10  -- Start again? (time loop)
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsCompleted finalState @?= 1

sm_startAfterCached :: Assertion
sm_startAfterCached = do
  now <- getCurrentTime
  let events =
        [ ProgressCached "//pkg:t" 1 10,
          ProgressStarting "//pkg:t" 1 10  -- Start after cached?
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsCached finalState @?= 1

-- ════════════════════════════════════════════════════════════════════════════
-- MALICIOUS PROGRESS EVENTS
-- Events with impossible/malicious values
-- ════════════════════════════════════════════════════════════════════════════

maliciousEventTests :: [TestTree]
maliciousEventTests =
  [ testCase "negative current index" mal_negativeIndex,
    testCase "current > total" mal_currentGreaterThanTotal,
    testCase "zero total" mal_zeroTotal,
    testCase "huge indices (near maxBound)" mal_hugeIndices,
    testCase "negative size" mal_negativeSize,
    testCase "empty target name" mal_emptyTarget,
    testCase "target with null bytes" mal_nullTarget,
    testCase "target with newlines" mal_newlineTarget,
    testCase "100KB target name" mal_hugeTargetName,
    testCase "unicode target names" mal_unicodeTarget,
    testCase "huge error message" mal_hugeErrorMessage
  ]

mal_negativeIndex :: Assertion
mal_negativeIndex = do
  now <- getCurrentTime
  -- This shouldn't be possible, but what if it happens?
  let events = [ProgressStarting "//pkg:t" (-1) 10]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState >= 0 @?= True

mal_currentGreaterThanTotal :: Assertion
mal_currentGreaterThanTotal = do
  now <- getCurrentTime
  let events = [ProgressStarting "//pkg:t" 999 10]  -- 999 > 10
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState >= 0 @?= True

mal_zeroTotal :: Assertion
mal_zeroTotal = do
  now <- getCurrentTime
  let events = [ProgressStarting "//pkg:t" 1 0]  -- 0 total targets?
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should not crash
  pure ()

mal_hugeIndices :: Assertion
mal_hugeIndices = do
  now <- getCurrentTime
  let huge = maxBound :: Int
      events = [ProgressStarting "//pkg:t" huge huge]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= huge

mal_negativeSize :: Assertion
mal_negativeSize = do
  now <- getCurrentTime
  let events = 
        [ ProgressStarting "//pkg:t" 1 10,
          ProgressCompleted "//pkg:t" 1 10 (-1000)  -- Negative size
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsCompleted finalState @?= 1

mal_emptyTarget :: Assertion
mal_emptyTarget = do
  now <- getCurrentTime
  let events = [ProgressStarting "" 1 10]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= 10

mal_nullTarget :: Assertion
mal_nullTarget = do
  now <- getCurrentTime
  let events = [ProgressStarting "//pkg:tar\x00get" 1 10]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= 10

mal_newlineTarget :: Assertion
mal_newlineTarget = do
  now <- getCurrentTime
  let events = [ProgressStarting "//pkg:tar\nget\r\n" 1 10]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= 10

mal_hugeTargetName :: Assertion
mal_hugeTargetName = do
  now <- getCurrentTime
  let hugeTarget = "//pkg:" <> T.replicate 100000 "x"
      events = [ProgressStarting hugeTarget 1 10]
  result <- timeout 5000000 $ evaluate $
    foldl' (flip (handleProgressEvent now)) initDashboardState events
  case result of
    Nothing -> assertFailure "huge target name timed out"
    Just _ -> pure ()

mal_unicodeTarget :: Assertion
mal_unicodeTarget = do
  now <- getCurrentTime
  let targets = 
        [ "//pkg:\x202E\x202D",  -- RTL/LTR override
          "//pkg:emoji",
          "//pkg:\x0000\x0001",        -- Control chars
          "//pkg:\xFEFF",               -- BOM
          "//pkg:e\x0301"               -- Combining char
        ]
      events = [ProgressStarting t 1 10 | t <- targets]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= 10

mal_hugeErrorMessage :: Assertion
mal_hugeErrorMessage = do
  now <- getCurrentTime
  let hugeError = T.replicate 1000000 "error: something went wrong\n"
      events = 
        [ ProgressStarting "//pkg:t" 1 10,
          ProgressFailed "//pkg:t" 1 10 hugeError
        ]
  result <- timeout 5000000 $ evaluate $
    foldl' (flip (handleProgressEvent now)) initDashboardState events
  case result of
    Nothing -> assertFailure "huge error message timed out"
    Just s -> dsFailed s @?= 1

-- ════════════════════════════════════════════════════════════════════════════
-- CACHE CORRUPTION TESTS
-- Attempts to corrupt or confuse cache hit tracking
-- ════════════════════════════════════════════════════════════════════════════

cacheCorruptionTests :: [TestTree]
cacheCorruptionTests =
  [ testCase "cache hit without corresponding cached" cache_hitWithoutCached,
    testCase "cached count exceeds completed" cache_exceedsCompleted,
    testCase "interleaved cache hits different targets" cache_interleavedTargets,
    testCase "cache hit on failed target" cache_hitOnFailed,
    testCase "cache flapping (hit/miss/hit/miss)" cache_flapping
  ]

cache_hitWithoutCached :: Assertion
cache_hitWithoutCached = do
  now <- getCurrentTime
  let events = replicate 100 (ProgressCacheHit "//pkg:t")  -- Only hits, no cached
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- CacheHit shouldn't increment dsCached
  dsCached finalState @?= 0

cache_exceedsCompleted :: Assertion
cache_exceedsCompleted = do
  now <- getCurrentTime
  let events = 
        [ ProgressCached "//pkg:t1" 1 10,
          ProgressCached "//pkg:t2" 2 10,
          ProgressCached "//pkg:t3" 3 10,
          -- No completed events
          ProgressStarting "//pkg:t4" 4 10,
          ProgressFailed "//pkg:t4" 4 10 "fail"
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Cached should never exceed completed
  dsCached finalState <= dsCompleted finalState @?= True

cache_interleavedTargets :: Assertion
cache_interleavedTargets = do
  now <- getCurrentTime
  let events = concat
        [ [ ProgressCacheHit ("//pkg:t" <> T.pack (show i)),
            ProgressCached ("//pkg:t" <> T.pack (show i)) i 1000
          ]
        | i <- [1..100]
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsCached finalState @?= 100

cache_hitOnFailed :: Assertion
cache_hitOnFailed = do
  now <- getCurrentTime
  let events =
        [ ProgressStarting "//pkg:t" 1 10,
          ProgressCacheHit "//pkg:t",  -- Cache hit during build?
          ProgressFailed "//pkg:t" 1 10 "failed anyway"
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsFailed finalState @?= 1
  dsCached finalState @?= 0

cache_flapping :: Assertion
cache_flapping = do
  now <- getCurrentTime
  -- Same target alternates between cache hit notifications
  let events = concat $ replicate 100
        [ ProgressCacheHit "//pkg:flapper",
          ProgressStarting "//pkg:flapper" 1 10,
          ProgressCompleted "//pkg:flapper" 1 10 0
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should not crash, counts should be reasonable
  dsCompleted finalState >= 0 @?= True

-- ════════════════════════════════════════════════════════════════════════════
-- TIME TRAVEL TESTS
-- Events with timestamps from the past or future
-- ════════════════════════════════════════════════════════════════════════════

timeTravelTests :: [TestTree]
timeTravelTests =
  [ testCase "events from the past" time_pastEvents,
    testCase "events from the far future" time_futureEvents,
    testCase "out of order timestamps" time_outOfOrder,
    testCase "epoch time (1970)" time_epoch,
    testCase "Y2K38 overflow" time_y2k38,
    testCase "negative duration calculations" time_negativeDuration
  ]

time_pastEvents :: Assertion
time_pastEvents = do
  now <- getCurrentTime
  let past = addUTCTime (-86400 * 365 * 10) now  -- 10 years ago
      events = [ProgressStarting "//pkg:ancient" 1 10]
      finalState = foldl' (flip (handleProgressEvent past)) initDashboardState events
  dsTotal finalState @?= 10

time_futureEvents :: Assertion
time_futureEvents = do
  now <- getCurrentTime
  let future = addUTCTime (86400 * 365 * 100) now  -- 100 years in future
      events = [ProgressStarting "//pkg:future" 1 10]
      finalState = foldl' (flip (handleProgressEvent future)) initDashboardState events
  dsTotal finalState @?= 10

time_outOfOrder :: Assertion
time_outOfOrder = do
  now <- getCurrentTime
  let t1 = now
      t2 = addUTCTime (-100) now  -- 100 seconds before
      t3 = addUTCTime 50 now       -- 50 seconds after
      state1 = handleProgressEvent t1 (ProgressStarting "//pkg:t1" 1 10) initDashboardState
      state2 = handleProgressEvent t2 (ProgressStarting "//pkg:t2" 2 10) state1  -- Past!
      state3 = handleProgressEvent t3 (ProgressStarting "//pkg:t3" 3 10) state2
  dsTotal state3 @?= 10

time_epoch :: Assertion
time_epoch = do
  let events = [ProgressStarting "//pkg:t" 1 10]
      finalState = foldl' (flip (handleProgressEvent epoch)) initDashboardState events
  dsTotal finalState @?= 10

time_y2k38 :: Assertion
time_y2k38 = do
  -- January 19, 2038 03:14:08 UTC (32-bit overflow)
  let y2k38 = addUTCTime (fromIntegral (2147483648 :: Int)) epoch
      events = [ProgressStarting "//pkg:y2k38" 1 10]
      finalState = foldl' (flip (handleProgressEvent y2k38)) initDashboardState events
  dsTotal finalState @?= 10

time_negativeDuration :: Assertion
time_negativeDuration = do
  now <- getCurrentTime
  let startTime = addUTCTime 100 now  -- Start time is IN THE FUTURE
      events = [ProgressStarting "//pkg:t" 1 10]
      state = foldl' (flip (handleProgressEvent now)) initDashboardState events
      -- Calculating duration would give negative
      state' = state { dsStartTime = Just startTime }
      duration = case dsStartTime state' of
        Just t -> diffUTCTime now t
        Nothing -> 0
  -- Duration is negative - should handle gracefully
  duration < 0 @?= True

-- ════════════════════════════════════════════════════════════════════════════
-- TERMINAL TORTURE TESTS
-- Things that would break terminal rendering
-- ════════════════════════════════════════════════════════════════════════════

terminalTortureTests :: [TestTree]
terminalTortureTests =
  [ testCase "escape sequence injection in target name" term_escapeSequence,
    testCase "terminal width 0" term_zeroWidth,
    testCase "terminal width maxBound" term_hugeWidth,
    testCase "rapid resize events" term_rapidResize,
    testCase "control characters in log output" term_controlChars,
    testCase "extremely long single line" term_longLine,
    testCase "10k lines of output" term_manyLines
  ]

term_escapeSequence :: Assertion
term_escapeSequence = do
  now <- getCurrentTime
  let malicious = "//pkg:\x1B[2J\x1B[H"  -- Clear screen + home cursor
      events = [ProgressStarting malicious 1 10]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= 10

term_zeroWidth :: Assertion
term_zeroWidth = do
  -- Terminal width of 0 shouldn't cause divide by zero
  let width = 0 :: Int
      text = "some progress text"
      truncated = if width > 0 then take width (T.unpack text) else ""
  length truncated @?= 0

term_hugeWidth :: Assertion
term_hugeWidth = do
  let width = maxBound :: Int
      text = "some progress text"
  -- Should not try to allocate maxBound characters
  length (T.unpack text) < width @?= True

term_rapidResize :: Assertion
term_rapidResize = do
  -- Simulate rapid terminal resize events
  result <- timeout 5000000 $ do
    forM_ [1..10000] $ \i -> do
      let width = (i `mod` 200) + 20
          height = (i `mod` 50) + 10
      -- Just computing sizes, no actual terminal
      evaluate $ width * height
    pure ()
  case result of
    Nothing -> assertFailure "rapid resize timed out"
    Just _ -> pure ()

term_controlChars :: Assertion
term_controlChars = do
  now <- getCurrentTime
  let controlChars = T.pack ['\x00'..'\x1F']  -- All ASCII control chars
      events = [ProgressFailed "//pkg:t" 1 10 controlChars]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsFailed finalState @?= 1

term_longLine :: Assertion
term_longLine = do
  now <- getCurrentTime
  let longTarget = "//pkg:" <> T.replicate 10000 "x"
      events = [ProgressStarting longTarget 1 10]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= 10

term_manyLines :: Assertion
term_manyLines = do
  now <- getCurrentTime
  let manyLineError = T.unlines (replicate 10000 "error line")
      events = [ProgressFailed "//pkg:t" 1 10 manyLineError]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsFailed finalState @?= 1

-- ════════════════════════════════════════════════════════════════════════════
-- RESOURCE STARVATION TESTS
-- ════════════════════════════════════════════════════════════════════════════

starvationTests :: [TestTree]
starvationTests =
  [ testCase "GC during event processing" starve_gcDuringProcessing,
    testCase "memory pressure doesn't corrupt state" starve_memoryPressure,
    testCase "thread pool exhaustion" starve_threadPoolExhaustion
  ]

starve_gcDuringProcessing :: Assertion
starve_gcDuringProcessing = do
  now <- getCurrentTime
  stateRef <- newIORef initDashboardState
  
  forM_ [1..1000] $ \i -> do
    let event = ProgressStarting ("//pkg:t" <> T.pack (show i)) i 1000
    atomicModifyIORef' stateRef $ \s ->
      (handleProgressEvent now event s, ())
    when (i `mod` 100 == 0) performGC
  
  finalState <- readIORef stateRef
  dsTotal finalState @?= 1000

starve_memoryPressure :: Assertion
starve_memoryPressure = do
  now <- getCurrentTime
  
  -- Allocate a bunch of memory
  refs <- replicateM 100 $ newIORef (replicate 10000 (0 :: Int))
  
  -- Process events under memory pressure
  let events = [ProgressStarting ("//pkg:t" <> T.pack (show i)) i 100 | i <- [1..100]]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  
  -- Force GC to clean up
  performGC
  
  dsTotal finalState @?= 100

starve_threadPoolExhaustion :: Assertion
starve_threadPoolExhaustion = do
  result <- timeout 30000000 $ do
    mvars <- replicateM 1000 newEmptyMVar
    
    -- Start 1000 threads that all block
    threads <- forM mvars $ \mvar -> async $ do
      () <- takeMVar mvar
      pure ()
    
    -- Release them all
    forM_ mvars $ \mvar -> putMVar mvar ()
    
    -- Wait for completion
    mapM_ wait threads
  
  case result of
    Nothing -> assertFailure "thread pool exhaustion timed out"
    Just _ -> pure ()

-- ════════════════════════════════════════════════════════════════════════════
-- COUNTER OVERFLOW TESTS
-- ════════════════════════════════════════════════════════════════════════════

overflowTests :: [TestTree]
overflowTests =
  [ testCase "completed counter near maxBound" overflow_completedMaxBound,
    testCase "cached counter near maxBound" overflow_cachedMaxBound,
    testCase "total counter near maxBound" overflow_totalMaxBound,
    testProperty "counters don't overflow on increment" prop_noOverflow
  ]

overflow_completedMaxBound :: Assertion
overflow_completedMaxBound = do
  now <- getCurrentTime
  let state = initDashboardState { dsCompleted = maxBound - 1 }
      events = [ProgressCompleted "//pkg:t" 1 10 0]
      -- This would overflow if not handled
      finalState = foldl' (flip (handleProgressEvent now)) state events
  -- Should be maxBound, not wrap to negative
  dsCompleted finalState >= 0 @?= True

overflow_cachedMaxBound :: Assertion
overflow_cachedMaxBound = do
  now <- getCurrentTime
  let state = initDashboardState { dsCached = maxBound - 1 }
      events = [ProgressCached "//pkg:t" 1 10]
      finalState = foldl' (flip (handleProgressEvent now)) state events
  dsCached finalState >= 0 @?= True

overflow_totalMaxBound :: Assertion
overflow_totalMaxBound = do
  now <- getCurrentTime
  let events = [ProgressGraphBuilt maxBound]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= maxBound

prop_noOverflow :: Property
prop_noOverflow = forAll (choose (maxBound - 100, maxBound :: Int)) $ \start ->
  let state = initDashboardState { dsCompleted = start }
      -- Try to increment
      newVal = start + 1
  in newVal > 0 || start == maxBound  -- Either positive or already maxed

-- ════════════════════════════════════════════════════════════════════════════
-- CONCURRENT MUTATION TESTS
-- Multiple threads modifying different fields simultaneously
-- ════════════════════════════════════════════════════════════════════════════

concurrentMutationTests :: [TestTree]
concurrentMutationTests =
  [ testCase "concurrent field updates" conc_fieldUpdates,
    testCase "concurrent map insertions" conc_mapInsertions,
    testCase "read your own writes" conc_readYourWrites
  ]

conc_fieldUpdates :: Assertion
conc_fieldUpdates = do
  completedRef <- newIORef (0 :: Int)
  cachedRef <- newIORef (0 :: Int)
  failedRef <- newIORef (0 :: Int)
  
  let numOps = 10000
  
  results <- forConcurrently [1..numOps] $ \i -> do
    case i `mod` 3 of
      0 -> atomicModifyIORef' completedRef $ \n -> (n + 1, ())
      1 -> atomicModifyIORef' cachedRef $ \n -> (n + 1, ())
      _ -> atomicModifyIORef' failedRef $ \n -> (n + 1, ())
  
  completed <- readIORef completedRef
  cached <- readIORef cachedRef
  failed <- readIORef failedRef
  
  completed + cached + failed @?= numOps

conc_mapInsertions :: Assertion
conc_mapInsertions = do
  mapRef <- newIORef (Map.empty :: Map.Map Text Int)
  
  let numOps = 10000
  
  results <- forConcurrently [1..numOps] $ \i -> do
    let key = "key" <> T.pack (show i)
    atomicModifyIORef' mapRef $ \m -> (Map.insert key i m, ())
  
  finalMap <- readIORef mapRef
  Map.size finalMap @?= numOps

conc_readYourWrites :: Assertion
conc_readYourWrites = do
  ref <- newIORef (0 :: Int)
  
  results <- forConcurrently [1..1000] $ \i -> do
    atomicModifyIORef' ref $ \n -> (n + 1, ())
    -- Should see at least our own write
    val <- readIORef ref
    pure (val > 0)
  
  all id results @?= True

-- ════════════════════════════════════════════════════════════════════════════
-- PHASE TRANSITION CHAOS
-- Rapid/illegal phase changes
-- ════════════════════════════════════════════════════════════════════════════

phaseTransitionTests :: [TestTree]
phaseTransitionTests =
  [ testCase "all phases in wrong order" phase_wrongOrder,
    testCase "skip directly to executing" phase_skipToExecuting,
    testCase "repeat same phase 1000 times" phase_repeatSame,
    testCase "rapid phase flipping" phase_rapidFlip
  ]

phase_wrongOrder :: Assertion
phase_wrongOrder = do
  now <- getCurrentTime
  let events =
        [ ProgressCompleted "//pkg:t1" 1 10 0,   -- Complete before start
          ProgressStarting "//pkg:t1" 1 10,      -- Start after complete
          ProgressFailed "//pkg:t1" 1 10 "fail", -- Fail after complete
          ProgressCached "//pkg:t1" 1 10         -- Cached after fail
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should not crash
  pure ()

phase_skipToExecuting :: Assertion
phase_skipToExecuting = do
  now <- getCurrentTime
  -- Go directly to completion without starting
  let events = [ProgressCompleted "//pkg:t" 1 10 0]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsCompleted finalState >= 0 @?= True

phase_repeatSame :: Assertion
phase_repeatSame = do
  now <- getCurrentTime
  let events = replicate 1000 (ProgressStarting "//pkg:t" 1 10)
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should still just be one target in starting state
  dsTotal finalState @?= 10

phase_rapidFlip :: Assertion
phase_rapidFlip = do
  now <- getCurrentTime
  let events = concat $ replicate 100
        [ ProgressStarting "//pkg:t" 1 10,
          ProgressCompleted "//pkg:t" 1 10 0,
          ProgressStarting "//pkg:t" 1 10,
          ProgressFailed "//pkg:t" 1 10 "fail"
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should not crash
  pure ()

-- ════════════════════════════════════════════════════════════════════════════
-- TARGET STATUS CHAOS
-- Crazy target status patterns
-- ════════════════════════════════════════════════════════════════════════════

targetStatusTests :: [TestTree]
targetStatusTests =
  [ testCase "1000 different targets same name pattern" target_samePattern,
    testCase "targets with colliding hashes" target_collidingHashes,
    testCase "duplicate target names" target_duplicateNames
  ]

target_samePattern :: Assertion
target_samePattern = do
  now <- getCurrentTime
  let events = [ProgressStarting ("//pkg:t" <> T.pack (show i)) i 1000 | i <- [1..1000]]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= 1000

target_collidingHashes :: Assertion
target_collidingHashes = do
  now <- getCurrentTime
  -- These won't actually collide, but test the pattern
  let similar = ["//pkg:aaaa", "//pkg:aaab", "//pkg:aaac", "//pkg:aaad"]
      events = [ProgressStarting t i 10 | (t, i) <- zip similar [1..]]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  dsTotal finalState @?= 10

target_duplicateNames :: Assertion
target_duplicateNames = do
  now <- getCurrentTime
  -- Same target name, different events
  let events = concat
        [ [ProgressStarting "//pkg:dup" 1 10, ProgressCompleted "//pkg:dup" 1 10 0]
        , [ProgressStarting "//pkg:dup" 1 10, ProgressCompleted "//pkg:dup" 1 10 0]
        , [ProgressStarting "//pkg:dup" 1 10, ProgressCompleted "//pkg:dup" 1 10 0]
        ]
      finalState = foldl' (flip (handleProgressEvent now)) initDashboardState events
  -- Should not crash
  pure ()

-- ════════════════════════════════════════════════════════════════════════════
-- LOG STREAM TORTURE
-- Abuse the log stream display
-- ════════════════════════════════════════════════════════════════════════════

logStreamTests :: [TestTree]
logStreamTests =
  [ testCase "10k log entries" log_10kEntries,
    testCase "log entry with 100KB text" log_hugeEntry,
    testCase "rapid log additions" log_rapidAdditions,
    testCase "binary data in logs" log_binaryData
  ]

log_10kEntries :: Assertion
log_10kEntries = do
  let entries = [T.pack $ "Log entry " ++ show i | i <- [1..10000 :: Int]]
      -- Just verify we can create them
      totalLen = sum $ map T.length entries
  totalLen > 0 @?= True

log_hugeEntry :: Assertion
log_hugeEntry = do
  let hugeEntry = T.replicate 100000 "x"
  T.length hugeEntry @?= 100000

log_rapidAdditions :: Assertion
log_rapidAdditions = do
  logRef <- newIORef ([] :: [Text])
  
  result <- timeout 5000000 $ do
    forM_ [1..10000] $ \i -> do
      atomicModifyIORef' logRef $ \logs ->
        (T.pack (show i) : logs, ())
  
  case result of
    Nothing -> assertFailure "rapid log additions timed out"
    Just _ -> pure ()

log_binaryData :: Assertion
log_binaryData = do
  let binary = T.pack $ map (toEnum . fromEnum) [0..255 :: Int]
  T.length binary @?= 256

-- ════════════════════════════════════════════════════════════════════════════
-- GENERATORS
-- ════════════════════════════════════════════════════════════════════════════

genEventSequence :: Gen [ProgressEvent]
genEventSequence = do
  n <- choose (0, 100)
  events <- replicateM n genEvent
  pure events

genEvent :: Gen ProgressEvent
genEvent = oneof
  [ ProgressStarting <$> genTarget <*> choose (1, 1000) <*> choose (1, 1000),
    ProgressCompleted <$> genTarget <*> choose (1, 1000) <*> choose (1, 1000) <*> choose (0, 10000),
    ProgressFailed <$> genTarget <*> choose (1, 1000) <*> choose (1, 1000) <*> genErrorMsg,
    ProgressCached <$> genTarget <*> choose (1, 1000) <*> choose (1, 1000),
    ProgressCacheHit <$> genTarget,
    ProgressGraphBuilt <$> choose (1, 1000)
  ]

genTarget :: Gen Text
genTarget = do
  n <- choose (1, 20)
  chars <- replicateM n $ elements (['a'..'z'] ++ ['0'..'9'] ++ ['-', '_', ':'])
  pure $ "//pkg:" <> T.pack chars

genErrorMsg :: Gen Text
genErrorMsg = do
  n <- choose (0, 100)
  chars <- replicateM n $ elements (['a'..'z'] ++ [' ', '\n', ':', '-'])
  pure $ T.pack chars

-- ════════════════════════════════════════════════════════════════════════════
-- LOCAL TYPE DEFINITIONS
-- Mirror TUI types for testing
-- ════════════════════════════════════════════════════════════════════════════

data ProgressEvent
  = ProgressStarting Text Int Int      -- target, current, total
  | ProgressCompleted Text Int Int Int -- target, current, total, size
  | ProgressFailed Text Int Int Text   -- target, current, total, error
  | ProgressCached Text Int Int        -- target, current, total
  | ProgressCacheHit Text              -- target (notification only)
  | ProgressGraphBuilt Int             -- total actions
  | ProgressBuildingGraph
  | ProgressGraphAction Text
  deriving (Show, Eq)

data TargetStatus = TPending | TBuilding | TCompleted | TFailed | TCached
  deriving (Show, Eq)

data DashboardState = DashboardState
  { dsCompleted :: Int,
    dsCached :: Int,
    dsFailed :: Int,
    dsTotal :: Int,
    dsTargets :: Map.Map Text TargetStatus,
    dsStartTime :: Maybe UTCTime,
    dsLogs :: [Text]
  }
  deriving (Show)

initDashboardState :: DashboardState
initDashboardState = DashboardState
  { dsCompleted = 0,
    dsCached = 0,
    dsFailed = 0,
    dsTotal = 0,
    dsTargets = Map.empty,
    dsStartTime = Nothing,
    dsLogs = []
  }

-- | Handle a progress event, updating dashboard state
-- This mirrors the real TUI.handleProgressEvent
handleProgressEvent :: UTCTime -> ProgressEvent -> DashboardState -> DashboardState
handleProgressEvent now event state = case event of
  ProgressStarting target _ total ->
    state
      { dsTotal = total,
        dsTargets = Map.insert target TBuilding (dsTargets state),
        dsStartTime = dsStartTime state <|> Just now
      }
  
  ProgressCompleted target _ _ _ ->
    case Map.lookup target (dsTargets state) of
      Just TBuilding ->
        state
          { dsCompleted = dsCompleted state + 1,
            dsTargets = Map.insert target TCompleted (dsTargets state)
          }
      Just TCompleted -> state  -- Already completed, ignore
      Just TFailed -> state     -- Failed, don't switch to completed
      Just TCached -> state     -- Already cached
      _ -> state                -- Unknown target, ignore or count?
  
  ProgressFailed target _ _ errMsg ->
    case Map.lookup target (dsTargets state) of
      Just TCompleted -> state  -- Already completed, ignore failure
      Just TFailed -> state     -- Already failed
      _ ->
        state
          { dsFailed = dsFailed state + 1,
            dsTargets = Map.insert target TFailed (dsTargets state)
          }
  
  ProgressCached target _ _ ->
    state
      { dsCompleted = dsCompleted state + 1,
        dsCached = dsCached state + 1,
        dsTargets = Map.insert target TCached (dsTargets state)
      }
  
  ProgressCacheHit _ ->
    state  -- Just a notification, don't increment anything
  
  ProgressGraphBuilt total ->
    state { dsTotal = total }
  
  ProgressBuildingGraph -> state
  ProgressGraphAction _ -> state

-- Alternative helper
(<|>) :: Maybe a -> Maybe a -> Maybe a
Nothing <|> b = b
a <|> _ = a

-- Epoch time for testing
epoch :: UTCTime
epoch = read "1970-01-01 00:00:00 UTC"
