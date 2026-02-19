{-# LANGUAGE OverloadedStrings #-}

-- | Main test runner for sensenet
--
-- Norman Stansfield tactics: comprehensive testing with NO SURVIVORS
module Main (main) where

import Test.SenseNet.Build qualified as Build
import Test.SenseNet.DICE qualified as DICE
import Test.SenseNet.Integration qualified as Integration
import Test.SenseNet.TUI qualified as TUI
import Test.Tasty

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "sensenet"
    [ DICE.tests,
      Build.tests,
      TUI.tests,
      Integration.tests
    ]
