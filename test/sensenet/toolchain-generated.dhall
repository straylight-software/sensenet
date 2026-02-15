-- toolchain-generated.dhall
-- Auto-generated from Nix toolchain configuration
-- DO NOT EDIT - regenerate with `nix run .#gen-toolchain-dhall`

let cc = env:CC as Text
let cxx = env:CXX as Text
let ar = env:AR as Text
let ld = env:LD as Text
let sysroot = env:SYSROOT as Text

in ''
-- Auto-generated from Nix toolchain configuration
-- DO NOT EDIT - regenerate with `nix run .#gen-toolchain-dhall`

let Toolchain = ../dhall/Toolchain.dhall

in  Toolchain::{
    , cc = "${cc}"
    , cxx = "${cxx}"
    , ar = "${ar}"
    , ld = "${ld}"
    , sysroot = Some "${sysroot}"
    }
''
