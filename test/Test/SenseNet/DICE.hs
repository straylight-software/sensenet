{-# LANGUAGE OverloadedStrings #-}

-- | Tests for SenseNet.DICE
--
-- Tests the core DICE incremental computation engine:
-- - compute: single target computation
-- - computeMany: multi-target with shared transaction
-- - tryCompute: error capture without failing monad
module Test.SenseNet.DICE (tests) where

import Control.Monad (forM_)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import SenseNet.DICE
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "DICE"
    [ testGroup
        "sha256"
        [ testCase "empty string" $ do
            let hash = sha256 ""
            -- SHA256 of empty string
            hash @?= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          testCase "hello world" $ do
            let hash = sha256 "hello world"
            hash @?= "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
          testCase "deterministic" $ do
            let h1 = sha256 "test input"
            let h2 = sha256 "test input"
            h1 @?= h2,
          testCase "different inputs produce different hashes" $ do
            let h1 = sha256 "input1"
            let h2 = sha256 "input2"
            assertBool "hashes should differ" (h1 /= h2)
        ],
      testGroup
        "runDICE"
        [ testCase "basic DICE computation" $ do
            result <- runDICE $ do
              inject "test.txt" (sha256 "content") 42
              pure ("success" :: Text)
            case result of
              Right val -> val @?= "success"
              Left err -> assertFailure $ "DICE failed: " ++ show err,
          testCase "multiple injects" $ do
            result <- runDICE $ do
              inject "file1.txt" (sha256 "content1") 100
              inject "file2.txt" (sha256 "content2") 200
              inject "file3.txt" (sha256 "content3") 300
              pure (3 :: Int)
            case result of
              Right val -> val @?= 3
              Left err -> assertFailure $ "DICE failed: " ++ show err
        ],
      testGroup
        "registerTarget"
        [ testCase "register single target" $ do
            callCount <- newIORef (0 :: Int)
            result <- runDICE $ do
              registerTarget "//pkg:target" [] $ \_ _ -> do
                modifyIORef' callCount (+ 1)
                pure "{\"outputs\": [], \"exit_code\": 0}"
              compute "//pkg:target"
            -- Target callback should have been called
            count <- readIORef callCount
            count @?= 1
            case result of
              Right _ -> pure ()
              Left err -> assertFailure $ "compute failed: " ++ show err,
          testCase "register target with deps" $ do
            callOrder <- newIORef ([] :: [Text])
            result <- runDICE $ do
              -- Register dep first
              registerTarget "//pkg:dep" [] $ \name _ -> do
                modifyIORef' callOrder (++ [name])
                pure "{\"outputs\": [\"dep.out\"], \"exit_code\": 0}"
              -- Register target that depends on dep
              registerTarget "//pkg:target" ["//pkg:dep"] $ \name _ -> do
                modifyIORef' callOrder (++ [name])
                pure "{\"outputs\": [\"target.out\"], \"exit_code\": 0}"
              compute "//pkg:target"
            order <- readIORef callOrder
            -- Dep should be built before target
            order @?= ["//pkg:dep", "//pkg:target"]
            case result of
              Right _ -> pure ()
              Left err -> assertFailure $ "compute failed: " ++ show err
        ],
      testGroup
        "computeMany"
        [ testCase "computes multiple targets" $ do
            callCount <- newIORef (0 :: Int)
            result <- runDICE $ do
              forM_ ["//a:x", "//b:y", "//c:z"] $ \name ->
                registerTarget name [] $ \_ _ -> do
                  modifyIORef' callCount (+ 1)
                  pure "{\"outputs\": [\"out\"], \"exit_code\": 0}"
              computeMany ["//a:x", "//b:y", "//c:z"]
            count <- readIORef callCount
            count @?= 3
            case result of
              Right results -> do
                length results @?= 3
                -- All should succeed
                forM_ results $ \(_, r) ->
                  case r of
                    Right _ -> pure ()
                    Left err -> assertFailure $ "target failed: " ++ show err
              Left err -> assertFailure $ "computeMany failed: " ++ show err,
          testCase "shared transaction enables memoization" $ do
            -- If same dep is used by multiple targets, it should only be built once
            depCallCount <- newIORef (0 :: Int)
            result <- runDICE $ do
              -- Shared dependency
              registerTarget "//shared:dep" [] $ \_ _ -> do
                modifyIORef' depCallCount (+ 1)
                pure "{\"outputs\": [\"shared.out\"], \"exit_code\": 0}"
              -- Two targets depending on same dep
              registerTarget "//pkg:a" ["//shared:dep"] $ \_ _ ->
                pure "{\"outputs\": [\"a.out\"], \"exit_code\": 0}"
              registerTarget "//pkg:b" ["//shared:dep"] $ \_ _ ->
                pure "{\"outputs\": [\"b.out\"], \"exit_code\": 0}"
              computeMany ["//pkg:a", "//pkg:b"]
            depCount <- readIORef depCallCount
            -- Shared dep should only be built ONCE due to memoization
            depCount @?= 1
            case result of
              Right results -> length results @?= 2
              Left err -> assertFailure $ "computeMany failed: " ++ show err,
          testCase "keep-going semantics" $ do
            -- One target fails, others should still complete
            result <- runDICE $ do
              registerTarget "//pkg:success1" [] $ \_ _ ->
                pure "{\"outputs\": [\"s1.out\"], \"exit_code\": 0}"
              registerTarget "//pkg:failure" [] $ \_ _ ->
                pure "{\"outputs\": [], \"exit_code\": 1, \"error\": \"intentional failure\"}"
              registerTarget "//pkg:success2" [] $ \_ _ ->
                pure "{\"outputs\": [\"s2.out\"], \"exit_code\": 0}"
              computeMany ["//pkg:success1", "//pkg:failure", "//pkg:success2"]
            case result of
              Right results -> do
                length results @?= 3
                -- Count successes and failures
                let successes = length [() | (_, Right _) <- results]
                let failures = length [() | (_, Left _) <- results]
                successes @?= 2
                failures @?= 1
              Left err -> assertFailure $ "computeMany failed: " ++ show err
        ],
      testGroup
        "tryCompute"
        [ testCase "captures success" $ do
            result <- runDICE $ do
              registerTarget "//pkg:ok" [] $ \_ _ ->
                pure "{\"outputs\": [\"ok.out\"], \"exit_code\": 0}"
              tryCompute "//pkg:ok"
            case result of
              Right (Right _) -> pure ()
              Right (Left err) -> assertFailure $ "tryCompute returned error: " ++ show err
              Left err -> assertFailure $ "runDICE failed: " ++ show err,
          testCase "captures failure without failing monad" $ do
            result <- runDICE $ do
              registerTarget "//pkg:fail" [] $ \_ _ ->
                pure "{\"outputs\": [], \"exit_code\": 1, \"error\": \"intentional\"}"
              r1 <- tryCompute "//pkg:fail"
              -- Should be able to continue after failure
              registerTarget "//pkg:ok" [] $ \_ _ ->
                pure "{\"outputs\": [\"ok.out\"], \"exit_code\": 0}"
              r2 <- tryCompute "//pkg:ok"
              pure (r1, r2)
            case result of
              Right (r1, r2) -> do
                case r1 of
                  Left _ -> pure () -- Expected failure
                  Right _ -> assertFailure "expected r1 to fail"
                case r2 of
                  Right _ -> pure () -- Expected success
                  Left err -> assertFailure $ "r2 should succeed: " ++ show err
              Left err -> assertFailure $ "runDICE failed: " ++ show err
        ]
    ]
