--| Extract flake dependencies from a BUILD.dhall
--|
--| Usage:
--|   dhall text <<< './extract-deps.dhall ./src/examples/simdjson/BUILD.dhall'
--|
--| Output: one flake ref per line (for nix-analyze)

let Prelude = ./Prelude.dhall
let Types = ./Types.dhall
let Cxx = ./Cxx.dhall

-- Extract flake refs from a dep list
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

-- Extract from a CxxBinary
let extractFromBinary
    : Cxx.CxxBinary -> List Text
    = \(bin : Cxx.CxxBinary) -> extractFlakeRefs bin.deps

-- Process a list of binaries and output unique refs
let process
    : List Cxx.CxxBinary -> Text
    = \(targets : List Cxx.CxxBinary) ->
        let allRefs = Prelude.List.concatMap Cxx.CxxBinary Text extractFromBinary targets
        in Prelude.Text.concatSep "\n" allRefs

in  process
