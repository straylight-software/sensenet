--| nix-analyze: Nix flake analysis tool for Buck2
--|
--| This tool is called by the nix_library() rule to resolve flake references
--| into compiler/linker flags.

let A = ../../dhall/prelude/package.dhall

let nix_analyze =
      (A.haskellBinary "nix-analyze" ["Main.hs", "Nix.hs"])
        with packages = ["base", "bytestring", "text", "process", "aeson", "containers"]
        with language_extensions = ["LambdaCase", "OverloadedStrings"]
        with ghc_options = ["-O2", "-Wall"]

in  { targets = [ A.rule.haskellBinary nix_analyze ] }
