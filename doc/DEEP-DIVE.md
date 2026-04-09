# sensenet Deep Dive

A comprehensive technical analysis of the sensenet codebase.

## Overview

sensenet is a typed build system that eliminates Starlark in favor of Dhall configuration, providing compile-time type checking for build definitions. It implements its own DICE-inspired incremental computation engine in pure Haskell, with content-addressed caching and parallel execution.

**Key Innovation**: Instead of generating BUCK files and shelling out to Buck2, sensenet now implements its own build executor with DICE semantics directly in Haskell. This removes the Buck2 dependency entirely for most use cases.

## Architecture At a Glance

```
BUILD.dhall ──> SenseNet.Dhall ──> SenseNet.IR ──> SenseNet.Build ──> SenseNet.DICE
     │              (parse)           (typed)        (actions)        (execute)
     │                                                   │
     │                                                   v
     └──────────────────────────────────────────> sensenet-out/
```

## Core Components

### 1. Internal Representation (`SenseNet.IR`)

**Location**: `src/sensenet/SenseNet/IR.hs` (519 lines)

The IR is the typed backbone of sensenet. All BUILD.dhall files ultimately resolve to these types.

**Key Types**:

```haskell
-- Dependencies: local targets or Nix flake refs
data Dep = DepLocal Text | DepFlake Text

-- The Rule union - every build target is one of these
data Rule
  = RCxxBinary CxxBinary
  | RCxxLibrary CxxLibrary
  | RRustBinary RustBinary
  | RRustLibrary RustLibrary
  | RHaskellBinary HaskellBinary
  | RHaskellLibrary HaskellLibrary
  | RHaskellFFIBinary HaskellFFIBinary
  | RLeanBinary LeanBinary
  | RLeanLibrary LeanLibrary
  | RNvBinary NvBinary
  | RNvLibrary NvLibrary
  | RPureScriptApp PureScriptApp
  | RPureScriptBinary PureScriptBinary
  | RPureScriptLibrary PureScriptLibrary
  | RGenrule Genrule
  | RNixCxxBinary NixCxxBinary
  | RCratesIo CratesIo
  | RHttpArchive HttpArchive

-- A package is a directory with BUILD.dhall
data Package = Package { path :: FilePath, rules :: [Rule] }
```

**Design Decisions**:

- Each rule type is a separate Haskell record (not a tagged union with shared fields)
- `Dep` distinguishes between local targets (`:foo`, `//pkg:bar`) and Nix deps (`nixpkgs#zlib`)
- `Vis` (Public/Private) tracks target visibility for future enforcement

### 2. Dhall Parser (`SenseNet.Dhall`)

**Location**: `src/sensenet/SenseNet/Dhall.hs` (592 lines)

Bridges Dhall's type system to Haskell IR using `FromDhall` typeclass.

**Pattern**: Two-layer types

- `DhallRule`, `DhallCxxBinary`, etc. - types with `FromDhall` instances
- `IR.Rule`, `IR.CxxBinary`, etc. - internal types (no Dhall dependency)

```haskell
-- Dhall types use snake_case (Dhall convention)
data DhallHaskellBinary = DhallHaskellBinary
  { name :: Text
  , language_extensions :: [Text]  -- snake_case
  , ghc_options :: [Text]
  , ...
  }

-- IR types use camelCase (Haskell convention)  
data HaskellBinary = HaskellBinary
  { name :: Text
  , languageExtensions :: [Text]  -- camelCase
  , ghcOptions :: [Text]
  , ...
  }
```

**Critical Detail**: `DhallRule` constructors must be in alphabetical order for `FromDhall` to work correctly (it uses constructor index matching).

### 3. DICE Engine (`SenseNet.DICE`)

**Location**: `src/sensenet/SenseNet/DICE.hs` (581 lines)

A pure Haskell implementation of content-addressed incremental computation, inspired by Buck2's DICE.

**Core Concept**: `ActionKey = hash(inputs + command)`

If inputs haven't changed, outputs are unchanged - skip execution.

**Key Types**:

```haskell
-- Content-addressed action key (BLAKE2b-256)
newtype ActionKey = ActionKey { unActionKey :: ByteString }

-- An action in the build graph
data Action = Action
  { aName      :: Text           -- "//pkg:target"
  , aCommand   :: [Text]         -- ["clang++", "-o", ...]
  , aInputs    :: [Text]         -- Source file hashes
  , aInputKeys :: [ActionKey]    -- Dependencies on other actions
  , aOutputs   :: [Text]         -- Expected output paths
  , aEnv       :: Map Text Text  -- Environment variables
  , aCoeffects :: [Text]         -- Resource requirements
  }

-- Build graph with topological ordering
data ActionGraph = ActionGraph
  { agActions :: Map ActionKey Action
  , agRoots   :: [ActionKey]
  }
```

**Execution Modes**:

1. **Sequential** (`executeGraph`): Process actions in topological order
1. **Parallel** (`executeGraphParallel`): Execute independent actions concurrently
1. **Job-Limited** (`executeGraphWithJobs`): Parallel with `-j N` throttling

**Caching**: Persistent file-based cache at `~/.cache/sensenet/actions/`

```haskell
-- Cache location: ~/.cache/sensenet/actions/<action-key-hex>
-- Content: null-separated output paths
checkCache :: ActionCache -> ActionKey -> IO (Maybe ActionResult)
storeCache :: ActionCache -> ActionKey -> ActionResult -> IO ()
```

### 4. Build Orchestration (`SenseNet.Build`)

**Location**: `src/sensenet/SenseNet/Build.hs` (1400+ lines)

The heart of sensenet - converts rules to actions and executes them.

**Entry Points**:

```haskell
build           :: Toolchains -> FilePath -> Package -> Text -> IO (Either BuildError BuildResult)
buildWithDeps   :: Toolchains -> FilePath -> Package -> Text -> IO (Either BuildError BuildResult)
buildWithDepsJ  :: Maybe Int -> Toolchains -> FilePath -> Package -> Text -> IO (...)
buildAllTargets :: Toolchains -> FilePath -> Package -> IO (Either BuildError Int)
```

**Rule-to-Action Pipeline**:

1. **Discover Sources**: Find files matching `srcs` patterns
1. **Hash Inputs**: BLAKE2b-256 of each source file
1. **Resolve Dependencies**: Parse `:local` and `//cross-package:deps`
1. **Generate Command**: Build compiler invocation from toolchain + flags
1. **Create Action**: Package into `Action` struct with coeffects
1. **Execute**: Run via `runAction` or cache-skip if hit

**Cross-Package Dependencies**:

```haskell
-- Parse "//pkg/path:target" or ":local"
parseDep :: Text -> (Maybe Text, Text)
parseDep dep
  | "//" `T.isPrefixOf` dep = ... -- (Just "pkg/path", "target")
  | ":" `T.isPrefixOf` dep  = ... -- (Nothing, "target")

-- Load packages lazily as deps are discovered
collectDepsWithPackages :: FilePath -> Map Text Package -> Package -> Rule 
                        -> IO (Map Text Package, [(Package, Rule)])
```

### 5. DhallFast Optimizer (`DhallFast.*`)

**Location**: `src/sensenet/DhallFast/` (4 modules)

A cache-optimized Dhall evaluator providing 2-10x speedup.

**Core Optimizations**:

| Component | Standard Dhall | DhallFast |
|-----------|---------------|-----------|
| Variables | `(Text, Int)` | De Bruijn `Int` |
| Records | `Map Text a` | Sorted `Vector (Name, a)` |
| Strings | `Text` | Interned `ShortText` |
| Literals | Boxed | Unboxed (Word64, Int64, etc.) |

**Key Files**:

- `Core.hs`: Compact AST targeting 32-byte nodes (vs ~80+ bytes upstream)
- `Eval.hs`: Normalizer using strict spine evaluation
- `Convert.hs`: Conversion from/to standard Dhall
- `Input.hs`: Drop-in replacement for `Dhall.inputFile`

**Usage**:

```haskell
-- Instead of:
import Dhall (inputFile, auto)

-- Use:
import DhallFast.Input (inputFile, auto)

config <- inputFile auto "BUILD.dhall"
```

### 6. Toolchains (`SenseNet.Toolchains`)

**Location**: `src/sensenet/SenseNet/Toolchains.hs`

Loads toolchain paths from `.sensenet/toolchains.dhall`.

```haskell
data Toolchains = Toolchains
  { cxx        :: Cxx
  , rust       :: Rust
  , haskell    :: Haskell
  , lean       :: Lean
  , python     :: Python
  , purescript :: PureScript
  }

data Cxx = Cxx
  { cc    :: Tool    -- clang
  , cxx   :: Tool    -- clang++
  , ar    :: Tool    -- llvm-ar
  , ld    :: Tool    -- ld.lld
  , paths :: Paths   -- include/lib dirs
  }
```

All paths are absolute Nix store paths, ensuring hermetic builds across machines.

### 7. nix-analyze Tool

**Location**: `src/nix-analyze/`

Standalone CLI for resolving Nix flake refs to compiler flags.

```bash
# Get compiler/linker flags for a package
nix-analyze resolve nixpkgs#zlib nixpkgs#openssl

# Output:
# -isystem /nix/store/.../include
# -L/nix/store/.../lib
# -Wl,-rpath,/nix/store/.../lib
# -lz
# -lssl
# -lcrypto
```

**Modes**:

- `resolve`: Output compiler flags (preferred, no JSON)
- `unroll`: Get build commands for a derivation (JSON)
- `deps`: Get dependency graph (JSON)

**Integration**: Called by `SenseNet.Build.resolveNixDeps` for `NixCxxBinary` rules.

## Dhall Type System

### Prelude Structure

```
dhall/prelude/
├── package.dhall      # Main export (all rules + constructors)
├── Types.dhall        # Dep, CxxStd, Vis
├── Rule.dhall         # Union type of all rules
├── Cxx.dhall          # cxxBinary, cxxLibrary
├── Rust.dhall         # rustBinary, rustLibrary
├── Haskell.dhall      # haskellBinary, haskellLibrary, haskellFFIBinary
├── Lean.dhall         # leanBinary, leanLibrary
├── Nv.dhall           # nvBinary, nvLibrary (CUDA)
├── PureScript.dhall   # purescriptApp, purescriptBinary
├── Genrule.dhall      # genrule
├── NixCxx.dhall       # nixCxxBinary (C++ with Nix deps)
├── RustCrate.dhall    # cratesIo, httpArchive
└── Toolchain.dhall    # Toolchain types for toolchains/BUILD.dhall
```

### Example BUILD.dhall

```dhall
let A = ../../dhall/prelude/package.dhall

let hello = A.cxxBinary "hello" ["main.cpp"]
  with deps = [A.local ":utils", A.flake "nixpkgs#openssl.dev"]
  with std = A.CxxStd.Cxx23

in { targets = [A.rule.CxxBinary hello] }
```

### Type Definitions (Types.dhall)

```dhall
let Dep = < Local : Text | Flake : Text >
let CxxStd = < Cxx11 | Cxx14 | Cxx17 | Cxx20 | Cxx23 >
let Vis = < Public | Private >

in { Dep, CxxStd, Vis
   , local = Dep.Local
   , flake = Dep.Flake
   , nix = \(p : Text) -> Dep.Flake "nixpkgs#${p}"
   }
```

## Starlark Toolchains (Buck2 Mode)

For compatibility with Buck2, sensenet can generate BUCK files and use Starlark toolchains.

**Location**: `toolchains/`

Key files:

- `cxx.bzl`: LLVM C++ toolchain (reads paths from `.buckconfig.local`)
- `haskell.bzl`: GHC toolchain
- `rust.bzl`: rustc toolchain
- `lean.bzl`: Lean 4 toolchain
- `nv.bzl`: CUDA toolchain (clang + ptxas)
- `execution.bzl`: Execution platform (local/remote)

### cxx.bzl Highlights

```python
def _llvm_toolchain_impl(ctx: AnalysisContext) -> list[Provider]:
    # Read tool paths from .buckconfig (Nix store paths)
    cc = read_root_config("cxx", "cc", "clang")
    cxx = read_root_config("cxx", "cxx", "clang++")
    
    # Build include flags from config
    clang_resource_dir = read_root_config("cxx", "clang_resource_dir", None)
    if clang_resource_dir:
        include_flags.append("-resource-dir=" + clang_resource_dir)
    
    # Always use lld
    extra_link_flags.append("-fuse-ld=lld")
```

## Build Output Structure

```
sensenet-out/
├── src/examples/cxx/
│   ├── hello-cxx            # Binary output
│   └── libutils.a           # Library output
├── src/examples/rust/
│   ├── hello-rs
│   └── libmylib.rlib
└── src/examples/haskell/
    ├── hello-hs
    └── mylib-hi/            # Interface files
        ├── MyModule.hi
        └── MyModule.o
```

## Performance Characteristics

### DICE Engine

| Operation | Throughput | Notes |
|-----------|------------|-------|
| ActionKey (BLAKE2b-256) | 509K keys/sec | 1.96 µs per key |
| Graph insertion | 235K inserts/sec | Map-based |
| Topological sort | 1.6M nodes/sec | For independent nodes |

### DhallFast vs Standard

| Workload | Standard | DhallFast | Speedup |
|----------|----------|-----------|---------|
| Simple arithmetic | 0.21 µs | 0.02 µs | 10x |
| 200 nested lets | 9.2 µs | 2.4 µs | 3.9x |
| Record 100 fields | 1.35 µs | 0.28 µs | 4.8x |

## Supported Languages

| Language | Rules | Toolchain | Notes |
|----------|-------|-----------|-------|
| C/C++ | `cxxBinary`, `cxxLibrary`, `nixCxxBinary` | LLVM 22 (clang++) | SM120 Blackwell support via straylight fork |
| Rust | `rustBinary`, `rustLibrary`, `cratesIo` | rustc | 2021 edition default |
| Haskell | `haskellBinary`, `haskellLibrary`, `haskellFFIBinary` | GHC 9.12 | Package resolution via ghc-pkg |
| Lean 4 | `leanBinary`, `leanLibrary` | lean/leanc | Theorem proving + executables |
| CUDA | `nvBinary`, `nvLibrary` | clang + ptxas | No nvcc, pure clang compilation |
| PureScript | `purescriptApp`, `purescriptBinary` | purs + esbuild | Halogen app bundling |
| Generic | `genrule` | sh | Arbitrary commands |

## Example Projects

The `src/examples/` directory contains 22 example projects:

| Example | Description |
|---------|-------------|
| `cxx/` | Basic C++ binary |
| `rust/` | Rust binary with library dep |
| `haskell/` | Haskell binary with packages |
| `haskell-cxx/` | Haskell-C++ FFI binary |
| `lean/` | Lean 4 theorem prover |
| `purescript/` | Halogen web app |
| `nv/` | CUDA kernel |
| `cross-pkg-test/` | Cross-package dependencies |
| `multi-dep/` | Multiple dependencies |
| `zlib-test/` | Nix dependency integration |
| `simdjson/` | NixCxxBinary example |

## Nix Integration

### Flake Structure

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    llvm-project.url = "github:straylight-software/llvm-project";  # LLVM 22 fork
    buck2-prelude.url = "github:weyl-ai/straylight-buck2-prelude";
    nativelink.url = "github:TraceMachina/nativelink";
    nvidia-sdk.url = "...";  # CUDA 13.1
    purescript-overlay.url = "github:thomashoneyman/purescript-overlay";
  };
  
  outputs = { flake-parts, ... }:
    flake-parts.lib.mkFlake { ... } {
      imports = [ ./nix/modules/flake/_index.nix ];
      
      flake.flakeModules = {
        sensenet = import ./nix/modules/flake/sensenet/default.nix;
        formatter = import ./nix/modules/flake/formatter.nix;
        lint = ./nix/modules/flake/lint.nix;
        devshell = import ./nix/modules/flake/devshell.nix;
        nativelink = ./nix/modules/flake/nativelink/flake-module.nix;
      };
    };
}
```

### Bootstrap Stages

sensenet uses a 3-stage bootstrap:

| Stage | Package | Purpose | Time |
|-------|---------|---------|------|
| 1 | `sensenet-bootstrap` | Minimal deps, initial bootstrap | ~30s |
| 2 | `sensenet-local` | Local features, no gRPC | ~30s |
| 3 | `sensenet` | Full build, remote execution | ~45s |

```bash
nix build .#sensenet-bootstrap  # Stage 1
nix build .#sensenet-local      # Stage 2
nix build .#sensenet            # Stage 3 (production)
```

## Remote Execution

sensenet supports remote execution via NativeLink (REAPI v2):

```nix
sensenet.projects.myapp = {
  remoteexecution = {
    enable = true;
    scheduler = "aleph-scheduler.fly.dev";
    cas = "aleph-cas.fly.dev";
    tls = true;
  };
};
```

**Architecture**:

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│    Scheduler    │────>│     Workers     │<───>│       CAS       │
│   (Fly.io)      │     │   (Fly.io)      │     │   (R2/S3)       │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

Workers run with identical Nix toolchains as local builds.

## CLI Reference

```bash
sensenet build <target> [-j N]   # Build target(s) with N parallel jobs
sensenet targets                  # List available targets
sensenet clean [--full]           # Remove build outputs (--full: clear cache)
```

**Target Patterns**:

- `//path/to/pkg:target` - Single target
- `//path/to/pkg:all` - All targets in package
- `//path/...` - All targets recursively

**Options**:

- `-j N, --jobs=N` - Limit parallel jobs (default: 80% of cores)
- `--all-cores` - Use all cores (unlimited parallelism)

## Future Directions

See [ROADMAP-v0.5.md](ROADMAP-v0.5.md) for the complete plan.

### sensenet v0.5: Distributed Build System

The next major version transforms sensenet into a fully distributed, coeffect-tracked build system:

1. **Native RE API v2** - Haskell implementation of gRPC client/server
1. **sensenet-worker** - Worker daemon with sandbox execution
1. **sensenet-scheduler** - Action routing and platform matching
1. **sensenet-cas** - Content-addressable storage service
1. **Coeffect Proofs** - Cryptographic attestations of build requirements

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              DEVELOPER MACHINE                               │
│   BUILD.dhall ──> sensenet build //pkg:target ──> RE API v2 ──> Results    │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
          ┌───────────────────────────┼───────────────────────────┐
          ▼                           ▼                           ▼
    ┌───────────┐              ┌───────────┐              ┌───────────┐
    │  Worker   │              │  Worker   │              │  Worker   │
    │  (Fly)    │              │  (local)  │              │  (k8s)    │
    │  Same Nix │              │  Same Nix │              │  Same Nix │
    │  closure  │              │  closure  │              │  closure  │
    └───────────┘              └───────────┘              └───────────┘
```

### Key Features

- **Identical toolchains everywhere** - Workers use same Nix closure as client
- **Zero-config remote execution** - Workers auto-discover from flake
- **Cryptographic attestations** - Ed25519 signed DischargeProofs
- **One-command deployment** - `nix build .#worker-image`

### Coeffect System (from armitage)

The existing `dhall/Resource.dhall` and `dhall/DischargeProof.dhall` will be integrated:

```haskell
-- Typed coeffects
data Resource = Pure | Network | Auth Text | Sandbox Text | Filesystem Text

-- Evidence of satisfaction
data DischargeProof = DischargeProof
  { dpCoeffects :: [Resource]
  , dpNetworkAccess :: [NetworkAccess]
  , dpFilesystemAccess :: [FilesystemAccess]
  , dpSignature :: Maybe Ed25519Signature
  }
```

## Development

```bash
# Enter devshell
nix develop

# Build sensenet
ghc -o sensenet -isrc/sensenet src/sensenet/Main.hs -threaded

# Run tests
./scripts/test-all.sh

# Build examples
./sensenet build //src/examples/...
```

## Key Files Reference

| File | Purpose | Lines |
|------|---------|-------|
| `src/sensenet/Main.hs` | CLI entry point | 325 |
| `src/sensenet/SenseNet/IR.hs` | Internal representation | 519 |
| `src/sensenet/SenseNet/Dhall.hs` | Dhall parser | 592 |
| `src/sensenet/SenseNet/Build.hs` | Build execution | 1400+ |
| `src/sensenet/SenseNet/DICE.hs` | Incremental engine | 581 |
| `src/sensenet/DhallFast/Core.hs` | Optimized AST | 372 |
| `src/nix-analyze/Nix.hs` | Nix integration | 539 |
| `dhall/prelude/package.dhall` | Dhall exports | 99 |
| `toolchains/cxx.bzl` | C++ toolchain | 173 |
