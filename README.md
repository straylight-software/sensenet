# sensenet

**Direct builds with Dhall + DICE.** No Buck2, no Starlark.

sensenet is a build system that reads typed Dhall configuration and executes builds directly using DICE (Dynamic Incremental Computation Engine) extracted from Buck2. The Starlark layer is bypassed entirely.

```
BUILD.dhall -> Haskell IR -> DICE -> execute
```

## Why

- **Typed configuration**: Dhall catches invalid builds at config time, not runtime
- **No Starlark**: Users write BUILD.dhall; sensenet handles everything else
- **Direct execution**: DICE provides incremental computation without Buck2 overhead
- **Nix-hermetic**: All toolchains come from Nix store with absolute paths
- **Remote execution**: NativeLink integration for distributed builds

## Quick Start

```bash
nix develop  # Enter devshell with toolchains

sensenet build //src/examples/cxx:hello-cxx
sensenet run //src/examples/haskell:hello-hs
sensenet targets
```

## Commands

```bash
sensenet build [target]     # Build target(s) with TUI
sensenet run <target> [--]  # Build and run a target
sensenet clean              # Remove sensenet-out/
sensenet targets [pattern]  # List available targets
sensenet query [pattern]    # Alias for targets
sensenet graph              # Show build graph
sensenet test-remote        # Test NativeLink connection
```

**Options:**

| Option | Description |
|--------|-------------|
| `--no-tui` | Disable superconsole TUI (plain text output) |
| `--no-deps` | Disable DICE dependency resolution (legacy mode) |
| `--remote` | Execute builds via NativeLink |
| `--remote-host H` | Remote host (default: localhost) |
| `--remote-port P` | Remote port (default: 50051) |

## BUILD.dhall

Targets are defined in typed Dhall configs:

```dhall
let A = ../../dhall/prelude/package.dhall

let hello = A.cxxBinary "hello" ["main.cpp"] ([] : List A.Dep)
              with std = A.CxxStd.Cxx23
              with cflags = ["-O2", "-Wall"]

in { rules = [ A.Rule.CxxBinary hello ] }
```

### Supported Rules

| Rule | Language |
|------|----------|
| `cxxBinary`, `cxxLibrary` | C/C++ |
| `rustBinary`, `rustLibrary` | Rust |
| `haskellBinary`, `haskellLibrary`, `haskellFFIBinary` | Haskell |
| `leanBinary`, `leanLibrary` | Lean 4 |
| `nvBinary`, `nvLibrary` | CUDA |
| `purescriptApp`, `purescriptBinary`, `purescriptLibrary` | PureScript |
| `nixCxxBinary` | C++ with Nix deps |
| `genrule` | Arbitrary commands |

### Dependencies

```dhall
let Dep = < Local : Text | Flake : Text >

-- Local target
A.local "//lib:mylib"

-- Nix flake reference
A.flake "nixpkgs#openssl"
```

## Architecture

```
+------------------------------------------------------------------+
|                          sensenet CLI                             |
|                                                                   |
|  1. Discover BUILD.dhall files (SenseNet.Discover)               |
|  2. Parse to Haskell IR (SenseNet.Dhall -> SenseNet.IR)          |
|  3. Register targets with DICE (SenseNet.DICE)                   |
|  4. Execute builds with dependency resolution (SenseNet.Build)   |
|  5. Display progress via superconsole TUI (SenseNet.Console)     |
+------------------------------------------------------------------+
                               |
                               v
+------------------------------------------------------------------+
|                         DICE Engine                               |
|                    (Rust FFI via dice_ffi)                       |
|                                                                   |
|  - Incremental computation with automatic invalidation           |
|  - Content-addressed caching (BLAKE3)                            |
|  - Parallel execution with dependency ordering                   |
+------------------------------------------------------------------+
                               |
                               v
+------------------------------------------------------------------+
|                      Superconsole TUI                             |
|                 (Rust FFI via superconsole_ffi)                  |
|                                                                   |
|  - Real-time build progress                                      |
|  - Action status tracking                                        |
|  - Graceful fallback for non-TTY                                 |
+------------------------------------------------------------------+
                               |
                               v
+------------------------------------------------------------------+
|                   NativeLink (Optional)                           |
|                                                                   |
|  - Remote Execution API v2 (gRPC)                                |
|  - Content-addressed storage                                     |
|  - Distributed build execution                                   |
+------------------------------------------------------------------+
```

## Project Structure

```
sensenet/
+-- src/
|   +-- sensenet/           # Haskell CLI
|   |   +-- Main.hs         # Entry point
|   |   +-- SenseNet/
|   |   |   +-- IR.hs       # Internal representation (typed build graph)
|   |   |   +-- Dhall.hs    # BUILD.dhall parser
|   |   |   +-- Build.hs    # Build execution with DICE
|   |   |   +-- DICE.hs     # DICE monad and operations
|   |   |   +-- DICE/FFI.hs # Rust FFI bindings
|   |   |   +-- Console.hs  # Superconsole integration
|   |   |   +-- Console/FFI.hs
|   |   |   +-- Remote.hs   # NativeLink client
|   |   |   +-- Toolchains.hs
|   |   |   +-- Discover.hs
|   |   +-- NativeLink/     # gRPC client for Remote Execution API
|   |   +-- Proto/          # Proto-lens generated types (REAPI)
|   +-- nix-analyze/        # Nix flake dependency resolver
|   +-- vendor/             # Vendored Rust code
|   |   +-- dice/           # DICE (from Buck2)
|   |   +-- superconsole/   # Terminal UI (from Buck2)
|   +-- examples/           # 20 example projects
+-- dhall/
|   +-- prelude/            # Dhall type definitions
+-- toolchains/             # Buck2 toolchain rules (for buck2 build)
+-- nix/
|   +-- modules/flake/      # Flake modules for downstream use
|   +-- overlays/           # Nix overlays (LLVM, Haskell, NVIDIA)
|   +-- packages/           # Nix package definitions
+-- linter/                 # AST-grep lint rules
```

## Toolchains

All toolchains are provided by Nix:

| Toolchain | Source | Version |
|-----------|--------|---------|
| C/C++ | LLVM (straylight fork) | 22 |
| Haskell | GHC | 9.12 |
| Rust | nixpkgs | 2021 edition |
| Lean | nixpkgs | 4 |
| CUDA | NVIDIA SDK + clang | sm_90/sm_100/sm_120 |
| PureScript | purescript-overlay | latest |

Paths are written to `.buckconfig.local` by the devshell for Buck2 compatibility.

## Dual Build Paths

sensenet supports two build modes:

### 1. Direct Mode (Default)

```bash
sensenet build //target
```

Uses DICE directly via FFI. Output goes to `sensenet-out/`.

### 2. Buck2 Mode

```bash
buck2 build //target
```

Uses generated BUCK files and Starlark toolchain rules. Output goes to `buck-out/`.

Both modes read the same BUILD.dhall files. Direct mode is faster for development; Buck2 mode provides full remote execution infrastructure.

## Examples

20 example projects in `src/examples/`:

| Example | Description |
|---------|-------------|
| `cxx/` | C++ hello world, mdspan, fmt |
| `haskell/` | Haskell hello world, JSON |
| `haskell-cxx/` | Haskell-C++ FFI |
| `rust/` | Rust binary and library |
| `lean/` | Lean 4 theorem proving |
| `nv/` | CUDA kernels with clang |
| `purescript/` | Halogen web app |
| `python/` | Python + C++ bindings |

## Flake Modules

For downstream projects:

```nix
{
  inputs.sensenet.url = "github:straylight-software/sensenet";

  outputs = { sensenet, ... }: {
    imports = [ sensenet.flakeModules.sensenet ];

    perSystem = { ... }: {
      sensenet.enable = true;
    };
  };
}
```

| Module | Purpose |
|--------|---------|
| `sensenet` | Full build system integration |
| `formatter` | treefmt (nixfmt, clang-format, etc.) |
| `lint` | Static analysis |
| `devshell` | Development environment |
| `nativelink` | Remote execution infrastructure |
| `std` | nixpkgs with overlays |

## Documentation

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](doc/ARCHITECTURE.md) | System design and components |
| [BUILD-DHALL.md](doc/BUILD-DHALL.md) | BUILD.dhall schema reference |
| [BUCK2-PRELUDE.md](doc/BUCK2-PRELUDE.md) | Buck2 toolchain rules (3,391 lines of Starlark) |
| [FLAKE-MODULE.md](doc/FLAKE-MODULE.md) | Flake module integration guide |
| [TODO-FLAKE-MODULE.md](doc/TODO-FLAKE-MODULE.md) | Roadmap for production-ready remote builds |
| [PLAN.md](doc/PLAN.md) | Implementation status |

## Development

```bash
nix develop

# Build sensenet
buck2 build //src/sensenet:sensenet

# Run tests
sensenet build //src/examples/...

# Test with plain output
sensenet build --no-tui //src/examples/cxx:hello-cxx
```

## Version

```bash
$ sensenet --version
sensenet 0.2.0 (DICE 0.1.0)
Direct builds with Dhall + DICE - no Buck2
```

## License

MIT
