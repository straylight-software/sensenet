--| Haskell Rules

let T = ./Types.dhall

let StanConfig =
      { config_file : Optional Text
      , severity : Optional Text
      }

let noStan = None StanConfig

let Binary =
      { name : Text
      , srcs : List Text
      , main : Text
      , packages : List Text
      , language_extensions : List Text
      , ghc_options : List Text
      , deps : List T.Dep
      , extra_libs : List Text
      , extra_lib_dirs : List Text
      , vis : T.Vis
      , stan : Optional StanConfig
      }

let binary
    : Text -> List Text -> Binary
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name, srcs
        , main = "Main"
        , packages = [ "base" ] : List Text
        , language_extensions = [] : List Text
        , ghc_options = [ "-O2", "-Wall" ] : List Text
        , deps = [] : List T.Dep
        , extra_libs = [] : List Text
        , extra_lib_dirs = [] : List Text
        , vis = T.Vis.Public
        , stan = noStan
        }

let Library =
      { name : Text
      , srcs : List Text
      , packages : List Text
      , language_extensions : List Text
      , ghc_options : List Text
      , deps : List T.Dep
        , vis : T.Vis
      , stan : Optional StanConfig
      }

let library
    : Text -> List Text -> Library
    = \(name : Text) ->
      \(srcs : List Text) ->
        { name, srcs
        , packages = [ "base" ] : List Text
        , language_extensions = [] : List Text
        , ghc_options = [ "-O2", "-Wall" ] : List Text
        , deps = [] : List T.Dep
        , vis = T.Vis.Public
        , stan = noStan
        }

let FFIBinary =
      { name : Text
      , hs_srcs : List Text
      , cxx_srcs : List Text
      , cxx_headers : List Text
      , packages : List Text
      , language_extensions : List Text
      , ghc_options : List Text
      , extra_libs : List Text
      , extra_lib_dirs : List Text
      , include_dirs : List Text
      , linker_flags : List Text
      , vis : T.Vis
      }

let ffiBinary
    : Text -> List Text -> List Text -> FFIBinary
    = \(name : Text) ->
      \(hs_srcs : List Text) ->
      \(cxx_srcs : List Text) ->
        { name, hs_srcs, cxx_srcs
        , cxx_headers = [] : List Text
        , packages = [ "base" ] : List Text
        , language_extensions = [] : List Text
        , ghc_options = [ "-O2" ] : List Text
        , extra_libs = [] : List Text
        , extra_lib_dirs = [] : List Text
        , include_dirs = [] : List Text
        , linker_flags = [] : List Text
        , vis = T.Vis.Public
        }

in  { StanConfig, Binary, binary, Library, library, FFIBinary, ffiBinary }
