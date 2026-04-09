--| zlib test with Nix-resolved dependencies

let E = ../../../dhall/evring/Compat.dhall

let zlibTest =
      (E.nix_cxx_binary "zlib-test" ["main.cpp"] ["nixpkgs#zlib"])
        with compiler_flags = ["-O2", "-Wall"]

in  { targets = [ E.rule.nixCxxBinary zlibTest ] }
