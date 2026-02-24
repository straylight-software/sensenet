{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

{- |
Module      : SenseNet.IR
Description : Internal representation — the typed build graph

This is the source of truth. sensenet reads BUILD.dhall files, constructs
this typed representation, then emits the Buck2 fiction from it.

Types mirror dhall/prelude/ but are native Haskell — no Dhall evaluation
at query time.
-}
module SenseNet.IR (
    -- * Core types
    Dep (..),
    Vis (..),
    CxxStd (..),
    RustEdition (..),

    -- * Rules
    CxxBinary (..),
    CxxLibrary (..),
    RustBinary (..),
    RustLibrary (..),
    HaskellBinary (..),
    HaskellLibrary (..),
    HaskellFFIBinary (..),
    LeanBinary (..),
    LeanLibrary (..),
    NvBinary (..),
    NvLibrary (..),
    PureScriptApp (..),
    PureScriptBinary (..),
    PureScriptLibrary (..),
    SrcSpec (..),
    Genrule (..),
    NixCxxBinary (..),
    CratesIo (..),
    HttpArchive (..),
    Rule (..),

    -- * Toolchains
    CxxToolchain (..),
    HaskellToolchain (..),
    RustToolchain (..),
    LeanToolchain (..),
    NvToolchain (..),
    PureScriptToolchain (..),
    ExecutionPlatform (..),
    PythonBootstrap (..),
    GenruleToolchain (..),
    Toolchain (..),

    -- * Build graph
    Package (..),
    BuildGraph (..),

    -- * Utilities
    ruleName,
    ruleVis,
    ruleDeps,
)
where

import Data.Text (Text)

-- ════════════════════════════════════════════════════════════════════════════
-- Core Types
-- ════════════════════════════════════════════════════════════════════════════

-- | Dependency reference
data Dep
    = -- | ":foo" or "//pkg:foo"
      DepLocal Text
    | -- | "nixpkgs#openssl.dev"
      DepFlake Text
    deriving (Show, Eq)

-- | Visibility
data Vis = Public | Private
    deriving (Show, Eq)

-- | C++ standard
data CxxStd = Cxx11 | Cxx14 | Cxx17 | Cxx20 | Cxx23
    deriving (Show, Eq)

-- | Rust edition
data RustEdition = E2015 | E2018 | E2021 | E2024
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- C++ Rules
-- ════════════════════════════════════════════════════════════════════════════

data CxxBinary = CxxBinary
    { name :: Text
    , srcs :: [Text]
    , deps :: [Dep]
    , std :: CxxStd
    , cflags :: [Text]
    , ldflags :: [Text]
    , vis :: Vis
    }
    deriving (Show, Eq)

data CxxLibrary = CxxLibrary
    { name :: Text
    , srcs :: [Text]
    , hdrs :: [Text]
    , deps :: [Dep]
    , std :: CxxStd
    , cflags :: [Text]
    , vis :: Vis
    }
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Rust Rules
-- ════════════════════════════════════════════════════════════════════════════

data RustBinary = RustBinary
    { name :: Text
    , srcs :: [Text]
    , deps :: [Dep]
    , edition :: RustEdition
    , vis :: Vis
    }
    deriving (Show, Eq)

data RustLibrary = RustLibrary
    { name :: Text
    , srcs :: [Text]
    , deps :: [Dep]
    , edition :: RustEdition
    , crateName :: Maybe Text
    , procMacro :: Bool
    , features :: [Text]
    , vis :: Vis
    }
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Haskell Rules
-- ════════════════════════════════════════════════════════════════════════════

data HaskellBinary = HaskellBinary
    { name :: Text
    , srcs :: [Text]
    , main :: Text
    , packages :: [Text]
    , languageExtensions :: [Text]
    , ghcOptions :: [Text]
    , deps :: [Dep]
    , extraLibs :: [Text]
    , extraLibDirs :: [Text]
    , vis :: Vis
    }
    deriving (Show, Eq)

data HaskellLibrary = HaskellLibrary
    { name :: Text
    , srcs :: [Text]
    , packages :: [Text]
    , languageExtensions :: [Text]
    , ghcOptions :: [Text]
    , deps :: [Dep]
    , vis :: Vis
    }
    deriving (Show, Eq)

data HaskellFFIBinary = HaskellFFIBinary
    { name :: Text
    , hsSrcs :: [Text]
    , cxxSrcs :: [Text]
    , cxxHeaders :: [Text]
    , packages :: [Text]
    , deps :: [Dep]
    , languageExtensions :: [Text]
    , ghcOptions :: [Text]
    , extraLibs :: [Text]
    , extraLibDirs :: [Text]
    , includeDirs :: [Text]
    , linkerFlags :: [Text]
    , vis :: Vis
    }
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Lean Rules
-- ════════════════════════════════════════════════════════════════════════════

data LeanBinary = LeanBinary
    { name :: Text
    , srcs :: [Text]
    , deps :: [Dep]
    , rootModule :: Maybe Text
    , vis :: Vis
    }
    deriving (Show, Eq)

data LeanLibrary = LeanLibrary
    { name :: Text
    , srcs :: [Text]
    , deps :: [Dep]
    , vis :: Vis
    }
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- NVIDIA/CUDA Rules
-- ════════════════════════════════════════════════════════════════════════════

data NvBinary = NvBinary
    { name :: Text
    , srcs :: [Text]
    , deps :: [Dep]
    , archs :: [Text]
    , vis :: Vis
    }
    deriving (Show, Eq)

data NvLibrary = NvLibrary
    { name :: Text
    , srcs :: [Text]
    , exportedHeaders :: [Text]
    , deps :: [Dep]
    , archs :: [Text]
    , vis :: Vis
    }
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- PureScript Rules
-- ════════════════════════════════════════════════════════════════════════════

data SrcSpec
    = SrcExplicit [Text]
    | SrcGlob Text
    | SrcGlobs [Text]
    deriving (Show, Eq)

data PureScriptApp = PureScriptApp
    { name :: Text
    , srcs :: SrcSpec
    , deps :: [Text] -- Direct dependencies (package names)
    , packageSet :: Text -- Package set version (e.g., "psc-0.15.15-20240416")
    , main :: Text
    , indexHtml :: Maybe Text
    , styleCss :: Maybe Text
    , vis :: Vis
    }
    deriving (Show, Eq)

data PureScriptBinary = PureScriptBinary
    { name :: Text
    , srcs :: SrcSpec
    , spagoYaml :: Text
    , main :: Text
    , vis :: Vis
    }
    deriving (Show, Eq)

data PureScriptLibrary = PureScriptLibrary
    { name :: Text
    , srcs :: SrcSpec
    , spagoYaml :: Maybe Text
    , vis :: Vis
    }
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Genrule
-- ════════════════════════════════════════════════════════════════════════════

data Genrule = Genrule
    { name :: Text
    , srcs :: [Text]
    , out :: Text
    , cmd :: Text
    , vis :: Vis
    }
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Nix C++ Rules
-- ════════════════════════════════════════════════════════════════════════════

data NixCxxBinary = NixCxxBinary
    { name :: Text
    , srcs :: [Text]
    , nixDeps :: [Text] -- Flake refs like "nixpkgs#zlib"
    , deps :: [Text] -- Regular Buck2 deps
    , compilerFlags :: [Text]
    , linkerFlags :: [Text]
    , vis :: Vis
    }
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Rust Crate Rules
-- ════════════════════════════════════════════════════════════════════════════

data CratesIo = CratesIo
    { name :: Text
    , version :: Text
    , sha256 :: Text
    , features :: [Text]
    , deps :: [Text]
    , procMacro :: Bool
    , vis :: Vis
    }
    deriving (Show, Eq)

data HttpArchive = HttpArchive
    { name :: Text
    , url :: Text
    , sha256 :: Text
    , stripPrefix :: Maybe Text
    , vis :: Vis
    }
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Rule Union
-- ════════════════════════════════════════════════════════════════════════════

data Rule
    = RCxxBinary CxxBinary
    | RCxxLibrary CxxLibrary
    | RRustBinary RustBinary
    | RRustLibrary RustLibrary
    | RHaskellBinary HaskellBinary
    | RHaskellLibrary HaskellLibrary
    | RHaskellFFIBinary HaskellFFIBinary
    | RLeanBinary LeanBinary
    | RLeanLibrary LeanLibrary
    | RNvBinary NvBinary
    | RNvLibrary NvLibrary
    | RPureScriptApp PureScriptApp
    | RPureScriptBinary PureScriptBinary
    | RPureScriptLibrary PureScriptLibrary
    | RGenrule Genrule
    | RNixCxxBinary NixCxxBinary
    | RCratesIo CratesIo
    | RHttpArchive HttpArchive
    deriving (Show, Eq)

-- | Extract rule name
ruleName :: Rule -> Text
ruleName = \case
    RCxxBinary r -> r.name
    RCxxLibrary r -> r.name
    RRustBinary r -> r.name
    RRustLibrary r -> r.name
    RHaskellBinary r -> r.name
    RHaskellLibrary r -> r.name
    RHaskellFFIBinary r -> r.name
    RLeanBinary r -> r.name
    RLeanLibrary r -> r.name
    RNvBinary r -> r.name
    RNvLibrary r -> r.name
    RPureScriptApp r -> r.name
    RPureScriptBinary r -> r.name
    RPureScriptLibrary r -> r.name
    RGenrule r -> r.name
    RNixCxxBinary r -> r.name
    RCratesIo r -> r.name
    RHttpArchive r -> r.name

-- | Extract rule visibility
ruleVis :: Rule -> Vis
ruleVis = \case
    RCxxBinary r -> r.vis
    RCxxLibrary r -> r.vis
    RRustBinary r -> r.vis
    RRustLibrary r -> r.vis
    RHaskellBinary r -> r.vis
    RHaskellLibrary r -> r.vis
    RHaskellFFIBinary r -> r.vis
    RLeanBinary r -> r.vis
    RLeanLibrary r -> r.vis
    RNvBinary r -> r.vis
    RNvLibrary r -> r.vis
    RPureScriptApp r -> r.vis
    RPureScriptBinary r -> r.vis
    RPureScriptLibrary r -> r.vis
    RGenrule r -> r.vis
    RNixCxxBinary r -> r.vis
    RCratesIo r -> r.vis
    RHttpArchive r -> r.vis

-- | Extract rule dependencies (local only)
ruleDeps :: Rule -> [Dep]
ruleDeps = \case
    RCxxBinary r -> r.deps
    RCxxLibrary r -> r.deps
    RRustBinary r -> r.deps
    RRustLibrary r -> r.deps
    RHaskellBinary r -> r.deps
    RHaskellLibrary r -> r.deps
    RHaskellFFIBinary r -> r.deps
    RLeanBinary _ -> []
    RLeanLibrary _ -> []
    RNvBinary _ -> []
    RNvLibrary _ -> []
    RPureScriptApp _ -> []
    RPureScriptBinary _ -> []
    RPureScriptLibrary _ -> []
    RGenrule _ -> []
    RNixCxxBinary _ -> [] -- Nix deps are Text, not Dep
    RCratesIo r -> map DepLocal r.deps -- Convert Text deps to DepLocal
    RHttpArchive _ -> []

-- ════════════════════════════════════════════════════════════════════════════
-- Toolchains
-- ════════════════════════════════════════════════════════════════════════════

data CxxToolchain = CxxToolchain
    { name :: Text
    , cExtraFlags :: [Text]
    , cxxExtraFlags :: [Text]
    , linkFlags :: [Text]
    , linkStyle :: Text
    , vis :: Vis
    }
    deriving (Show, Eq)

data HaskellToolchain = HaskellToolchain
    { name :: Text
    , compilerFlags :: [Text]
    , vis :: Vis
    }
    deriving (Show, Eq)

data RustToolchain = RustToolchain
    { name :: Text
    , defaultEdition :: Text
    , rustcFlags :: [Text]
    , vis :: Vis
    }
    deriving (Show, Eq)

data LeanToolchain = LeanToolchain
    { name :: Text
    , vis :: Vis
    }
    deriving (Show, Eq)

data NvToolchain = NvToolchain
    { name :: Text
    , nvArchs :: [Text]
    , nvidiaSdkPath :: Text
    , nvidiaSdkInclude :: Text
    , nvidiaSdkLib :: Text
    , vis :: Vis
    }
    deriving (Show, Eq)

data PureScriptToolchain = PureScriptToolchain
    { name :: Text
    , vis :: Vis
    }
    deriving (Show, Eq)

data ExecutionPlatform = ExecutionPlatform
    { name :: Text
    , localEnabled :: Bool
    , remoteEnabled :: Bool
    , vis :: Vis
    }
    deriving (Show, Eq)

data PythonBootstrap = PythonBootstrap
    { name :: Text
    , vis :: Vis
    }
    deriving (Show, Eq)

data GenruleToolchain = GenruleToolchain
    { name :: Text
    , vis :: Vis
    }
    deriving (Show, Eq)

-- | Toolchain union
data Toolchain
    = TCxx CxxToolchain
    | THaskell HaskellToolchain
    | TRust RustToolchain
    | TLean LeanToolchain
    | TNv NvToolchain
    | TPureScript PureScriptToolchain
    | TExecution ExecutionPlatform
    | TPython PythonBootstrap
    | TGenrule GenruleToolchain
    deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Build Graph
-- ════════════════════════════════════════════════════════════════════════════

-- | A package is a directory containing a BUILD.dhall
data Package = Package
    { path :: FilePath
    -- ^ Relative path from project root
    , rules :: [Rule]
    }
    deriving (Show, Eq)

-- | The complete build graph
data BuildGraph = BuildGraph
    { packages :: [Package]
    , toolchains :: [Toolchain]
    }
    deriving (Show, Eq)
