--| SQLite3 example with Nix-resolved dependencies (new format)

let A = ../../../dhall/prelude/package.dhall

let sqliteTest =
      (A.nixCxxBinary "sqlite-test" ["main.cpp"] ["nixpkgs#sqlite"])
        with compiler_flags = ["-O2", "-Wall"]

in  { targets = [ A.rule.nixCxxBinary sqliteTest ] }
