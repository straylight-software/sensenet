{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SenseNet.Nix
-- Description : Nix flake resolution for NixCxxBinary rules
--
-- Resolves nix flake references to compiler/linker flags.
-- Used by Build.hs to support NixCxxBinary rules without
-- requiring an external nix-analyze binary.
module SenseNet.Nix
  ( -- * Main API
    resolveNixDeps,
  )
where

import Control.Exception (SomeException, try)
import Data.List (isSuffixOf)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode, readProcessWithExitCode)

-- | Resolve multiple nix flake refs to compiler/linker flags
-- Returns list of flags like: ["-isystem", "/nix/store/.../include", "-L/nix/store/.../lib", "-lz"]
resolveNixDeps :: [Text] -> IO (Either Text [String])
resolveNixDeps refs = do
  results <- mapM resolveOnePackage refs
  let errors = [e | Left e <- results]
      flags = concat [fs | Right fs <- results]
  case errors of
    (e : _) -> pure $ Left e
    [] -> pure $ Right flags

-- | Resolve a single package to its flags using pkg-config
resolveOnePackage :: Text -> IO (Either Text [String])
resolveOnePackage ref = do
  -- Get output path (try .out first for packages with multiple outputs)
  outResult <- resolveOutput ref "out"
  case outResult of
    Left err -> pure $ Left err
    Right outPath -> do
      devResult <- resolveOutput ref "dev"
      let devPath = case devResult of
            Right p -> p
            Left _ -> outPath -- Fall back to out if no dev output
      let includePath = T.unpack devPath <> "/include"
          libPath = T.unpack outPath <> "/lib"
          pkgConfigPath = T.unpack devPath <> "/lib/pkgconfig:" <> T.unpack outPath <> "/lib/pkgconfig"

      -- Try pkg-config first, fall back to package name
      pkgConfigFlags <- queryPkgConfig pkgConfigPath ref

      -- Build flag list
      pure $
        Right $
          [ "-isystem",
            includePath,
            "-L" <> libPath,
            "-Wl,-rpath," <> libPath
          ]
            ++ pkgConfigFlags

-- | Resolve a specific output of a flake ref
resolveOutput :: Text -> Text -> IO (Either Text Text)
resolveOutput ref output = do
  -- Try ref.output first, fall back to ref
  let refWithOutput = ref <> "." <> output
  result <-
    try @SomeException $
      readProcessWithExitCode
        "nix"
        ["build", T.unpack refWithOutput, "--print-out-paths", "--no-link"]
        ""
  case result of
    Left err -> pure $ Left $ "nix build failed: " <> T.pack (show err)
    Right (ExitSuccess, stdout, _) -> pure $ Right $ T.strip $ T.pack stdout
    Right (ExitFailure _, _, _) -> do
      -- Fall back to base ref
      result' <-
        try @SomeException $
          readProcessWithExitCode
            "nix"
            ["build", T.unpack ref, "--print-out-paths", "--no-link"]
            ""
      case result' of
        Left err -> pure $ Left $ "nix build failed: " <> T.pack (show err)
        Right (ExitSuccess, stdout', _) -> pure $ Right $ T.strip $ T.pack stdout'
        Right (ExitFailure code, _, stderr) ->
          pure $ Left $ "nix build failed (exit " <> T.pack (show code) <> "): " <> T.pack stderr

-- | Query pkg-config for library flags
-- Returns -l flags from pkg-config, or falls back to package name
queryPkgConfig :: String -> Text -> IO [String]
queryPkgConfig pkgConfigPath ref = do
  let pkg = T.takeWhileEnd (/= '#') ref
      -- Strip version suffix if present (e.g., simdjson-4.2.4 -> simdjson)
      basePkg = T.takeWhile (/= '-') $ T.takeWhile (/= '.') pkg

  -- Get current environment and add PKG_CONFIG_PATH
  baseEnv <- getEnvironment
  let pkgConfigEnv = Just $ ("PKG_CONFIG_PATH", pkgConfigPath) : filter ((/= "PKG_CONFIG_PATH") . fst) baseEnv
      mkPkgConfigProc args = (proc "pkg-config" args) {env = pkgConfigEnv}

  -- Try pkg-config with the package name
  result <-
    try @SomeException $
      readCreateProcessWithExitCode (mkPkgConfigProc ["--libs", T.unpack basePkg]) ""

  case result of
    Left _ -> pure ["-l" <> T.unpack basePkg]
    Right (ExitSuccess, stdout, _) -> pure $ extractLibFlags stdout
    Right (ExitFailure _, _, _) -> do
      -- Try scanning for .pc files
      pcNames <- findPkgConfigNames pkgConfigPath
      case pcNames of
        (pcName : _) -> do
          result' <-
            try @SomeException $
              readCreateProcessWithExitCode (mkPkgConfigProc ["--libs", pcName]) ""
          case result' of
            Right (ExitSuccess, out, _) -> pure $ extractLibFlags out
            _ -> pure ["-l" <> T.unpack basePkg]
        [] -> pure ["-l" <> T.unpack basePkg]

-- | Extract -l flags from pkg-config output
extractLibFlags :: String -> [String]
extractLibFlags output = [flag | flag <- words output, "-l" `isPrefixOf` flag]
  where
    isPrefixOf prefix str = take (length prefix) str == prefix

-- | Find .pc file names in pkg-config path
findPkgConfigNames :: String -> IO [String]
findPkgConfigNames pkgConfigPath = do
  let dirs = splitOn ':' pkgConfigPath
  pcFiles <- concat <$> mapM findPcFiles dirs
  pure $ map (dropSuffix ".pc") pcFiles
  where
    findPcFiles dir = do
      exists <- doesDirectoryExist dir
      if exists
        then do
          contents <- listDirectory dir
          pure [f | f <- contents, ".pc" `isSuffixOf` f]
        else pure []
    splitOn c s = case break (== c) s of
      (a, []) -> [a]
      (a, _ : rest) -> a : splitOn c rest
    dropSuffix suf s
      | suf `isSuffixOf` s = take (length s - length suf) s
      | otherwise = s
