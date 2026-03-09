--| Multi-dependency example with zlib, openssl, and curl (new format)

let A = ../../../dhall/prelude/package.dhall

let multiDep =
      (A.nixCxxBinary "multi-dep" ["main.cpp"] 
        ["nixpkgs#zlib", "nixpkgs#openssl", "nixpkgs#curl"])
        with compiler_flags = ["-O2", "-Wall"]

in  { targets = [ A.rule.nixCxxBinary multiDep ] }
