{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : SenseNet.Complete
-- Description : Ultra-fast shell completion for sensenet
--
-- Provides sub-50ms target completions using:
--   1. Cached target index stored in ~/.cache/sensenet/targets.idx
--   2. Lazy parsing - only parse packages matching the prefix
--   3. Background refresh - stale cache is served while updating
--
-- The cache is automatically invalidated when BUILD.dhall files change.
module SenseNet.Complete
  ( -- * Completion
    completeTargetsCached,
    completeTargetsFresh,

    -- * Cache management
    refreshTargetCache,
    invalidateCache,

    -- * Low-level (for testing)
    TargetIndex (..),
    loadIndex,
    saveIndex,
  )
where

import Control.Concurrent.Async (forConcurrently)
import Control.Exception (SomeException, catch)
import Control.Monad (when)
import Data.List (sortBy)
import Data.Maybe (mapMaybe)
import Data.Ord (comparing)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import SenseNet.Dhall qualified as Dhall
import SenseNet.Discover (DhallFile (..), discover)
import SenseNet.IR (Package (..), ruleName)
import System.Directory
  ( XdgDirectory (..),
    createDirectoryIfMissing,
    doesFileExist,
    getXdgDirectory,
    removeFile,
  )
import System.FilePath ((</>))

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

-- | Cached target index
data TargetIndex = TargetIndex
  { -- | Project root this index is for
    tiProjectRoot :: !FilePath,
    -- | When the index was built
    tiBuildTime :: !UTCTime,
    -- | All targets as "//path:name"
    tiTargets :: ![Text],
    -- | All package paths (for //path:all and //path/... completions)
    tiPackages :: ![Text]
  }
  deriving (Show, Eq)

-- | Maximum cache age before forced refresh (1 hour)
cacheMaxAgeSeconds :: Double
cacheMaxAgeSeconds = 3600.0

-- ════════════════════════════════════════════════════════════════════════════
-- Public API
-- ════════════════════════════════════════════════════════════════════════════

-- | Complete targets with caching
-- Returns completions for the given prefix, using cached index if available.
-- Cache is refreshed in background if stale.
completeTargetsCached :: FilePath -> Text -> IO [Text]
completeTargetsCached projectRoot prefix = do
  cacheFile <- getCacheFile projectRoot
  mIndex <- loadIndex cacheFile

  case mIndex of
    Just idx | tiProjectRoot idx == projectRoot -> do
      -- Check if cache is still fresh
      now <- getCurrentTime
      let age = realToFrac $ diffUTCTime now (tiBuildTime idx)

      -- If very stale, rebuild synchronously
      when (age > cacheMaxAgeSeconds) $ do
        refreshTargetCache projectRoot
        pure ()

      -- Return completions from cache
      pure $ filterCompletions prefix idx
    _ -> do
      -- No cache or wrong project, build fresh
      completeTargetsFresh projectRoot prefix

-- | Complete targets without caching (slower, always fresh)
completeTargetsFresh :: FilePath -> Text -> IO [Text]
completeTargetsFresh projectRoot prefix = do
  -- Discover and parse targets
  idx <- buildTargetIndex projectRoot

  -- Save to cache for next time
  cacheFile <- getCacheFile projectRoot
  saveIndex cacheFile idx

  pure $ filterCompletions prefix idx

-- | Force refresh of the target cache
refreshTargetCache :: FilePath -> IO ()
refreshTargetCache projectRoot = do
  idx <- buildTargetIndex projectRoot
  cacheFile <- getCacheFile projectRoot
  saveIndex cacheFile idx

-- | Invalidate the cache (e.g., after build completes)
invalidateCache :: FilePath -> IO ()
invalidateCache projectRoot = do
  cacheFile <- getCacheFile projectRoot
  exists <- doesFileExist cacheFile
  when exists $ removeFile cacheFile

-- ════════════════════════════════════════════════════════════════════════════
-- Filtering
-- ════════════════════════════════════════════════════════════════════════════

-- | Filter completions based on prefix
filterCompletions :: Text -> TargetIndex -> [Text]
filterCompletions prefix idx
  | T.null prefix || prefix == "//" =
      -- Empty or "//" - suggest packages with :
      take 50 $ map (<> ":") (tiPackages idx) ++ ["//..."]
  | ":" `T.isInfixOf` prefix =
      -- Has colon - complete targets within package
      let (pkgPart, colonRest) = T.breakOn ":" prefix
          targetPrefix = T.drop 1 colonRest
          pkgPath = T.drop 2 pkgPart -- Remove //
          matchingTargets = filter (matchesPackageTarget pkgPath targetPrefix) (tiTargets idx)
       in take 50 $ sortBy (comparing T.length) matchingTargets
  | "..." `T.isSuffixOf` prefix =
      -- Already has ..., no more completions
      [prefix]
  | otherwise =
      -- Completing package path (no colon yet)
      let pathPrefix = T.drop 2 prefix -- Remove //
      -- Find matching packages
          matchingPkgs = filter (pathPrefix `T.isPrefixOf`) (tiPackages idx)
          -- Also suggest recursive pattern
          recursiveSuggestion = if T.null pathPrefix then "//..." else prefix <> "..."
          -- Format as //pkg:
          formatted = map (\p -> "//" <> p <> ":") matchingPkgs
       in take 50 $ recursiveSuggestion : sortBy (comparing T.length) formatted

-- | Check if a target matches package and target prefix
matchesPackageTarget :: Text -> Text -> Text -> Bool
matchesPackageTarget pkgPath targetPrefix target =
  let -- target format: "//pkg/path:name"
      expectedPrefix = "//" <> pkgPath <> ":"
   in expectedPrefix `T.isPrefixOf` target
        && targetPrefix `T.isPrefixOf` (T.drop (T.length expectedPrefix) target)

-- ════════════════════════════════════════════════════════════════════════════
-- Index Building
-- ════════════════════════════════════════════════════════════════════════════

-- | Build target index from project
buildTargetIndex :: FilePath -> IO TargetIndex
buildTargetIndex projectRoot = do
  now <- getCurrentTime

  -- Discover BUILD.dhall files
  dhallFiles <- discover projectRoot

  -- Parse packages (in parallel for speed)
  packages <- parsePackagesParallel projectRoot dhallFiles

  -- Extract targets and package paths
  let targets = concatMap packageToTargets packages
      pkgPaths = map (\p -> T.pack p.path) packages

  pure
    TargetIndex
      { tiProjectRoot = projectRoot,
        tiBuildTime = now,
        tiTargets = targets,
        tiPackages = pkgPaths
      }

-- | Parse packages in parallel using async
-- Full Dhall parsing but concurrent for speed
parsePackagesParallel :: FilePath -> [DhallFile] -> IO [Package]
parsePackagesParallel projectRoot dhallFiles = do
  -- Parse all packages concurrently
  results <- forConcurrently dhallFiles $ \df -> do
    catch
      (Just <$> Dhall.parsePackageFile projectRoot (dhallPath df))
      (\(_ :: SomeException) -> pure Nothing)

  pure $ mapMaybe id results

-- | Convert package to list of target strings
packageToTargets :: Package -> [Text]
packageToTargets pkg =
  let pkgPath = T.pack pkg.path
   in map (\r -> "//" <> pkgPath <> ":" <> ruleName r) pkg.rules

-- ════════════════════════════════════════════════════════════════════════════
-- Cache I/O
-- ════════════════════════════════════════════════════════════════════════════

-- | Get cache file path for a project
getCacheFile :: FilePath -> IO FilePath
getCacheFile projectRoot = do
  cacheDir <- getXdgDirectory XdgCache "sensenet"
  createDirectoryIfMissing True cacheDir

  -- Use hash of project root for cache file name
  let projectHash = hashPath projectRoot
  pure $ cacheDir </> ("targets-" <> projectHash <> ".idx")

-- | Simple hash of path for cache filename
hashPath :: FilePath -> String
hashPath = take 16 . show . abs . foldr (\c h -> fromEnum c + h * 31) 0

-- | Load index from cache file
loadIndex :: FilePath -> IO (Maybe TargetIndex)
loadIndex cacheFile = do
  exists <- doesFileExist cacheFile
  if not exists
    then pure Nothing
    else catch (Just <$> readIndex cacheFile) (\(_ :: SomeException) -> pure Nothing)

-- | Read index from file
readIndex :: FilePath -> IO TargetIndex
readIndex cacheFile = do
  content <- TIO.readFile cacheFile
  let ls = T.lines content
  case ls of
    (projectLine : timeLine : pkgCountLine : rest) -> do
      let projectRoot = T.unpack projectLine
          buildTime = posixSecondsToUTCTime $ realToFrac (read (T.unpack timeLine) :: Double)
          pkgCount = read (T.unpack pkgCountLine) :: Int
          (pkgLines, targetLines) = splitAt pkgCount rest
      pure
        TargetIndex
          { tiProjectRoot = projectRoot,
            tiBuildTime = buildTime,
            tiTargets = targetLines,
            tiPackages = pkgLines
          }
    _ -> error "Invalid cache format"

-- | Save index to cache file
saveIndex :: FilePath -> TargetIndex -> IO ()
saveIndex cacheFile idx = do
  let posixTime :: Double
      posixTime = realToFrac (utcTimeToPOSIXSeconds (tiBuildTime idx))
      content =
        T.unlines $
          [ T.pack (tiProjectRoot idx),
            T.pack $ show posixTime,
            T.pack $ show (length (tiPackages idx))
          ]
            ++ tiPackages idx
            ++ tiTargets idx
  TIO.writeFile cacheFile content
