--| BLAKE2 hashing demo using crypton (new format)
--|
--| crypton is already in aleph's haskell package set

let A = ../../../dhall/prelude/package.dhall

let blake =
      (A.haskellBinary "blake" ["Main.hs"])
        with packages = ["base", "bytestring", "crypton", "memory"]
        with language_extensions = ["OverloadedStrings", "DataKinds"]
        with ghc_options = ["-O2"]

in  { targets = [ A.rule.haskellBinary blake ] }
