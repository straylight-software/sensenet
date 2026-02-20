{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Build helper functions shared across language modules
module SenseNet.Build.Helpers
  ( -- * File operations
    copyFile,
    checkSources,

    -- * Process execution
    runProcessInDir,
    runProcessWithPath,

    -- * Language flags
    cxxStdFlag,
    rustEditionFlag,
  )
where

import Data.ByteString qualified as BS
import Data.List (intercalate)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.IO.Handle (hGetContents)
import SenseNet.IR qualified as IR
import System.Directory (doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)

-- | Copy a file
copyFile :: FilePath -> FilePath -> IO ()
copyFile src dst = BS.readFile src >>= BS.writeFile dst

-- | Run a process in a specific directory, returning exit code and stderr
runProcessInDir :: FilePath -> String -> [String] -> IO (ExitCode, String)
runProcessInDir dir prog args = do
  let p = (proc prog args) {cwd = Just dir, std_out = CreatePipe, std_err = CreatePipe}
  (_, _, Just herr, ph) <- createProcess p
  stderr <- hGetContents herr
  exitCode <- waitForProcess ph
  pure (exitCode, stderr)

-- | Run a process with modified PATH, returning exit code and stderr
runProcessWithPath :: FilePath -> [FilePath] -> String -> [String] -> IO (ExitCode, String)
runProcessWithPath dir extraPaths prog args = do
  currentEnv <- getEnvironment
  let currentPath = fromMaybe "" $ lookup "PATH" currentEnv
      newPath = intercalate ":" extraPaths <> ":" <> currentPath
      newEnv = ("PATH", newPath) : filter ((/= "PATH") . fst) currentEnv
      p = (proc prog args) {cwd = Just dir, std_out = CreatePipe, std_err = CreatePipe, env = Just newEnv}
  (_, _, Just herr, ph) <- createProcess p
  stderr <- hGetContents herr
  exitCode <- waitForProcess ph
  pure (exitCode, stderr)

-- | Check if all source files exist, return first missing
checkSources :: FilePath -> [Text] -> IO (Maybe FilePath)
checkSources srcDir = go
  where
    go [] = pure Nothing
    go (s : rest) = do
      let path = srcDir </> T.unpack s
      exists <- doesFileExist path
      if exists then go rest else pure $ Just path

-- | Convert C++ standard to compiler flag
cxxStdFlag :: IR.CxxStd -> String
cxxStdFlag = \case
  IR.Cxx11 -> "-std=c++11"
  IR.Cxx14 -> "-std=c++14"
  IR.Cxx17 -> "-std=c++17"
  IR.Cxx20 -> "-std=c++20"
  IR.Cxx23 -> "-std=c++23"

-- | Convert Rust edition to flag value
rustEditionFlag :: IR.RustEdition -> String
rustEditionFlag = \case
  IR.E2015 -> "2015"
  IR.E2018 -> "2018"
  IR.E2021 -> "2021"
  IR.E2024 -> "2024"
