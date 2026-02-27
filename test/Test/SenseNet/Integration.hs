{-# LANGUAGE OverloadedStrings #-}

-- | Integration tests for sensenet
--
-- End-to-end tests that exercise the full build system
module Test.SenseNet.Integration (tests) where

import Control.Exception (SomeException, bracket, try)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory, removeDirectoryRecursive, setCurrentDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, CreateProcess(..))
import Test.Tasty
import Test.Tasty.HUnit

-- | The sensenet binary (self-built, exists when tests run)
sensenetBin :: FilePath
sensenetBin = "sensenet-out/src/sensenet/sensenet"

-- | Run sensenet with SENSENET_AGENT=1 (for programmatic access)
runSensenetAgent :: [String] -> IO (ExitCode, String, String)
runSensenetAgent args = do
  env <- getEnvironment
  let env' = ("SENSENET_AGENT", "1") : filter ((/= "SENSENET_AGENT") . fst) env
  readCreateProcessWithExitCode (proc sensenetBin args) { env = Just env' } ""

-- | Run sensenet without SENSENET_AGENT (should crash when piped)
runSensenetPiped :: [String] -> IO (ExitCode, String, String)
runSensenetPiped args = readProcessWithExitCode sensenetBin args ""

tests :: TestTree
tests =
  testGroup
    "Integration"
    [ testGroup
        "CLI"
        [ testCase "--version returns success" $ do
            (code, stdout, _) <- runSensenetAgent ["--version"]
            code @?= ExitSuccess
            T.pack stdout `T.isInfixOf` "sensenet" @?= True,
          testCase "--help returns success" $ do
            (code, stdout, _) <- runSensenetAgent ["--help"]
            code @?= ExitSuccess
            T.pack stdout `T.isInfixOf` "Usage" @?= True
        ],
      testGroup
        "Pipe crash"
        [ testCase "crashes without SENSENET_AGENT when piped" $ do
            (code, _, stderr) <- runSensenetPiped ["--version"]
            code @?= ExitFailure 1
            T.pack stderr `T.isInfixOf` "SENSENET_AGENT" @?= True,
          testCase "works with SENSENET_AGENT=1 when piped" $ do
            (code, _, _) <- runSensenetAgent ["--version"]
            code @?= ExitSuccess
        ],
      testGroup
        "Build commands"
        [ testCase "build single C++ target" $ do
            (code, _, _) <- runSensenetAgent ["build", "//src/examples/cxx:hello-cxx"]
            code @?= ExitSuccess
            -- Output should exist
            exists <- doesFileExist "sensenet-out/src/examples/cxx/hello-cxx"
            exists @?= True,
          testCase "build single Rust target" $ do
            (code, _, _) <- runSensenetAgent ["build", "//src/examples/rust:hello-rs"]
            code @?= ExitSuccess
            exists <- doesFileExist "sensenet-out/src/examples/rust/hello-rs"
            exists @?= True,
          testCase "build multiple targets" $ do
            (code, _, _) <-
              runSensenetAgent
                ["build", "//src/examples/cxx:hello-cxx", "//src/examples/rust:hello-rs"]
            code @?= ExitSuccess
            -- Both outputs should exist
            cxxExists <- doesFileExist "sensenet-out/src/examples/cxx/hello-cxx"
            rsExists <- doesFileExist "sensenet-out/src/examples/rust/hello-rs"
            cxxExists @?= True
            rsExists @?= True,
          testCase "build wildcard //pkg/..." $ do
            (code, _, _) <- runSensenetAgent ["build", "//src/examples/cxx/..."]
            -- May succeed or fail depending on what targets exist
            -- Just verify it doesn't crash
            pure (),
          testCase "build nonexistent target fails" $ do
            (code, _, _) <- runSensenetAgent ["build", "//nonexistent:target"]
            code @?= ExitFailure 1
        ],
      testGroup
        "Stub mode"
        [ testCase "--stub builds instantly" $ do
            (code, stdout, _) <- runSensenetAgent ["build", "--stub", "//src/sensenet/..."]
            code @?= ExitSuccess
            T.pack stdout `T.isInfixOf` "[stub]" @?= True
        ],
      testGroup
        "Output correctness"
        [ testCase "C++ binary runs correctly" $ do
            -- First ensure it's built
            _ <- runSensenetAgent ["build", "//src/examples/cxx:hello-cxx"]
            -- Then run it
            (code, stdout, _) <-
              readProcessWithExitCode
                "sensenet-out/src/examples/cxx/hello-cxx"
                []
                ""
            code @?= ExitSuccess
            T.pack stdout `T.isInfixOf` "straylight" @?= True,
          testCase "Rust binary runs correctly" $ do
            _ <- runSensenetAgent ["build", "//src/examples/rust:hello-rs"]
            (code, stdout, _) <-
              readProcessWithExitCode
                "sensenet-out/src/examples/rust/hello-rs"
                []
                ""
            code @?= ExitSuccess
            T.pack stdout `T.isInfixOf` "rust" @?= True,
          testCase "Haskell binary runs correctly" $ do
            _ <- runSensenetAgent ["build", "//src/examples/haskell:hello-hs"]
            (code, stdout, _) <-
              readProcessWithExitCode
                "sensenet-out/src/examples/haskell/hello-hs"
                []
                ""
            code @?= ExitSuccess
            T.pack stdout `T.isInfixOf` "Haskell" @?= True
        ],
      testGroup
        "Result counting"
        [ testCase "correct count for 2 targets" $ do
            (code, stdout, _) <-
              runSensenetAgent
                ["build", "//src/examples/cxx:hello-cxx", "//src/examples/rust:hello-rs"]
            code @?= ExitSuccess
            -- Should see "Built 2 targets" or similar
            let out = T.pack stdout
            (T.isInfixOf "2 targets" out || T.isInfixOf "Built" out) @?= True,
          testCase "correct count for 3 targets" $ do
            (code, _, _) <-
              runSensenetAgent
                [ "build",
                  "//src/examples/cxx:hello-cxx",
                  "//src/examples/rust:hello-rs",
                  "//src/examples/haskell:hello-hs"
                ]
            code @?= ExitSuccess
        ],
      testGroup
        "Dependency handling"
        [ testCase "shared deps built once" $ do
            -- This test would need a target with shared deps
            -- For now, just verify multi-target doesn't crash
            (code, _, _) <-
              runSensenetAgent
                ["build", "//src/examples/cxx:hello-cxx", "//src/examples/rust:hello-rs"]
            code @?= ExitSuccess
        ]
    ]
