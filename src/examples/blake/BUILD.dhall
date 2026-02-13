--| BLAKE2 hashing demo using crypton
--|
--| crypton is already in aleph's haskell package set

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let blake =
      (A.haskellBinary "blake" ["Main.hs"])
        with packages = ["base", "bytestring", "crypton", "memory"]
        with language_extensions = ["OverloadedStrings", "DataKinds"]
        with ghc_options = ["-O2"]

in  { rules = [ S.haskellBinary blake ]
    , header = ''
        load("@toolchains//:haskell.bzl", "haskell_binary")
        ''
    }
