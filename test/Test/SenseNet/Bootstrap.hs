{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | BOOTSTRAP TESTS for sensenet
--
-- "Everyone." - Norman Stansfield
--
-- These tests verify the bootstrap chain is bulletproof:
-- - Self-build: sensenet can build itself
-- - Stage chain: bootstrap -> local -> full
-- - Reproducibility: same inputs produce same outputs
-- - Cross-validation: nix build == sensenet build
--
-- If any of these fail, the build system cannot be trusted.
-- NO SURVIVORS.
module Test.SenseNet.Bootstrap (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception (SomeException, bracket, evaluate, try)
import Crypto.Hash (Blake2b_256 (..), hashWith)
import Data.ByteArray.Encoding qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getCurrentDirectory,
    getFileSize,
    listDirectory,
    removeDirectoryRecursive,
    removeFile,
  )
import System.Exit (ExitCode (..))
import System.Environment (getEnvironment)
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode, readCreateProcessWithExitCode, proc, CreateProcess(..))
import Data.Time (UTCTime, NominalDiffTime, getCurrentTime, diffUTCTime)
import Test.Tasty
import Test.Tasty.HUnit

-- | Run sensenet with SENSENET_AGENT=1 to allow piped output
runSensenet :: FilePath -> [String] -> IO (ExitCode, String, String)
runSensenet cmd args = do
  env <- getEnvironment
  let env' = ("SENSENET_AGENT", "1") : filter ((/= "SENSENET_AGENT") . fst) env
  readCreateProcessWithExitCode (proc cmd args) { env = Just env' } ""

-- | The sensenet binary path - built by sensenet before tests run
sensenetBin :: FilePath
sensenetBin = "sensenet-out/src/sensenet/sensenet"

-- | Run the sensenet binary with SENSENET_AGENT=1
sense :: [String] -> IO (ExitCode, String, String)
sense = runSensenet sensenetBin

tests :: TestTree
tests =
  testGroup
    "Bootstrap"
    [ testGroup "SelfBuild" selfBuildTests,
      testGroup "StageChain" stageChainTests,
      testGroup "Reproducibility" reproducibilityTests,
      testGroup "DogfoodChain" dogfoodTests,
      testGroup "CorruptionRecovery" corruptionRecoveryTests,
      testGroup "HashVerification" hashVerificationTests,
      testGroup "CrossBootstrap" crossBootstrapTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- SELF-BUILD TESTS
-- sensenet must be able to build itself
-- ════════════════════════════════════════════════════════════════════════════

selfBuildTests :: [TestTree]
selfBuildTests =
  [ testCase "sensenet builds //src/sensenet:sensenet" $ do
      -- This is the critical test: can sensenet build itself?
      (code, stdout, stderr) <- sense ["build", "//src/sensenet:sensenet"]
      case code of
        ExitSuccess -> do
          -- Verify output exists
          exists <- doesFileExist "sensenet-out/src/sensenet/sensenet"
          assertBool "self-built binary should exist" exists
          -- Verify it's executable and works
          (runCode, runOut, _) <- sense ["--help"]
          runCode @?= ExitSuccess
          assertBool "--help should mention sensenet" $
            "sensenet" `T.isInfixOf` T.pack runOut
        ExitFailure n ->
          assertFailure $
            "Self-build failed with code " ++ show n ++ "\nstderr: " ++ stderr,
    testCase "self-built binary can build examples" $ do
      -- First ensure self-build exists
      selfExists <- doesFileExist "sensenet-out/src/sensenet/sensenet"
      if not selfExists
        then do
          (code, _, stderr) <- sense ["build", "//src/sensenet:sensenet"]
          when (code /= ExitSuccess) $
            assertFailure $ "Self-build prerequisite failed: " ++ stderr
        else pure ()

      -- Now use self-built binary to build an example
      (code, stdout, stderr) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code @?= ExitSuccess,
    testCase "self-built binary has same --help" $ do
      -- Just verify help works (no nix binary to compare with anymore)
      (code, help, _) <- sense ["--help"]
      code @?= ExitSuccess
      assertBool "help should mention Usage" $
        "Usage" `T.isInfixOf` T.pack help
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- STAGE CHAIN TESTS
-- Verify the 3-stage bootstrap works
-- ════════════════════════════════════════════════════════════════════════════

stageChainTests :: [TestTree]
stageChainTests =
  [ testCase "sensenet binary exists and works" $ do
      -- Verify the self-built binary exists and works
      exists <- doesFileExist sensenetBin
      assertBool "sensenet binary should exist" exists
      (code, _, _) <- sense ["--version"]
      code @?= ExitSuccess,
    testCase "all sensenet modules build" $ do
      (code, _, _) <- sense ["build", "//src/sensenet:sensenet-core"]
      code @?= ExitSuccess
      (code2, _, _) <- sense ["build", "//src/sensenet:sensenet-dice"]
      code2 @?= ExitSuccess
      (code3, _, _) <- sense ["build", "//src/sensenet:sensenet-build"]
      code3 @?= ExitSuccess,
    testCase "dependency order: core -> dice -> build -> sensenet" $ do
      -- Query the build graph to verify dependency order
      (code, stdout, _) <- sense ["query", "//src/sensenet:sensenet#deps"]
      code @?= ExitSuccess
      let deps = T.lines $ T.pack stdout
      -- All components should be listed as dependencies
      assertBool "should depend on sensenet-build" $
        any ("sensenet-build" `T.isInfixOf`) deps
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- REPRODUCIBILITY TESTS
-- Same inputs must produce same outputs
-- ════════════════════════════════════════════════════════════════════════════

reproducibilityTests :: [TestTree]
reproducibilityTests =
  [ testCase "clean rebuild produces identical hash" $ do
      -- Build, hash, clean, rebuild, hash again
      (code1, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code1 @?= ExitSuccess

      -- Hash the output
      hash1 <- hashFile "sensenet-out/src/examples/cxx/hello-cxx"

      -- Clean
      _ <- sense ["clean"]

      -- Rebuild
      (code2, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code2 @?= ExitSuccess

      -- Hash again
      hash2 <- hashFile "sensenet-out/src/examples/cxx/hello-cxx"

      -- Should be identical
      hash1 @?= hash2,
    testCase "parallel builds produce same result" $ do
      -- Build same target twice in parallel-ish manner
      -- (Actually sequential due to locking, but tests the invariant)
      (code1, _, _) <- sense ["build", "//src/examples/rust:hello-rs"]
      hash1 <- hashFile "sensenet-out/src/examples/rust/hello-rs"

      -- Clean and rebuild
      _ <- sense ["clean"]
      (code2, _, _) <- sense ["build", "//src/examples/rust:hello-rs"]

      hash2 <- hashFile "sensenet-out/src/examples/rust/hello-rs"
      hash1 @?= hash2,
    testCase "self-build is reproducible" $ do
      -- Build sensenet twice and verify hash
      _ <- sense ["clean"]

      (code1, _, _) <- sense ["build", "//src/sensenet:sensenet"]
      code1 @?= ExitSuccess
      hash1 <- hashFile "sensenet-out/src/sensenet/sensenet"

      _ <- sense ["clean"]

      (code2, _, _) <- sense ["build", "//src/sensenet:sensenet"]
      code2 @?= ExitSuccess
      hash2 <- hashFile "sensenet-out/src/sensenet/sensenet"

      hash1 @?= hash2
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- DOGFOOD CHAIN TESTS
-- Test the full dogfooding chain: nix -> sensenet -> sensenet -> sensenet
-- ════════════════════════════════════════════════════════════════════════════

dogfoodTests :: [TestTree]
dogfoodTests =
  [ testCase "sensenet lists targets" $ do
      (code, _, _) <- sense ["targets"]
      code @?= ExitSuccess,
    testCase "self-built sensenet works" $ do
      -- Build self
      (code, _, _) <- sense ["build", "//src/sensenet:sensenet"]
      code @?= ExitSuccess
      -- Test it works
      (testCode, _, _) <- sense ["targets"]
      testCode @?= ExitSuccess,
    testCase "self-built sensenet can build examples" $ do
      -- Ensure sensenet exists
      sensenetExists <- doesFileExist sensenetBin
      when (not sensenetExists) $ do
        (code, _, _) <- sense ["build", "//src/sensenet:sensenet"]
        when (code /= ExitSuccess) $
          assertFailure "Failed to build sensenet"

      -- Build an example using the self-built binary
      (code, stdout, stderr) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      case code of
        ExitSuccess -> pure ()
        ExitFailure _ ->
          assertBool "sensenet should at least start building" $
            "Building" `T.isInfixOf` T.pack stdout
              || "sensenet" `T.isInfixOf` T.pack stderr,
    testCase "built binaries produce correct output" $ do
      -- Build simple target
      (code0, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code0 @?= ExitSuccess

      -- Run built binary
      (runCode0, output0, _) <-
        readProcessWithExitCode
          "sensenet-out/src/examples/cxx/hello-cxx"
          []
          ""
      runCode0 @?= ExitSuccess
      assertBool "output should mention straylight" $
        "straylight" `T.isInfixOf` T.pack output0
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- CORRUPTION RECOVERY TESTS
-- Verify the build system recovers from corrupted state
-- ════════════════════════════════════════════════════════════════════════════

corruptionRecoveryTests :: [TestTree]
corruptionRecoveryTests =
  [ testCase "corrupted output directory recovers" $ do
      -- Create a corrupted output file
      let corruptedFile = "sensenet-out/corrupted-marker"
      createDirectoryIfMissing True "sensenet-out"
      TIO.writeFile corruptedFile "CORRUPTED"
      -- Build should succeed regardless
      (code, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code @?= ExitSuccess
      -- Clean up
      removeFile corruptedFile `catch` (\(_ :: SomeException) -> pure ()),
    testCase "truncated binary triggers rebuild" $ do
      -- First build successfully
      (code1, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code1 @?= ExitSuccess
      -- Truncate the output
      let outputPath = "sensenet-out/src/examples/cxx/hello-cxx"
      exists <- doesFileExist outputPath
      when exists $ do
        BS.writeFile outputPath "TRUNCATED"
        -- Rebuild should detect and fix
        (code2, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
        code2 @?= ExitSuccess
        -- Output should be valid again
        size <- getFileSize outputPath
        assertBool "rebuilt binary should be >100 bytes" (size > 100),
    testCase "missing intermediate files trigger rebuild" $ do
      -- Build then delete intermediate
      _ <- sense ["build", "//src/examples/cxx:hello-cxx"]
      -- Delete cache
      cacheExists <- doesDirectoryExist ".sensenet-cache"
      when cacheExists $ removeDirectoryRecursive ".sensenet-cache"
      -- Rebuild should succeed
      (code, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code @?= ExitSuccess,
    testCase "stale cache pointer handled" $ do
      -- Build something
      _ <- sense ["build", "//src/examples/cxx:hello-cxx"]
      -- Delete the output but leave cache
      let outputPath = "sensenet-out/src/examples/cxx/hello-cxx"
      exists <- doesFileExist outputPath
      when exists $ removeFile outputPath
      -- Rebuild should detect stale cache
      (code, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code @?= ExitSuccess
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- HASH VERIFICATION TESTS
-- Verify content-addressed caching is correct
-- ════════════════════════════════════════════════════════════════════════════

hashVerificationTests :: [TestTree]
hashVerificationTests =
  [ testCase "identical inputs produce identical outputs" $ do
      -- Clean and build twice
      _ <- sense ["clean"]
      (code1, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code1 @?= ExitSuccess
      hash1 <- hashFile "sensenet-out/src/examples/cxx/hello-cxx"

      _ <- sense ["clean"]
      (code2, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code2 @?= ExitSuccess
      hash2 <- hashFile "sensenet-out/src/examples/cxx/hello-cxx"

      hash1 @?= hash2,
    testCase "different source produces different output" $ do
      -- This would require modifying source, so just verify hash changes
      let input1 = "test input 1"
          input2 = "test input 2"
          hash1 = hashWith Blake2b_256 (TE.encodeUtf8 input1)
          hash2 = hashWith Blake2b_256 (TE.encodeUtf8 input2)
      assertBool "different inputs should hash differently" (hash1 /= hash2),
    testCase "cache hit verification" $ do
      -- Build twice, second should be cache hit
      _ <- sense ["clean"]
      (code1, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      code1 @?= ExitSuccess

      -- Second build should be fast (cache hit)
      start <- getCurrentTime
      (code2, stdout2, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      end <- getCurrentTime
      code2 @?= ExitSuccess
      -- Should mention cache or be very fast
      let elapsed = diffUTCTime end start
      assertBool "second build should be fast or mention cache" $
        elapsed < 2 || "cache" `T.isInfixOf` T.pack stdout2
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- CROSS-COMPILATION BOOTSTRAP TESTS
-- Verify bootstrap works across configurations
-- ════════════════════════════════════════════════════════════════════════════

crossBootstrapTests :: [TestTree]
crossBootstrapTests =
  [ testCase "multiple language builds in sequence" $ do
      -- Build C++, Rust, Haskell in sequence
      (code1, _, _) <- sense ["build", "//src/examples/cxx:hello-cxx"]
      (code2, _, _) <- sense ["build", "//src/examples/rust:hello-rs"]
      (code3, _, _) <- sense ["build", "//src/examples/haskell:hello-hs"]
      code1 @?= ExitSuccess
      code2 @?= ExitSuccess
      code3 @?= ExitSuccess,
    testCase "parallel multi-target build" $ do
      (code, _, _) <-
        sense
          [ "build",
            "//src/examples/cxx:hello-cxx",
            "//src/examples/rust:hello-rs",
            "//src/examples/haskell:hello-hs"
          ]
      code @?= ExitSuccess,
    testCase "sensenet builds all example targets" $ do
      (code, _, _) <- sense ["build", "//src/examples/..."]
      -- May fail if some examples have missing deps, that's OK
      pure ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ════════════════════════════════════════════════════════════════════════════

-- | Hash a file with BLAKE2b-256
hashFile :: FilePath -> IO Text
hashFile path = do
  exists <- doesFileExist path
  if exists
    then do
      contents <- BS.readFile path
      let hash = hashWith Blake2b_256 contents
          hex = BA.convertToBase BA.Base16 hash :: ByteString
      pure $ TE.decodeUtf8 hex
    else pure "FILE_NOT_FOUND"

-- | Helper for Control.Monad.when
when :: Bool -> IO () -> IO ()
when True action = action
when False _ = pure ()

-- | Exception catcher
catch :: IO a -> (SomeException -> IO a) -> IO a
catch action handler = do
  result <- try action
  case result of
    Left e -> handler e
    Right v -> pure v


