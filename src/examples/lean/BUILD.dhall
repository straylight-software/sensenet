--| Lean 4 examples

let E = ../../../dhall/evring/Compat.dhall

let hello = E.lean_binary "hello-lean" ["Hello.lean"]
let hashmap = E.lean_binary "hashmap" ["HashMap.lean"]

in  { targets =
        [ E.rule.leanBinary hello
        , E.rule.leanBinary hashmap
        ]
    }
