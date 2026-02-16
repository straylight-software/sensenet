# sensenet

**Zero-Starlark builds.** Write `BUILD.dhall`, get remote execution.

sensenet wraps Buck2 with typed Dhall configuration, running builds through NativeLink's remote execution infrastructure by default. Users write `BUILD.dhall` files; sensenet generates the Buck2 machinery at runtime in a Linux namespace.

```
BUILD.dhall → Haskell IR → BUCK (ephemeral) → Buck2/DICE → NativeLink RE
```

## Why

- **Typed configuration**: Dhall catches invalid builds at config time, not runtime
- **No Starlark in repo**: Users never write `.bzl` files
- **Nix deps as first-class**: `deps = ["nixpkgs#openssl.dev"]` works directly
- **Remote-first**: NativeLink remote execution is the default, not an afterthought
- **Hermetic toolchains**: All tools come from Nix store with absolute paths

## Quick Start

```bash
nix develop  # Enter devshell with toolchains

sensenet build //src/examples/cxx:hello-cxx
sensenet run //src/examples/haskell:hello-hs
sensenet query //...
```

Or in your own flake:

```nix
{
  inputs.sensenet.url = "github:straylight-software/sensenet";

  outputs = { sensenet, ... }: {
    imports = [ sensenet.flakeModules.sensenet ];

    perSystem = { ... }: {
      sensenet.projects.myapp = {
        src = ./.;
        targets = [ "//src:myapp" ];
        toolchain = {
          cxx.enable = true;
          haskell.enable = true;
        };
        remoteexecution = {
          enable = true;  # Default
          scheduler = "your-scheduler.fly.dev";
          cas = "your-cas.fly.dev";
        };
      };
    };
  };
}
```

## BUILD.dhall

```dhall
let A = ../../dhall/prelude/package.dhall

let server =
      (A.cxxBinary "server" ["main.cpp", "server.cpp"])
        with deps = [A.local ":utils", A.flake "nixpkgs#openssl.dev"]
        with std = A.CxxStd.Cxx23

in { targets = [ A.rule.cxxBinary server ] }
```

Supported rules:

| Rule                                                  | Languages                 |
| ----------------------------------------------------- | ------------------------- |
| `cxxBinary`, `cxxLibrary`                             | C, C++                    |
| `rustBinary`, `rustLibrary`                           | Rust                      |
| `haskellBinary`, `haskellLibrary`, `haskellFFIBinary` | Haskell                   |
| `leanBinary`, `leanLibrary`                           | Lean 4                    |
| `nvBinary`, `nvLibrary`                               | CUDA (clang + ptxas)      |
| `purescriptApp`, `purescriptBinary`                   | PureScript                |
| `nixCxxBinary`                                        | C++ with Nix dependencies |
| `genrule`                                             | Arbitrary commands        |

## Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                              sensenet CLI                              │
│                                                                        │
│  1. Discover BUILD.dhall files                                         │
│  2. Parse to typed Haskell IR                                          │
│  3. Generate BUCK files to /tmp/sensenet-xxx/                          │
│  4. Set up Linux namespace with bind mounts                            │
│  5. Execute buck2 in namespace                                         │
└────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│                           Mount Namespace                              │
│                                                                        │
│  project/                                                              │
│  ├── src/myapp/BUCK      ← bind mount from /tmp/sensenet-xxx/          │
│  ├── toolchains/         ← bind mount (Starlark rules)                 │
│  ├── prelude/            ← bind mount (buck2-prelude from Nix)         │
│  └── .buckconfig         ← bind mount (generated config)               │
│                                                                        │
│  Buck2 sees a complete project without modifying your repo             │
└────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│                          Buck2 (DICE Engine)                           │
│                                                                        │
│  - Incremental computation via DICE                                    │
│  - Tool paths from .buckconfig.local (Nix store)                       │
│  - Remote execution via RE API v2                                      │
└────────────────────────────────────────────────────────────────────────┘
                                   │
                                   ▼
┌────────────────────────────────────────────────────────────────────────┐
│                      NativeLink (Remote Execution)                     │
│                                                                        │
│  ┌─────────────┐     ┌─────────────┐     ┌─────────────┐              │
│  │  Scheduler  │────▶│   Workers   │◀───▶│     CAS     │              │
│  │  (Fly.io)   │     │  (Fly.io)   │     │ (R2/S3)     │              │
│  └─────────────┘     └─────────────┘     └─────────────┘              │
│                                                                        │
│  - Same Nix toolchains as local builds                                 │
│  - BLAKE3 content addressing                                           │
│  - Builds run remotely by default                                      │
└────────────────────────────────────────────────────────────────────────┘
```

## Nix Dependencies

Any flake reference works as a dependency:

```dhall
let mylib = A.cxxLibrary "mylib" ["lib.cpp"]
      with deps = [
        A.flake "nixpkgs#zlib",
        A.flake "nixpkgs#openssl.dev",
        A.flake "github:user/repo#package"
      ]
```

Resolution happens via `nix-analyze`:

```
nixpkgs#zlib
    ↓
nix build nixpkgs#zlib.dev --print-out-paths
nix build nixpkgs#zlib.out --print-out-paths
pkg-config --libs z
    ↓
-isystem /nix/store/xxx-zlib-dev/include
-L/nix/store/yyy-zlib/lib
-Wl,-rpath,/nix/store/yyy-zlib/lib
-lz
```

## Toolchains

All toolchains are Nix-hermetic with paths from the devshell:

| Toolchain  | Source                    | Notes                           |
| ---------- | ------------------------- | ------------------------------- |
| C/C++      | LLVM 22 (straylight fork) | SM120 Blackwell support         |
| Haskell    | GHC 9.12                  | ghcWithPackages integration     |
| Rust       | rustc from nixpkgs        | 2021 edition default            |
| Lean       | lean4 from nixpkgs        | Theorem proving + executables   |
| CUDA       | NVIDIA SDK + clang        | No nvcc, pure clang compilation |
| PureScript | purs + spago              | Halogen app bundling            |

Paths are written to `.buckconfig.local` by the devshell:

```ini
[cxx]
cc = /nix/store/xxx/bin/clang
cxx = /nix/store/xxx/bin/clang++
ar = /nix/store/xxx/bin/llvm-ar
ld = /nix/store/xxx/bin/ld.lld

[haskell]
ghc = /nix/store/yyy/bin/ghc
ghc_pkg = /nix/store/yyy/bin/ghc-pkg
```

## Remote Execution

Remote execution via NativeLink is the default mode. Local-only mode exists for testing:

```dhall
-- toolchains/BUILD.dhall
let lre = (A.executionPlatform "lre")
      with local_enabled = True
      with remote_enabled = True   -- Default: remote

let local = (A.executionPlatform "local")
      with local_enabled = True
      with remote_enabled = False  -- Testing only
```

Workers run as Nix containers on Fly.io with identical toolchains to local builds.

## Project Structure

```
sensenet/
├── src/
│   ├── sensenet/           # Haskell CLI
│   │   ├── Main.hs         # Entry point
│   │   └── SenseNet/
│   │       ├── IR.hs       # Internal representation
│   │       ├── Dhall.hs    # BUILD.dhall parser
│   │       ├── Emit.hs     # BUCK generator
│   │       ├── Namespace.hs # Linux namespace setup
│   │       └── Generate.hs # Orchestration
│   └── nix-analyze/        # Nix dependency resolver
├── dhall/
│   └── prelude/            # Dhall type definitions
├── toolchains/             # Starlark toolchain rules
│   ├── cxx.bzl
│   ├── haskell.bzl
│   ├── rust.bzl
│   └── ...
├── nix/
│   └── modules/flake/
│       ├── sensenet/       # Flake module
│       └── nativelink/     # RE infrastructure
└── src/examples/           # Example projects
```

## Commands

```bash
sensenet build [target]     # Build (remote by default)
sensenet run <target>       # Build and execute
sensenet clean              # Kill daemon, clean buck-out
sensenet query <expr>       # Query build graph
sensenet targets [dir]      # List available targets
sensenet emit-buck <file>   # Debug: show generated BUCK
sensenet graph [pattern]    # Show build graph
```

## Flake Modules

| Module       | Purpose                                      |
| ------------ | -------------------------------------------- |
| `sensenet`   | Full build system integration                |
| `formatter`  | treefmt (nixfmt, clang-format, rustfmt, ...) |
| `lint`       | Static analysis (statix, clang-tidy, ...)    |
| `devshell`   | Development environment                      |
| `nativelink` | Remote execution infrastructure              |
| `std`        | nixpkgs with overlays                        |

## Development

```bash
# Enter devshell
nix develop

# Build sensenet CLI
ghc -o sensenet -isrc/sensenet src/sensenet/Main.hs -threaded

# Test build
./sensenet build //src/examples/cxx:hello-cxx

# Run tests
./sensenet build //src/examples/...
```

## What's Next: FFI to DICE

The current architecture generates BUCK files as text, then runs Buck2. The next step is direct FFI to Buck2's DICE engine:

```
Current:  Dhall → Haskell IR → BUCK (text) → Starlark parser → DICE
Future:   Dhall → Haskell IR → Rust FFI → DICE (direct)
```

This eliminates the Starlark intermediary entirely, enabling:

- Typed build graph manipulation in Haskell
- Direct access to DICE incremental computation
- Richer tooling that understands the build graph natively

## License

MIT
