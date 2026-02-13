--| Dhall -> Starlark

let P = ./Prelude.dhall
let T = ./Types.dhall
let C = ./Cxx.dhall
let R = ./Rust.dhall
let H = ./Haskell.dhall
let L = ./Lean.dhall
let N = ./Nv.dhall
let PS = ./PureScript.dhall
let G = ./Genrule.dhall
let RC = ./RustCrate.dhall
let NC = ./NixCxx.dhall

let q = \(t : Text) -> "\"${t}\""

let list = \(xs : List Text) ->
    "[" ++ P.Text.concatSep ", " (P.List.map Text Text q xs) ++ "]"

let flakes
    : List T.Dep -> List Text
    = \(ds : List T.Dep) ->
        P.List.concatMap T.Dep Text
          (\(d : T.Dep) -> merge { Local = \(_ : Text) -> [] : List Text
                                 , Flake = \(r : Text) -> [r] } d) ds

let locals
    : List T.Dep -> List Text
    = \(ds : List T.Dep) ->
        P.List.concatMap T.Dep Text
          (\(d : T.Dep) -> merge { Local = \(t : Text) -> [t]
                                 , Flake = \(_ : Text) -> [] : List Text } d) ds

let cxxStd = \(s : T.CxxStd) -> merge
    { Cxx11 = "-std=c++11", Cxx14 = "-std=c++14", Cxx17 = "-std=c++17"
    , Cxx20 = "-std=c++20", Cxx23 = "-std=c++23" } s

let rustEdition = \(e : R.Edition) -> merge
    { E2015 = "2015", E2018 = "2018", E2021 = "2021", E2024 = "2024" } e

let vis = \(v : T.Vis) -> merge { Public = "[\"PUBLIC\"]", Private = "[]" } v

let Flags = { compiler : List Text, linker : List Text }

let cxxBinary
    : C.Binary -> Flags -> Text
    = \(b : C.Binary) -> \(f : Flags) ->
        let cf = [cxxStd b.std] # b.cflags # f.compiler
        let lf = b.ldflags # f.linker
        in ''
        cxx_binary(
            name = ${q b.name},
            srcs = ${list b.srcs},
            deps = ${list (locals b.deps)},
            compiler_flags = ${list cf},
            linker_flags = ${list lf},
            visibility = ${vis b.vis},
        )
        ''

let rustBinary
    : R.Binary -> Text
    = \(b : R.Binary) ->
        ''
        rust_binary(
            name = ${q b.name},
            srcs = ${list b.srcs},
            deps = ${list (locals b.deps)},
            edition = ${q (rustEdition b.edition)},
            visibility = ${vis b.vis},
        )
        ''

let rustLibrary
    : R.Library -> Text
    = \(lib : R.Library) ->
        let crateName = merge { Some = \(n : Text) -> "    crate_name = ${q n},\n"
                              , None = "" } lib.crate_name
        let procMacro = if lib.proc_macro then "    proc_macro = True,\n" else ""
        let features = if P.List.null Text lib.features
                       then ""
                       else "    features = ${list lib.features},\n"
        in ''
        rust_library(
            name = ${q lib.name},
            srcs = ${list lib.srcs},
            deps = ${list (locals lib.deps)},
            edition = ${q (rustEdition lib.edition)},
        ${crateName}${procMacro}${features}    visibility = ${vis lib.vis},
        )
        ''

-- ══════════════════════════════════════════════════════════════════════════════
-- Haskell
-- ══════════════════════════════════════════════════════════════════════════════

let haskellBinary
    : H.Binary -> Text
    = \(b : H.Binary) ->
        let exts = if P.List.null Text b.language_extensions
                   then ""
                   else "    language_extensions = ${list b.language_extensions},\n"
        in ''
        haskell_binary(
            name = ${q b.name},
            srcs = ${list b.srcs},
            main = ${q b.main},
            packages = ${list b.packages},
        ${exts}    ghc_options = ${list b.ghc_options},
            visibility = ${vis b.vis},
        )
        ''

let haskellLibrary
    : H.Library -> Text
    = \(lib : H.Library) ->
        let exts = if P.List.null Text lib.language_extensions
                   then ""
                   else "    language_extensions = ${list lib.language_extensions},\n"
        in ''
        haskell_library(
            name = ${q lib.name},
            srcs = ${list lib.srcs},
            packages = ${list lib.packages},
        ${exts}    ghc_options = ${list lib.ghc_options},
            visibility = ${vis lib.vis},
        )
        ''

let haskellFFIBinary
    : H.FFIBinary -> Text
    = \(b : H.FFIBinary) ->
        let hdrs = if P.List.null Text b.cxx_headers
                   then ""
                   else "    cxx_headers = ${list b.cxx_headers},\n"
        in ''
        haskell_ffi_binary(
            name = ${q b.name},
            hs_srcs = ${list b.hs_srcs},
            cxx_srcs = ${list b.cxx_srcs},
        ${hdrs}    visibility = ${vis b.vis},
        )
        ''

-- ══════════════════════════════════════════════════════════════════════════════
-- Lean
-- ══════════════════════════════════════════════════════════════════════════════

let leanBinary
    : L.Binary -> Text
    = \(b : L.Binary) ->
        let rootModule = merge { Some = \(m : Text) -> "    root_module = ${q m},\n"
                               , None = "" } b.root_module
        in ''
        lean_binary(
            name = ${q b.name},
            srcs = ${list b.srcs},
        ${rootModule}    visibility = ${vis b.vis},
        )
        ''

let leanLibrary
    : L.Library -> Text
    = \(lib : L.Library) ->
        ''
        lean_library(
            name = ${q lib.name},
            srcs = ${list lib.srcs},
            visibility = ${vis lib.vis},
        )
        ''

-- ══════════════════════════════════════════════════════════════════════════════
-- NVIDIA/CUDA
-- ══════════════════════════════════════════════════════════════════════════════

let nvBinary
    : N.Binary -> Text
    = \(b : N.Binary) ->
        ''
        nv_binary(
            name = ${q b.name},
            srcs = ${list b.srcs},
            visibility = ${vis b.vis},
        )
        ''

let nvLibrary
    : N.Library -> Text
    = \(lib : N.Library) ->
        let hdrs = if P.List.null Text lib.exported_headers
                   then ""
                   else "    exported_headers = ${list lib.exported_headers},\n"
        in ''
        nv_library(
            name = ${q lib.name},
            srcs = ${list lib.srcs},
        ${hdrs}    visibility = ${vis lib.vis},
        )
        ''

-- ══════════════════════════════════════════════════════════════════════════════
-- PureScript
-- ══════════════════════════════════════════════════════════════════════════════

-- Helper for SrcSpec (explicit list or glob pattern)
let srcSpec
    : PS.SrcSpec -> Text
    = \(s : PS.SrcSpec) ->
        merge { Explicit = \(xs : List Text) -> list xs
              , Glob = \(pattern : Text) -> "glob([${q pattern}])" } s

let purescriptApp
    : PS.App -> Text
    = \(a : PS.App) ->
        let indexHtml = merge { Some = \(f : Text) -> "    index_html = ${q f},\n"
                              , None = "" } a.index_html
        let styleCss = merge { Some = \(f : Text) -> "    style_css = ${q f},\n"
                             , None = "" } a.style_css
        in ''
        purescript_app(
            name = ${q a.name},
            srcs = ${srcSpec a.srcs},
            spago_yaml = ${q a.spago_yaml},
            main = ${q a.main},
        ${indexHtml}${styleCss}    visibility = ${vis a.vis},
        )
        ''

let purescriptBinary
    : PS.Binary -> Text
    = \(b : PS.Binary) ->
        ''
        purescript_binary(
            name = ${q b.name},
            srcs = ${srcSpec b.srcs},
            spago_yaml = ${q b.spago_yaml},
            main = ${q b.main},
            visibility = ${vis b.vis},
        )
        ''

let purescriptLibrary
    : PS.Library -> Text
    = \(lib : PS.Library) ->
        let spagoYaml = merge { Some = \(f : Text) -> "    spago_yaml = ${q f},\n"
                              , None = "" } lib.spago_yaml
        in ''
        purescript_library(
            name = ${q lib.name},
            srcs = ${srcSpec lib.srcs},
        ${spagoYaml}    visibility = ${vis lib.vis},
        )
        ''

-- ══════════════════════════════════════════════════════════════════════════════
-- Dep extractors
-- ══════════════════════════════════════════════════════════════════════════════

let cxxDeps = \(b : C.Binary) -> P.Text.concatSep "\n" (flakes b.deps)
let rustBinaryDeps = \(b : R.Binary) -> P.Text.concatSep "\n" (flakes b.deps)
let rustLibraryDeps = \(lib : R.Library) -> P.Text.concatSep "\n" (flakes lib.deps)

-- Backward compat aliases
let std = cxxStd
let binary = cxxBinary
let deps = cxxDeps

-- ══════════════════════════════════════════════════════════════════════════════
-- Toolchains
-- ══════════════════════════════════════════════════════════════════════════════

let TC = ./Toolchain.dhall

let cxxToolchain
    : TC.CxxToolchain -> Text
    = \(t : TC.CxxToolchain) ->
        ''
        llvm_toolchain(
            name = ${q t.name},
            c_extra_flags = ${list t.c_extra_flags},
            cxx_extra_flags = ${list t.cxx_extra_flags},
            link_flags = ${list t.link_flags},
            link_style = ${q t.link_style},
            visibility = ${vis t.vis},
        )
        ''

let haskellToolchain
    : TC.HaskellToolchain -> Text
    = \(t : TC.HaskellToolchain) ->
        ''
        haskell_toolchain(
            name = ${q t.name},
            compiler_flags = ${list t.compiler_flags},
            visibility = ${vis t.vis},
        )
        ''

let executionPlatform
    : TC.ExecutionPlatform -> Text
    = \(t : TC.ExecutionPlatform) ->
        let localStr = if t.local_enabled then "True" else "False"
        let remoteStr = if t.remote_enabled then "True" else "False"
        in ''
        lre_execution_platform(
            name = ${q t.name},
            cpu_configuration = host_configuration.cpu,
            os_configuration = host_configuration.os,
            local_enabled = ${localStr},
            remote_enabled = ${remoteStr},
            visibility = ${vis t.vis},
        )
        ''

let pythonBootstrap
    : TC.PythonBootstrap -> Text
    = \(t : TC.PythonBootstrap) ->
        ''
        system_python_bootstrap_toolchain(
            name = ${q t.name},
            visibility = ${vis t.vis},
        )
        ''

let genruleToolchain
    : TC.GenruleToolchain -> Text
    = \(t : TC.GenruleToolchain) ->
        ''
        system_genrule_toolchain(
            name = ${q t.name},
            visibility = ${vis t.vis},
        )
        ''

let nvToolchain
    : TC.NvToolchain -> Text
    = \(t : TC.NvToolchain) ->
        ''
        nv_toolchain(
            name = ${q t.name},
            nv_archs = ${list t.nv_archs},
            nvidia_sdk_path = ${q t.nvidia_sdk_path},
            nvidia_sdk_include = ${q t.nvidia_sdk_include},
            nvidia_sdk_lib = ${q t.nvidia_sdk_lib},
            visibility = ${vis t.vis},
        )
        ''

let rustToolchain
    : TC.RustToolchain -> Text
    = \(t : TC.RustToolchain) ->
        ''
        rust_toolchain(
            name = ${q t.name},
            default_edition = ${q t.default_edition},
            rustc_flags = ${list t.rustc_flags},
            visibility = ${vis t.vis},
        )
        ''

let leanToolchain
    : TC.LeanToolchain -> Text
    = \(t : TC.LeanToolchain) ->
        ''
        lean_toolchain(
            name = ${q t.name},
            visibility = ${vis t.vis},
        )
        ''

let purescriptToolchain
    : TC.PureScriptToolchain -> Text
    = \(t : TC.PureScriptToolchain) ->
        ''
        purescript_toolchain(
            name = ${q t.name},
            visibility = ${vis t.vis},
        )
        ''

-- ══════════════════════════════════════════════════════════════════════════════
-- Genrule
-- ══════════════════════════════════════════════════════════════════════════════

let genrule
    : G.Genrule -> Text
    = \(g : G.Genrule) ->
        let srcs = if P.List.null Text g.srcs
                   then ""
                   else "    srcs = ${list g.srcs},\n"
        in ''
        genrule(
            name = ${q g.name},
        ${srcs}    out = ${q g.out},
            cmd = ${q g.cmd},
            visibility = ${vis g.vis},
        )
        ''

-- ══════════════════════════════════════════════════════════════════════════════
-- Rust Crates
-- ══════════════════════════════════════════════════════════════════════════════

let cratesIo
    : RC.CratesIo -> Text
    = \(c : RC.CratesIo) ->
        let features = if P.List.null Text c.features
                       then ""
                       else "    features = ${list c.features},\n"
        let deps = if P.List.null Text c.deps
                   then ""
                   else "    deps = ${list c.deps},\n"
        let procMacro = if c.proc_macro then "    proc_macro = True,\n" else ""
        in ''
        crates_io(
            name = ${q c.name},
            version = ${q c.version},
            sha256 = ${q c.sha256},
        ${features}${deps}${procMacro}    visibility = ${vis c.vis},
        )
        ''

let httpArchive
    : RC.HttpArchive -> Text
    = \(a : RC.HttpArchive) ->
        let stripPrefix = merge { Some = \(p : Text) -> "    strip_prefix = ${q p},\n"
                                , None = "" } a.strip_prefix
        in ''
        http_archive(
            name = ${q a.name},
            url = ${q a.url},
            sha256 = ${q a.sha256},
        ${stripPrefix}    visibility = ${vis a.vis},
        )
        ''

-- ══════════════════════════════════════════════════════════════════════════════
-- Nix C++
-- ══════════════════════════════════════════════════════════════════════════════

let nixCxxBinary
    : NC.NixBinary -> Text
    = \(b : NC.NixBinary) ->
        let deps = if P.List.null Text b.deps
                   then ""
                   else "    deps = ${list b.deps},\n"
        let cflags = if P.List.null Text b.compiler_flags
                     then ""
                     else "    compiler_flags = ${list b.compiler_flags},\n"
        let lflags = if P.List.null Text b.linker_flags
                     then ""
                     else "    linker_flags = ${list b.linker_flags},\n"
        in ''
        nix_cxx_binary(
            name = ${q b.name},
            srcs = ${list b.srcs},
            deps = ${list b.nix_deps},
        ${deps}${cflags}${lflags}    visibility = ${vis b.vis},
        )
        ''

in  { q, list, flakes, locals
    , cxxStd, rustEdition, vis, Flags
    -- C++
    , cxxBinary
    , cxxDeps
    -- Rust
    , rustBinary, rustLibrary
    , rustBinaryDeps, rustLibraryDeps
    -- Haskell
    , haskellBinary, haskellLibrary, haskellFFIBinary
    -- Lean
    , leanBinary, leanLibrary
    -- NVIDIA
    , nvBinary, nvLibrary
    -- PureScript
    , purescriptApp, purescriptBinary, purescriptLibrary
    -- Genrule
    , genrule
    -- Rust crates
    , cratesIo, httpArchive
    -- Nix C++
    , nixCxxBinary
    -- Toolchains
    , cxxToolchain, haskellToolchain, executionPlatform
    , pythonBootstrap, genruleToolchain
    , nvToolchain, rustToolchain, leanToolchain, purescriptToolchain
    -- backward compat
    , std, binary, deps
    }
