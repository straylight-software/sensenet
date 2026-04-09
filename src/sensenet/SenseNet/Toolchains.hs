{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

{- |
Module      : SenseNet.Toolchains
Description : Parse .sensenet/toolchains.dhall for compiler/linker paths

A toolchain is defined by what a remote execution container needs:
- A container image (for RE) or None (for local Nix)
- Executables at absolute paths
- Include paths for headers
- Library paths for linking

This same shape works for local and remote execution.

OPTIMIZATION: Toolchains are cached as JSON in .sensenet/toolchains.json
to avoid re-parsing Dhall on every invocation (~50ms savings).
-}
module SenseNet.Toolchains (
    Toolchains (..),
    Tool (..),
    Paths (..),
    Cxx (..),
    Nv (..),
    Rust (..),
    Haskell (..),
    Lean (..),
    PureScript (..),
    loadToolchains,
    defaultToolchainsPath,
)
where

import Data.Aeson (FromJSON, ToJSON, eitherDecodeFileStrict', encodeFile)
import Data.Text (Text)
import Dhall (FromDhall)
import DhallFast.Input (auto, inputFile)
import GHC.Generics (Generic)
import System.Directory (doesFileExist, getModificationTime)
import System.FilePath (replaceExtension, (</>))

-- ════════════════════════════════════════════════════════════════════════════
-- Core Types
-- ════════════════════════════════════════════════════════════════════════════

-- | A single executable tool
data Tool = Tool
    { path :: Text
    }
    deriving stock (Show, Generic)
    deriving anyclass (FromDhall, FromJSON, ToJSON)

-- | Include/library search paths
data Paths = Paths
    { includes :: [Text]
    , libs :: [Text]
    }
    deriving stock (Show, Generic)
    deriving anyclass (FromDhall, FromJSON, ToJSON)

-- ════════════════════════════════════════════════════════════════════════════
-- C++ Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data Cxx = Cxx
    { image :: Maybe Text -- Container image (Nothing = local)
    , cc :: Tool -- C compiler
    , cxx :: Tool -- C++ compiler
    , ar :: Tool -- Archiver
    , ld :: Tool -- Linker
    , paths :: Paths -- Search paths
    , sysroot :: Text -- Sysroot (for cross-compilation)
    , target :: Text -- Target triple
    }
    deriving stock (Show, Generic)
    deriving anyclass (FromDhall, FromJSON, ToJSON)

-- ════════════════════════════════════════════════════════════════════════════
-- NVIDIA Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data Nv = Nv
    { image :: Maybe Text -- Container image (Nothing = local)
    , clang :: Tool -- Clang with CUDA support
    , ptxas :: Tool -- PTX assembler
    , fatbinary :: Tool -- Fat binary tool
    , sdk_path :: Text -- NVIDIA SDK root (for --cuda-path)
    , sdk :: Paths -- CUDA SDK include/lib paths
    , archs :: [Text] -- Target SM architectures
    , cxx :: Cxx -- C++ toolchain (for stdlib)
    }
    deriving stock (Show, Generic)
    deriving anyclass (FromDhall, FromJSON, ToJSON)

-- ════════════════════════════════════════════════════════════════════════════
-- Rust Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data Rust = Rust
    { image :: Maybe Text
    , rustc :: Tool
    , cargo :: Tool
    , edition :: Text -- Default edition
    , target :: Text -- Target triple
    }
    deriving stock (Show, Generic)
    deriving anyclass (FromDhall, FromJSON, ToJSON)

-- ════════════════════════════════════════════════════════════════════════════
-- Haskell Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data Haskell = Haskell
    { image :: Maybe Text
    , ghc :: Tool
    , ghc_pkg :: Tool
    , paths :: Paths -- Package DB, lib paths
    }
    deriving stock (Show, Generic)
    deriving anyclass (FromDhall, FromJSON, ToJSON)

-- ════════════════════════════════════════════════════════════════════════════
-- Lean Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data Lean = Lean
    { image :: Maybe Text
    , lean :: Tool
    , leanc :: Tool
    , paths :: Paths
    }
    deriving stock (Show, Generic)
    deriving anyclass (FromDhall, FromJSON, ToJSON)

-- ════════════════════════════════════════════════════════════════════════════
-- PureScript Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data PureScript = PureScript
    { image :: Maybe Text
    , purs :: Tool
    , spago :: Tool
    , node :: Tool
    , esbuild :: Tool
    }
    deriving stock (Show, Generic)
    deriving anyclass (FromDhall, FromJSON, ToJSON)

-- ════════════════════════════════════════════════════════════════════════════
-- Complete Toolchains
-- ════════════════════════════════════════════════════════════════════════════

data Toolchains = Toolchains
    { cxx :: Cxx
    , nv :: Maybe Nv
    , rust :: Rust
    , haskell :: Haskell
    , lean :: Lean
    , purescript :: PureScript
    }
    deriving stock (Show, Generic)
    deriving anyclass (FromDhall, FromJSON, ToJSON)

-- ════════════════════════════════════════════════════════════════════════════
-- Loading
-- ════════════════════════════════════════════════════════════════════════════

-- | Default path to toolchains config
defaultToolchainsPath :: FilePath -> FilePath
defaultToolchainsPath projectRoot = projectRoot </> ".sensenet" </> "toolchains.dhall"

{- | Load toolchains with caching
If .sensenet/toolchains.json exists and is newer than toolchains.dhall,
load from JSON (~1ms). Otherwise parse Dhall and cache to JSON (~50ms).
-}
loadToolchains :: FilePath -> IO Toolchains
loadToolchains dhallPath = do
    let jsonPath = replaceExtension dhallPath ".json"
    jsonExists <- doesFileExist jsonPath
    dhallExists <- doesFileExist dhallPath

    if not dhallExists
        then error $ "Toolchains file not found: " <> dhallPath
        else
            if jsonExists
                then do
                    -- Check if JSON cache is newer than Dhall source
                    dhallMtime <- getModificationTime dhallPath
                    jsonMtime <- getModificationTime jsonPath
                    if jsonMtime > dhallMtime
                        then loadFromJson jsonPath
                        else reparse dhallPath jsonPath
                else reparse dhallPath jsonPath
  where
    loadFromJson :: FilePath -> IO Toolchains
    loadFromJson jsonPath = do
        result <- eitherDecodeFileStrict' jsonPath
        case result of
            Right tc -> pure tc
            Left _ -> do
                -- JSON corrupted, re-parse from Dhall
                let dhallPath' = replaceExtension jsonPath ".dhall"
                reparse dhallPath' jsonPath

    reparse :: FilePath -> FilePath -> IO Toolchains
    reparse dhallPath' jsonPath = do
        tc <- inputFile auto dhallPath'
        encodeFile jsonPath tc
        pure tc
