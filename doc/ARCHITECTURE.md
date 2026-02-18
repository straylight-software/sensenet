# SENSE // NET

A build system for the age of acceleration.

## Overview

SENSENET is a build system that combines:

- **Dhall** for typed, total configuration
- **DICE** for incremental computation (extracted from Buck2)
- **Nix** for hermetic toolchains
- **NativeLink** for remote execution

No Starlark. No BXL. No runtime type errors. Just types, all the way down.

The key insight: Buck2's value is DICE, not Starlark. SENSENET extracts DICE via FFI
and drives it directly from Haskell, bypassing Buck2 entirely.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                          USER SPACE                                  │
│                                                                      │
│  BUILD.dhall          sensenet CLI         .sensenet/toolchains.dhall│
│  (target defs)        (build/run/query)    (compiler paths)         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      HASKELL FRONTEND                                │
│                                                                      │
│  ┌────────────┐    ┌────────────┐    ┌─────────────────────────┐   │
│  │SenseNet.   │───▶│ SenseNet.  │───▶│     SenseNet.Build      │   │
│  │Dhall       │    │ IR         │    │  (rule-specific builders)│   │
│  │(parse)     │    │(typed graph)│    │                         │   │
│  └────────────┘    └────────────┘    └────────────┬────────────┘   │
│                                                   │                 │
│                                      ┌────────────┴────────────┐   │
│                                      ▼                         ▼   │
│                           ┌──────────────────┐    ┌──────────────┐ │
│                           │  SenseNet.DICE   │    │SenseNet.     │ │
│                           │  (incremental)   │    │Remote        │ │
│                           └────────┬─────────┘    │(NativeLink)  │ │
│                                    │              └──────┬───────┘ │
│  ┌─────────────────┐               │                     │         │
│  │ SenseNet.Console│◀──────────────┤                     │         │
│  │ (superconsole)  │               │                     │         │
│  └────────┬────────┘               │                     │         │
└───────────┼────────────────────────┼─────────────────────┼─────────┘
            │ FFI                    │ FFI                 │ gRPC
            ▼                        ▼                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        RUST / NATIVE                                 │
│                                                                      │
│  ┌───────────────────┐    ┌───────────────────┐                     │
│  │  superconsole_ffi │    │     dice_ffi      │                     │
│  │  (terminal TUI)   │    │  (DICE engine)    │                     │
│  └───────────────────┘    └───────────────────┘                     │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
            │                        │
            ▼                        ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          NIX TOOLCHAINS                              │
│                                                                      │
│  clang++ (LLVM 22) │ rustc │ ghc 9.12 │ lean │ purs │ esbuild       │
└─────────────────────────────────────────────────────────────────────┘
```

## Data Flow

```
BUILD.dhall → Dhall.parsePackageFile → IR.Package → Build.buildTarget
                                                          │
                                    ┌─────────────────────┴──────────────────┐
                                    ▼                                        ▼
                              [local build]                           [remote build]
                                    │                                        │
                            DICE.registerTarget                    Remote.buildRemote
                            DICE.compute                                     │
                                    │                              ┌─────────┴─────────┐
                                    ▼                              ▼                   ▼
                           toolchain invocation              upload to CAS      execute via RE
                           (clang++, rustc, ghc...)                │                   │
                                    │                              └─────────┬─────────┘
                                    ▼                                        ▼
                              sensenet-out/                          download outputs
```

## Components

### SenseNet.IR — Internal Representation

The typed build graph. All BUILD.dhall files parse into these types.

```haskell
-- Dependency reference
data Dep
  = DepLocal Text      -- ":foo" or "//pkg:foo"
  | DepFlake Text      -- "nixpkgs#openssl.dev"

-- Rules (one per supported target type)
data Rule
  = RuleCxxBinary CxxBinary
  | RuleCxxLibrary CxxLibrary
  | RuleRustBinary RustBinary
  | RuleRustLibrary RustLibrary
  | RuleHaskellBinary HaskellBinary
  | RuleHaskellLibrary HaskellLibrary
  | RuleHaskellFFIBinary HaskellFFIBinary
  | RuleLeanBinary LeanBinary
  | RuleLeanLibrary LeanLibrary
  | RuleNvBinary NvBinary
  | RuleNvLibrary NvLibrary
  | RulePureScriptApp PureScriptApp
  | RulePureScriptBinary PureScriptBinary
  | RulePureScriptLibrary PureScriptLibrary
  | RuleGenrule Genrule
  | RuleNixCxxBinary NixCxxBinary
  | RuleCratesIo CratesIo
  | RuleHttpArchive HttpArchive

-- A package is a directory with a BUILD.dhall
data Package = Package
  { path  :: FilePath
  , rules :: [Rule]
  }
```

### SenseNet.Dhall — Dhall Parser

Parses BUILD.dhall files into the IR using the `dhall` Haskell library.

```haskell
parsePackageFile :: FilePath -> FilePath -> IO Package
-- Takes project root and BUILD.dhall path, returns typed Package
```

Key detail: defines intermediate `DhallRule`, `DhallCxxBinary`, etc. types with
`FromDhall` instances, then converts to IR types. This isolates Dhall's type
system from the rest of the codebase.

### SenseNet.Build — Build Execution

Orchestrates builds. Three modes:

1. **`build`** — Simple sequential builds (legacy)
2. **`buildWithDeps`** — DICE-based incremental builds
3. **`buildWithConsole`** — DICE + superconsole TUI (default)

Implements a builder for each rule type:

```haskell
buildCxxBinary      :: Toolchains -> CxxBinary -> IO BuildResult
buildRustBinary     :: Toolchains -> RustBinary -> IO BuildResult
buildHaskellBinary  :: Toolchains -> HaskellBinary -> IO BuildResult
buildLeanBinary     :: Toolchains -> LeanBinary -> IO BuildResult
buildNvBinary       :: Toolchains -> NvBinary -> IO BuildResult
buildPureScriptApp  :: Toolchains -> PureScriptApp -> IO BuildResult
buildGenrule        :: Toolchains -> Genrule -> IO BuildResult
```

Each builder:
1. Resolves Nix dependencies (`DepFlake` → store paths)
2. Constructs compiler flags (includes, libs, defines)
3. Invokes the toolchain (clang++, rustc, ghc, etc.)
4. Writes output to `sensenet-out/`

### SenseNet.DICE — Incremental Computation

Haskell interface to Buck2's DICE engine via FFI.

```haskell
-- The DICE monad
newtype DICE a = DICE (ReaderT DICEEnv IO a)

-- Core operations
inject   :: Text -> Text -> Word64 -> DICE ()  -- Register source file
compute  :: Text -> DICE ByteString             -- Request computation
registerTarget :: Text -> [Text] -> (Text -> IO ByteString) -> DICE ()
```

DICE provides:
- Automatic invalidation when inputs change
- Cached computation results
- Dependency tracking

### SenseNet.DICE.FFI — Low-level FFI

C ABI bindings to the Rust DICE library:

```haskell
foreign import ccall "dice_runtime_new"     dice_runtime_new     :: IO (Ptr DICERuntime)
foreign import ccall "dice_engine_new"      dice_engine_new      :: Ptr DICERuntime -> IO (Ptr DICEEngine)
foreign import ccall "dice_updater_new"     dice_updater_new     :: Ptr DICEEngine -> IO (Ptr DICEUpdater)
foreign import ccall "dice_updater_inject"  dice_updater_inject  :: ...
foreign import ccall "dice_updater_commit"  dice_updater_commit  :: ...
foreign import ccall "dice_compute"         dice_compute         :: ...
foreign import ccall "dice_sha256"          dice_sha256          :: ...
```

### SenseNet.Console — Terminal UI

Buck2-style build progress display via superconsole FFI.

```haskell
withBuildConsole :: (Console -> IO a) -> IO a
updateProgress   :: Console -> Int -> Int -> IO ()  -- completed / total
addAction        :: Console -> Text -> IO ActionHandle
completeAction   :: ActionHandle -> IO ()
```

Shows:
- Progress bar
- Currently running actions with elapsed time
- Completed action log

### SenseNet.Remote — Remote Execution

NativeLink client for remote builds (REAPI v2).

```haskell
buildRemote :: RemoteConfig -> Rule -> IO BuildResult
```

Flow:
1. Upload source files to CAS (Content Addressable Storage)
2. Create action proto with command + inputs
3. Submit to execution service
4. Poll for completion
5. Download outputs from CAS

Currently supports: CxxBinary, Genrule. Other rules return "not yet supported".

### SenseNet.Toolchains — Toolchain Configuration

Parses `.sensenet/toolchains.dhall` for compiler paths.

```haskell
data Toolchains = Toolchains
  { cxx       :: Maybe CxxToolchain
  , rust      :: Maybe RustToolchain
  , haskell   :: Maybe HaskellToolchain
  , lean      :: Maybe LeanToolchain
  , nv        :: Maybe NvToolchain
  , purescript :: Maybe PureScriptToolchain
  }

data CxxToolchain = CxxToolchain
  { cc      :: FilePath
  , cxx     :: FilePath
  , ar      :: FilePath
  , ld      :: FilePath
  , sysroot :: Maybe FilePath
  }
```

All paths are Nix store paths, ensuring hermetic builds.

### SenseNet.Emit — Buck2 Generation (Legacy)

Generates BUCK files from IR. Used for the "Buck2 fiction" mode (namespace mounts).
Still present but no longer the primary execution path.

### SenseNet.Discover — File Discovery

Walks the project tree finding BUILD.dhall files.

```haskell
discover :: FilePath -> IO [DhallFile]
```

Respects `.gitignore` and `.sensenetignore`. Skips `buck-out`, `node_modules`,
`sensenet-out`, etc.

## Supported Languages

| Language   | Rules                                          | Toolchain          |
|------------|------------------------------------------------|--------------------|
| C/C++      | `cxxBinary`, `cxxLibrary`, `nixCxxBinary`      | LLVM 22 (clang++)  |
| Rust       | `rustBinary`, `rustLibrary`, `cratesIo`        | rustc              |
| Haskell    | `haskellBinary`, `haskellLibrary`, `haskellFFIBinary` | GHC 9.12    |
| Lean 4     | `leanBinary`, `leanLibrary`                    | lean/leanc         |
| CUDA       | `nvBinary`, `nvLibrary`                        | clang + ptxas      |
| PureScript | `purescriptApp`, `purescriptBinary`, `purescriptLibrary` | purs + esbuild |
| Generic    | `genrule`                                      | sh                 |

## Directory Structure

```
sensenet/
├── src/
│   ├── sensenet/                  # Main Haskell package
│   │   ├── Main.hs                # CLI entry point
│   │   ├── SenseNet/
│   │   │   ├── IR.hs              # Internal representation
│   │   │   ├── Dhall.hs           # BUILD.dhall parser
│   │   │   ├── Build.hs           # Build execution
│   │   │   ├── DICE.hs            # DICE interface
│   │   │   ├── DICE/
│   │   │   │   └── FFI.hs         # DICE FFI bindings
│   │   │   ├── Console.hs         # Superconsole interface
│   │   │   ├── Console/
│   │   │   │   └── FFI.hs         # Superconsole FFI
│   │   │   ├── Remote.hs          # NativeLink client
│   │   │   ├── Toolchains.hs      # Toolchain config
│   │   │   ├── Discover.hs        # BUILD.dhall discovery
│   │   │   └── Emit.hs            # BUCK generation (legacy)
│   │   └── NativeLink/            # REAPI client
│   │       ├── Client.hs          # CAS operations
│   │       ├── Execution.hs       # Remote execution
│   │       └── Proto.hs           # Proto-lens types
│   ├── vendor/
│   │   ├── dice/                  # Vendored from Buck2
│   │   │   ├── dice/              # Core DICE engine
│   │   │   ├── dice_ffi/          # C ABI wrapper
│   │   │   ├── allocative/        # Memory tracking
│   │   │   └── gazebo/            # Utilities
│   │   └── superconsole/          # Terminal UI library
│   └── examples/                  # Example projects
├── dhall/
│   └── prelude/                   # Dhall type definitions
│       ├── package.dhall          # Main export
│       ├── Types.dhall            # Dep, CxxStd, Vis
│       ├── Cxx.dhall              # C++ rules
│       ├── Rust.dhall             # Rust rules
│       ├── Haskell.dhall          # Haskell rules
│       └── Rule.dhall             # Union type
├── toolchains/                    # Starlark (legacy/Buck2 mode)
├── nix/
│   ├── modules/flake/             # Flake modules
│   └── packages/                  # Nix derivations
├── doc/
│   ├── ARCHITECTURE.md            # This file
│   └── PLAN.md                    # Implementation plan
├── sensenet.cabal
└── flake.nix
```

## CLI

```
sensenet build [target]      Build target(s)
sensenet run <target>        Build and run a binary
sensenet clean               Remove sensenet-out/
sensenet targets             List all targets
sensenet query               Alias for targets
sensenet graph               Dump build graph as JSON
sensenet --version           Show version info
```

Options:
```
--remote              Enable remote execution
--remote-host <host>  NativeLink host (default: localhost)
--remote-port <port>  NativeLink port (default: 50051)
--tui / --no-tui      Enable/disable superconsole (default: enabled)
--deps / --no-deps    Enable/disable DICE dependency tracking (default: enabled)
```

## Comparison with Buck2

| Feature          | Buck2          | SENSENET       |
|------------------|----------------|----------------|
| Config language  | Starlark       | Dhall          |
| Type checking    | Runtime        | Compile time   |
| Rule definitions | .bzl files     | Dhall types    |
| Queries          | BXL            | dhall + jq     |
| Toolchains       | Starlark       | Nix            |
| Incremental      | DICE           | DICE (same!)   |
| Remote exec      | RE API         | NativeLink     |
| Bootstrap        | Buck2 or Cargo | Cabal + Nix    |

## Milestones

### M1: Bootstrap ✓

- [x] Haskell CLI scaffold
- [x] Rust workspace with DICE extraction
- [x] FFI bridge working
- [x] Superconsole integration
- [x] `sensenet --version` works

### M2: Local Execution ✓

- [x] Dhall target loading
- [x] Nix toolchain resolution
- [x] Action graph construction
- [x] Local action execution
- [x] `sensenet build //examples/cxx:hello` works

### M3: Incremental Builds ✓

- [x] DICE integration via FFI
- [x] Dependency tracking
- [x] Incremental rebuilds
- [x] `sensenet build` is incremental

### M4: Remote Execution (Partial)

- [x] NativeLink client
- [x] CAS upload/download
- [x] Remote execution for C++
- [ ] Remote execution for all rule types
- [x] `sensenet build --remote` works (C++ only)

### M5: Polish (In Progress)

- [ ] Full remote execution support
- [ ] Self-hosting SENSENET build
- [ ] Documentation complete
- [ ] v1.0.0 release

## License

Apache 2.0 (DICE, superconsole derived from Meta OSS)
