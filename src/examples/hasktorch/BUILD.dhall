--| Hasktorch examples - tensor operations with libtorch (new format)
--|
--| Demonstrates:
--|   - haskell_binary with packages attr
--|   - Language extensions
--|   - Hasktorch tensor API

let A = ../../../dhall/prelude/package.dhall

let hasktorch_demo =
      (A.haskellBinary "hasktorch_demo" ["Main.hs"])
        with packages = ["base", "hasktorch"]
        with language_extensions = ["DataKinds", "ExtendedDefaultRules", "OverloadedStrings", "TypeApplications"]

let linear_regression =
      (A.haskellBinary "linear_regression" ["LinearRegression.hs"])
        with packages = ["base", "hasktorch"]
        with language_extensions = ["RecordWildCards"]

in  { targets =
        [ A.rule.haskellBinary hasktorch_demo
        , A.rule.haskellBinary linear_regression
        ]
    }
