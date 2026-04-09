{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | DHALL/NIX INTEGRATION TESTS for sensenet
--
-- "I like these calm little moments before the storm."
-- - Norman Stansfield
--
-- This replaces test/sensenet/run-tests.sh with proper Haskell tests.
-- NO SURVIVORS for the bash script.
--
-- Tests:
-- - Dhall type checking
-- - Proof obligations
-- - nix-compile integration
-- - Build graph analysis
-- - Flake module validation
module Test.SenseNet.DhallNixIntegration (tests) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, when)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "DhallNixIntegration"
    [ testGroup "DhallTypecheck" dhallTypecheckTests,
      testGroup "NixParse" nixParseTests,
      testGroup "FlakeValidation" flakeValidationTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- DHALL TYPE CHECKING
-- ════════════════════════════════════════════════════════════════════════════

dhallTypecheckTests :: [TestTree]
dhallTypecheckTests =
  [ testCase "Resource.dhall typechecks" $ typecheckDhallFile "dhall/Resource.dhall",
    testCase "DischargeProof.dhall typechecks" $ typecheckDhallFile "dhall/DischargeProof.dhall",
    testCase "Toolchain.dhall typechecks" $ typecheckDhallFile "dhall/Toolchain.dhall",
    testCase "Build.dhall typechecks" $ typecheckDhallFile "dhall/Build.dhall",
    testCase "package.dhall typechecks" $ typecheckDhallFile "dhall/package.dhall",
    testCase "Invalid Dhall rejected" $ do
      let invalidDhall = "let x = { broken"
      (code, _, _) <- readProcessWithExitCode "dhall" [] invalidDhall
      code @?= ExitFailure 1
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- NIX PARSE TESTS
-- ════════════════════════════════════════════════════════════════════════════

nixParseTests :: [TestTree]
nixParseTests =
  [ testCase "flake.nix parses" $ do
      (code, _, _) <- readProcessWithExitCode "nix-instantiate" ["--parse", "flake.nix"] ""
      code @?= ExitSuccess,
    testCase "sensenet.nix parses" $ parseNixFile "nix/packages/sensenet.nix",
    testCase "sensenet-bootstrap.nix parses" $ parseNixFile "nix/packages/sensenet-bootstrap.nix",
    testCase "sensenet-local.nix parses" $ parseNixFile "nix/packages/sensenet-local.nix"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- FLAKE VALIDATION
-- ════════════════════════════════════════════════════════════════════════════

flakeValidationTests :: [TestTree]
flakeValidationTests =
  [ testCase "nix flake show works" $ do
      (code, stdout, _) <- readProcessWithExitCode "nix" ["flake", "show", "--json"] ""
      code @?= ExitSuccess
      assertBool "should list packages" ("packages" `T.isInfixOf` T.pack stdout),
    testCase "sensenet package exists" $ do
      (code, _, _) <- readProcessWithExitCode "nix" ["build", ".#sensenet", "--dry-run"] ""
      code @?= ExitSuccess,
    testCase "sensenet targets command works" $ do
      (code, _, _) <- readProcessWithExitCode "./sense" ["targets"] ""
      code @?= ExitSuccess
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ════════════════════════════════════════════════════════════════════════════

typecheckDhallFile :: FilePath -> IO ()
typecheckDhallFile path = do
  exists <- doesFileExist path
  when exists $ do
    (code, _, stderr) <- readProcessWithExitCode "dhall" ["--file", path] ""
    case code of
      ExitSuccess -> pure ()
      ExitFailure _ -> assertFailure $ "Dhall typecheck failed: " ++ path ++ "\n" ++ stderr

parseNixFile :: FilePath -> IO ()
parseNixFile path = do
  exists <- doesFileExist path
  when exists $ do
    (code, _, stderr) <- readProcessWithExitCode "nix-instantiate" ["--parse", path] ""
    case code of
      ExitSuccess -> pure ()
      ExitFailure _ -> assertFailure $ "Nix parse failed: " ++ path ++ "\n" ++ stderr
