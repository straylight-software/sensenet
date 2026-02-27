{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : SenseNet.PureScript
Description : PureScript package fetching without spago

Fetches PureScript packages directly from the registry/GitHub,
resolves transitive dependencies, and extracts to a local cache.
No spago dependency - just curl and tar.
-}
module SenseNet.PureScript (
    -- * Package Set
    PackageSet,
    PackageInfo (..),
    fetchPackageSet,

    -- * Dependency Resolution
    resolveDeps,

    -- * Package Fetching
    fetchPackages,
    PackageCache,
    getCacheDir,

    -- * Errors
    PureScriptError (..),
)
where

import Control.Monad (forM)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import GHC.Generics (Generic)
import System.Directory (
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getHomeDirectory,
 )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (
    CreateProcess (..),
    StdStream (..),
    createProcess,
    proc,
    readProcessWithExitCode,
    waitForProcess,
 )

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

-- | Package set: map from package name to info
type PackageSet = Map Text PackageInfo

-- | Information about a package in the package set
data PackageInfo = PackageInfo
    { piDependencies :: [Text]
    , piRepo :: Text
    , piVersion :: Text
    }
    deriving (Show, Eq, Generic)

-- | Package cache directory path
type PackageCache = FilePath

-- | Errors that can occur during PureScript operations
data PureScriptError
    = FetchError Text
    | ParseError Text
    | DependencyError Text
    | ExtractError Text
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Package Set Fetching
-- ════════════════════════════════════════════════════════════════════════════

{- | Fetch and parse a package set from the PureScript package-sets repo

Package set URL format:
  https://raw.githubusercontent.com/purescript/package-sets/psc-{compiler}-{date}/packages.json

For now we use a pinned set (matching what spago uses by default).
-}
fetchPackageSet :: Text -> IO (Either PureScriptError PackageSet)
fetchPackageSet setVersion = do
    let url =
            "https://raw.githubusercontent.com/purescript/package-sets/"
                <> T.unpack setVersion
                <> "/packages.json"

    cacheDir <- getCacheDir
    let cacheFile = cacheDir </> "package-sets" </> T.unpack setVersion <> ".json"

    -- Check if cached
    cached <- doesFileExist cacheFile
    if cached
        then parsePackageSetFile cacheFile
        else do
            -- Fetch with curl
            createDirectoryIfMissing True (cacheDir </> "package-sets")
            exitCode <- runCurl url cacheFile
            case exitCode of
                ExitSuccess -> parsePackageSetFile cacheFile
                ExitFailure code ->
                    pure $ Left $ FetchError $ "curl failed with code " <> T.pack (show code)

{- | Parse a package set JSON file

The format is:
{
  "package-name": {
    "dependencies": ["dep1", "dep2"],
    "repo": "https://github.com/owner/repo.git",
    "version": "vX.Y.Z"
  }
}
-}
parsePackageSetFile :: FilePath -> IO (Either PureScriptError PackageSet)
parsePackageSetFile path = do
    content <- TIO.readFile path
    pure $ parsePackageSetJSON content

{- | Parse package set JSON content

Simple hand-rolled JSON parser - avoids aeson dependency
-}
parsePackageSetJSON :: Text -> Either PureScriptError PackageSet
parsePackageSetJSON content =
    -- This is a minimal JSON parser for the specific format we need
    -- Format: { "name": { "dependencies": [...], "repo": "...", "version": "..." }, ... }
    case parseTopLevel (T.strip content) of
        Just pkgs -> Right $ Map.fromList pkgs
        Nothing -> Left $ ParseError "Failed to parse package set JSON"
  where
    parseTopLevel :: Text -> Maybe [(Text, PackageInfo)]
    parseTopLevel t = do
        -- Strip outer braces
        inner <- T.stripPrefix "{" t >>= T.stripSuffix "}"
        parsePackages (T.strip inner)

    parsePackages :: Text -> Maybe [(Text, PackageInfo)]
    parsePackages t
        | T.null t = Just []
        | otherwise = do
            -- Parse "name": { ... }
            (name, rest1) <- parseString t
            rest2 <- T.stripPrefix ":" (T.strip rest1)
            (info, rest3) <- parsePackageInfo (T.strip rest2)
            let rest4 = T.strip rest3
            rest5 <- case T.uncons rest4 of
                Just (',', r) -> Just (T.strip r)
                Just ('}', _) -> Just "" -- End of outer object
                Nothing -> Just ""
                _ -> Nothing
            morePackages <- parsePackages rest5
            Just $ (name, info) : morePackages

    parsePackageInfo :: Text -> Maybe (PackageInfo, Text)
    parsePackageInfo t = do
        rest1 <- T.stripPrefix "{" t
        (deps, rest2) <- parseDepsField (T.strip rest1)
        (repo, rest3) <- parseRepoField (T.strip rest2)
        (version, rest4) <- parseVersionField (T.strip rest3)
        rest5 <- T.stripPrefix "}" (T.strip rest4)
        Just (PackageInfo deps repo version, rest5)

    parseDepsField :: Text -> Maybe ([Text], Text)
    parseDepsField t = do
        rest1 <- T.stripPrefix "\"dependencies\"" t >>= T.stripPrefix ":" . T.strip
        (deps, rest2) <- parseArray (T.strip rest1)
        rest3 <- skipComma rest2
        Just (deps, rest3)

    parseRepoField :: Text -> Maybe (Text, Text)
    parseRepoField t = do
        rest1 <- T.stripPrefix "\"repo\"" t >>= T.stripPrefix ":" . T.strip
        (repo, rest2) <- parseString (T.strip rest1)
        rest3 <- skipComma rest2
        Just (repo, rest3)

    parseVersionField :: Text -> Maybe (Text, Text)
    parseVersionField t = do
        rest1 <- T.stripPrefix "\"version\"" t >>= T.stripPrefix ":" . T.strip
        (version, rest2) <- parseString (T.strip rest1)
        Just (version, T.strip rest2)

    skipComma :: Text -> Maybe Text
    skipComma t =
        let stripped = T.strip t
         in case T.uncons stripped of
                Just (',', r) -> Just (T.strip r)
                _ -> Just stripped

    parseString :: Text -> Maybe (Text, Text)
    parseString t = do
        rest1 <- T.stripPrefix "\"" t
        let (str, rest2) = T.breakOn "\"" rest1
        rest3 <- T.stripPrefix "\"" rest2
        Just (str, T.strip rest3)

    parseArray :: Text -> Maybe ([Text], Text)
    parseArray t = do
        rest1 <- T.stripPrefix "[" t
        parseArrayItems (T.strip rest1) []

    parseArrayItems :: Text -> [Text] -> Maybe ([Text], Text)
    parseArrayItems t acc = case T.uncons (T.strip t) of
        Just (']', rest) -> Just (reverse acc, T.strip rest)
        _ -> do
            (item, rest1) <- parseString (T.strip t)
            let rest2 = T.strip rest1
            rest3 <- case T.uncons rest2 of
                Just (',', r) -> Just (T.strip r)
                Just (']', _) -> Just rest2
                _ -> Nothing
            parseArrayItems rest3 (item : acc)

-- ════════════════════════════════════════════════════════════════════════════
-- Dependency Resolution
-- ════════════════════════════════════════════════════════════════════════════

-- | Resolve transitive dependencies for a list of direct dependencies
resolveDeps :: PackageSet -> [Text] -> Either PureScriptError (Set Text)
resolveDeps pkgSet directDeps = go Set.empty directDeps
  where
    go :: Set Text -> [Text] -> Either PureScriptError (Set Text)
    go seen [] = Right seen
    go seen (dep : rest)
        | Set.member dep seen = go seen rest
        | otherwise = case Map.lookup dep pkgSet of
            Nothing -> Left $ DependencyError $ "Package not found: " <> dep
            Just info -> go (Set.insert dep seen) (info.piDependencies ++ rest)

-- ════════════════════════════════════════════════════════════════════════════
-- Package Fetching
-- ════════════════════════════════════════════════════════════════════════════

-- | Get the sensenet cache directory
getCacheDir :: IO FilePath
getCacheDir = do
    home <- getHomeDirectory
    let cacheDir = home </> ".cache" </> "sensenet" </> "purescript"
    createDirectoryIfMissing True cacheDir
    pure cacheDir

{- | Fetch all packages to the cache, returning the path to the packages dir

Each package is extracted to: {cache}/packages/{name}-{version}/
-}
fetchPackages ::
    PackageSet ->
    Set Text ->
    IO (Either PureScriptError FilePath)
fetchPackages pkgSet deps = do
    cacheDir <- getCacheDir
    let pkgsDir = cacheDir </> "packages"
    createDirectoryIfMissing True pkgsDir

    -- Fetch each package
    results <- forM (Set.toList deps) $ \pkgName ->
        case Map.lookup pkgName pkgSet of
            Nothing -> pure $ Left $ DependencyError $ "Package not in set: " <> pkgName
            Just info -> fetchPackage pkgsDir pkgName info

    case sequence results of
        Left err -> pure $ Left err
        Right _ -> pure $ Right pkgsDir

-- | Fetch a single package to the cache
fetchPackage :: FilePath -> Text -> PackageInfo -> IO (Either PureScriptError ())
fetchPackage pkgsDir pkgName info = do
    let version = T.dropWhile (== 'v') info.piVersion -- "v7.0.0" -> "7.0.0"
        pkgDir = pkgsDir </> T.unpack pkgName <> "-" <> T.unpack version

    -- Check if already cached
    exists <- doesDirectoryExist pkgDir
    if exists
        then pure $ Right ()
        else do
            -- Convert repo URL to tarball URL
            -- "https://github.com/owner/repo.git" -> "https://github.com/owner/repo/archive/refs/tags/vX.Y.Z.tar.gz"
            let tarballUrl = repoToTarballUrl info.piRepo info.piVersion
            case tarballUrl of
                Nothing -> pure $ Left $ FetchError $ "Cannot convert repo URL: " <> info.piRepo
                Just url -> do
                    -- Fetch and extract
                    let tmpTar = pkgsDir </> T.unpack pkgName <> ".tar.gz"
                    exitCode <- runCurl (T.unpack url) tmpTar
                    case exitCode of
                        ExitFailure code ->
                            pure $ Left $ FetchError $ "Failed to fetch " <> pkgName <> ": curl exit " <> T.pack (show code)
                        ExitSuccess -> do
                            -- Extract tarball
                            -- The tarball extracts to: repo-name-version/ (e.g., purescript-halogen-7.0.0/)
                            extractResult <- extractTarball tmpTar pkgsDir pkgDir
                            -- Clean up tarball
                            _ <- runProcess "rm" ["-f", tmpTar]
                            pure extractResult

-- | Convert a git repo URL to a GitHub tarball URL
repoToTarballUrl :: Text -> Text -> Maybe Text
repoToTarballUrl repo version
    | "https://github.com/" `T.isPrefixOf` repo = do
        -- "https://github.com/owner/repo.git" -> "https://github.com/owner/repo"
        let stripped = fromMaybe repo (T.stripSuffix ".git" repo)
        Just $ stripped <> "/archive/refs/tags/" <> version <> ".tar.gz"
    | otherwise = Nothing

-- | Extract a tarball to a destination directory
extractTarball :: FilePath -> FilePath -> FilePath -> IO (Either PureScriptError ())
extractTarball tarPath workDir destDir = do
    -- First, find the top-level directory in the tarball using tar --list
    -- This avoids the ambiguity of listing the directory after extraction
    topDirResult <- getTarTopDir tarPath
    case topDirResult of
        Left err -> pure $ Left err
        Right topDir -> do
            -- Extract the tarball
            exitCode <- runProcess "tar" ["-xzf", tarPath, "-C", workDir]
            case exitCode of
                ExitFailure code ->
                    pure $ Left $ ExtractError $ "tar extract failed: " <> T.pack (show code)
                ExitSuccess -> do
                    -- Move extracted directory to final destination
                    let srcPath = workDir </> topDir
                    _ <- runProcess "mv" [srcPath, destDir]
                    pure $ Right ()

-- | Get the top-level directory name from a tarball
getTarTopDir :: FilePath -> IO (Either PureScriptError FilePath)
getTarTopDir tarPath = do
    -- Run: tar -tzf file.tar.gz | head -1
    -- This gives us the first entry which is the top-level directory
    (exitCode, stdout, _) <- readProcessWithExitCode "tar" ["-tzf", tarPath] ""
    case exitCode of
        ExitFailure code ->
            pure $ Left $ ExtractError $ "tar list failed: " <> T.pack (show code)
        ExitSuccess -> do
            -- Parse the first line to get the directory name
            -- It will be something like "purescript-halogen-7.0.0/"
            let firstLine = takeWhile (/= '\n') stdout
                topDir = takeWhile (/= '/') firstLine
            if null topDir
                then pure $ Left $ ExtractError "Empty tarball or invalid format"
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
    (ec, _, _) <- readProcessWithExitCode cmd args ""
    pure ec
