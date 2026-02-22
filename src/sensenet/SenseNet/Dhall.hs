{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}

-- |
-- Module      : SenseNet.Dhall
-- Description : Parse BUILD.dhall files into the internal representation
--
-- Uses the dhall Haskell library to evaluate Dhall files and decode them
-- into typed IR values.
--
-- BUILD.dhall format:
--   { targets : List Rule }
--
-- Where Rule is a union type matching SenseNet.IR.Rule.
module SenseNet.Dhall
  ( parsePackageFile,
    BuildFile (..),
  )
where

import Data.Text (Text)
import Dhall (FromDhall, auto, inputFile)
import GHC.Generics (Generic)
import SenseNet.IR qualified as IR
import System.FilePath (makeRelative, takeDirectory)

-- ════════════════════════════════════════════════════════════════════════════
-- Dhall Decodable Types
--
-- These mirror the Dhall schema and derive FromDhall automatically.
-- We then convert to the IR types.
-- ════════════════════════════════════════════════════════════════════════════

-- | The top-level BUILD.dhall structure
data BuildFile = BuildFile
  { targets :: [DhallRule]
  }
  deriving (Show, Generic)

instance FromDhall BuildFile

-- | Extract targets from BuildFile
buildFileTargets :: BuildFile -> [DhallRule]
buildFileTargets (BuildFile ts) = ts

-- | Dependency (matches dhall/prelude/Types.dhall Dep)
-- Constructors must be in alphabetical order for FromDhall
data DhallDep
  = Flake Text
  | Local Text
  deriving (Show, Generic)

instance FromDhall DhallDep

-- | Visibility
-- Constructors must be in alphabetical order for FromDhall
data DhallVis = Private | Public
  deriving (Show, Generic)

instance FromDhall DhallVis

-- | C++ standard
data DhallCxxStd = Cxx11 | Cxx14 | Cxx17 | Cxx20 | Cxx23
  deriving (Show, Generic)

instance FromDhall DhallCxxStd

-- | Rust edition
data DhallRustEdition = E2015 | E2018 | E2021 | E2024
  deriving (Show, Generic)

instance FromDhall DhallRustEdition

-- | PureScript SrcSpec
-- Constructors must be in alphabetical order for FromDhall
data DhallSrcSpec
  = Explicit [Text]
  | Glob Text
  | Globs [Text]
  deriving (Show, Generic)

instance FromDhall DhallSrcSpec

-- ════════════════════════════════════════════════════════════════════════════
-- Individual Rule Types
-- ════════════════════════════════════════════════════════════════════════════

data DhallCxxBinary = DhallCxxBinary
  { name :: Text,
    srcs :: [Text],
    deps :: [DhallDep],
    std :: DhallCxxStd,
    cflags :: [Text],
    ldflags :: [Text],
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallCxxBinary

data DhallCxxLibrary = DhallCxxLibrary
  { name :: Text,
    srcs :: [Text],
    hdrs :: [Text],
    deps :: [DhallDep],
    std :: DhallCxxStd,
    cflags :: [Text],
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallCxxLibrary

data DhallRustBinary = DhallRustBinary
  { name :: Text,
    srcs :: [Text],
    deps :: [DhallDep],
    edition :: DhallRustEdition,
    features :: [Text],
    rustflags :: [Text],
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallRustBinary

data DhallRustLibrary = DhallRustLibrary
  { name :: Text,
    srcs :: [Text],
    deps :: [DhallDep],
    edition :: DhallRustEdition,
    crate_name :: Maybe Text,
    features :: [Text],
    proc_macro :: Bool,
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallRustLibrary

data DhallHaskellBinary = DhallHaskellBinary
  { name :: Text,
    srcs :: [Text],
    main :: Text,
    packages :: [Text],
    language_extensions :: [Text],
    ghc_options :: [Text],
    deps :: [DhallDep],
    extra_libs :: [Text],
    extra_lib_dirs :: [Text],
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallHaskellBinary

data DhallHaskellLibrary = DhallHaskellLibrary
  { name :: Text,
    srcs :: [Text],
    packages :: [Text],
    language_extensions :: [Text],
    ghc_options :: [Text],
    deps :: [DhallDep],
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallHaskellLibrary

data DhallHaskellFFIBinary = DhallHaskellFFIBinary
  { name :: Text,
    hs_srcs :: [Text],
    cxx_srcs :: [Text],
    cxx_headers :: [Text],
    packages :: [Text],
    deps :: [DhallDep],
    language_extensions :: [Text],
    ghc_options :: [Text],
    extra_libs :: [Text],
    extra_lib_dirs :: [Text],
    include_dirs :: [Text],
    linker_flags :: [Text],
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallHaskellFFIBinary

data DhallLeanBinary = DhallLeanBinary
  { name :: Text,
    srcs :: [Text],
    deps :: [DhallDep],
    root_module :: Maybe Text,
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallLeanBinary

data DhallLeanLibrary = DhallLeanLibrary
  { name :: Text,
    srcs :: [Text],
    deps :: [DhallDep],
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallLeanLibrary

data DhallNvBinary = DhallNvBinary
  { name :: Text,
    srcs :: [Text],
    deps :: [DhallDep],
    archs :: [Text],
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallNvBinary

data DhallNvLibrary = DhallNvLibrary
  { name :: Text,
    srcs :: [Text],
    exported_headers :: [Text],
    deps :: [DhallDep],
    archs :: [Text],
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallNvLibrary

data DhallPureScriptApp = DhallPureScriptApp
  { name :: Text,
    srcs :: DhallSrcSpec,
    deps :: [Text], -- Direct dependencies (package names)
    package_set :: Text, -- Package set version (e.g., "psc-0.15.15-20240416")
    main :: Text,
    index_html :: Maybe Text,
    style_css :: Maybe Text,
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallPureScriptApp

data DhallPureScriptBinary = DhallPureScriptBinary
  { name :: Text,
    srcs :: DhallSrcSpec,
    spago_yaml :: Text,
    main :: Text,
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallPureScriptBinary

data DhallPureScriptLibrary = DhallPureScriptLibrary
  { name :: Text,
    srcs :: DhallSrcSpec,
    spago_yaml :: Maybe Text,
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallPureScriptLibrary

data DhallGenrule = DhallGenrule
  { name :: Text,
    srcs :: [Text],
    out :: Text,
    cmd :: Text,
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallGenrule

data DhallNixCxxBinary = DhallNixCxxBinary
  { name :: Text,
    srcs :: [Text],
    nix_deps :: [Text],
    deps :: [Text],
    compiler_flags :: [Text],
    linker_flags :: [Text],
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallNixCxxBinary

data DhallCratesIo = DhallCratesIo
  { name :: Text,
    version :: Text,
    sha256 :: Text,
    features :: [Text],
    deps :: [Text],
    proc_macro :: Bool,
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallCratesIo

data DhallHttpArchive = DhallHttpArchive
  { name :: Text,
    url :: Text,
    sha256 :: Text,
    strip_prefix :: Maybe Text,
    vis :: DhallVis
  }
  deriving (Show, Generic)

instance FromDhall DhallHttpArchive

-- ════════════════════════════════════════════════════════════════════════════
-- Rule Union
-- Constructors MUST be in alphabetical order for FromDhall to work correctly
-- ════════════════════════════════════════════════════════════════════════════

data DhallRule
  = CratesIo DhallCratesIo
  | CxxBinary DhallCxxBinary
  | CxxLibrary DhallCxxLibrary
  | Genrule DhallGenrule
  | HaskellBinary DhallHaskellBinary
  | HaskellFFIBinary DhallHaskellFFIBinary
  | HaskellLibrary DhallHaskellLibrary
  | HttpArchive DhallHttpArchive
  | LeanBinary DhallLeanBinary
  | LeanLibrary DhallLeanLibrary
  | NixCxxBinary DhallNixCxxBinary
  | NvBinary DhallNvBinary
  | NvLibrary DhallNvLibrary
  | PureScriptApp DhallPureScriptApp
  | PureScriptBinary DhallPureScriptBinary
  | PureScriptLibrary DhallPureScriptLibrary
  | RustBinary DhallRustBinary
  | RustLibrary DhallRustLibrary
  deriving (Show, Generic)

instance FromDhall DhallRule

-- ════════════════════════════════════════════════════════════════════════════
-- Conversion to IR
-- ════════════════════════════════════════════════════════════════════════════

toIRDep :: DhallDep -> IR.Dep
toIRDep = \case
  Flake t -> IR.DepFlake t
  Local t -> IR.DepLocal t

toIRVis :: DhallVis -> IR.Vis
toIRVis = \case
  Private -> IR.Private
  Public -> IR.Public

toIRCxxStd :: DhallCxxStd -> IR.CxxStd
toIRCxxStd = \case
  Cxx11 -> IR.Cxx11
  Cxx14 -> IR.Cxx14
  Cxx17 -> IR.Cxx17
  Cxx20 -> IR.Cxx20
  Cxx23 -> IR.Cxx23

toIRRustEdition :: DhallRustEdition -> IR.RustEdition
toIRRustEdition = \case
  E2015 -> IR.E2015
  E2018 -> IR.E2018
  E2021 -> IR.E2021
  E2024 -> IR.E2024

toIRSrcSpec :: DhallSrcSpec -> IR.SrcSpec
toIRSrcSpec = \case
  Explicit xs -> IR.SrcExplicit xs
  Glob p -> IR.SrcGlob p
  Globs ps -> IR.SrcGlobs ps

toIRRule :: DhallRule -> IR.Rule
toIRRule = \case
  CxxBinary r ->
    IR.RCxxBinary
      IR.CxxBinary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.deps = map toIRDep r.deps,
          IR.std = toIRCxxStd r.std,
          IR.cflags = r.cflags,
          IR.ldflags = r.ldflags,
          IR.vis = toIRVis r.vis
        }
  CxxLibrary r ->
    IR.RCxxLibrary
      IR.CxxLibrary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.hdrs = r.hdrs,
          IR.deps = map toIRDep r.deps,
          IR.std = toIRCxxStd r.std,
          IR.cflags = r.cflags,
          IR.vis = toIRVis r.vis
        }
  RustBinary r ->
    IR.RRustBinary
      IR.RustBinary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.deps = map toIRDep r.deps,
          IR.edition = toIRRustEdition r.edition,
          IR.vis = toIRVis r.vis
        }
  RustLibrary r ->
    IR.RRustLibrary
      IR.RustLibrary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.deps = map toIRDep r.deps,
          IR.edition = toIRRustEdition r.edition,
          IR.crateName = r.crate_name,
          IR.procMacro = r.proc_macro,
          IR.features = r.features,
          IR.vis = toIRVis r.vis
        }
  HaskellBinary r ->
    IR.RHaskellBinary
      IR.HaskellBinary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.main = r.main,
          IR.packages = r.packages,
          IR.languageExtensions = r.language_extensions,
          IR.ghcOptions = r.ghc_options,
          IR.deps = map toIRDep r.deps,
          IR.extraLibs = r.extra_libs,
          IR.extraLibDirs = r.extra_lib_dirs,
          IR.vis = toIRVis r.vis
        }
  HaskellLibrary r ->
    IR.RHaskellLibrary
      IR.HaskellLibrary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.packages = r.packages,
          IR.languageExtensions = r.language_extensions,
          IR.ghcOptions = r.ghc_options,
          IR.deps = map toIRDep r.deps,
          IR.vis = toIRVis r.vis
        }
  HaskellFFIBinary r ->
    IR.RHaskellFFIBinary
      IR.HaskellFFIBinary
        { IR.name = r.name,
          IR.hsSrcs = r.hs_srcs,
          IR.cxxSrcs = r.cxx_srcs,
          IR.cxxHeaders = r.cxx_headers,
          IR.packages = r.packages,
          IR.deps = map toIRDep r.deps,
          IR.languageExtensions = r.language_extensions,
          IR.ghcOptions = r.ghc_options,
          IR.extraLibs = r.extra_libs,
          IR.extraLibDirs = r.extra_lib_dirs,
          IR.includeDirs = r.include_dirs,
          IR.linkerFlags = r.linker_flags,
          IR.vis = toIRVis r.vis
        }
  LeanBinary r ->
    IR.RLeanBinary
      IR.LeanBinary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.deps = map toIRDep r.deps,
          IR.rootModule = r.root_module,
          IR.vis = toIRVis r.vis
        }
  LeanLibrary r ->
    IR.RLeanLibrary
      IR.LeanLibrary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.deps = map toIRDep r.deps,
          IR.vis = toIRVis r.vis
        }
  NvBinary r ->
    IR.RNvBinary
      IR.NvBinary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.deps = map toIRDep r.deps,
          IR.archs = r.archs,
          IR.vis = toIRVis r.vis
        }
  NvLibrary r ->
    IR.RNvLibrary
      IR.NvLibrary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.exportedHeaders = r.exported_headers,
          IR.deps = map toIRDep r.deps,
          IR.archs = r.archs,
          IR.vis = toIRVis r.vis
        }
  PureScriptApp r ->
    IR.RPureScriptApp
      IR.PureScriptApp
        { IR.name = r.name,
          IR.srcs = toIRSrcSpec r.srcs,
          IR.deps = r.deps,
          IR.packageSet = r.package_set,
          IR.main = r.main,
          IR.indexHtml = r.index_html,
          IR.styleCss = r.style_css,
          IR.vis = toIRVis r.vis
        }
  PureScriptBinary r ->
    IR.RPureScriptBinary
      IR.PureScriptBinary
        { IR.name = r.name,
          IR.srcs = toIRSrcSpec r.srcs,
          IR.spagoYaml = r.spago_yaml,
          IR.main = r.main,
          IR.vis = toIRVis r.vis
        }
  PureScriptLibrary r ->
    IR.RPureScriptLibrary
      IR.PureScriptLibrary
        { IR.name = r.name,
          IR.srcs = toIRSrcSpec r.srcs,
          IR.spagoYaml = r.spago_yaml,
          IR.vis = toIRVis r.vis
        }
  Genrule r ->
    IR.RGenrule
      IR.Genrule
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.out = r.out,
          IR.cmd = r.cmd,
          IR.vis = toIRVis r.vis
        }
  NixCxxBinary r ->
    IR.RNixCxxBinary
      IR.NixCxxBinary
        { IR.name = r.name,
          IR.srcs = r.srcs,
          IR.nixDeps = r.nix_deps,
          IR.deps = r.deps,
          IR.compilerFlags = r.compiler_flags,
          IR.linkerFlags = r.linker_flags,
          IR.vis = toIRVis r.vis
        }
  CratesIo r ->
    IR.RCratesIo
      IR.CratesIo
        { IR.name = r.name,
          IR.version = r.version,
          IR.sha256 = r.sha256,
          IR.features = r.features,
          IR.deps = r.deps,
          IR.procMacro = r.proc_macro,
          IR.vis = toIRVis r.vis
        }
  HttpArchive r ->
    IR.RHttpArchive
      IR.HttpArchive
        { IR.name = r.name,
          IR.url = r.url,
          IR.sha256 = r.sha256,
          IR.stripPrefix = r.strip_prefix,
          IR.vis = toIRVis r.vis
        }

-- ════════════════════════════════════════════════════════════════════════════
-- Public API
-- ════════════════════════════════════════════════════════════════════════════

-- | Parse a BUILD.dhall file and return a Package
parsePackageFile :: FilePath -> FilePath -> IO IR.Package
parsePackageFile projectRoot dhallPath = do
  let relPath = makeRelative projectRoot (takeDirectory dhallPath)
  buildFile <- inputFile auto dhallPath :: IO BuildFile
  pure
    IR.Package
      { IR.path = relPath,
        IR.rules = map toIRRule (buildFileTargets buildFile)
      }
