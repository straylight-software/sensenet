{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Adversarial tests for sensenet
--
-- Tests targeting edge cases, known bugs, and failure modes.
-- Norman Stansfield tactics: find bugs before users do.
module Test.SenseNet.Adversarial (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception (SomeException, evaluate, try)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import SenseNet.Build (BuildError (..), BuildResult (..))
import SenseNet.DICE
import SenseNet.IR
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

tests :: TestTree
tests =
  testGroup
    "Adversarial"
    [ testGroup "DICE.topoSort" topoSortTests,
      testGroup "DICE.actionKey" actionKeyTests,
      testGroup "IR.ruleDeps" ruleDepsTests,
      testGroup "IR.ruleName" ruleNameTests,
      testGroup "BuildError" buildErrorTests,
      testGroup "EdgeCases" edgeCaseTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- DICE.topoSort - Cycle Detection and Edge Cases
-- ════════════════════════════════════════════════════════════════════════════

topoSortTests :: [TestTree]
topoSortTests =
  [ testCase "empty graph returns empty list" $ do
      let sorted = topoSort emptyGraph
      sorted @?= [],
    testCase "single action with no deps" $ do
      let action = mkAction "build" [] []
          graph = addAction action emptyGraph
          sorted = topoSort graph
      length sorted @?= 1,
    testCase "linear dependency chain" $ do
      -- A -> B -> C (C depends on B, B depends on A)
      let actionA = mkAction "A" [] []
          actionB = mkAction "B" [] [actionKey actionA]
          actionC = mkAction "C" [] [actionKey actionB]
          graph = addAction actionC $ addAction actionB $ addAction actionA emptyGraph
          sorted = topoSort graph
      -- A should come before B, B before C
      length sorted @?= 3
      let keyA = actionKey actionA
          keyB = actionKey actionB
          keyC = actionKey actionC
          posA = elemIndex' keyA sorted
          posB = elemIndex' keyB sorted
          posC = elemIndex' keyC sorted
      assertBool "A before B" (posA < posB)
      assertBool "B before C" (posB < posC),
    testCase "diamond dependency" $ do
      -- D depends on B and C, both depend on A
      --     A
      --    / \
      --   B   C
      --    \ /
      --     D
      let actionA = mkAction "A" [] []
          actionB = mkAction "B" [] [actionKey actionA]
          actionC = mkAction "C" [] [actionKey actionA]
          actionD = mkAction "D" [] [actionKey actionB, actionKey actionC]
          graph =
            addAction actionD $
              addAction actionC $
                addAction actionB $
                  addAction actionA emptyGraph
          sorted = topoSort graph
      length sorted @?= 4
      let posA = elemIndex' (actionKey actionA) sorted
          posB = elemIndex' (actionKey actionB) sorted
          posC = elemIndex' (actionKey actionC) sorted
          posD = elemIndex' (actionKey actionD) sorted
      -- A must come before B, C, D
      assertBool "A before B" (posA < posB)
      assertBool "A before C" (posA < posC)
      assertBool "B before D" (posB < posD)
      assertBool "C before D" (posC < posD),
    testCase "missing dependency reference handled gracefully" $ do
      -- Action references a dep that doesn't exist in graph
      let missingKey = ActionKey "0000000000000000000000000000000000000000000000000000000000000000"
          action = mkAction "orphan" [] [missingKey]
          graph = addAction action emptyGraph
      -- Should not crash, should still return the action
      let sorted = topoSort graph
      length sorted @?= 1,
    testCase "self-referential action" $ do
      -- An action that depends on itself (degenerate case)
      -- First create action, then modify to reference itself
      let baseAction = mkAction "self" [] []
          selfKey = actionKey baseAction
          selfAction =
            baseAction
              { aInputKeys = [selfKey]
              }
          graph = addAction selfAction emptyGraph
      -- Should terminate (not infinite loop) and return the action
      result <- race (threadDelay 1000000) (evaluate $ length $ topoSort graph)
      case result of
        Left () -> assertFailure "topoSort timed out on self-referential action"
        Right n -> n @?= 1,
    testCase "mutual dependency cycle (A <-> B)" $ do
      -- This tests cycle handling - should terminate
      let actionA = mkAction "A" [] []
          actionB = mkAction "B" [] []
          keyA = actionKey actionA
          keyB = actionKey actionB
          -- Create cyclic versions
          cyclicA = actionA {aInputKeys = [keyB]}
          cyclicB = actionB {aInputKeys = [keyA]}
          graph = addAction cyclicA $ addAction cyclicB emptyGraph
      -- Should terminate within reasonable time
      result <- race (threadDelay 1000000) (evaluate $ length $ topoSort graph)
      case result of
        Left () -> assertFailure "topoSort timed out on cyclic dependency"
        Right _ -> pure (), -- Any termination is acceptable
    testCase "large linear chain (100 actions)" $ do
      -- Stress test: chain of 100 dependencies
      let actions = buildChain 100
          graph = foldr addAction emptyGraph actions
          sorted = topoSort graph
      length sorted @?= 100,
    testCase "wide graph (100 independent actions)" $ do
      let actions = [mkAction ("action" <> show i) [] [] | i <- [1 .. 100 :: Int]]
          graph = foldr addAction emptyGraph actions
          sorted = topoSort graph
      length sorted @?= 100
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- DICE.actionKey - Hash Stability and Collision Resistance
-- ════════════════════════════════════════════════════════════════════════════

actionKeyTests :: [TestTree]
actionKeyTests =
  [ testCase "identical actions produce same key" $ do
      let a1 = mkAction "build" ["file.c"] []
          a2 = mkAction "build" ["file.c"] []
      actionKey a1 @?= actionKey a2,
    testCase "different commands produce different keys" $ do
      let a1 = mkAction "gcc" ["file.c"] []
          a2 = mkAction "clang" ["file.c"] []
      assertBool "different commands -> different keys" (actionKey a1 /= actionKey a2),
    testCase "different inputs produce different keys" $ do
      let a1 = mkAction "build" ["a.c"] []
          a2 = mkAction "build" ["b.c"] []
      assertBool "different inputs -> different keys" (actionKey a1 /= actionKey a2),
    testCase "input order matters" $ do
      let a1 = mkAction "build" ["a.c", "b.c"] []
          a2 = mkAction "build" ["b.c", "a.c"] []
      -- Order should matter for determinism
      assertBool "input order affects key" (actionKey a1 /= actionKey a2),
    testCase "empty action has valid key" $ do
      let a = mkAction "" [] []
          key = actionKey a
      -- Key should be a valid 64-char hex string (SHA256)
      T.length (actionKeyText key) @?= 64,
    testCase "unicode in command produces valid key" $ do
      let a = mkAction "echo ''" ["src.hs"] []
          key = actionKey a
      T.length (actionKeyText key) @?= 64,
    testProperty "all actions produce 64-char hex keys" $ \(cmd :: String) ->
      let a = mkAction (T.pack cmd) [] []
          keyText = actionKeyText (actionKey a)
       in T.length keyText == 64 && T.all isHexChar keyText
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- IR.ruleDeps - Known Bug: Some rules return empty deps
-- ════════════════════════════════════════════════════════════════════════════

ruleDepsTests :: [TestTree]
ruleDepsTests =
  [ testCase "CxxBinary deps extracted" $ do
      let rule =
            RCxxBinary
              CxxBinary
                { name = "test",
                  srcs = ["main.cpp"],
                  hdrs = [],
                  deps = [DepLocal ":lib", DepFlake "nixpkgs#zlib"],
                  std = Cxx17,
                  vis = Public
                }
      length (ruleDeps rule) @?= 2,
    testCase "RustBinary deps extracted" $ do
      let rule =
            RRustBinary
              RustBinary
                { name = "test",
                  srcs = ["main.rs"],
                  deps = [DepLocal ":core"],
                  edition = E2021,
                  vis = Public
                }
      length (ruleDeps rule) @?= 1,
    -- KNOWN BUG: LeanBinary has deps field but ruleDeps returns []
    testCase "LeanBinary deps returns empty (KNOWN BUG)" $ do
      let rule =
            RLeanBinary
              LeanBinary
                { name = "prover",
                  srcs = ["Main.lean"],
                  deps = [DepLocal ":mathlib"],
                  vis = Public
                }
      -- This documents the current (broken) behavior
      -- When fixed, this test should fail and be updated
      ruleDeps rule @?= [],
    -- KNOWN BUG: NvBinary has deps field but ruleDeps returns []
    testCase "NvBinary deps returns empty (KNOWN BUG)" $ do
      let rule =
            RNvBinary
              NvBinary
                { name = "kernel",
                  srcs = ["kernel.cu"],
                  deps = [DepLocal ":cuda_utils"],
                  archs = ["sm_90"],
                  vis = Public
                }
      -- Documents broken behavior
      ruleDeps rule @?= [],
    testCase "Genrule deps returns empty (by design)" $ do
      let rule =
            RGenrule
              Genrule
                { name = "codegen",
                  srcs = ["input.txt"],
                  outs = ["output.gen"],
                  cmd = "cat $SRCS > $OUT",
                  vis = Public
                }
      -- Genrule doesn't have deps field, so empty is correct
      ruleDeps rule @?= [],
    testCase "HaskellFFIBinary deps extracted" $ do
      let rule =
            RHaskellFFIBinary
              HaskellFFIBinary
                { name = "ffi-test",
                  hsSrcs = ["Main.hs"],
                  cSrcs = ["bindings.c"],
                  deps = [DepLocal ":base"],
                  ghcOptions = [],
                  vis = Public
                }
      length (ruleDeps rule) @?= 1
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- IR.ruleName - Edge Cases
-- ════════════════════════════════════════════════════════════════════════════

ruleNameTests :: [TestTree]
ruleNameTests =
  [ testCase "empty name handled" $ do
      let rule = RCxxBinary CxxBinary {name = "", srcs = [], hdrs = [], deps = [], std = Cxx17, vis = Public}
      ruleName rule @?= "",
    testCase "unicode name handled" $ do
      let rule = RCxxBinary CxxBinary {name = "", srcs = [], hdrs = [], deps = [], std = Cxx17, vis = Public}
      ruleName rule @?= "",
    testCase "name with special chars" $ do
      let rule = RCxxBinary CxxBinary {name = "test-bin_v2.0", srcs = [], hdrs = [], deps = [], std = Cxx17, vis = Public}
      ruleName rule @?= "test-bin_v2.0"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- BuildError - Show/Eq instances
-- ════════════════════════════════════════════════════════════════════════════

buildErrorTests :: [TestTree]
buildErrorTests =
  [ testCase "TargetNotFound equality" $ do
      let e1 = TargetNotFound "//a:x"
          e2 = TargetNotFound "//a:x"
      e1 @?= e2,
    testCase "TargetNotFound inequality" $ do
      let e1 = TargetNotFound "//a:x"
          e2 = TargetNotFound "//a:y"
      assertBool "different targets" (e1 /= e2),
    testCase "CommandFailed with empty error message" $ do
      let e = CommandFailed "gcc" 1 ""
      show e `seq` pure (), -- Should not crash
    testCase "CommandFailed with very long message" $ do
      let longMsg = T.replicate 10000 "error: something went wrong\n"
          e = CommandFailed "gcc" 1 longMsg
      length (show e) > 0 @?= True,
    testCase "DependencyFailed show" $ do
      let e = DependencyFailed "//pkg:target" "dep failed first"
      T.pack (show e) `T.isInfixOf` "DependencyFailed" @?= True,
    testCase "SourceNotFound with path containing spaces" $ do
      let e = SourceNotFound "/path/with spaces/file.cpp"
      show e `seq` pure (),
    testCase "PackageError with unicode" $ do
      let e = PackageError "Failed to fetch: "
      show e `seq` pure ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Edge Cases - Stress Tests and Boundary Conditions
-- ════════════════════════════════════════════════════════════════════════════

edgeCaseTests :: [TestTree]
edgeCaseTests =
  [ testCase "ActionGraph with duplicate actions" $ do
      let action = mkAction "same" ["file.c"] []
          graph = addAction action $ addAction action emptyGraph
      -- Adding same action twice should deduplicate
      length (Map.keys $ agActions graph) @?= 1,
    testCase "ActionKey conversion roundtrip" $ do
      let action = mkAction "test" ["src.hs"] []
          key = actionKey action
          keyText = actionKeyText key
      -- Key text should be valid hex
      T.all isHexChar keyText @?= True,
    testCase "emptyGraph has no roots" $ do
      agRoots emptyGraph @?= [],
    testCase "emptyGraph has no actions" $ do
      Map.null (agActions emptyGraph) @?= True,
    testCase "hashText deterministic" $ do
      let h1 = hashText "hello world"
          h2 = hashText "hello world"
      h1 @?= h2,
    testCase "hashText empty string" $ do
      let h = hashText ""
      T.length h @?= 64, -- SHA256 = 64 hex chars
    testCase "hashBytes deterministic" $ do
      let h1 = hashBytes "test"
          h2 = hashBytes "test"
      h1 @?= h2,
    testProperty "hashText produces 64-char hex" $ \(s :: String) ->
      let h = hashText (T.pack s)
       in T.length h == 64 && T.all isHexChar h,
    -- Test that action results can represent all states
    testCase "ActionResult success" $ do
      let r = ActionResult {arExitCode = 0, arOutputs = ["out.o"], arStdout = "", arStderr = ""}
      arExitCode r @?= 0,
    testCase "ActionResult failure" $ do
      let r = ActionResult {arExitCode = 1, arOutputs = [], arStdout = "", arStderr = "error"}
      arExitCode r @?= 1,
    testCase "ExecutionResult empty" $ do
      let r = ExecutionResult {erResults = Map.empty, erCacheHits = 0, erExecuted = 0, erFailed = []}
      erCacheHits r @?= 0
      erExecuted r @?= 0
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

-- | Create a test action
mkAction :: Text -> [Text] -> [ActionKey] -> Action
mkAction cmd inputs deps =
  Action
    { aName = cmd,
      aCommand = [cmd],
      aInputs = Map.fromList [(inp, hashText inp) | inp <- inputs],
      aInputKeys = deps,
      aOutputs = ["out"],
      aEnv = Map.empty,
      aCoeffects = []
    }

-- | Build a linear chain of N actions where each depends on the previous
buildChain :: Int -> [Action]
buildChain n = go n Nothing []
  where
    go 0 _ acc = acc
    go i prevKey acc =
      let action = mkAction ("action" <> T.pack (show i)) [] (maybe [] (: []) prevKey)
          key = actionKey action
       in go (i - 1) (Just key) (action : acc)

-- | Find index in list
elemIndex' :: (Eq a) => a -> [a] -> Int
elemIndex' x xs = go 0 xs
  where
    go _ [] = -1
    go i (y : ys)
      | x == y = i
      | otherwise = go (i + 1) ys

-- | Check if character is hex
isHexChar :: Char -> Bool
isHexChar c = c `elem` ("0123456789abcdef" :: String)
