# SENSE // NET Implementation Plan

## Current State: Direct DICE Integration

sensenet now drives DICE directly via FFI, bypassing Buck2 entirely. The original
"Buck2 fiction" approach (generating BUCK files, bind-mounting, running Buck2) has
been superseded.

```
BUILD.dhall → Dhall parser → IR → DICE → execute
```

No Starlark generation. No Buck2 subprocess. Just typed Dhall to typed Haskell to
incremental builds.

## What's Working

### Core Pipeline ✓

- **Dhall parsing** — BUILD.dhall files parse into typed `IR.Package` via the
  dhall Haskell library (`SenseNet.Dhall`)
- **Internal representation** — Full typed build graph with all rule types
  (`SenseNet.IR`)
- **Toolchain loading** — `.sensenet/toolchains.dhall` provides compiler paths
  (`SenseNet.Toolchains`)
- **File discovery** — Walks project tree respecting .gitignore
  (`SenseNet.Discover`)

### Build Execution ✓

- **Direct compilation** — Invokes clang++, rustc, ghc, lean, purs directly
  (`SenseNet.Build`)
- **Nix dependency resolution** — `DepFlake "nixpkgs#foo"` resolves to store
  paths with correct -I/-L flags
- **DICE integration** — Incremental builds via FFI to vendored DICE engine
  (`SenseNet.DICE`, `SenseNet.DICE.FFI`)
- **Superconsole TUI** — Buck2-style progress display via FFI
  (`SenseNet.Console`, `SenseNet.Console.FFI`)

### Remote Execution (Partial) ✓

- **NativeLink client** — gRPC client for REAPI v2 (`NativeLink.*`)
- **CAS operations** — Upload/download to content-addressable storage
- **Remote builds** — Working for CxxBinary and Genrule

### Supported Languages ✓

| Language | Local Build | Remote Build |
|------------|-------------|--------------|
| C/C++ | ✓ | ✓ |
| Rust | ✓ | — |
| Haskell | ✓ | — |
| Lean 4 | ✓ | — |
| CUDA | ✓ | — |
| PureScript | ✓ | — |
| Genrule | ✓ | ✓ |

## Remaining Work

### P0: Critical Path to v1.0

1. **Self-hosting** 🎯

   - sensenet should build sensenet — this is the unlock
   - Every improvement compounds once we're self-hosting
   - Need BUILD.dhall for:
     - Haskell modules (SenseNet.*, NativeLink.*, Proto.\*)
     - Rust FFI crates (dice_ffi, superconsole_ffi)
   - Bootstrap via nix/cabal, then self-host
   - Milestone: `sensenet build //src/sensenet:sensenet` produces working binary

1. **Startup performance** ⚡ (good enough for now)

   - `sensenet query` was ~1.6s, now ~0.9s (44% faster)
   - Fixes applied:
     - [x] `-threaded -rtsopts "-with-rtsopts=-N"` for parallel runtime
     - [x] `mapConcurrently` for parallel Dhall parsing
   - Future (when we need \<200ms):
     - [ ] Cache normalized Dhall (hash inputs → cached IR)
     - [ ] Dhall semantic cache (`dhall freeze` prelude)
     - [ ] Target manifest for instant queries

1. **Remote execution for all languages**

   - Extend `SenseNet.Remote` to support Rust, Haskell, Lean, PureScript
   - Main challenge: capturing correct environment/toolchain for remote workers

1. **Action caching**

   - Local action cache (content-addressed by inputs)
   - Remote action cache via NativeLink
   - Currently DICE handles in-session caching; need persistent cache

1. **Parallel builds**

   - DICE supports parallelism; need to wire it through to Build.hs
   - Currently builds are sequential within a target

### P1: Quality of Life

6. **Better error messages**

   - Dhall parse errors should point to BUILD.dhall location
   - Build failures should show command + output clearly
   - Nix resolution failures need clearer diagnostics

1. **Query improvements**

   - `sensenet query deps(//foo:bar)` — show dependencies
   - `sensenet query rdeps(//..., //lib:core)` — reverse dependencies
   - Currently just lists all targets

1. **Watch mode**

   - `sensenet build --watch //foo:bar`
   - Re-run build on source file changes
   - Leverage DICE invalidation

### P2: Ecosystem

9. **Package manager integration**

   - `cratesIo` rule for Rust crates (exists but incomplete)
   - `hackage` rule for Haskell packages
   - Better `nixpkgs#` resolution caching

1. **IDE integration**

   - LSP-style diagnostics
   - compile_commands.json generation for C++

### P3: Advanced

11. **Distributed builds**

    - Multiple NativeLink workers
    - Geographic distribution
    - Build farm integration

01. **Artifact deduplication**

    - Share artifacts across projects
    - Remote cache population from CI

## File Structure

```
src/sensenet/
├── Main.hs                    # CLI entrypoint
├── SenseNet/
│   ├── IR.hs                  # Internal representation ✓
│   ├── Dhall.hs               # Dhall parsing ✓
│   ├── Build.hs               # Build execution ✓
│   ├── DICE.hs                # DICE interface ✓
│   ├── DICE/
│   │   └── FFI.hs             # DICE FFI bindings ✓
│   ├── Console.hs             # Superconsole interface ✓
│   ├── Console/
│   │   └── FFI.hs             # Superconsole FFI ✓
│   ├── Remote.hs              # NativeLink client ✓
│   ├── Toolchains.hs          # Toolchain config ✓
│   ├── Discover.hs            # File discovery ✓
│   ├── Emit.hs                # BUCK generation (legacy)
│   ├── Cache.hs               # Action cache (TODO)
│   └── Query.hs               # Query interface (TODO)
├── NativeLink/
│   ├── Client.hs              # CAS client ✓
│   ├── Execution.hs           # Remote execution ✓
│   └── Proto.hs               # Proto-lens types ✓
```

## Deleted / Superseded

The following were part of the "Buck2 fiction" approach and are no longer needed:

- `SenseNet.Namespace` — Linux namespace setup for bind mounts (never implemented)
- `SenseNet.Generate` — Orchestrating BUCK generation (absorbed into Build.hs)
- Most of `SenseNet.Emit` — Still exists but unused in primary flow

## Testing Strategy

1. **Unit tests** — IR construction, Dhall parsing, flag generation
1. **Integration tests** — Build each `src/examples/*/` project
1. **Golden tests** — Compare build output against expected
1. **Round-trip tests** — Parse → IR → (optionally emit) → build succeeds

## Open Questions

1. **Should SenseNet.Emit be removed?**

   - Pro: Dead code, confusing
   - Con: Might want Buck2 compatibility mode later

1. **Nix evaluation caching?**

   - Currently shells out to `nix build` each time
   - Could cache flake resolution in a sqlite db

1. **Dhall evaluation caching?**

   - Dhall is pure and normalizable
   - Could cache normalized output keyed by file hash

1. **Worker protocol?**

   - NativeLink is one option
   - Could also do simple SSH + rsync for small teams
