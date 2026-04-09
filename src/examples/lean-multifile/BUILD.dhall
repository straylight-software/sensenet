--| Multi-file Lean 4 project
--|
--| Demonstrates:
--|   - Hierarchical module imports (Straylight.Derivation, etc.)
--|   - External library usage (Std.HashMap)
--|   - Proof-carrying code (compile-time verified theorems)
--|   - Hermetic build via Buck2 + Nix toolchain

let E = ../../../dhall/evring/Compat.dhall

let straylight =
      (E.lean_binary "straylight"
        -- Order matters: dependencies first, Main.lean last
        [ "Derivation.lean"  -- Core types (no deps)
        , "Proofs.lean"      -- Theorems (imports Derivation)
        , "Store.lean"       -- Store ops (imports Derivation, Std)
        , "Main.lean"        -- Entry point (imports all)
        ])
        with root_module = Some "Straylight"

in  { targets = [ E.rule.leanBinary straylight ] }
