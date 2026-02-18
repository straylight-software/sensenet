{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

-- |
-- Module      : SenseNet.Toolchains
-- Description : Parse .sensenet/toolchains.dhall for compiler/linker paths
--
-- A toolchain is defined by what a remote execution container needs:
-- - A container image (for RE) or None (for local Nix)
-- - Executables at absolute paths
-- - Include paths for headers
-- - Library paths for linking
--
-- This same shape works for local and remote execution.
module SenseNet.Toolchains
  ( Toolchains (..),
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

import Data.Text (Text)
import Dhall (FromDhall, auto, inputFile)
import GHC.Generics (Generic)
import System.FilePath ((</>))

-- ════════════════════════════════════════════════════════════════════════════
-- Core Types
-- ════════════════════════════════════════════════════════════════════════════

-- | A single executable tool
data Tool = Tool
  { path :: Text
  }
  deriving (Show, Generic)

instance FromDhall Tool

-- | Include/library search paths
data Paths = Paths
  { includes :: [Text],
    libs :: [Text]
  }
  deriving (Show, Generic)

instance FromDhall Paths

-- ════════════════════════════════════════════════════════════════════════════
-- C++ Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data Cxx = Cxx
  { image :: Maybe Text, -- Container image (Nothing = local)
    cc :: Tool, -- C compiler
    cxx :: Tool, -- C++ compiler
    ar :: Tool, -- Archiver
    ld :: Tool, -- Linker
    paths :: Paths, -- Search paths
    sysroot :: Text, -- Sysroot (for cross-compilation)
    target :: Text -- Target triple
  }
  deriving (Show, Generic)

instance FromDhall Cxx

-- ════════════════════════════════════════════════════════════════════════════
-- NVIDIA Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data Nv = Nv
  { image :: Maybe Text, -- Container image (Nothing = local)
    clang :: Tool, -- Clang with CUDA support
    ptxas :: Tool, -- PTX assembler
    fatbinary :: Tool, -- Fat binary tool
    sdk_path :: Text, -- NVIDIA SDK root (for --cuda-path)
    sdk :: Paths, -- CUDA SDK include/lib paths
    archs :: [Text], -- Target SM architectures
    cxx :: Cxx -- C++ toolchain (for stdlib)
  }
  deriving (Show, Generic)

instance FromDhall Nv

-- ════════════════════════════════════════════════════════════════════════════
-- Rust Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data Rust = Rust
  { image :: Maybe Text,
    rustc :: Tool,
    cargo :: Tool,
    edition :: Text, -- Default edition
    target :: Text -- Target triple
  }
  deriving (Show, Generic)

instance FromDhall Rust

-- ════════════════════════════════════════════════════════════════════════════
-- Haskell Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data Haskell = Haskell
  { image :: Maybe Text,
    ghc :: Tool,
    ghc_pkg :: Tool,
    paths :: Paths -- Package DB, lib paths
  }
  deriving (Show, Generic)

instance FromDhall Haskell

-- ════════════════════════════════════════════════════════════════════════════
-- Lean Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data Lean = Lean
  { image :: Maybe Text,
    lean :: Tool,
    leanc :: Tool,
    paths :: Paths
  }
  deriving (Show, Generic)

instance FromDhall Lean

-- ════════════════════════════════════════════════════════════════════════════
-- PureScript Toolchain
-- ════════════════════════════════════════════════════════════════════════════

data PureScript = PureScript
  { image :: Maybe Text,
    purs :: Tool,
    spago :: Tool,
    node :: Tool,
    esbuild :: Tool
  }
  deriving (Show, Generic)

instance FromDhall PureScript

-- ════════════════════════════════════════════════════════════════════════════
-- Complete Toolchains
-- ════════════════════════════════════════════════════════════════════════════

data Toolchains = Toolchains
  { cxx :: Cxx,
    nv :: Maybe Nv,
    rust :: Rust,
    haskell :: Haskell,
    lean :: Lean,
    purescript :: PureScript
  }
  deriving (Show, Generic)

instance FromDhall Toolchains

-- ════════════════════════════════════════════════════════════════════════════
-- Loading
-- ════════════════════════════════════════════════════════════════════════════

-- | Default path to toolchains config
defaultToolchainsPath :: FilePath -> FilePath
defaultToolchainsPath projectRoot = projectRoot </> ".sensenet" </> "toolchains.dhall"

-- | Load toolchains from a Dhall file
loadToolchains :: FilePath -> IO Toolchains
loadToolchains = inputFile auto
