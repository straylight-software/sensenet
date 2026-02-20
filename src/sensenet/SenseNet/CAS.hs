{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : SenseNet.CAS
Description : Content Addressable Storage

Simple file-based CAS for build artifacts.
Store by hash, retrieve by hash. That's it.
-}
module SenseNet.CAS
  ( -- * CAS Handle
    CAS
  , newCAS
  , casDir

    -- * Operations
  , store
  , retrieve
  , exists
  , link

    -- * Digests
  , Digest (..)
  , digestFromBytes
  , digestFromFile
  , digestText
  ) where

import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteArray.Encoding qualified as BA
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , copyFile
  , getXdgDirectory
  , XdgDirectory(..)
  )
import System.FilePath ((</>), takeDirectory)

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

-- | CAS handle
newtype CAS = CAS { casDir :: FilePath }

-- | Content digest (SHA256)
newtype Digest = Digest { unDigest :: ByteString }
  deriving (Eq, Ord, Show)

-- ════════════════════════════════════════════════════════════════════════════
-- Initialization
-- ════════════════════════════════════════════════════════════════════════════

-- | Create or open CAS
newCAS :: IO CAS
newCAS = do
  dir <- getXdgDirectory XdgCache "sensenet/cas"
  createDirectoryIfMissing True dir
  pure (CAS dir)

-- ════════════════════════════════════════════════════════════════════════════
-- Digests
-- ════════════════════════════════════════════════════════════════════════════

-- | Compute digest from bytes
digestFromBytes :: ByteString -> Digest
digestFromBytes bs =
  let hash = hashWith SHA256 bs
  in Digest (BA.convertToBase BA.Base16 hash)

-- | Compute digest from file
digestFromFile :: FilePath -> IO Digest
digestFromFile path = digestFromBytes <$> BS.readFile path

-- | Get digest as text
digestText :: Digest -> Text
digestText = TE.decodeUtf8 . unDigest

-- ════════════════════════════════════════════════════════════════════════════
-- Operations
-- ════════════════════════════════════════════════════════════════════════════

-- | Store content, return digest
store :: CAS -> ByteString -> IO Digest
store cas content = do
  let digest = digestFromBytes content
      path = blobPath cas digest
  createDirectoryIfMissing True (takeDirectory path)
  BS.writeFile path content
  pure digest

-- | Retrieve content by digest
retrieve :: CAS -> Digest -> IO (Maybe ByteString)
retrieve cas digest = do
  let path = blobPath cas digest
  ex <- doesFileExist path
  if ex
    then Just <$> BS.readFile path
    else pure Nothing

-- | Check if digest exists in CAS
exists :: CAS -> Digest -> IO Bool
exists cas digest = doesFileExist (blobPath cas digest)

-- | Hard link a file into CAS, return digest
link :: CAS -> FilePath -> IO Digest
link cas srcPath = do
  digest <- digestFromFile srcPath
  let destPath = blobPath cas digest
  ex <- doesFileExist destPath
  if ex
    then pure digest  -- Already in CAS
    else do
      createDirectoryIfMissing True (takeDirectory destPath)
      copyFile srcPath destPath  -- Copy instead of link for safety
      pure digest

-- ════════════════════════════════════════════════════════════════════════════
-- Internal
-- ════════════════════════════════════════════════════════════════════════════

-- | Path for a blob in CAS (sharded by first 2 chars)
blobPath :: CAS -> Digest -> FilePath
blobPath (CAS dir) (Digest hash) =
  let hex = T.unpack (TE.decodeUtf8 hash)
      prefix = take 2 hex
  in dir </> prefix </> hex
