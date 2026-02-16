--| simdjson example with Nix-resolved dependencies (new format)

let A = ../../../dhall/prelude/package.dhall

let twitter =
      (A.nixCxxBinary "twitter" ["twitter.cpp"] ["nixpkgs#simdjson"])
        with compiler_flags = ["-O2"]

in  { targets = [ A.rule.nixCxxBinary twitter ] }
