--| Hasktorch examples - tensor operations with libtorch
--|
--| Demonstrates:
--|   - haskell_binary with packages attr
--|   - Language extensions
--|   - Hasktorch tensor API

let E = ../../../dhall/evring/Compat.dhall

let hasktorch_demo =
      (E.haskell_binary "hasktorch_demo" ["Main.hs"])
        with packages = ["base", "hasktorch"]
        with language_extensions = ["DataKinds", "ExtendedDefaultRules", "OverloadedStrings", "TypeApplications"]

let linear_regression =
      (E.haskell_binary "linear_regression" ["LinearRegression.hs"])
        with packages = ["base", "hasktorch"]
        with language_extensions = ["RecordWildCards"]

in  { targets =
        [ E.rule.haskellBinary hasktorch_demo
        , E.rule.haskellBinary linear_regression
        ]
    }
