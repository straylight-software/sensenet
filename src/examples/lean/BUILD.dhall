--| Lean 4 examples (new format)

let A = ../../../dhall/prelude/package.dhall

let hello = A.leanBinary "hello-lean" ["Hello.lean"]
let hashmap = A.leanBinary "hashmap" ["HashMap.lean"]

in  { targets =
        [ A.rule.leanBinary hello
        , A.rule.leanBinary hashmap
        ]
    }
