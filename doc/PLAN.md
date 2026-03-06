# sensenet Implementation Status

## Current State: Direct Execution with DICE

sensenet has evolved from a Buck2 wrapper to a **direct build system** that bypasses Buck2 entirely. The core pipeline:

```
BUILD.dhall -> Haskell IR -> DICE (FFI) -> execute
```

No Starlark, no BUCK generation at runtime, no Buck2 process. Just typed Dhall configuration and direct DICE execution.

## Completed

### Phase 1: Internal Representation

- [x] `SenseNet.IR` - Typed build graph (518 lines)
  - 18 rule types: CxxBinary, CxxLibrary, RustBinary, RustLibrary, HaskellBinary, HaskellLibrary, HaskellFFIBinary, LeanBinary, LeanLibrary, NvBinary, NvLibrary, PureScriptApp, PureScriptBinary, PureScriptLibrary, Genrule, NixCxxBinary, CratesIo, HttpArchive
  - Dependency types: DepLocal, DepFlake
  - Toolchain types for all languages

### Phase 2: Dhall Parsing

- [x] `SenseNet.Dhall` - BUILD.dhall parser using dhall library
  - Parses typed Dhall to Haskell IR
  - No shelling out to dhall CLI

### Phase 3: DICE Integration

- [x] `SenseNet.DICE` - DICE monad and operations
  - `inject` - Register source files
  - `compute` - Request computation
  - `registerTarget` - Register targets with dependencies
  - Content-addressed caching via BLAKE3

- [x] `SenseNet.DICE.FFI` - Rust FFI bindings
  - Safe wrappers around dice_ffi.so
  - Engine lifecycle management
  - Transaction handling

### Phase 4: Build Execution

- [x] `SenseNet.Build` - Build orchestration
  - `build` - Legacy single-target build
  - `buildWithDeps` - DICE-based dependency resolution
  - `buildWithConsole` - With superconsole TUI

- [x] Toolchain execution
  - C++ via clang (LLVM 22)
  - Rust via rustc
  - Haskell via GHC 9.12
  - Lean 4
  - CUDA via clang + ptxas
  - PureScript via purs + spago

### Phase 5: Console TUI

- [x] `SenseNet.Console` - Superconsole integration
  - Real-time build progress
  - Action status tracking
  - Graceful fallback for non-TTY

- [x] `SenseNet.Console.FFI` - Rust FFI bindings
  - Safe wrappers around superconsole_ffi.so

### Phase 6: Remote Execution

- [x] `SenseNet.Remote` - NativeLink client (partial)
  - Connection testing
  - Basic remote build support
  - gRPC via grapesy

- [x] Proto-lens generated types (REAPI v2)
  - Full Remote Execution API
  - Bytestream API

### Phase 7: CLI

- [x] `Main.hs` - Full CLI implementation
  - `sensenet build [target]`
  - `sensenet run <target>`
  - `sensenet clean`
  - `sensenet targets`
  - `sensenet query`
  - `sensenet graph`
  - `sensenet test-remote`
  - Options: `--no-tui`, `--no-deps`, `--remote`, `--remote-host`, `--remote-port`

## In Progress

### Buck2 Compatibility Mode

The project maintains Buck2 toolchain rules for `buck2 build` compatibility:

- [x] Generated BUCK files (from BUILD.dhall via devshell hook)
- [x] Starlark toolchain rules in `toolchains/*.bzl`
- [x] `.buckconfig` and `.buckconfig.local` support

This allows using either:
- `sensenet build //target` (direct DICE)
- `buck2 build //target` (traditional Buck2)

## Future Work

### Remote Execution Completion

- [ ] Full action execution via NativeLink
- [ ] Content-addressed storage integration
- [ ] Remote caching

### Parallel Multi-Target Builds

- [ ] Parallel DICE computation for multiple targets
- [ ] Better progress aggregation

### Watch Mode

- [ ] File system watching
- [ ] Incremental rebuilds on change

### Query Language

- [ ] Dhall-native target queries
- [ ] Dependency graph visualization

### Self-Hosting

- [ ] Build sensenet with sensenet (currently uses Buck2)
- [ ] Remove Buck2 dependency entirely

## File Structure

```
src/sensenet/
+-- Main.hs                    # CLI entry point
+-- SenseNet/
|   +-- IR.hs                  # Internal representation
|   +-- Dhall.hs               # BUILD.dhall parser
|   +-- Discover.hs            # File discovery
|   +-- Build.hs               # Build execution
|   +-- DICE.hs                # DICE monad
|   +-- DICE/FFI.hs            # Rust FFI
|   +-- Console.hs             # Superconsole
|   +-- Console/FFI.hs         # Rust FFI
|   +-- Remote.hs              # NativeLink client
|   +-- Toolchains.hs          # Toolchain loading
|   +-- Config.hs              # Project config (legacy)
|   +-- Emit.hs                # BUCK generation (legacy)
|   +-- Generate.hs            # Orchestration (legacy)
|   +-- Namespace.hs           # Linux namespace (legacy)
|   +-- Target.hs              # Target types (legacy)
+-- NativeLink/
|   +-- Client.hs
|   +-- Execution.hs
|   +-- Proto.hs
+-- Proto/                     # Proto-lens generated

src/vendor/
+-- dice/                      # DICE engine (from Buck2)
+-- superconsole/              # Terminal UI (from Buck2)
```

## Dependencies

```cabal
extra-libraries:  dice_ffi superconsole_ffi

build-depends:
  , dhall          >= 1.42
  , crypton        >= 0.34
  , grapesy        >= 0.1
  , proto-lens     >= 0.7
  , aeson          >= 2.0
```

## Milestones Achieved

| Milestone | Status | Description |
|-----------|--------|-------------|
| M1: Bootstrap | Done | CLI, DICE FFI, superconsole |
| M2: Local Execution | Done | Direct builds without Buck2 |
| M3: Dependency Resolution | Done | DICE-based dep ordering |
| M4: TUI | Done | Superconsole progress display |
| M5: Remote (partial) | In Progress | NativeLink connection, basic builds |

## Key Decisions

1. **No Buck2 at runtime** - sensenet drives DICE directly, not via Buck2
2. **Dhall, not Starlark** - Type safety at config time
3. **FFI, not IPC** - Direct Rust calls, not subprocess communication
4. **Output to sensenet-out/** - Separate from buck-out/ for parallel use
5. **Graceful TUI fallback** - Works in pipes and non-TTY contexts
