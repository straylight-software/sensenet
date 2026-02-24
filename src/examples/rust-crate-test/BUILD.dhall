--| Test fetching and building crates from crates.io

let E = ../../../dhall/evring/Compat.dhall

-- Simple crate with no dependencies
let onceCrate =
      (E.crates_io "once_cell" "1.21.3" "42f5e15c9953c5e4ccceeb2e7382a716482c34515315f7b03532b8b4e8393d2d")
        with features = ["std"]

-- cfg-if: commonly used, no deps
let cfgIf =
      E.crates_io "cfg-if" "1.0.0" "baf1de4339761588bc0619e3cbc0120ee582ebb74b53b4efbf79117bd2da40fd"

-- log: depends on cfg-if (dev deps only, so it should build)
let logCrate =
      (E.crates_io "log" "0.4.22" "a7a70ba024b9dc04c27ea2f0c0548feb474ec5c54bba33a7f72f873a39d07b24")
        with deps = [":cfg-if"]

-- Test binary using the crate
let testBinary =
      (E.rust_binary "test_once_cell" ["test_once_cell.rs"])
        with deps = [E.local ":once_cell"]

-- Test binary using log
let testLog =
      (E.rust_binary "test_log" ["test_log.rs"])
        with deps = [E.local ":log"]

in  { targets =
        [ E.rule.cratesIo onceCrate
        , E.rule.cratesIo cfgIf
        , E.rule.cratesIo logCrate
        , E.rule.rustBinary testBinary
        , E.rule.rustBinary testLog
        ]
    }
