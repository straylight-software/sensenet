{-# LANGUAGE OverloadedStrings #-}

-- | TUI tests for sensenet
--
-- Tests for terminal UI functionality:
-- - Dashboard state management
-- - Progress event handling
-- - Cache hit/miss tracking
-- - Phase transitions
module Test.SenseNet.TUI (tests) where

import Data.Map.Strict qualified as Map
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import SenseNet.Build (ProgressEvent (..))
import SenseNet.TUI (DashboardState (..), handleProgressEvent, initDashboardState)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "TUI"
    [ testGroup
        "DashboardState"
        [ testCase "initDashboardState has zero counts" $ do
            let s = initDashboardState
            dsCompleted s @?= 0
            dsCached s @?= 0
            dsFailed s @?= 0
            dsTotal s @?= 0,
          testCase "initDashboardState has empty targets" $ do
            let s = initDashboardState
            Map.null (dsTargets s) @?= True
        ],
      testGroup
        "handleProgressEvent"
        [ testCase "ProgressCached increments dsCached" $ do
            now <- getCurrentTime
            let s0 = initDashboardState
                s1 = handleProgressEvent now (ProgressCached "//pkg:target" 1 5) s0
            dsCached s1 @?= 1
            dsCompleted s1 @?= 1,
          testCase "ProgressCached increments multiple times" $ do
            now <- getCurrentTime
            let s0 = initDashboardState
                s1 = handleProgressEvent now (ProgressCached "//pkg:a" 1 5) s0
                s2 = handleProgressEvent now (ProgressCached "//pkg:b" 2 5) s1
                s3 = handleProgressEvent now (ProgressCached "//pkg:c" 3 5) s2
            dsCached s3 @?= 3
            dsCompleted s3 @?= 3,
          testCase "ProgressCompleted increments dsCompleted but not dsCached" $ do
            now <- getCurrentTime
            let s0 = initDashboardState
                -- First start the target so it's in TBuilding state
                s1 = handleProgressEvent now (ProgressStarting "//pkg:target" 1 5) s0
                s2 = handleProgressEvent now (ProgressCompleted "//pkg:target" 1 5 1024) s1
            dsCompleted s2 @?= 1
            dsCached s2 @?= 0,
          testCase "ProgressFailed increments dsFailed" $ do
            now <- getCurrentTime
            let s0 = initDashboardState
                s1 = handleProgressEvent now (ProgressStarting "//pkg:target" 1 5) s0
                s2 = handleProgressEvent now (ProgressFailed "//pkg:target" 1 5 "error") s1
            dsFailed s2 @?= 1
            dsCompleted s2 @?= 0
            dsCached s2 @?= 0,
          testCase "mixed cached and executed" $ do
            now <- getCurrentTime
            let s0 = initDashboardState
                -- 2 cached
                s1 = handleProgressEvent now (ProgressCached "//pkg:a" 1 5) s0
                s2 = handleProgressEvent now (ProgressCached "//pkg:b" 2 5) s1
                -- 1 executed
                s3 = handleProgressEvent now (ProgressStarting "//pkg:c" 3 5) s2
                s4 = handleProgressEvent now (ProgressCompleted "//pkg:c" 3 5 512) s3
                -- 1 failed
                s5 = handleProgressEvent now (ProgressStarting "//pkg:d" 4 5) s4
                s6 = handleProgressEvent now (ProgressFailed "//pkg:d" 4 5 "boom") s5
            dsCompleted s6 @?= 3 -- 2 cached + 1 executed
            dsCached s6 @?= 2
            dsFailed s6 @?= 1,
          testCase "ProgressGraphBuilt sets dsTotal" $ do
            now <- getCurrentTime
            let s0 = initDashboardState
                s1 = handleProgressEvent now (ProgressGraphBuilt 42) s0
            dsTotal s1 @?= 42,
          testCase "ProgressCacheHit does not increment dsCached" $ do
            -- ProgressCacheHit is just a notification, not a completion
            -- dsCached is only incremented by ProgressCached
            now <- getCurrentTime
            let s0 = initDashboardState
                s1 = handleProgressEvent now (ProgressCacheHit "//pkg:target") s0
            dsCached s1 @?= 0
            dsCompleted s1 @?= 0
        ],
      testGroup
        "cache rate calculation"
        [ testCase "cache rate 100% when all cached" $ do
            now <- getCurrentTime
            let s0 = initDashboardState
                s1 = handleProgressEvent now (ProgressCached "//pkg:a" 1 2) s0
                s2 = handleProgressEvent now (ProgressCached "//pkg:b" 2 2) s1
                rate = if dsCompleted s2 > 0 then (dsCached s2 * 100) `div` dsCompleted s2 else 0
            rate @?= 100,
          testCase "cache rate 50% when half cached" $ do
            now <- getCurrentTime
            let s0 = initDashboardState
                s1 = handleProgressEvent now (ProgressCached "//pkg:a" 1 2) s0
                s2 = handleProgressEvent now (ProgressStarting "//pkg:b" 2 2) s1
                s3 = handleProgressEvent now (ProgressCompleted "//pkg:b" 2 2 0) s2
                rate = if dsCompleted s3 > 0 then (dsCached s3 * 100) `div` dsCompleted s3 else 0
            rate @?= 50,
          testCase "cache rate 0% when none cached" $ do
            now <- getCurrentTime
            let s0 = initDashboardState
                s1 = handleProgressEvent now (ProgressStarting "//pkg:a" 1 2) s0
                s2 = handleProgressEvent now (ProgressCompleted "//pkg:a" 1 2 0) s1
                s3 = handleProgressEvent now (ProgressStarting "//pkg:b" 2 2) s2
                s4 = handleProgressEvent now (ProgressCompleted "//pkg:b" 2 2 0) s3
                rate = if dsCompleted s4 > 0 then (dsCached s4 * 100) `div` dsCompleted s4 else 0
            rate @?= 0
        ]
    ]
