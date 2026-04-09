--| Haskell examples

let E = ../../../dhall/evring/Compat.dhall

-- Simple binary (no deps)
let hello = E.haskell_binary "hello-hs" ["Main.hs"]

-- Library
let greetlib = E.haskell_library "greetlib" ["Greet.hs"]

-- Binary depending on library
let greeter =
      (E.haskell_binary "greeter" ["Main.hs"])
        with deps = [E.local ":greetlib"]

let json_demo =
      (E.haskell_binary "json_demo" ["JsonDemo.hs"])
        with packages = ["base", "aeson", "text", "bytestring"]
        with language_extensions = ["DeriveGeneric", "OverloadedStrings"]

in  { targets =
        [ E.rule.haskellBinary hello
        , E.rule.haskellLibrary greetlib
        , E.rule.haskellBinary greeter
        , E.rule.haskellBinary json_demo
        ]
    }
