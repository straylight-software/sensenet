--| Continuity: The Straylight Build Formalization (new format)
--|
--| A formal proof that the Continuity build system maintains correctness
--| across content-addressed derivations, typed toolchains, and isolation
--| boundaries.
--|
--| STATUS: This target requires Mathlib which is managed by Lake.
--|         Lake builds are non-hermetic and disabled in Buck2.
--|
--| To build this project, use Lake directly:
--|     cd src/examples/lean-continuity
--|     lake build

let A = ../../../dhall/prelude/package.dhall

let placeholder =
      A.genrule "continuity" "README.txt"
        "echo 'This target requires Mathlib (Lake dependency).' > \$OUT && echo 'Lake builds are non-hermetic and disabled in Buck2.' >> \$OUT && echo '' >> \$OUT && echo 'Build with: cd src/examples/lean-continuity && lake build' >> \$OUT"

in  { targets = [ A.rule.genrule placeholder ] }
