{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : SenseNet.Emit
Description : Emit Starlark from the internal representation

Generates BUCK files and .bzl toolchain definitions from the typed IR.
This is the "fiction generator" — it produces exactly what Buck2 needs to see.

The output is ephemeral; it exists only to extract DICE + TUI behavior from Buck2.
-}
module SenseNet.Emit
  ( -- * BUCK emission
    emitBuck
  , emitRule
  
    -- * Toolchain emission
  , emitToolchain
  , emitToolchainsBuck
  
    -- * Utilities
  , emitVis
  , emitCxxStd
  , emitRustEdition
  , emitSrcSpec
  , quote
  , list
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import SenseNet.IR

-- ════════════════════════════════════════════════════════════════════════════
-- Utilities
-- ════════════════════════════════════════════════════════════════════════════

quote :: Text -> Text
quote t = "\"" <> t <> "\""

list :: [Text] -> Text
list xs = "[" <> T.intercalate ", " (map quote xs) <> "]"

emitVis :: Vis -> Text
emitVis Public = "[\"PUBLIC\"]"
emitVis Private = "[]"

emitCxxStd :: CxxStd -> Text
emitCxxStd = \case
  Cxx11 -> "-std=c++11"
  Cxx14 -> "-std=c++14"
  Cxx17 -> "-std=c++17"
  Cxx20 -> "-std=c++20"
  Cxx23 -> "-std=c++23"

emitRustEdition :: RustEdition -> Text
emitRustEdition = \case
  E2015 -> "2015"
  E2018 -> "2018"
  E2021 -> "2021"
  E2024 -> "2024"

emitSrcSpec :: SrcSpec -> Text
emitSrcSpec = \case
  SrcExplicit xs -> list xs
  SrcGlob pattern -> "glob([" <> quote pattern <> "])"
  SrcGlobs patterns -> T.intercalate " + " $ map (\p -> "glob([" <> quote p <> "])") patterns

-- | Extract local deps only (flake deps are resolved separately)
localDeps :: [Dep] -> [Text]
localDeps = concatMap $ \case
  DepLocal t -> [t]
  DepFlake _ -> []

-- ════════════════════════════════════════════════════════════════════════════
-- BUCK Emission
-- ════════════════════════════════════════════════════════════════════════════

-- | Emit a complete BUCK file for a package
emitBuck :: Package -> Text
emitBuck pkg = 
  let rules = pkg.rules
      loads = collectLoads rules
      loadsText = if null loads then "" else T.unlines loads <> "\n"
  in loadsText <> T.unlines (map emitRule rules)

-- | Collect required load() statements based on rule types
collectLoads :: [Rule] -> [Text]
collectLoads rules = 
  let needed = map ruleLoad rules
      -- De-duplicate and sort
      unique = nub $ concat needed
  in unique
  where
    nub [] = []
    nub (x:xs) = x : nub (filter (/= x) xs)

-- | Get required load statement for a rule type
ruleLoad :: Rule -> [Text]
ruleLoad = \case
  -- Native Buck2 rules don't need loads
  RCxxBinary _ -> []
  RCxxLibrary _ -> []
  RRustBinary _ -> ["load(\"@toolchains//:rust.bzl\", \"rust_binary\")"]
  RRustLibrary _ -> ["load(\"@toolchains//:rust.bzl\", \"rust_library\")"]
  RHaskellBinary _ -> ["load(\"@toolchains//:haskell.bzl\", \"haskell_binary\")"]
  RHaskellLibrary _ -> ["load(\"@toolchains//:haskell.bzl\", \"haskell_library\")"]
  RHaskellFFIBinary _ -> ["load(\"@toolchains//:haskell.bzl\", \"haskell_ffi_binary\")"]
  RLeanBinary _ -> ["load(\"@toolchains//:lean.bzl\", \"lean_binary\")"]
  RLeanLibrary _ -> ["load(\"@toolchains//:lean.bzl\", \"lean_library\")"]
  RNvBinary _ -> ["load(\"@toolchains//:nv.bzl\", \"nv_binary\")"]
  RNvLibrary _ -> ["load(\"@toolchains//:nv.bzl\", \"nv_library\")"]
  RPureScriptApp _ -> ["load(\"@toolchains//:purescript.bzl\", \"purescript_app\")"]
  RPureScriptBinary _ -> ["load(\"@toolchains//:purescript.bzl\", \"purescript_binary\")"]
  RPureScriptLibrary _ -> ["load(\"@toolchains//:purescript.bzl\", \"purescript_library\")"]
  -- Genrule is native
  RGenrule _ -> []
  -- Nix C++ rules
  RNixCxxBinary _ -> ["load(\"@toolchains//:nix_analyze.bzl\", \"nix_cxx_binary\")"]
  -- Rust crate rules
  RCratesIo _ -> ["load(\"@toolchains//:rust_crate.bzl\", \"crates_io\")"]
  RHttpArchive _ -> []  -- http_archive is native in Buck2

-- | Emit a single rule
emitRule :: Rule -> Text
emitRule = \case
  RCxxBinary r -> emitCxxBinary r
  RCxxLibrary r -> emitCxxLibrary r
  RRustBinary r -> emitRustBinary r
  RRustLibrary r -> emitRustLibrary r
  RHaskellBinary r -> emitHaskellBinary r
  RHaskellLibrary r -> emitHaskellLibrary r
  RHaskellFFIBinary r -> emitHaskellFFIBinary r
  RLeanBinary r -> emitLeanBinary r
  RLeanLibrary r -> emitLeanLibrary r
  RNvBinary r -> emitNvBinary r
  RNvLibrary r -> emitNvLibrary r
  RPureScriptApp r -> emitPureScriptApp r
  RPureScriptBinary r -> emitPureScriptBinary r
  RPureScriptLibrary r -> emitPureScriptLibrary r
  RGenrule r -> emitGenrule r
  RNixCxxBinary r -> emitNixCxxBinary r
  RCratesIo r -> emitCratesIo r
  RHttpArchive r -> emitHttpArchive r

-- ════════════════════════════════════════════════════════════════════════════
-- C++ Rules
-- ════════════════════════════════════════════════════════════════════════════

emitCxxBinary :: CxxBinary -> Text
emitCxxBinary r = T.unlines
  [ "cxx_binary("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  , "    deps = " <> list (localDeps r.deps) <> ","
  , "    compiler_flags = " <> list (emitCxxStd r.std : r.cflags) <> ","
  , "    linker_flags = " <> list r.ldflags <> ","
  , "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

emitCxxLibrary :: CxxLibrary -> Text
emitCxxLibrary r = T.unlines $
  [ "cxx_library("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  ] ++
  (if null r.hdrs then [] else ["    exported_headers = " <> list r.hdrs <> ","]) ++
  [ "    deps = " <> list (localDeps r.deps) <> ","
  , "    compiler_flags = " <> list (emitCxxStd r.std : r.cflags) <> ","
  , "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Rust Rules
-- ════════════════════════════════════════════════════════════════════════════

emitRustBinary :: RustBinary -> Text
emitRustBinary r = T.unlines
  [ "rust_binary("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  , "    deps = " <> list (localDeps r.deps) <> ","
  , "    edition = " <> quote (emitRustEdition r.edition) <> ","
  , "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

emitRustLibrary :: RustLibrary -> Text
emitRustLibrary r = T.unlines $
  [ "rust_library("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  , "    deps = " <> list (localDeps r.deps) <> ","
  , "    edition = " <> quote (emitRustEdition r.edition) <> ","
  ] ++
  maybe [] (\cn -> ["    crate_name = " <> quote cn <> ","]) r.crateName ++
  (if r.procMacro then ["    proc_macro = True,"] else []) ++
  (if null r.features then [] else ["    features = " <> list r.features <> ","]) ++
  [ "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Haskell Rules
-- ════════════════════════════════════════════════════════════════════════════

emitHaskellBinary :: HaskellBinary -> Text
emitHaskellBinary r = T.unlines $
  [ "haskell_binary("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  , "    main = " <> quote r.main <> ","
  , "    packages = " <> list r.packages <> ","
  ] ++
  (if null r.languageExtensions then [] else ["    language_extensions = " <> list r.languageExtensions <> ","]) ++
  [ "    ghc_options = " <> list r.ghcOptions <> ","
  , "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

emitHaskellLibrary :: HaskellLibrary -> Text
emitHaskellLibrary r = T.unlines $
  [ "haskell_library("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  , "    packages = " <> list r.packages <> ","
  ] ++
  (if null r.languageExtensions then [] else ["    language_extensions = " <> list r.languageExtensions <> ","]) ++
  [ "    ghc_options = " <> list r.ghcOptions <> ","
  , "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

emitHaskellFFIBinary :: HaskellFFIBinary -> Text
emitHaskellFFIBinary r = T.unlines $
  [ "haskell_ffi_binary("
  , "    name = " <> quote r.name <> ","
  , "    hs_srcs = " <> list r.hsSrcs <> ","
  , "    cxx_srcs = " <> list r.cxxSrcs <> ","
  ] ++
  (if null r.cxxHeaders then [] else ["    cxx_headers = " <> list r.cxxHeaders <> ","]) ++
  (if null r.packages then [] else ["    packages = " <> list r.packages <> ","]) ++
  (if null r.languageExtensions then [] else ["    language_extensions = " <> list r.languageExtensions <> ","]) ++
  (if null r.ghcOptions then [] else ["    ghc_options = " <> list r.ghcOptions <> ","]) ++
  (if null r.extraLibs then [] else ["    extra_libs = " <> list r.extraLibs <> ","]) ++
  (if null r.extraLibDirs then [] else ["    extra_lib_dirs = " <> list r.extraLibDirs <> ","]) ++
  (if null r.includeDirs then [] else ["    include_dirs = " <> list r.includeDirs <> ","]) ++
  (if null r.linkerFlags then [] else ["    linker_flags = " <> list r.linkerFlags <> ","]) ++
  [ "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Lean Rules
-- ════════════════════════════════════════════════════════════════════════════

emitLeanBinary :: LeanBinary -> Text
emitLeanBinary r = T.unlines $
  [ "lean_binary("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  , "    deps = " <> list (localDeps r.deps) <> ","
  ] ++
  maybe [] (\m -> ["    root_module = " <> quote m <> ","]) r.rootModule ++
  [ "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

emitLeanLibrary :: LeanLibrary -> Text
emitLeanLibrary r = T.unlines
  [ "lean_library("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  , "    deps = " <> list (localDeps r.deps) <> ","
  , "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- NVIDIA/CUDA Rules
-- ════════════════════════════════════════════════════════════════════════════

emitNvBinary :: NvBinary -> Text
emitNvBinary r = T.unlines $
  [ "nv_binary("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  , "    deps = " <> list (localDeps r.deps) <> ","
  ] ++
  (if null r.archs then [] else ["    archs = " <> list r.archs <> ","]) ++
  [ "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

emitNvLibrary :: NvLibrary -> Text
emitNvLibrary r = T.unlines $
  [ "nv_library("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  ] ++
  (if null r.exportedHeaders then [] else ["    exported_headers = " <> list r.exportedHeaders <> ","]) ++
  [ "    deps = " <> list (localDeps r.deps) <> ","
  ] ++
  (if null r.archs then [] else ["    archs = " <> list r.archs <> ","]) ++
  [ "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- PureScript Rules
-- ════════════════════════════════════════════════════════════════════════════

emitPureScriptApp :: PureScriptApp -> Text
emitPureScriptApp r = T.unlines $
  [ "purescript_app("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> emitSrcSpec r.srcs <> ","
  , "    spago_yaml = " <> quote r.spagoYaml <> ","
  ] ++
  maybe [] (\sl -> ["    spago_lock = " <> quote sl <> ","]) r.spagoLock ++
  [ "    main = " <> quote r.main <> ","
  ] ++
  maybe [] (\ih -> ["    index_html = " <> quote ih <> ","]) r.indexHtml ++
  maybe [] (\sc -> ["    style_css = " <> quote sc <> ","]) r.styleCss ++
  [ "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

emitPureScriptBinary :: PureScriptBinary -> Text
emitPureScriptBinary r = T.unlines
  [ "purescript_binary("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> emitSrcSpec r.srcs <> ","
  , "    spago_yaml = " <> quote r.spagoYaml <> ","
  , "    main = " <> quote r.main <> ","
  , "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

emitPureScriptLibrary :: PureScriptLibrary -> Text
emitPureScriptLibrary r = T.unlines $
  [ "purescript_library("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> emitSrcSpec r.srcs <> ","
  ] ++
  maybe [] (\sy -> ["    spago_yaml = " <> quote sy <> ","]) r.spagoYaml ++
  [ "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Genrule
-- ════════════════════════════════════════════════════════════════════════════

emitGenrule :: Genrule -> Text
emitGenrule r = T.unlines $
  [ "genrule("
  , "    name = " <> quote r.name <> ","
  ] ++
  (if null r.srcs then [] else ["    srcs = " <> list r.srcs <> ","]) ++
  [ "    out = " <> quote r.out <> ","
  , "    cmd = " <> quote r.cmd <> ","
  , "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Nix C++ Rules
-- ════════════════════════════════════════════════════════════════════════════

emitNixCxxBinary :: NixCxxBinary -> Text
emitNixCxxBinary r = T.unlines $
  [ "nix_cxx_binary("
  , "    name = " <> quote r.name <> ","
  , "    srcs = " <> list r.srcs <> ","
  , "    nix_deps = " <> list r.nixDeps <> ","
  ] ++
  (if null r.deps then [] else ["    deps = " <> list r.deps <> ","]) ++
  (if null r.compilerFlags then [] else ["    compiler_flags = " <> list r.compilerFlags <> ","]) ++
  (if null r.linkerFlags then [] else ["    linker_flags = " <> list r.linkerFlags <> ","]) ++
  [ "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Rust Crate Rules
-- ════════════════════════════════════════════════════════════════════════════

emitCratesIo :: CratesIo -> Text
emitCratesIo r = T.unlines $
  [ "crates_io("
  , "    name = " <> quote r.name <> ","
  , "    version = " <> quote r.version <> ","
  , "    sha256 = " <> quote r.sha256 <> ","
  ] ++
  (if null r.features then [] else ["    features = " <> list r.features <> ","]) ++
  (if null r.deps then [] else ["    deps = " <> list r.deps <> ","]) ++
  (if not r.procMacro then [] else ["    proc_macro = True,"]) ++
  [ "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

emitHttpArchive :: HttpArchive -> Text
emitHttpArchive r = T.unlines $
  [ "http_archive("
  , "    name = " <> quote r.name <> ","
  , "    urls = [" <> quote r.url <> "],"
  , "    sha256 = " <> quote r.sha256 <> ","
  ] ++
  maybe [] (\sp -> ["    strip_prefix = " <> quote sp <> ","]) r.stripPrefix ++
  [ "    visibility = " <> emitVis r.vis <> ","
  , ")"
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Toolchain Emission
-- ════════════════════════════════════════════════════════════════════════════

-- | Emit a toolchain definition (for BUCK file in toolchains/)
emitToolchain :: Toolchain -> Text
emitToolchain = \case
  TCxx t -> emitCxxToolchain t
  THaskell t -> emitHaskellToolchain t
  TRust t -> emitRustToolchain t
  TLean t -> emitLeanToolchain t
  TNv t -> emitNvToolchain t
  TPureScript t -> emitPureScriptToolchain t
  TExecution t -> emitExecutionPlatform t
  TPython t -> emitPythonBootstrap t
  TGenrule t -> emitGenruleToolchain t

emitCxxToolchain :: CxxToolchain -> Text
emitCxxToolchain t = T.unlines
  [ "llvm_toolchain("
  , "    name = " <> quote t.name <> ","
  , "    c_extra_flags = " <> list t.cExtraFlags <> ","
  , "    cxx_extra_flags = " <> list t.cxxExtraFlags <> ","
  , "    link_flags = " <> list t.linkFlags <> ","
  , "    link_style = " <> quote t.linkStyle <> ","
  , "    visibility = " <> emitVis t.vis <> ","
  , ")"
  ]

emitHaskellToolchain :: HaskellToolchain -> Text
emitHaskellToolchain t = T.unlines
  [ "haskell_toolchain("
  , "    name = " <> quote t.name <> ","
  , "    compiler_flags = " <> list t.compilerFlags <> ","
  , "    visibility = " <> emitVis t.vis <> ","
  , ")"
  ]

emitRustToolchain :: RustToolchain -> Text
emitRustToolchain t = T.unlines
  [ "rust_toolchain("
  , "    name = " <> quote t.name <> ","
  , "    default_edition = " <> quote t.defaultEdition <> ","
  , "    rustc_flags = " <> list t.rustcFlags <> ","
  , "    visibility = " <> emitVis t.vis <> ","
  , ")"
  ]

emitLeanToolchain :: LeanToolchain -> Text
emitLeanToolchain t = T.unlines
  [ "lean_toolchain("
  , "    name = " <> quote t.name <> ","
  , "    visibility = " <> emitVis t.vis <> ","
  , ")"
  ]

emitNvToolchain :: NvToolchain -> Text
emitNvToolchain t = T.unlines
  [ "nv_toolchain("
  , "    name = " <> quote t.name <> ","
  , "    nv_archs = " <> list t.nvArchs <> ","
  , "    nvidia_sdk_path = " <> quote t.nvidiaSdkPath <> ","
  , "    nvidia_sdk_include = " <> quote t.nvidiaSdkInclude <> ","
  , "    nvidia_sdk_lib = " <> quote t.nvidiaSdkLib <> ","
  , "    visibility = " <> emitVis t.vis <> ","
  , ")"
  ]

emitPureScriptToolchain :: PureScriptToolchain -> Text
emitPureScriptToolchain t = T.unlines
  [ "purescript_toolchain("
  , "    name = " <> quote t.name <> ","
  , "    visibility = " <> emitVis t.vis <> ","
  , ")"
  ]

emitExecutionPlatform :: ExecutionPlatform -> Text
emitExecutionPlatform t = T.unlines
  [ "lre_execution_platform("
  , "    name = " <> quote t.name <> ","
  , "    cpu_configuration = host_configuration.cpu,"
  , "    os_configuration = host_configuration.os,"
  , "    local_enabled = " <> (if t.localEnabled then "True" else "False") <> ","
  , "    remote_enabled = " <> (if t.remoteEnabled then "True" else "False") <> ","
  , "    visibility = " <> emitVis t.vis <> ","
  , ")"
  ]

emitPythonBootstrap :: PythonBootstrap -> Text
emitPythonBootstrap t = T.unlines
  [ "system_python_bootstrap_toolchain("
  , "    name = " <> quote t.name <> ","
  , "    visibility = " <> emitVis t.vis <> ","
  , ")"
  ]

emitGenruleToolchain :: GenruleToolchain -> Text
emitGenruleToolchain t = T.unlines
  [ "system_genrule_toolchain("
  , "    name = " <> quote t.name <> ","
  , "    visibility = " <> emitVis t.vis <> ","
  , ")"
  ]

-- | Emit a complete toolchains BUCK file
emitToolchainsBuck :: [Toolchain] -> Text
emitToolchainsBuck ts = T.unlines $ map emitToolchain ts
