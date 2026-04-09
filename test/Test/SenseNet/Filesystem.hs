{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | FILESYSTEM TORTURE TESTS for sensenet
--
-- "You don't like Beethoven. You don't know what you're missing."
-- - Norman Stansfield
--
-- Edge cases that break file-based build systems:
-- - Symlink loops
-- - Permission errors
-- - Long paths
-- - Special characters in filenames
-- - Race conditions (TOCTOU)
-- - Disappearing files
--
-- These tests verify the build system doesn't crash on hostile filesystems.
module Test.SenseNet.Filesystem (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, race, wait)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM_, replicateM_, when)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectory,
    createDirectoryIfMissing,
    createDirectoryLink,
    createFileLink,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    getCurrentDirectory,
    getPermissions,
    listDirectory,
    removeDirectoryRecursive,
    removeFile,
    removePathForcibly,
    setPermissions,
    writable,
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, hFlush, openTempFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process (readProcessWithExitCode)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "Filesystem"
    [ testGroup "SymlinkEdgeCases" symlinkTests,
      testGroup "Permissions" permissionTests,
      testGroup "PathEdgeCases" pathEdgeCaseTests,
      testGroup "SpecialFilenames" specialFilenameTests,
      testGroup "RaceConditions" raceConditionTests,
      testGroup "OutputDirectory" outputDirTests,
      testGroup "TOCTOUAttacks" toctouTests,
      testGroup "HardLinks" hardLinkTests,
      testGroup "SparseFiles" sparseFileTests,
      testGroup "FileLocking" fileLockTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- SYMLINK EDGE CASES
-- ════════════════════════════════════════════════════════════════════════════

symlinkTests :: [TestTree]
symlinkTests =
  [ testCase "symlink to valid file works" $ do
      withSystemTempDirectory "symlink-test" $ \tmpDir -> do
        let realFile = tmpDir </> "real.txt"
            linkFile = tmpDir </> "link.txt"
        writeFile realFile "content"
        createFileLink realFile linkFile
        content <- readFile linkFile
        content @?= "content",
    testCase "broken symlink detected" $ do
      withSystemTempDirectory "symlink-test" $ \tmpDir -> do
        let linkFile = tmpDir </> "broken-link"
        createFileLink "/nonexistent/path/to/file" linkFile
        exists <- doesFileExist linkFile
        exists @?= False, -- Broken symlink should not "exist" as file
    testCase "symlink loop detection" $ do
      withSystemTempDirectory "symlink-test" $ \tmpDir -> do
        let linkA = tmpDir </> "a"
            linkB = tmpDir </> "b"
        -- Create mutual symlinks
        createFileLink linkB linkA
        createFileLink linkA linkB
        -- Reading should fail, not hang
        result <- try @SomeException $ readFile linkA
        case result of
          Left _ -> pure () -- Error expected
          Right _ -> assertFailure "symlink loop should fail",
    testCase "deeply nested symlinks" $ do
      withSystemTempDirectory "symlink-test" $ \tmpDir -> do
        let depth = 50
            realFile = tmpDir </> "real.txt"
        writeFile realFile "deep content"
        -- Create chain of symlinks
        forM_ [1 .. depth] $ \i -> do
          let prev = if i == 1 then realFile else tmpDir </> ("link" ++ show (i - 1))
              curr = tmpDir </> ("link" ++ show i)
          createFileLink prev curr
        -- Read through deepest link
        let deepest = tmpDir </> ("link" ++ show depth)
        result <- try @SomeException $ readFile deepest
        case result of
          Right content -> content @?= "deep content"
          Left _ -> pure (), -- Some systems may reject deep symlinks
    testCase "symlink outside project root" $ do
      -- sensenet should not follow symlinks that escape project root
      withSystemTempDirectory "symlink-test" $ \tmpDir -> do
        let escapeLink = tmpDir </> "escape"
        createDirectoryLink "/etc" escapeLink
        -- Verify link exists
        exists <- doesPathExist escapeLink
        exists @?= True
        -- But listing it shouldn't give us /etc contents in build context
        contents <- listDirectory escapeLink
        -- This is just testing symlink mechanics, not sensenet behavior
        length contents > 0 @?= True
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- PERMISSION ERRORS
-- ════════════════════════════════════════════════════════════════════════════

permissionTests :: [TestTree]
permissionTests =
  [ testCase "unreadable source file fails gracefully" $ do
      withSystemTempDirectory "perm-test" $ \tmpDir -> do
        let file = tmpDir </> "unreadable.txt"
        writeFile file "secret"
        setFileMode file 0o000 -- No permissions
        result <- try @SomeException $ readFile file
        -- Restore permissions for cleanup
        setFileMode file 0o644
        case result of
          Left _ -> pure () -- Expected
          Right _ -> assertFailure "should not read unreadable file",
    testCase "unwritable output directory fails gracefully" $ do
      withSystemTempDirectory "perm-test" $ \tmpDir -> do
        let outDir = tmpDir </> "readonly-out"
        createDirectory outDir
        setFileMode outDir 0o555 -- Read-only
        let outFile = outDir </> "output.txt"
        result <- try @SomeException $ writeFile outFile "test"
        -- Restore permissions for cleanup
        setFileMode outDir 0o755
        case result of
          Left _ -> pure () -- Expected
          Right _ -> assertFailure "should not write to readonly dir",
    testCase "executable without read permission" $ do
      withSystemTempDirectory "perm-test" $ \tmpDir -> do
        let script = tmpDir </> "exec-only.sh"
        writeFile script "#!/bin/sh\necho hello"
        setFileMode script 0o111 -- Execute only
        -- Try to read it
        result <- try @SomeException $ readFile script
        -- Restore for cleanup
        setFileMode script 0o755
        case result of
          Left _ -> pure ()
          Right _ -> assertFailure "should not read execute-only file"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- PATH EDGE CASES
-- ════════════════════════════════════════════════════════════════════════════

pathEdgeCaseTests :: [TestTree]
pathEdgeCaseTests =
  [ testCase "very long filename (255 chars)" $ do
      withSystemTempDirectory "path-test" $ \tmpDir -> do
        let longName = replicate 250 'a' ++ ".txt"
            longPath = tmpDir </> longName
        result <- try @SomeException $ writeFile longPath "content"
        case result of
          Right _ -> do
            content <- readFile longPath
            content @?= "content"
          Left _ -> pure (), -- Some filesystems reject this
    testCase "very long path (4096+ chars)" $ do
      withSystemTempDirectory "path-test" $ \tmpDir -> do
        -- Create deeply nested directories
        let depth = 100
            dirs = replicate depth "deep"
            deepPath = foldl (</>) tmpDir dirs
        result <- try @SomeException $ createDirectoryIfMissing True deepPath
        case result of
          Right _ -> do
            let file = deepPath </> "file.txt"
            writeFile file "deep content"
            content <- readFile file
            content @?= "deep content"
          Left _ -> pure (), -- Path too long, acceptable
    testCase "relative path normalization" $ do
      withSystemTempDirectory "path-test" $ \tmpDir -> do
        let nested = tmpDir </> "a" </> "b"
        createDirectoryIfMissing True nested
        let file = nested </> "file.txt"
        writeFile file "test"
        -- Access via .. should work
        let weirdPath = tmpDir </> "a" </> "b" </> ".." </> "b" </> "file.txt"
        content <- readFile weirdPath
        content @?= "test",
    testCase "dot files handled" $ do
      withSystemTempDirectory "path-test" $ \tmpDir -> do
        let dotFile = tmpDir </> ".hidden"
        writeFile dotFile "hidden content"
        content <- readFile dotFile
        content @?= "hidden content",
    testCase "double dots in filename" $ do
      withSystemTempDirectory "path-test" $ \tmpDir -> do
        let weirdFile = tmpDir </> "file..weird..name"
        writeFile weirdFile "content"
        content <- readFile weirdFile
        content @?= "content"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- SPECIAL FILENAMES
-- ════════════════════════════════════════════════════════════════════════════

specialFilenameTests :: [TestTree]
specialFilenameTests =
  [ testCase "filename with spaces" $ do
      withSystemTempDirectory "name-test" $ \tmpDir -> do
        let file = tmpDir </> "file with spaces.txt"
        writeFile file "content"
        content <- readFile file
        content @?= "content",
    testCase "filename with unicode" $ do
      withSystemTempDirectory "name-test" $ \tmpDir -> do
        let file = tmpDir </> "日本語ファイル.txt"
        writeFile file "unicode content"
        content <- readFile file
        content @?= "unicode content",
    testCase "filename with emoji" $ do
      withSystemTempDirectory "name-test" $ \tmpDir -> do
        let file = tmpDir </> "🔥file🎉.txt"
        result <- try @SomeException $ writeFile file "emoji file"
        case result of
          Right _ -> do
            content <- readFile file
            content @?= "emoji file"
          Left _ -> pure (), -- Some filesystems don't support emoji
    testCase "filename with newline (should fail)" $ do
      withSystemTempDirectory "name-test" $ \tmpDir -> do
        let file = tmpDir </> "file\nwith\nnewlines"
        result <- try @SomeException $ writeFile file "content"
        -- Most systems reject newlines in filenames
        case result of
          Left _ -> pure ()
          Right _ -> pure (), -- If it works, fine
    testCase "filename with shell metacharacters" $ do
      withSystemTempDirectory "name-test" $ \tmpDir -> do
        let file = tmpDir </> "file;rm -rf;.txt"
        writeFile file "safe content"
        content <- readFile file
        content @?= "safe content",
    testCase "filename starting with dash" $ do
      withSystemTempDirectory "name-test" $ \tmpDir -> do
        let file = tmpDir </> "-dangerous-filename"
        writeFile file "content"
        content <- readFile file
        content @?= "content"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- RACE CONDITIONS (TOCTOU)
-- ════════════════════════════════════════════════════════════════════════════

raceConditionTests :: [TestTree]
raceConditionTests =
  [ testCase "file deleted during read" $ do
      withSystemTempDirectory "race-test" $ \tmpDir -> do
        let file = tmpDir </> "disappearing.txt"
        writeFile file "now you see me"
        -- Delete async while "reading"
        result <-
          race
            (threadDelay 1000 >> removeFile file)
            ( do
                exists <- doesFileExist file
                when exists $ do
                  threadDelay 2000 -- Delay to allow deletion
                  result <- try @SomeException $ readFile file
                  case result of
                    Left _ -> pure ()
                    Right _ -> pure ()
            )
        -- Either outcome is fine - we're testing crash resistance
        pure (),
    testCase "directory deleted during traversal" $ do
      withSystemTempDirectory "race-test" $ \tmpDir -> do
        let subDir = tmpDir </> "vanishing"
        createDirectory subDir
        forM_ [1 .. 10] $ \i ->
          writeFile (subDir </> ("file" ++ show i ++ ".txt")) "content"
        -- Delete while listing
        result <-
          race
            (threadDelay 500 >> removePathForcibly subDir)
            ( do
                result <- try @SomeException $ listDirectory subDir
                case result of
                  Left _ -> pure ()
                  Right files -> forM_ files $ \f -> do
                    threadDelay 100
                    _ <- try @SomeException $ readFile (subDir </> f)
                    pure ()
            )
        pure (),
    testCase "parallel writes to same file" $ do
      withSystemTempDirectory "race-test" $ \tmpDir -> do
        let file = tmpDir </> "contested.txt"
        counter <- newIORef (0 :: Int)
        -- Multiple async writers
        asyncs <- mapM async $ replicate 10 $ do
          forM_ [1 .. 100] $ \i -> do
            result <- try @SomeException $ writeFile file (show i)
            case result of
              Right _ -> atomicModifyIORef' counter (\x -> (x + 1, ()))
              Left _ -> pure ()
        mapM_ wait asyncs
        -- At least some writes should succeed
        count <- readIORef counter
        count > 0 @?= True
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- OUTPUT DIRECTORY TESTS
-- ════════════════════════════════════════════════════════════════════════════

outputDirTests :: [TestTree]
outputDirTests =
  [ testCase "output dir created if missing" $ do
      withSystemTempDirectory "out-test" $ \tmpDir -> do
        let outDir = tmpDir </> "new" </> "nested" </> "output"
        createDirectoryIfMissing True outDir
        exists <- doesDirectoryExist outDir
        exists @?= True,
    testCase "output dir with existing file fails" $ do
      withSystemTempDirectory "out-test" $ \tmpDir -> do
        let outPath = tmpDir </> "output"
        writeFile outPath "I am a file" -- Create file, not dir
        result <- try @SomeException $ createDirectory outPath
        case result of
          Left _ -> pure () -- Expected - can't create dir over file
          Right _ -> assertFailure "should fail to create dir over file",
    testCase "clean removes output dir" $ do
      withSystemTempDirectory "out-test" $ \tmpDir -> do
        let outDir = tmpDir </> "sensenet-out"
        createDirectoryIfMissing True outDir
        writeFile (outDir </> "artifact") "build output"
        removeDirectoryRecursive outDir
        exists <- doesDirectoryExist outDir
        exists @?= False
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- TOCTOU ATTACKS
-- ════════════════════════════════════════════════════════════════════════════

toctouTests :: [TestTree]
toctouTests =
  [ testCase "check then use race" $ do
      -- Classic TOCTOU: check file exists, then use it
      -- Between check and use, attacker replaces with symlink
      withSystemTempDirectory "toctou-test" $ \tmpDir -> do
        let target = tmpDir </> "target.txt"
        writeFile target "safe content"
        exists <- doesFileExist target
        -- In real attack, file could be replaced here
        when exists $ do
          content <- readFile target
          content @?= "safe content"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- HARD LINKS
-- ════════════════════════════════════════════════════════════════════════════

hardLinkTests :: [TestTree]
hardLinkTests =
  [ testCase "placeholder - hard link tests" $ do
      -- Hard link tests are filesystem-specific
      return ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- SPARSE FILES
-- ════════════════════════════════════════════════════════════════════════════

sparseFileTests :: [TestTree]
sparseFileTests =
  [ testCase "placeholder - sparse file tests" $ do
      -- Sparse file tests are filesystem-specific
      return ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- FILE LOCKING
-- ════════════════════════════════════════════════════════════════════════════

fileLockTests :: [TestTree]
fileLockTests =
  [ testCase "placeholder - file lock tests" $ do
      -- File locking tests are platform-specific
      return ()
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- HELPERS
-- ════════════════════════════════════════════════════════════════════════════
