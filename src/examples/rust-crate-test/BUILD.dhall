--| Test fetching and building crates from crates.io

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

-- Simple crate with no dependencies
let onceCrate =
      (A.cratesIo "once_cell" "1.21.3" "42f5e15c9953c5e4ccceeb2e7382a716482c34515315f7b03532b8b4e8393d2d")
        with features = ["std"]

-- Test binary using the crate
let testBinary =
      A.rustBinary "test_once_cell" ["test_once_cell.rs"] [A.local ":once_cell"]

in  { rules =
        [ S.cratesIo onceCrate
        , S.rustBinary testBinary
        ]
    , header = ''
        load("@toolchains//:rust_crate.bzl", "crates_io", "rust_crate")
        load("@toolchains//:rust.bzl", "rust_binary")
        load("@straylight_prelude//http_archive.bzl", "http_archive")
        ''
    }
