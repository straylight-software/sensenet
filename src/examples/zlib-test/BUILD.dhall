--| zlib test with Nix-resolved dependencies (new format)

let A = ../../../dhall/prelude/package.dhall

let zlibTest =
      (A.nixCxxBinary "zlib-test" ["main.cpp"] ["nixpkgs#zlib"])
        with compiler_flags = ["-O2", "-Wall"]

in  { targets = [ A.rule.nixCxxBinary zlibTest ] }
