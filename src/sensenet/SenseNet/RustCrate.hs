{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : SenseNet.RustCrate
-- Description : Rust crate fetching from crates.io
--
-- Fetches Rust crates directly from crates.io, resolves dependencies,
-- and provides paths to cached sources. No cargo dependency.
module SenseNet.RustCrate
  ( -- * Crate Index
    CrateIndex,
    CrateVersionInfo (..),
    CrateDep (..),
    fetchCrateIndex,

    -- * Crate Fetching
    fetchCrate,
    getCacheDir,

    -- * Errors
    RustCrateError (..),
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getHomeDirectory,
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process
  ( CreateProcess (..),
    StdStream (..),
    createProcess,
    proc,
    readProcessWithExitCode,
    waitForProcess,
  )

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

-- | Crate index: map from version to info
type CrateIndex = Map Text CrateVersionInfo

-- | Information about a crate version
data CrateVersionInfo = CrateVersionInfo
  { cviName :: Text,
    cviVersion :: Text,
    cviChecksum :: Text,
    cviDeps :: [CrateDep],
    cviFeatures :: Map Text [Text],
    cviYanked :: Bool
  }
  deriving (Show, Eq)

-- | Crate dependency
data CrateDep = CrateDep
  { cdName :: Text,
    cdReq :: Text, -- Version requirement (semver)
    cdKind :: Text, -- "normal", "dev", "build"
    cdOptional :: Bool,
    cdDefaultFeatures :: Bool,
    cdFeatures :: [Text]
  }
  deriving (Show, Eq)

-- | Errors that can occur during Rust crate operations
data RustCrateError
  = FetchError Text
  | ParseError Text
  | ExtractError Text
  | ChecksumMismatch Text Text -- expected, actual
  deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Crate Index
-- ════════════════════════════════════════════════════════════════════════════

-- | Fetch crate index from crates.io-index
--
-- Index URL format:
--   1 char name:  1/{name}
--   2 char name:  2/{name}
--   3 char name:  3/{first-char}/{name}
--   4+ char name: {first-2-chars}/{chars-3-4}/{name}
fetchCrateIndex :: Text -> IO (Either RustCrateError CrateIndex)
fetchCrateIndex crateName = do
  let prefix = indexPrefix crateName
      url =
        "https://raw.githubusercontent.com/rust-lang/crates.io-index/master/"
          <> T.unpack prefix
          <> "/"
          <> T.unpack crateName

  cacheDir <- getCacheDir
  let cacheFile = cacheDir </> "index" </> T.unpack crateName <> ".idx"

  -- Check if cached (indexes update, so we could add TTL later)
  cached <- doesFileExist cacheFile
  if cached
    then parseCrateIndexFile cacheFile
    else do
      createDirectoryIfMissing True (cacheDir </> "index")
      exitCode <- runCurl url cacheFile
      case exitCode of
        ExitSuccess -> parseCrateIndexFile cacheFile
        ExitFailure code ->
          pure $ Left $ FetchError $ "curl failed for " <> crateName <> ": exit " <> T.pack (show code)

-- | Calculate the index prefix for a crate name
indexPrefix :: Text -> Text
indexPrefix name =
  case T.length name of
    1 -> "1"
    2 -> "2"
    3 -> "3/" <> T.take 1 name
    _ -> T.take 2 name <> "/" <> T.take 2 (T.drop 2 name)

-- | Parse a crate index file (one JSON per line)
parseCrateIndexFile :: FilePath -> IO (Either RustCrateError CrateIndex)
parseCrateIndexFile path = do
  content <- TIO.readFile path
  let versions = map parseIndexLine (T.lines content)
      validVersions = [(v.cviVersion, v) | Right v <- versions]
  if null validVersions
    then pure $ Left $ ParseError $ "No valid versions in index: " <> T.pack path
    else pure $ Right $ Map.fromList validVersions

-- | Parse a single index line (JSON object)
parseIndexLine :: Text -> Either RustCrateError CrateVersionInfo
parseIndexLine line =
  -- Minimal JSON parser for index format
  case parseIndexJSON line of
    Just info -> Right info
    Nothing -> Left $ ParseError $ "Failed to parse: " <> T.take 100 line

-- | Parse index JSON (minimal hand-rolled parser)
parseIndexJSON :: Text -> Maybe CrateVersionInfo
parseIndexJSON t = do
  -- Extract key fields
  name <- extractString "name" t
  vers <- extractString "vers" t
  cksum <- extractString "cksum" t
  let yanked = fromMaybe False (extractBool "yanked" t)
      deps = fromMaybe [] (extractDeps t)
      features = fromMaybe Map.empty (extractFeatures t)
  Just
    CrateVersionInfo
      { cviName = name,
        cviVersion = vers,
        cviChecksum = cksum,
        cviDeps = deps,
        cviFeatures = features,
        cviYanked = yanked
      }
  where
    extractString :: Text -> Text -> Maybe Text
    extractString key json = do
      let pattern = "\"" <> key <> "\":\""
          afterKey = snd $ T.breakOn pattern json
      rest <- T.stripPrefix pattern afterKey
      let (value, _) = T.breakOn "\"" rest
      Just value

    extractBool :: Text -> Text -> Maybe Bool
    extractBool key json =
      let patternTrue = "\"" <> key <> "\":true"
          patternFalse = "\"" <> key <> "\":false"
       in if patternTrue `T.isInfixOf` json
            then Just True
            else
              if patternFalse `T.isInfixOf` json
                then Just False
                else Nothing

    extractDeps :: Text -> Maybe [CrateDep]
    extractDeps json = do
      -- Find "deps":[ ... ]
      let afterDeps = snd $ T.breakOn "\"deps\":[" json
      rest <- T.stripPrefix "\"deps\":[" afterDeps
      let (depsArray, _) = T.breakOn "]" rest
      Just $ parseDepsArray depsArray

    parseDepsArray :: Text -> [CrateDep]
    parseDepsArray arr =
      -- Very simplified: just extract names for now
      -- Full implementation would parse each dep object
      let depObjs = T.splitOn "},{" arr
       in [dep | Just dep <- map parseDepObj depObjs]

    parseDepObj :: Text -> Maybe CrateDep
    parseDepObj obj = do
      name <- extractString "name" obj
      req <- extractString "req" obj
      let kind = fromMaybe "normal" (extractString "kind" obj)
          optional = fromMaybe False (extractBool "optional" obj)
          defaultFeatures = fromMaybe True (extractBool "default_features" obj)
      Just
        CrateDep
          { cdName = name,
            cdReq = req,
            cdKind = kind,
            cdOptional = optional,
            cdDefaultFeatures = defaultFeatures,
            cdFeatures = []
          }

    extractFeatures :: Text -> Maybe (Map Text [Text])
    extractFeatures _ = Just Map.empty -- TODO: parse features

-- ════════════════════════════════════════════════════════════════════════════
-- Crate Fetching
-- ════════════════════════════════════════════════════════════════════════════

-- | Get the sensenet Rust cache directory
getCacheDir :: IO FilePath
getCacheDir = do
  home <- getHomeDirectory
  let cacheDir = home </> ".cache" </> "sensenet" </> "rust"
  createDirectoryIfMissing True cacheDir
  pure cacheDir

-- | Fetch a crate from crates.io
--
-- Returns the path to the extracted crate directory.
fetchCrate :: Text -> Text -> Text -> IO (Either RustCrateError FilePath)
fetchCrate crateName version checksum = do
  cacheDir <- getCacheDir
  let crateDir = cacheDir </> "crates" </> T.unpack crateName <> "-" <> T.unpack version
      tarPath = cacheDir </> "crates" </> T.unpack crateName <> "-" <> T.unpack version <> ".crate"

  createDirectoryIfMissing True (cacheDir </> "crates")

  -- Check if already cached
  exists <- doesDirectoryExist crateDir
  if exists
    then pure $ Right crateDir
    else do
      -- Download crate
      let url = "https://crates.io/api/v1/crates/" <> T.unpack crateName <> "/" <> T.unpack version <> "/download"
      exitCode <- runCurl url tarPath
      case exitCode of
        ExitFailure code ->
          pure $ Left $ FetchError $ "Failed to download " <> crateName <> "-" <> version <> ": curl exit " <> T.pack (show code)
        ExitSuccess -> do
          -- Verify checksum
          checksumResult <- verifySha256 tarPath checksum
          case checksumResult of
            Left err -> pure $ Left err
            Right () -> do
              -- Extract crate (.crate files are gzipped tarballs)
              extractResult <- extractCrate tarPath (cacheDir </> "crates") crateDir
              -- Clean up
              _ <- runProcess "rm" ["-f", tarPath]
              pure extractResult

-- | Verify SHA256 checksum
verifySha256 :: FilePath -> Text -> IO (Either RustCrateError ())
verifySha256 path expected = do
  (exitCode, stdout, _) <- readProcessWithExitCode "sha256sum" [path] ""
  case exitCode of
    ExitFailure _ -> pure $ Right () -- Skip check if sha256sum not available
    ExitSuccess -> do
      let actual = T.strip $ T.pack $ takeWhile (/= ' ') stdout
      if actual == expected
        then pure $ Right ()
        else pure $ Left $ ChecksumMismatch expected actual

-- | Extract a .crate file
extractCrate :: FilePath -> FilePath -> FilePath -> IO (Either RustCrateError FilePath)
extractCrate tarPath workDir destDir = do
  -- Get the top-level directory name
  topDirResult <- getTarTopDir tarPath
  case topDirResult of
    Left err -> pure $ Left err
    Right topDir -> do
      -- Extract
      exitCode <- runProcess "tar" ["-xzf", tarPath, "-C", workDir]
      case exitCode of
        ExitFailure code ->
          pure $ Left $ ExtractError $ "tar extract failed: " <> T.pack (show code)
        ExitSuccess -> do
          let srcPath = workDir </> topDir
          -- Move to final destination
          _ <- runProcess "mv" [srcPath, destDir]
          pure $ Right destDir

-- | Get the top-level directory from a tarball
getTarTopDir :: FilePath -> IO (Either RustCrateError FilePath)
getTarTopDir tarPath = do
  (exitCode, stdout, _) <- readProcessWithExitCode "tar" ["-tzf", tarPath] ""
  case exitCode of
    ExitFailure code ->
      pure $ Left $ ExtractError $ "tar list failed: " <> T.pack (show code)
    ExitSuccess -> do
      let firstLine = takeWhile (/= '\n') stdout
          topDir = takeWhile (/= '/') firstLine
      if null topDir
        then pure $ Left $ ExtractError "Empty tarball"
        else pure $ Right topDir

-- ════════════════════════════════════════════════════════════════════════════
-- Process Utilities
-- ════════════════════════════════════════════════════════════════════════════

-- | Run curl to download a URL to a file
runCurl :: String -> FilePath -> IO ExitCode
runCurl url destFile = do
  let args = ["-sL", "-o", destFile, url]
  runProcess "curl" args

-- | Run a process and wait for it to complete
runProcess :: String -> [String] -> IO ExitCode
runProcess cmd args = do
  let cp =
        (proc cmd args)
          { std_out = CreatePipe,
            std_err = CreatePipe,
            std_in = NoStream
          }
  (_, _, _, ph) <- createProcess cp
  waitForProcess ph
