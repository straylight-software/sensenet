{- |
Module      : SenseNet.Discover
Description : Discover Dhall files in a project

Walks the project tree, consulting SCM ignore files,
to find all Dhall build definitions.
-}
module SenseNet.Discover
  ( DhallFile(..)
  , discover
  ) where

import Control.Monad (filterM, forM)
import Data.List (isPrefixOf)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>), takeFileName, makeRelative)

-- | A discovered Dhall file
data DhallFile = DhallFile
  { dhallPath :: FilePath    -- ^ Absolute path to the .dhall file
  , dhallRelPath :: FilePath -- ^ Path relative to project root
  }
  deriving (Show, Eq)

-- | Discover all .dhall files under a directory
-- Respects .gitignore patterns and skips generated content
discover :: FilePath -> IO [DhallFile]
discover root = do
  ignores <- loadIgnorePatterns root
  go ignores root
  where
    go ignores dir = do
      entries <- listDirectory dir
      let paths = map (dir </>) entries
      
      -- Find BUILD.dhall files only
      dhallFiles <- filterM doesFileExist $ filter isBuildDhall paths
      let here = map (\fp -> DhallFile fp (makeRelative root fp)) dhallFiles
      
      -- Recurse into subdirectories
      subdirs <- filterM doesDirectoryExist paths
      let validDirs = filter (not . isIgnored ignores root) subdirs
      
      children <- concat <$> forM validDirs (go ignores)
      pure (here ++ children)
    
    isBuildDhall p = takeFileName p == "BUILD.dhall"
    
    isSuffixOf suffix str = suffix == drop (length str - length suffix) str

-- | Check if a path should be ignored
isIgnored :: [String] -> FilePath -> FilePath -> Bool
isIgnored patterns root path =
  let name = takeFileName path
      rel = makeRelative root path
  in 
     -- Always skip these
     any (`elem` ("._" :: String)) (take 1 name)
     || name `elem` builtinIgnores
     -- Check gitignore patterns
     || any (`matches` rel) patterns
  where
    builtinIgnores = 
      [ "buck-out"
      , "node_modules" 
      , ".git"
      , ".direnv"
      , "result"
      , "dist-newstyle"
      , "toolchains"    -- sensenet toolchains come from Nix, not discovered
      , "prelude"       -- buck2 prelude comes from Nix
      , "nix"           -- nix build artifacts
      ]
    
    -- Simple pattern matching (TODO: full gitignore glob support)
    matches pat p
      | "/" `isPrefixOf` pat = takeFileName p == drop 1 pat
      | otherwise = pat `isPrefixOf` p || ("/" ++ pat) `isInfixOf` p
    
    isInfixOf needle haystack = any (isPrefixOf needle) (tails haystack)
    tails [] = [[]]
    tails xs@(_:xs') = xs : tails xs'

-- | Load ignore patterns from .gitignore and .sensenetignore
loadIgnorePatterns :: FilePath -> IO [String]
loadIgnorePatterns root = do
  git <- loadIgnoreFile (root </> ".gitignore")
  sensenet <- loadIgnoreFile (root </> ".sensenetignore")
  pure (git ++ sensenet)

loadIgnoreFile :: FilePath -> IO [String]
loadIgnoreFile path = do
  exists <- doesFileExist path
  if exists
    then do
      content <- readFile path
      pure $ filter validLine $ lines content
    else pure []
  where
    validLine l = not (null l) && not ("#" `isPrefixOf` l)
