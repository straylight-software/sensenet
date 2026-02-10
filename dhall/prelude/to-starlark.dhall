--| Dhall to Starlark Transpiler
--|
--| Renders Dhall build definitions as Starlark BUCK files.

let Prelude = ./Prelude.dhall

let Types = ./Types.dhall
let Cxx = ./Cxx.dhall

-- =============================================================================
-- Starlark Primitives
-- =============================================================================

let quote = \(t : Text) -> "\"${t}\""

let join = Prelude.Text.concatSep

let renderList = \(xs : List Text) ->
    let quoted = Prelude.List.map Text Text quote xs
    in "[" ++ join ", " quoted ++ "]"

-- =============================================================================
-- Dependency Extraction
-- =============================================================================

-- Extract flake refs from deps (for nix-analyze)
let extractFlakeRefs
    : List Types.Dep -> List Text
    = \(deps : List Types.Dep) ->
        Prelude.List.concatMap
          Types.Dep
          Text
          (\(d : Types.Dep) ->
            merge
              { Local = \(_ : Text) -> [] : List Text
              , Flake = \(ref : Text) -> [ref]
              }
              d
          )
          deps

-- Extract local deps (become Buck2 target refs)
let extractLocalDeps
    : List Types.Dep -> List Text
    = \(deps : List Types.Dep) ->
        Prelude.List.concatMap
          Types.Dep
          Text
          (\(d : Types.Dep) ->
            merge
              { Local = \(t : Text) -> [t]
              , Flake = \(_ : Text) -> [] : List Text
              }
              d
          )
          deps

-- =============================================================================
-- C++ Standard Rendering
-- =============================================================================

let renderCxxStd
    : Types.CxxStandard -> Text
    = \(std : Types.CxxStandard) ->
        merge
          { Cxx11 = "-std=c++11"
          , Cxx14 = "-std=c++14"
          , Cxx17 = "-std=c++17"
          , Cxx20 = "-std=c++20"
          , Cxx23 = "-std=c++23"
          }
          std

-- =============================================================================
-- Visibility Rendering
-- =============================================================================

let renderVisibility
    : Types.Visibility -> Text
    = \(vis : Types.Visibility) ->
        merge
          { Public = "[\"PUBLIC\"]"
          , Private = "[]"
          , Package = "[\":...\"]"
          , Targets = \(ts : List Text) -> renderList ts
          }
          vis

-- =============================================================================
-- Flag Classification
-- =============================================================================

-- nix-analyze outputs flags like:
--   -isystem /path/include
--   -L/path/lib
--   -Wl,-rpath,/path/lib
--   -lfoo
--
-- We need to split these:
--   compiler_flags: -isystem, -I (and their paths)
--   linker_flags: -L, -Wl, -l
--
-- Since Dhall can't do string prefix matching easily, we pass separate lists

-- Resolved flags structure (from nix-analyze)
let ResolvedFlags =
      { compiler : List Text  -- -isystem, -I flags
      , linker : List Text    -- -L, -Wl,-rpath, -l flags
      }

-- =============================================================================
-- cxx_binary Rendering
-- =============================================================================

-- Render a CxxBinary to Starlark
let renderCxxBinary
    : Cxx.CxxBinary -> ResolvedFlags -> Text
    = \(bin : Cxx.CxxBinary) ->
      \(resolved : ResolvedFlags) ->
        let localDeps = extractLocalDeps bin.deps
        let stdFlag = renderCxxStd bin.cxx_std
        let allCompilerFlags = [stdFlag] # bin.compiler_flags # resolved.compiler
        let allLinkerFlags = bin.linker_flags # resolved.linker
        in
        ''
        cxx_binary(
            name = ${quote bin.name},
            srcs = ${renderList bin.srcs},
            deps = ${renderList localDeps},
            compiler_flags = ${renderList allCompilerFlags},
            linker_flags = ${renderList allLinkerFlags},
            visibility = ${renderVisibility bin.visibility},
        )
        ''

-- Simplified version that takes all flags together (for backward compat)
let renderCxxBinarySimple
    : Cxx.CxxBinary -> List Text -> Text
    = \(bin : Cxx.CxxBinary) ->
      \(allFlags : List Text) ->
        -- Put all flags in both for now (Buck2 is forgiving)
        renderCxxBinary bin { compiler = allFlags, linker = allFlags }

-- =============================================================================
-- cxx_library Rendering
-- =============================================================================

let renderCxxLibrary
    : Cxx.CxxLibrary -> ResolvedFlags -> Text
    = \(lib : Cxx.CxxLibrary) ->
      \(resolved : ResolvedFlags) ->
        let localDeps = extractLocalDeps lib.deps
        let stdFlag = renderCxxStd lib.cxx_std
        let allCompilerFlags = [stdFlag] # lib.compiler_flags # resolved.compiler
        in
        ''
        cxx_library(
            name = ${quote lib.name},
            srcs = ${renderList lib.srcs},
            headers = ${renderList lib.hdrs},
            deps = ${renderList localDeps},
            compiler_flags = ${renderList allCompilerFlags},
            linker_flags = ${renderList lib.linker_flags},
            visibility = ${renderVisibility lib.visibility},
        )
        ''

-- =============================================================================
-- Extract deps for external resolution
-- =============================================================================

let extractDeps
    : Cxx.CxxBinary -> Text
    = \(bin : Cxx.CxxBinary) ->
        join "\n" (extractFlakeRefs bin.deps)

let extractDepsFromList
    : List Cxx.CxxBinary -> Text
    = \(bins : List Cxx.CxxBinary) ->
        let allRefs = Prelude.List.concatMap Cxx.CxxBinary Text 
              (\(b : Cxx.CxxBinary) -> extractFlakeRefs b.deps) bins
        in join "\n" allRefs

-- =============================================================================
-- Exports
-- =============================================================================

in  { quote
    , renderList
    , extractFlakeRefs
    , extractLocalDeps
    , renderCxxStd
    , renderVisibility
    , ResolvedFlags
    , renderCxxBinary
    , renderCxxBinarySimple
    , renderCxxLibrary
    , extractDeps
    , extractDepsFromList
    }
