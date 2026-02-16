--| Test fetching and building crates from crates.io (new format)

let A = ../../../dhall/prelude/package.dhall

-- Simple crate with no dependencies
let onceCrate =
      (A.cratesIo "once_cell" "1.21.3" "42f5e15c9953c5e4ccceeb2e7382a716482c34515315f7b03532b8b4e8393d2d")
        with features = ["std"]

-- Test binary using the crate
let testBinary =
      A.rustBinary "test_once_cell" ["test_once_cell.rs"] [A.local ":once_cell"]

in  { targets =
        [ A.rule.cratesIo onceCrate
        , A.rule.rustBinary testBinary
        ]
    }
