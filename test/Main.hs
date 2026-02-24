{-# LANGUAGE OverloadedStrings #-}

-- | Main test runner for sensenet
--
-- Norman Stansfield tactics: comprehensive testing with NO SURVIVORS
--
-- Test categories:
-- - Unit tests (Build, DICE, TUI)
-- - Integration tests (CLI, end-to-end)
-- - Adversarial tests (edge cases, known bugs)
-- - Crasher tests (partial functions, infinite loops)
-- - Psychotic tests (stress, chaos, concurrency torture)
module Main (main) where

import Test.SenseNet.Adversarial qualified as Adversarial
import Test.SenseNet.Build qualified as Build
import Test.SenseNet.Crashers qualified as Crashers
import Test.SenseNet.DICE qualified as DICE
import Test.SenseNet.Integration qualified as Integration
import Test.SenseNet.Psychotic qualified as Psychotic
import Test.SenseNet.Savage qualified as Savage
import Test.SenseNet.TUI qualified as TUI
import Test.Tasty

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "sensenet"
    [ -- Core unit tests
      testGroup
        "Unit"
        [ DICE.tests,
          Build.tests,
          TUI.tests
        ],
      -- End-to-end integration tests
      testGroup
        "Integration"
        [ Integration.tests
        ],
      -- Adversarial: edge cases and known bugs
      testGroup
        "Adversarial"
        [ Adversarial.tests,
          Crashers.tests
        ],
      -- PSYCHOTIC: stress, chaos, concurrency torture
      testGroup
        "PSYCHOTIC (stress)"
        [ Psychotic.tests
        ],
      -- SAVAGE: mutation testing, invariant hunting, contracts
      testGroup
        "SAVAGE (contracts)"
        [ Savage.tests
        ]
    ]
