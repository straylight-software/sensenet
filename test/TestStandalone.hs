{-# LANGUAGE OverloadedStrings #-}

-- | Standalone test runner
-- 
-- Runs tests that don't depend on SenseNet.* modules.
-- These are the PSYCHOTIC tests that can run without the full build.
module Main where

import Test.SenseNet.Crashers qualified as Crashers
import Test.SenseNet.Psychotic qualified as Psychotic
import Test.SenseNet.Savage qualified as Savage
import Test.Tasty

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "sensenet-standalone"
    [ Crashers.tests,
      Psychotic.tests,
      Savage.tests
    ]
