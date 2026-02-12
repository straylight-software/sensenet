--| Haskell examples for Buck2
--|
--| Demonstrates:
--|   - haskell_binary: standalone executable
--|   - Packages and language extensions

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let hello = A.haskellBinary "hello-hs" ["Main.hs"]

let json_demo =
      (A.haskellBinary "json_demo" ["JsonDemo.hs"])
        with packages = ["base", "aeson", "text", "bytestring"]
        with language_extensions = ["DeriveGeneric", "OverloadedStrings"]

in  { rules =
        [ S.haskellBinary hello
        , S.haskellBinary json_demo
        ]
    , header = ''
        load("@toolchains//:haskell.bzl", "haskell_binary")
        ''
    }
