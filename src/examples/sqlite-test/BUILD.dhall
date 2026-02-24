--| SQLite3 example with Nix-resolved dependencies

let E = ../../../dhall/evring/Compat.dhall

let sqliteTest =
      (E.nix_cxx_binary "sqlite-test" ["main.cpp"] ["nixpkgs#sqlite"])
        with compiler_flags = ["-O2", "-Wall"]

in  { targets = [ E.rule.nixCxxBinary sqliteTest ] }
