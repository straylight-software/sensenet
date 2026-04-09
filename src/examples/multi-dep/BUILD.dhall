--| Multi-dependency example with zlib, openssl, and curl

let E = ../../../dhall/evring/Compat.dhall

let multiDep =
      (E.nix_cxx_binary "multi-dep" ["main.cpp"] 
        ["nixpkgs#zlib", "nixpkgs#openssl", "nixpkgs#curl"])
        with compiler_flags = ["-O2", "-Wall"]

in  { targets = [ E.rule.nixCxxBinary multiDep ] }
