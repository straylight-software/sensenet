--| BLAKE2 hashing demo using crypton
--|
--| crypton is already in aleph's haskell package set

let E = ../../../dhall/evring/Compat.dhall

let blake =
      (E.haskell_binary "blake" ["Main.hs"])
        with packages = ["base", "bytestring", "crypton", "memory"]
        with language_extensions = ["OverloadedStrings", "DataKinds"]
        with ghc_options = ["-O2"]

in  { targets = [ E.rule.haskellBinary blake ] }
