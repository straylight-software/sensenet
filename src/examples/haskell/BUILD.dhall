--| Haskell examples (new format)

let A = ../../../dhall/prelude/package.dhall

let hello = A.haskellBinary "hello-hs" ["Main.hs"]

let json_demo =
      (A.haskellBinary "json_demo" ["JsonDemo.hs"])
        with packages = ["base", "aeson", "text", "bytestring"]
        with language_extensions = ["DeriveGeneric", "OverloadedStrings"]

in  { targets =
        [ A.rule.haskellBinary hello
        , A.rule.haskellBinary json_demo
        ]
    }
