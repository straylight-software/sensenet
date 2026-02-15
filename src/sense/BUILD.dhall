--| sense - the invisible build system
--|
--| Self-hosting: sense builds itself via Buck2

let A = ../../dhall/prelude/package.dhall
let S = ../../dhall/prelude/to-starlark.dhall

let sense =
      (A.haskellBinary "sense" ["Main.hs"])
        with packages = ["base", "directory", "filepath", "process"]

in  { rules = [ S.haskellBinary sense ]
    , header = ''
        load("@toolchains//:haskell.bzl", "haskell_binary")
        ''
    }
