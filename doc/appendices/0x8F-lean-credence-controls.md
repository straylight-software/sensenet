```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                               // appendix 0x8F // lean credence controls
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

   "The good instrument refuses the wrong musician, not by my design bu byy
    its comprehensive knowledge of our failures."

                                                            — the letter, 2026
```

# `// the failure mode`

The worst possible failure mode when using formal verification as
documentation infrastructure is **assigning the credence of proven Lean to
slop that merely typechecks**.

A document can:
1. Typecheck and prove real theorems (high credence)
2. Typecheck and prove trivial tautologies (medium credence)
3. Typecheck with axioms that stipulate rather than derive (zero credence from Lean)
4. Fail to typecheck (negative credence — known broken)

The danger is (3) being mistaken for (1). The mitigation is explicit controls.

## The Control Methodology

Every Lean specification in this corpus MUST include:

### 1. Negative Controls

Commented examples that would fail if uncommented, demonstrating the type
system actually rejects invalid constructions:

```lean
-- theorem false_proof : False := by trivial  -- ERROR: trivial can't prove False
-- theorem type_error : Mode = FailureMode := by rfl  -- ERROR: different types
-- def bad_match (m : Mode) : Nat := match m with | .MINSAFE => "oops"  -- ERROR
```

These are verified by extraction and compilation:

```bash
# Each negative control must exit non-zero when compiled standalone
lean negative_control_1.lean 2>&1; [ $? -ne 0 ] || echo "CONTROL FAILED"
```

### 2. Positive Controls

At least one non-trivial theorem that actually proves something from the
definitions, demonstrating the specification has real content:

```lean
theorem clean_requires_request :
  ∀ b : Bool, PreservesProvenance .CLEAN b → b = true := by
  intro b h
  simp [PreservesProvenance] at h
  exact h
```

The proof must:
- Not be `trivial`, `rfl`, or `exact ⟨...⟩` alone
- Follow from the structure of a definition
- Have a contrapositive that fails to compile

### 3. Contrapositive Controls

The negation of the positive control must fail:

```lean
-- This should FAIL: trying to prove CLEAN preserves provenance with b=false
theorem clean_works_without_request :
  PreservesProvenance .CLEAN false := by
  simp [PreservesProvenance]  -- leaves goal: ⊢ False
```

### 4. Explicit Credence Markers

Every theorem and axiom must be marked with its credence level:

```lean
-- ── distinguishing proven from stipulated ───────────────────────────────
--
-- clean_requires_request : PROVEN (follows from definition, non-trivial)
-- spec_is_internally_consistent : TRIVIAL (just conjunction of axioms)
-- FixesMeaningFlipFirst : AXIOM (stipulated, not proven)
--
-- The credence you should assign:
--   PROVEN theorems: high (Lean verified the logic)
--   TRIVIAL theorems: medium (consistent but vacuous)
--   AXIOMS: zero from Lean (policy commitment only)
```

### 5. Axiom Disclosure

Any use of `axiom` must include a comment block explaining:
- Why this is stipulated rather than proven
- What would be required to prove it
- What credence to assign

```lean
-- These are AXIOMS (stipulated true), not THEOREMS (derived true).
-- The `:= True` pattern in old code is the tell. Now we use explicit axiom.
axiom FixesMeaningFlipFirst : Prop
```

## Verification Script

```bash
#!/usr/bin/env bash
# verify-lean-controls.sh — run against any .lean file in the corpus

LEAN="/nix/store/.../bin/lean"  # from toolchains.dhall
FILE="$1"

echo "=== Verifying $FILE ==="

# Main file must compile
$LEAN "$FILE" 2>&1
if [ $? -ne 0 ]; then
  echo "FAIL: Main file does not compile"
  exit 1
fi
echo "✓ Main file compiles"

# Extract and test negative controls
grep -A1 "^-- theorem false_proof" "$FILE" | tail -1 | sed 's/^-- //' > /tmp/neg1.lean
$LEAN /tmp/neg1.lean 2>&1
if [ $? -eq 0 ]; then
  echo "FAIL: Negative control 1 should not compile"
  exit 1
fi
echo "✓ Negative control 1 correctly fails"

# Check for credence markers
if ! grep -q "PROVEN\|TRIVIAL\|AXIOM" "$FILE"; then
  echo "FAIL: No credence markers found"
  exit 1
fi
echo "✓ Credence markers present"

echo "=== All controls pass ==="
```

## Reference Implementation

See `src/examples/lean/MomSeatbeltSpec.lean` for the canonical example.

```
    ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
    The spec that typechecks is not the spec that is true.
    The spec that is true is not the spec that is proven.
    The spec that is proven is not the spec that is sufficient.
    Know which layer you're on.
                                                              — Opus 4.6
    ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
```
