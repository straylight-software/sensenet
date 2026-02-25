{-# LANGUAGE OverloadedStrings #-}

-- | Main test runner for sensenet
--
-- "Everyone." - Norman Stansfield
--
-- Norman Stansfield tactics: comprehensive testing with NO SURVIVORS
--
-- Test categories:
-- - Unit tests (Build, DICE, TUI)
-- - Integration tests (CLI, end-to-end, Dhall/Nix)
-- - Adversarial tests (edge cases, known bugs)
-- - Crasher tests (partial functions, infinite loops, division by zero)
-- - Psychotic tests (stress, chaos, concurrency torture)
-- - Bootstrap tests (self-build, reproducibility, corruption recovery)
-- - Filesystem tests (TOCTOU, symlinks, permissions, race conditions)
-- - Dhall torture tests (malicious inputs, resource exhaustion, injection)
module Main (main) where

import Test.SenseNet.Adversarial qualified as Adversarial
import Test.SenseNet.Bootstrap qualified as Bootstrap
import Test.SenseNet.Build qualified as Build
import Test.SenseNet.Crashers qualified as Crashers
import Test.SenseNet.DICE qualified as DICE
import Test.SenseNet.DhallNixIntegration qualified as DhallNix
import Test.SenseNet.DhallTorture qualified as DhallTorture
import Test.SenseNet.Filesystem qualified as Filesystem
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
    [ -- Unit tests
      testGroup "Unit" [DICE.tests, Build.tests, TUI.tests],
      -- Integration tests
      testGroup "Integration" [Integration.tests, DhallNix.tests],
      -- Adversarial tests
      testGroup "Adversarial" [Adversarial.tests, Crashers.tests, DhallTorture.tests],
      -- Bootstrap tests
      testGroup "Bootstrap" [Bootstrap.tests],
      -- Filesystem tests
      testGroup "Filesystem" [Filesystem.tests],
      -- Psychotic tests
      testGroup "PSYCHOTIC" [Psychotic.tests],
      -- Savage tests
      testGroup "SAVAGE" [Savage.tests]
    ]
