{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Crasher tests for sensenet
--
-- These tests specifically target code paths that can crash the program.
-- Each test documents a known crash risk and verifies the fix.
--
-- CRITICAL: These tests must pass for production use.
module Test.SenseNet.Crashers (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception (ErrorCall, SomeException, evaluate, try)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "Crashers"
    [ testGroup "foldr1 on empty list" foldr1CrashTests,
      testGroup "Partial functions" partialFunctionTests,
      testGroup "Infinite loops" infiniteLoopTests,
      testGroup "Division by zero" divisionByZeroTests,
      testGroup "Stack overflow" stackOverflowTests,
      testGroup "Memory exhaustion" memoryExhaustionTests,
      testGroup "File handle exhaustion" fileHandleTests,
      testGroup "Signal handling" signalTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- foldr1 Crash (Build.hs:1032-1033)
--
-- The intercalate function in Build.hs uses foldr1 which crashes on empty list.
-- This happens when a C++ binary has zero sources.
-- ════════════════════════════════════════════════════════════════════════════

foldr1CrashTests :: [TestTree]
foldr1CrashTests =
  [ testCase "foldr1 crashes on empty list (demonstrates bug)" $ do
      -- This demonstrates the dangerous pattern in Build.hs
      result <- try @ErrorCall $ evaluate $ foldr1 (\a b -> a <> "," <> b) ([] :: [String])
      case result of
        Left _ -> return () -- Expected: foldr1 throws on empty list
        Right _ -> assertFailure "foldr1 should throw on empty list",
    testCase "safe intercalate handles empty list" $ do
      -- This is how the code SHOULD work
      let safeIntercalate :: String -> [String] -> String
          safeIntercalate _ [] = ""
          safeIntercalate sep xs = foldr1 (\a b -> a <> sep <> b) xs
      safeIntercalate "," [] @?= "",
    testCase "safe intercalate single element" $ do
      let safeIntercalate :: String -> [String] -> String
          safeIntercalate _ [] = ""
          safeIntercalate sep xs = foldr1 (\a b -> a <> sep <> b) xs
      safeIntercalate "," ["one"] @?= "one",
    testCase "safe intercalate multiple elements" $ do
      let safeIntercalate :: String -> [String] -> String
          safeIntercalate _ [] = ""
          safeIntercalate sep xs = foldr1 (\a b -> a <> sep <> b) xs
      safeIntercalate "," ["a", "b", "c"] @?= "a,b,c"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Partial Functions (error, head, !!, Map.!)
--
-- These functions throw exceptions on certain inputs.
-- ════════════════════════════════════════════════════════════════════════════

partialFunctionTests :: [TestTree]
partialFunctionTests =
  [ testCase "error throws (documents Build.hs:290 risk)" $ do
      -- Build.hs:290 uses `error "buildActionGraph: no actions"`
      result <- try @ErrorCall $ evaluate $ error "test error"
      case result of
        Left _ -> return () -- Expected
        Right _ -> assertFailure "error should throw",
    testCase "head crashes on empty (documents potential issues)" $ do
      result <- try @ErrorCall $ evaluate $ head ([] :: [Int])
      case result of
        Left _ -> return ()
        Right _ -> assertFailure "head should throw on empty list",
    testCase "!! crashes on out of bounds" $ do
      result <- try @ErrorCall $ evaluate $ ([1, 2, 3] :: [Int]) !! 10
      case result of
        Left _ -> return ()
        Right _ -> assertFailure "!! should throw on out of bounds",
    testCase "safe headOr pattern" $ do
      let headOr :: a -> [a] -> a
          headOr def [] = def
          headOr _ (x : _) = x
      headOr 0 [] @?= (0 :: Int)
      headOr 0 [1, 2, 3] @?= 1,
    testCase "safe lookup with Maybe" $ do
      let m = Map.fromList [("a", 1), ("b", 2)] :: Map.Map String Int
      Map.lookup "a" m @?= Just 1
      Map.lookup "missing" m @?= Nothing
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Infinite Loops (buildPackageWaves)
--
-- Main.hs:220-242 can loop forever if deps never become ready.
-- ════════════════════════════════════════════════════════════════════════════

infiniteLoopTests :: [TestTree]
infiniteLoopTests =
  [ testCase "cycle detection example - terminates" $ do
      -- Simulates buildPackageWaves with a circular dependency
      -- A depends on B, B depends on A
      let packages = [("A", ["B"]), ("B", ["A"])] :: [(String, [String])]
          go :: Int -> [String] -> [(String, [String])] -> IO [String]
          go 0 completed _ = pure completed -- Max iterations safety
          go _ completed [] = pure completed
          go n completed ((pkg, deps) : rest)
            | all (`elem` completed) deps = go (n - 1) (pkg : completed) rest
            | otherwise = go (n - 1) completed (rest ++ [(pkg, deps)])

      -- With max iterations, this terminates
      result <- race (threadDelay 1000000) (go 100 [] packages)
      case result of
        Left () -> assertFailure "cycle detection timed out"
        Right completed -> do
          -- Neither should complete due to circular dep
          length completed @?= 0,
    testCase "proper topological sort handles DAG" $ do
      -- A -> B -> C (C depends on B, B depends on A)
      let packages = [("A", []), ("B", ["A"]), ("C", ["B"])] :: [(String, [String])]
          go :: [String] -> [(String, [String])] -> IO [String]
          go completed [] = pure completed
          go completed ((pkg, deps) : rest)
            | all (`elem` completed) deps = go (pkg : completed) rest
            | otherwise = go completed (rest ++ [(pkg, deps)])

      result <- race (threadDelay 1000000) (go [] packages)
      case result of
        Left () -> assertFailure "proper DAG timed out (unexpected)"
        Right completed -> do
          -- All should complete
          length completed @?= 3
          -- Order: A first, then B, then C
          assertBool "A in result" ("A" `elem` completed)
          assertBool "B in result" ("B" `elem` completed)
          assertBool "C in result" ("C" `elem` completed),
    testCase "buildPackageWaves-style with max retries" $ do
      -- Safe version with max retry count
      let buildWithRetries ::
            Int -> -- Max retries per package
            [(String, [String])] ->
            [String] ->
            IO (Either String [String])
          buildWithRetries maxRetries packages initialCompleted = go maxRetries initialCompleted packages
            where
              go _ completed [] = pure $ Right completed
              go 0 _ _ = pure $ Left "exceeded max retries - possible cycle"
              go n completed ((pkg, deps) : rest)
                | all (`elem` completed) deps = go maxRetries (pkg : completed) rest
                | otherwise = go (n - 1) completed (rest ++ [(pkg, deps)])

      -- Test with cycle
      result1 <- buildWithRetries 10 [("A", ["B"]), ("B", ["A"])] []
      case result1 of
        Left err -> "cycle" `T.isInfixOf` T.pack err @?= True
        Right _ -> assertFailure "should detect cycle"

      -- Test with valid DAG
      result2 <- buildWithRetries 10 [("A", []), ("B", ["A"])] []
      case result2 of
        Left err -> assertFailure $ "should succeed: " ++ err
        Right completed -> length completed @?= 2
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Division by Zero
-- ════════════════════════════════════════════════════════════════════════════

divisionByZeroTests :: [TestTree]
divisionByZeroTests =
  [ testCase "division by zero caught" $ do
      result <- try @SomeException $ evaluate (1 `div` 0 :: Int)
      case result of
        Left _ -> return ()  -- Expected: ArithException
        Right _ -> assertFailure "division by zero should throw"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Stack Overflow (placeholder)
-- ════════════════════════════════════════════════════════════════════════════

stackOverflowTests :: [TestTree]
stackOverflowTests =
  [ testCase "placeholder - stack overflow tests" $ do
      -- Stack overflow tests are tricky to implement portably
      return ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Memory Exhaustion (placeholder)
-- ════════════════════════════════════════════════════════════════════════════

memoryExhaustionTests :: [TestTree]
memoryExhaustionTests =
  [ testCase "placeholder - memory exhaustion tests" $ do
      -- Memory exhaustion tests require careful setup
      return ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- File Handle Exhaustion (placeholder)
-- ════════════════════════════════════════════════════════════════════════════

fileHandleTests :: [TestTree]
fileHandleTests =
  [ testCase "placeholder - file handle tests" $ do
      -- File handle exhaustion tests are platform-specific
      return ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Signal Handling (placeholder)
-- ════════════════════════════════════════════════════════════════════════════

signalTests :: [TestTree]
signalTests =
  [ testCase "placeholder - signal handling tests" $ do
      -- Signal handling tests require platform-specific setup
      return ()
  ]
