--| Hasktorch examples - tensor operations with libtorch
--|
--| Demonstrates:
--|   - haskell_binary with packages attr
--|   - Language extensions
--|   - Hasktorch tensor API

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let hasktorch_demo =
      (A.haskellBinary "hasktorch_demo" ["Main.hs"])
        with packages = ["base", "hasktorch"]
        with language_extensions = ["DataKinds", "ExtendedDefaultRules", "OverloadedStrings", "TypeApplications"]

let linear_regression =
      (A.haskellBinary "linear_regression" ["LinearRegression.hs"])
        with packages = ["base", "hasktorch"]
        with language_extensions = ["RecordWildCards"]

in  { rules =
        [ S.haskellBinary hasktorch_demo
        , S.haskellBinary linear_regression
        ]
    , header = ''
        load("@toolchains//:haskell.bzl", "haskell_binary")
        ''
    }
