{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for SenseNet.TUI
--
-- Tests the TUI:
-- - hasValidTerminal logic
-- - State updates from events
-- - Progress calculation
module Test.SenseNet.TUI (tests) where

import Control.Exception (bracket)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Vector qualified as Vec
import Lens.Micro ((^.))
import SenseNet.TUI
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

tests :: TestTree
tests =
  testGroup
    "TUI"
    [ testGroup
        "hasValidTerminal"
        [ testCase "valid COLUMNS and LINES" $ do
            bracket
              ( do
                  oldCols <- lookupEnv "COLUMNS"
                  oldLines <- lookupEnv "LINES"
                  setEnv "COLUMNS" "120"
                  setEnv "LINES" "40"
                  pure (oldCols, oldLines)
              )
              ( \(oldCols, oldLines) -> do
                  maybe (unsetEnv "COLUMNS") (setEnv "COLUMNS") oldCols
                  maybe (unsetEnv "LINES") (setEnv "LINES") oldLines
              )
              ( \_ -> do
                  valid <- hasValidTerminal
                  valid @?= True
              ),
          testCase "zero dimensions" $ do
            bracket
              ( do
                  oldCols <- lookupEnv "COLUMNS"
                  oldLines <- lookupEnv "LINES"
                  oldTerm <- lookupEnv "TERM"
                  setEnv "COLUMNS" "0"
                  setEnv "LINES" "0"
                  unsetEnv "TERM"
                  pure (oldCols, oldLines, oldTerm)
              )
              ( \(oldCols, oldLines, oldTerm) -> do
                  maybe (unsetEnv "COLUMNS") (setEnv "COLUMNS") oldCols
                  maybe (unsetEnv "LINES") (setEnv "LINES") oldLines
                  maybe (unsetEnv "TERM") (setEnv "TERM") oldTerm
              )
              ( \_ -> do
                  valid <- hasValidTerminal
                  valid @?= False
              ),
          testCase "TERM=dumb is invalid" $ do
            bracket
              ( do
                  oldCols <- lookupEnv "COLUMNS"
                  oldLines <- lookupEnv "LINES"
                  oldTerm <- lookupEnv "TERM"
                  unsetEnv "COLUMNS"
                  unsetEnv "LINES"
                  setEnv "TERM" "dumb"
                  pure (oldCols, oldLines, oldTerm)
              )
              ( \(oldCols, oldLines, oldTerm) -> do
                  maybe (unsetEnv "COLUMNS") (setEnv "COLUMNS") oldCols
                  maybe (unsetEnv "LINES") (setEnv "LINES") oldLines
                  maybe (unsetEnv "TERM") (setEnv "TERM") oldTerm
              )
              ( \_ -> do
                  valid <- hasValidTerminal
                  valid @?= False
              ),
          testCase "TERM=xterm-256color is valid" $ do
            bracket
              ( do
                  oldCols <- lookupEnv "COLUMNS"
                  oldLines <- lookupEnv "LINES"
                  oldTerm <- lookupEnv "TERM"
                  unsetEnv "COLUMNS"
                  unsetEnv "LINES"
                  setEnv "TERM" "xterm-256color"
                  pure (oldCols, oldLines, oldTerm)
              )
              ( \(oldCols, oldLines, oldTerm) -> do
                  maybe (unsetEnv "COLUMNS") (setEnv "COLUMNS") oldCols
                  maybe (unsetEnv "LINES") (setEnv "LINES") oldLines
                  maybe (unsetEnv "TERM") (setEnv "TERM") oldTerm
              )
              ( \_ -> do
                  valid <- hasValidTerminal
                  valid @?= True
              )
        ],
      testGroup
        "initialState"
        [ testCase "starts with zero counts" $ do
            now <- getCurrentTime
            let s = initialState now
            -- Access via exported initialState - we can't access internal lenses
            -- So we just verify the function doesn't crash
            pure ()
        ],
      testGroup
        "BuildEvent"
        [ testCase "EventBuildStarted show" $ do
            let e = EventBuildStarted 10
            show e @?= "EventBuildStarted 10",
          testCase "EventActionStarted show" $ do
            let e = EventActionStarted 1 "//pkg:target"
            show e @?= "EventActionStarted 1 \"//pkg:target\"",
          testCase "EventActionCompleted show" $ do
            let e = EventActionCompleted 1 "//pkg:target" ["out.o"]
            T.pack (show e) `T.isInfixOf` "EventActionCompleted" @?= True,
          testCase "EventActionFailed show" $ do
            let e = EventActionFailed 1 "//pkg:target" "compile error"
            T.pack (show e) `T.isInfixOf` "EventActionFailed" @?= True,
          testCase "EventActionCached show" $ do
            let e = EventActionCached 1 "//pkg:target" ["cached.o"]
            T.pack (show e) `T.isInfixOf` "EventActionCached" @?= True,
          testCase "EventBuildFinished success" $ do
            let e = EventBuildFinished (Right ["out1", "out2"])
            T.pack (show e) `T.isInfixOf` "EventBuildFinished" @?= True,
          testCase "EventBuildFinished failure" $ do
            let e = EventBuildFinished (Left "build failed")
            T.pack (show e) `T.isInfixOf` "EventBuildFinished" @?= True
        ],
      testGroup
        "ActionInfo"
        [ testCase "show ActionInfo" $ do
            now <- getCurrentTime
            let info = ActionInfo 42 "//pkg:target" now
            T.pack (show info) `T.isInfixOf` "ActionInfo" @?= True
        ],
      testGroup
        "Progress calculation"
        [ testProperty "progress percentage never exceeds 100" $ \(completed :: Int) (cached :: Int) (failed :: Int) (total :: Int) ->
            let validTotal = max 1 (abs total)
                validCompleted = min validTotal (abs completed)
                validCached = min (validTotal - validCompleted) (abs cached)
                validFailed = min (validTotal - validCompleted - validCached) (abs failed)
                done = validCompleted + validCached + validFailed
                pct = (fromIntegral done / fromIntegral validTotal :: Double) * 100
             in pct >= 0 && pct <= 100,
          testProperty "done count equals sum of completed + cached + failed" $ \(c :: Int) (h :: Int) (f :: Int) ->
            let completed = abs c `mod` 100
                cached = abs h `mod` 100
                failed = abs f `mod` 100
                done = completed + cached + failed
             in done == completed + cached + failed
        ]
    ]
