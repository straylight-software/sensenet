--| C/C++ Rules
--|
--| cxx_library, cxx_binary, cxx_test

let Types = ./Types.dhall
let Toolchain = ./Toolchain.dhall

-- =============================================================================
-- Link Style
-- =============================================================================

let LinkStyle = < Static | Shared >

-- =============================================================================
-- cxx_library
-- =============================================================================

let CxxLibrary =
      { name : Text
      , srcs : List Text
      , hdrs : List Text
      , deps : List Types.Dep
      , exported_deps : List Types.Dep
      , includes : List Text
      , defines : List { name : Text, value : Optional Text }
      , cxx_std : Types.CxxStandard
      , compiler_flags : List Text
      , linker_flags : List Text
      , visibility : Types.Visibility
      , toolchain : Optional Toolchain.Toolchain
      }

let cxx_library
    : Text -> List Text -> List Types.Dep -> CxxLibrary
    = \(name : Text) ->
      \(srcs : List Text) ->
      \(deps : List Types.Dep) ->
        { name
        , srcs
        , hdrs = [] : List Text
        , deps
        , exported_deps = [] : List Types.Dep
        , includes = [] : List Text
        , defines = [] : List { name : Text, value : Optional Text }
        , cxx_std = Types.CxxStandard.Cxx17
        , compiler_flags = [] : List Text
        , linker_flags = [] : List Text
        , visibility = Types.Visibility.Public
        , toolchain = None Toolchain.Toolchain
        }

-- =============================================================================
-- cxx_binary
-- =============================================================================

let CxxBinary =
      { name : Text
      , srcs : List Text
      , deps : List Types.Dep
      , includes : List Text
      , defines : List { name : Text, value : Optional Text }
      , cxx_std : Types.CxxStandard
      , compiler_flags : List Text
      , linker_flags : List Text
      , link_style : LinkStyle
      , visibility : Types.Visibility
      , toolchain : Optional Toolchain.Toolchain
      }

let cxx_binary
    : Text -> List Text -> List Types.Dep -> CxxBinary
    = \(name : Text) ->
      \(srcs : List Text) ->
      \(deps : List Types.Dep) ->
        { name
        , srcs
        , deps
        , includes = [] : List Text
        , defines = [] : List { name : Text, value : Optional Text }
        , cxx_std = Types.CxxStandard.Cxx17
        , compiler_flags = [] : List Text
        , linker_flags = [] : List Text
        , link_style = LinkStyle.Static
        , visibility = Types.Visibility.Public
        , toolchain = None Toolchain.Toolchain
        }

-- =============================================================================
-- cxx_test
-- =============================================================================

let CxxTest =
      { name : Text
      , srcs : List Text
      , deps : List Types.Dep
      , includes : List Text
      , cxx_std : Types.CxxStandard
      , compiler_flags : List Text
      , toolchain : Optional Toolchain.Toolchain
      }

let cxx_test
    : Text -> List Text -> List Types.Dep -> CxxTest
    = \(name : Text) ->
      \(srcs : List Text) ->
      \(deps : List Types.Dep) ->
        { name
        , srcs
        , deps
        , includes = [] : List Text
        , cxx_std = Types.CxxStandard.Cxx17
        , compiler_flags = [] : List Text
        , toolchain = None Toolchain.Toolchain
        }

-- =============================================================================
-- Exports
-- =============================================================================

in  { LinkStyle
    , CxxLibrary
    , cxx_library
    , CxxBinary
    , cxx_binary
    , CxxTest
    , cxx_test
    }
