# sense/net Test Suite

> "The matrix has its roots in primitive arcade games, in early graphics
> programs and military experimentation with cranial jacks."
>
> — Neuromancer

## Overview

This test suite exercises the integration between:

- **nix-compile**: Type inference for Nix/bash (Hindley-Milner + row polymorphism)
- **sense/net**: Typed build graphs (Dhall → Starlark) with proof obligations
- **DischargeProof**: Coeffect evidence for verified builds

## Test Structure

```
test/sensenet/
├── README.md                    # this file
├── run-tests.sh                 # test runner
├── toolchain-types.nix          # Nix toolchain type inference
├── toolchain-types.nix.expected # expected output (currently failing)
├── cross-language.nix           # Nix → Dhall → Starlark data flow
├── proof-obligations.dhall      # DischargeProof type exercises
└── build-graph.dhall            # Build graph with proof obligations
```

## Running Tests

```bash
# From devshell (has nix-compile in PATH)
nix develop
./test/sensenet/run-tests.sh

# With verbose output
./test/sensenet/run-tests.sh --verbose

# Regenerate expected outputs (when features are implemented)
./test/sensenet/run-tests.sh --bless
```

## Test Categories

### 1. Dhall Type Checking

Verifies that all Dhall files type-check:

- `Resource.dhall` — Coeffect algebra
- `DischargeProof.dhall` — Build evidence types
- `Toolchain.dhall` — Toolchain configuration
- `Build.dhall` — Build target types

**Status**: ✓ Passing

### 2. Proof Obligations

Exercises the `DischargeProof.dhall` types:

- Pure builds have empty coeffects
- Network builds require NetworkAccess evidence
- Proofs compose under tensor product
- Insufficient evidence is detected

**Status**: ✗ Partially failing (Lean4 verification not implemented)

### 3. nix-compile Integration

Tests nix-compile on sense/net code:

- Parse toolchain definitions
- Infer types for Nix expressions
- Track coeffects through derivations
- Cross-language dependency analysis

**Status**: ✗ Failing (expected, features not implemented)

### 4. Build Graph Analysis

Tests the full build graph typing:

- Targets have typed dependencies
- Coeffects propagate through dependency graph
- Proof obligations can be verified

**Status**: ✗ Failing (expected, features not implemented)

### 5. Flake Module

Tests the nix-compile flake module:

- Module file exists and parses
- Options are correctly defined
- Checks are properly configured

**Status**: ✓ Passing

## Expected Failures

The test suite uses "expected failure" (XFAIL) markers for features that
are designed but not yet implemented:

| Feature | Status | Reason |
|---------|--------|--------|
| Cross-file type inference | XFAIL | nix-compile doesn't trace imports |
| Coeffect inference | XFAIL | Not implemented |
| Cross-language report | XFAIL | `--cross-lang-report` flag missing |
| Lean4 proof verification | XFAIL | Lean4 formalization incomplete |
| Coeffect propagation | XFAIL | Graph analysis not implemented |

## Integration with nix-compile

The flake module at `nix/modules/flake/nix-compile/default.nix` provides:

```nix
{
  imports = [ inputs.sensenet.flakeModules.nix-compile ];

  sense.nix-compile = {
    enable = true;
    profile = "strict";        # strict | standard | minimal | security
    verify-dhall = true;       # type-check Dhall files
    verify-proofs = false;     # Lean4 verification (requires toolchain)
    cross-language = true;     # Nix → Dhall → Starlark tracking
    buck2-graph = true;        # Analyze buck2 build graph
  };
}
```

This adds the following checks:

- `checks.${system}.sense-nix-compile` — nix-compile on Nix files
- `checks.${system}.sense-dhall` — Dhall type checking
- `checks.${system}.sense-cross-lang` — Cross-language analysis
- `checks.${system}.sense-buck2-graph` — Build graph analysis
- `checks.${system}.sense-proofs` — Proof verification (optional)

## Adding New Tests

### Nix Tests

1. Create `test/sensenet/your-test.nix`
2. Add `__tests` attribute with test metadata
3. Create `test/sensenet/your-test.nix.expected`
4. Add to `run-tests.sh`

### Dhall Tests

1. Create `test/sensenet/your-test.dhall`
2. Use Dhall assertions for type-level tests
3. Add to `run-tests.sh`

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   Nix files     │────▶│  nix-compile    │────▶│  Type report    │
│  (toolchains)   │     │  (Haskell)      │     │  (violations)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
        │                       ▼                       │
        │               ┌─────────────────┐             │
        │               │ Cross-language  │             │
        │               │   bridge        │             │
        │               └─────────────────┘             │
        │                       │                       │
        ▼                       ▼                       ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Dhall files    │────▶│  Dhall checker  │────▶│  Type check     │
│ (Build, Proof)  │     │  (dhall binary) │     │  (pass/fail)    │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
        │                       ▼                       │
        │               ┌─────────────────┐             │
        │               │  to-buck2.dhall │             │
        │               │  (transpiler)   │             │
        │               └─────────────────┘             │
        │                       │                       │
        ▼                       ▼                       ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Starlark       │────▶│    buck2        │────▶│  Build graph    │
│  (.bzl files)   │     │    audit        │     │  (JSON)         │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                       │
        │                       ▼                       │
        │               ┌─────────────────┐             │
        │               │  Lean4 verifier │             │
        │               │  (optional)     │             │
        │               └─────────────────┘             │
        │                       │                       │
        ▼                       ▼                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    DischargeProof                                │
│  (evidence that coeffects were satisfied during build)           │
└─────────────────────────────────────────────────────────────────┘
```

## Related Documentation

- [nix-compile SPECIFICATION.md](../../nix-compile/SPECIFICATION.md)
- [Dhall configuration](../../dhall/README.md)
- [DischargeProof.dhall](../../dhall/DischargeProof.dhall)
- [Straylight Cube architecture](https://straylight.software/straylight-cube.svg)
