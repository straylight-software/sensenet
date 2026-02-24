--| simdjson example with Nix-resolved dependencies

let E = ../../../dhall/evring/Compat.dhall

let twitter =
      (E.nix_cxx_binary "twitter" ["twitter.cpp"] ["nixpkgs#simdjson"])
        with compiler_flags = ["-O2"]

in  { targets = [ E.rule.nixCxxBinary twitter ] }
