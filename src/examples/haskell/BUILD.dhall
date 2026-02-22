--| Haskell examples (new format)

let A = ../../../dhall/prelude/package.dhall

-- Simple binary (no deps)
let hello = A.haskellBinary "hello-hs" ["Main.hs"]

-- Library
let greetlib = A.haskellLibrary "greetlib" ["Greet.hs"]

-- Binary depending on library
let greeter =
      (A.haskellBinary "greeter" ["Main.hs"])
        with deps = [A.local ":greetlib"]

let json_demo =
      (A.haskellBinary "json_demo" ["JsonDemo.hs"])
        with packages = ["base", "aeson", "text", "bytestring"]
        with language_extensions = ["DeriveGeneric", "OverloadedStrings"]

in  { targets =
        [ A.rule.haskellLibrary greetlib
        , A.rule.haskellBinary greeter
        , A.rule.haskellBinary json_demo
        ]
    }
