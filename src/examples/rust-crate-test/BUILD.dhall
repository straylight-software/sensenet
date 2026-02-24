--| Test fetching and building crates from crates.io (new format)

let A = ../../../dhall/prelude/package.dhall

-- Simple crate with no dependencies
let onceCrate =
      (A.cratesIo "once_cell" "1.21.3" "42f5e15c9953c5e4ccceeb2e7382a716482c34515315f7b03532b8b4e8393d2d")
        with features = ["std"]

-- cfg-if: commonly used, no deps
let cfgIf =
      A.cratesIo "cfg-if" "1.0.0" "baf1de4339761588bc0619e3cbc0120ee582ebb74b53b4efbf79117bd2da40fd"

-- log: depends on cfg-if (dev deps only, so it should build)
let logCrate =
      (A.cratesIo "log" "0.4.22" "a7a70ba024b9dc04c27ea2f0c0548feb474ec5c54bba33a7f72f873a39d07b24")
        with deps = [":cfg-if"]

-- Test binary using the crate
let testBinary =
      A.rustBinary "test_once_cell" ["test_once_cell.rs"] [A.local ":once_cell"]

-- Test binary using log
let testLog =
      A.rustBinary "test_log" ["test_log.rs"] [A.local ":log"]

in  { targets =
        [ A.rule.cratesIo onceCrate
        , A.rule.cratesIo cfgIf
        , A.rule.cratesIo logCrate
        , A.rule.rustBinary testBinary
        , A.rule.rustBinary testLog
        ]
    }
