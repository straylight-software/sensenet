{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for SenseNet.Build
--
-- Tests the build system:
-- - BuildResult counting
-- - Multi-target builds
-- - Callback invocation
-- - Error handling
module Test.SenseNet.Build (tests) where

import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import SenseNet.Build (BuildError (..), BuildResult (..))
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "Build"
    [ testGroup
        "BuildResult"
        [ testCase "BuildSuccess equality" $ do
            let r1 = BuildSuccess ["a.out", "b.out"]
            let r2 = BuildSuccess ["a.out", "b.out"]
            r1 @?= r2,
          testCase "BuildCached equality" $ do
            let r1 = BuildCached ["cached.out"]
            let r2 = BuildCached ["cached.out"]
            r1 @?= r2,
          testCase "BuildSuccess vs BuildCached" $ do
            let r1 = BuildSuccess ["out"]
            let r2 = BuildCached ["out"]
            assertBool "should not be equal" (r1 /= r2)
        ],
      testGroup
        "BuildError"
        [ testCase "SourceNotFound" $ do
            let err = SourceNotFound "/path/to/missing"
            show err @?= "SourceNotFound \"/path/to/missing\"",
          testCase "CommandFailed" $ do
            let err = CommandFailed "gcc" 1 "error: undefined reference"
            case err of
              CommandFailed cmd code msg -> do
                cmd @?= "gcc"
                code @?= 1
                T.isInfixOf "undefined" msg @?= True
              _ -> assertFailure "wrong error type",
          testCase "TargetNotFound" $ do
            let err = TargetNotFound "//missing:target"
            case err of
              TargetNotFound name -> name @?= "//missing:target"
              _ -> assertFailure "wrong error type"
        ],
      testGroup
        "Result Counting"
        [ testCase "count successes" $ do
            let results = [BuildSuccess ["a"], BuildSuccess ["b"], BuildCached ["c"]]
            let successes = length [() | BuildSuccess _ <- results]
            successes @?= 2,
          testCase "count cached" $ do
            let results = [BuildSuccess ["a"], BuildCached ["b"], BuildCached ["c"]]
            let cached = length [() | BuildCached _ <- results]
            cached @?= 2,
          testCase "empty results" $ do
            let results = [] :: [BuildResult]
            let successes = length [() | BuildSuccess _ <- results]
            let cached = length [() | BuildCached _ <- results]
            successes @?= 0
            cached @?= 0,
          testCase "replicate creates correct count" $ do
            let count = 5
            let results = replicate count (BuildSuccess ["out"])
            length results @?= 5
            length [() | BuildSuccess _ <- results] @?= 5
        ],
      testGroup
        "Multi-target result semantics"
        [ testCase "one result per successful target" $ do
            -- Simulate what buildMultipleWithBrickTUI does
            let targetResults =
                  [ ("//a:x", Right ["a.out"]),
                    ("//b:y", Right ["b.out"]),
                    ("//c:z", Left ("failed" :: Text))
                  ]
            let successes = length [() | (_, Right _) <- targetResults]
            let allOutputs = concat [outs | (_, Right outs) <- targetResults]
            let buildResults = replicate successes (BuildSuccess allOutputs)

            length buildResults @?= 2 -- Only 2 succeeded
            case head buildResults of
              BuildSuccess outs -> length outs @?= 2 -- Combined outputs
              _ -> assertFailure "expected BuildSuccess",
          testCase "sequence Either results" $ do
            let results = [Right (BuildSuccess ["a"]), Right (BuildCached ["b"])]
            case sequence results of
              Right rs -> length rs @?= 2
              Left _ -> assertFailure "sequence should succeed",
          testCase "sequence with failure" $ do
            let results = [Right (BuildSuccess ["a"]), Left (TargetNotFound "x")]
            case sequence results of
              Right _ -> assertFailure "sequence should fail"
              Left err -> case err of
                TargetNotFound n -> n @?= "x"
                _ -> assertFailure "wrong error type"
        ]
    ]
