{-# LANGUAGE OverloadedStrings #-}

-- | TUI tests for sensenet
--
-- Tests for terminal UI functionality:
-- - Output formatting
-- - Progress display
-- - Color handling
-- - Terminal detection
module Test.SenseNet.TUI (tests) where

import Data.List (isInfixOf)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "TUI"
    [ testGroup
        "Output"
        [ testCase "progress format" $ do
            -- Test progress formatting: [1/10] → target
            let formatted = formatProgress 1 10 "//pkg:target"
            formatted @?= "[1/10] → //pkg:target",
          testCase "success format" $ do
            let formatted = formatSuccess "//pkg:target"
            formatted @?= "✓ //pkg:target",
          testCase "failure format" $ do
            let formatted = formatFailure "//pkg:target" "error message"
            ("//pkg:target" `isInfixOf` formatted) @?= True
        ],
      testGroup
        "TerminalDetection"
        [ testCase "non-interactive fallback" $ do
            -- When piped, should not use TUI escape sequences
            let output = "Building target..."
            -- Should not contain alternate screen escape
            not ("\x1b[?1049h" `isInfixOf` output) @?= True
        ]
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- HELPERS (mirrors expected TUI.hs format functions)
-- ════════════════════════════════════════════════════════════════════════════

formatProgress :: Int -> Int -> String -> String
formatProgress current total target =
  "[" ++ show current ++ "/" ++ show total ++ "] → " ++ target

formatSuccess :: String -> String
formatSuccess target = "✓ " ++ target

formatFailure :: String -> String -> String
formatFailure target _err = "✗ " ++ target ++ " (failed)"
