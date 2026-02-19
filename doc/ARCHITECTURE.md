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
│                          USER SPACE                                 │
│                                                                     │
│  BUILD.dhall          sensenet CLI      .sensenet/toolchains.dhall  │
│  (target defs)        (build/run/query)    (compiler paths)         │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      HASKELL FRONTEND                               │
│                                                                     │
│  ┌────────────┐    ┌────────────┐    ┌──────────────────────────┐   │
│  │SenseNet.   │───▶│ SenseNet.  │───▶│     SenseNet.Build       │   │
│  │Dhall       │    │ IR         │    │  (rule-specific builders)│   │
│  │(parse)     │    │(typed graph)│    │                         │   │
│  └────────────┘    └────────────┘    └────────────┬─────────────┘   │
│                                                   │                 │
│                                      ┌────────────┴────────────┐    │
│                                      ▼                         ▼    │
│                           ┌──────────────────┐    ┌──────────────┐  │
│                           │  SenseNet.DICE   │    │SenseNet.     │  │
│                           │  (incremental)   │    │Remote        │  │
│                           └────────┬─────────┘    │(NativeLink)  │  │
│                                    │              └──────┬───────┘  │
│  ┌─────────────────┐               │                     │          │
│  │ SenseNet.Console│◀──────────────┤                     │          │
│  │ (superconsole)  │               │                     │          │
│  └────────┬────────┘               │                     │          │
└───────────┼────────────────────────┼─────────────────────┼──────────┘
            │ FFI                    │ FFI                 │ gRPC
            ▼                        ▼                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        RUST / NATIVE                                │
│                                                                     │
│  ┌───────────────────┐    ┌───────────────────┐                     │
│  │  superconsole_ffi │    │     dice_ffi      │                     │
│  │  (terminal TUI)   │    │  (DICE engine)    │                     │
│  └───────────────────┘    └───────────────────┘                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
            │                        │
            ▼                        ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          NIX TOOLCHAINS                             │
│                                                                     │
│  clang++ (LLVM 22 fork) │ rustc │ ghc 9.12 │ lean │ purs │ esbuild  │
│                                                                     │
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

### M5: Self-Hosting ✓

- [x] `sensenet emit --write` generates BUCK files
- [x] `buck2 build //src/sensenet:sensenet` compiles sensenet
- [x] Memory profiling via `getrusage(RUSAGE_CHILDREN)`
- [x] Profile data cached in DICE's `TargetResult`

### M6: Memory-Aware Scheduling (In Progress)

- [x] Memory profiling infrastructure (commit `1207719`)
- [ ] Cross-package dependency resolution
- [ ] Lazy package loading via PackageCache
- [ ] Scheduler reads cached ProfileData before spawning
- [ ] `--max-memory` CLI flag

### M7: Full Coeffect Formalism (Future)

- [ ] BuildCoeffect algebra (graded semiring)
- [ ] Indexed Build monad
- [ ] Coeffect discharge proofs
- [ ] Attestation integration (RFC-008)
- [ ] Dynamic dependencies (IFD-style)

## Coeffect-Aware Scheduling (RFC-008)

This section documents the formalism and implementation plan for memory-aware
scheduling with dynamic dependency support. This builds on the Continuity Project
(aleph-008) and Petricek's coeffect calculus.

### The Problem

Two issues with the current build system:

1. **Memory blindness**: The scheduler doesn't know how much memory actions need.
   Large parallel builds can OOM the machine because we spawn N jobs without
   knowing their combined memory footprint.

2. **Static dependencies only**: Cross-package deps (`//src/foo:bar` depending on
   `//src/baz:qux`) fail because we only load one package at a time. Dynamic
   dependencies (like GHC discovering imports) aren't supported at all.

### The Formalism

Build systems are fundamentally about **tracking and discharging resource
requirements** — this is exactly what coeffect systems model.

From Petricek & Orchard's work on coeffects:

- **Coeffects** track what a computation *requires* from its context
- A **graded comonad** indexes computations by their requirements
- **Semiring** structure enables composition of requirements

For builds, the coeffect ("grade") is:

```haskell
-- MILE MARKER: This is the target algebra for full formalism (Path B)
-- Current implementation uses simpler ProfileData (Path A)
data BuildCoeffect = BuildCoeffect
  { deps      :: Set TargetKey           -- Static deps (known at definition)
  , dynDeps   :: DynDeps                  -- Dynamic deps (discovered at build time)
  , peakMem   :: MemoryBound              -- Peak memory requirement
  , wallTime  :: TimeBound                -- Wall time estimate
  , network   :: NetworkReq               -- Network access requirements
  , sandbox   :: SandboxReq               -- Isolation level
  }

-- Semiring operations for composition:
--   Sequential (>>):  deps union, memory MAX, time SUM
--   Parallel   (&&):  deps union, memory SUM, time MAX
```

### Current State (Path A — Bootstrap)

We're implementing a minimal version that captures the key insight without
requiring full graded monad machinery:

**Memory Profiling** (Completed — commit `1207719`):
- `getrusage(RUSAGE_CHILDREN)` FFI to track peak memory of child processes
- `ProfileData` type with `time_ms` and `peak_memory_bytes`
- Profile data stored in DICE's `TargetResult` for caching
- First build profiles, subsequent builds use cached data

```haskell
-- Current implementation
data ProfileData = ProfileData
  { timeMs         :: !Word64  -- Wall time in milliseconds
  , peakMemoryKb   :: !Word64  -- Peak RSS in kilobytes
  }

-- Stored in DICE result JSON:
-- {"outputs": [...], "exit_code": 0, "time_ms": 9800, "peak_memory_bytes": 429000000}
```

**Cross-Package Dependencies** (In Progress):
- `DepLocal` can be `:foo` (same package) or `//pkg:target` (cross-package)
- Current `extractLocalDepNames` only handles `:foo` format
- Need: parse `//pkg:target`, load package lazily, register with DICE

### Implementation Plan

#### Phase 1: Cross-Package Dependencies (Current)

Fix the transitive dependency gap so builds can span packages:

```
//src/sensenet:sensenet
    └── depends on → //src/vendor/dice:dice_ffi
                         └── depends on → //src/vendor/dice:dice
```

**Changes required:**

1. **Parse cross-package deps** — Update `extractLocalDepNames`:
   ```haskell
   -- NEW: returns (Maybe PackagePath, TargetName)
   parseDep :: Dep -> Maybe (Maybe Text, Text)
   parseDep (DepLocal t)
     | "//" `T.isPrefixOf` t = parseFullTarget t  -- //pkg:target
     | ":" `T.isPrefixOf` t  = Just (Nothing, T.drop 1 t)  -- :target
     | otherwise             = Just (Nothing, t)  -- target
   parseDep (DepFlake _) = Nothing  -- External, not DICE
   ```

2. **Add PackageCache** — Avoid re-parsing BUILD.dhall:
   ```haskell
   type PackageCache = IORef (Map FilePath Package)
   
   loadPackage :: PackageCache -> FilePath -> FilePath -> IO Package
   loadPackage cache projectRoot pkgPath = do
     cached <- readIORef cache
     case Map.lookup pkgPath cached of
       Just pkg -> pure pkg
       Nothing -> do
         pkg <- Dhall.parsePackageFile projectRoot (pkgPath </> "BUILD.dhall")
         modifyIORef' cache (Map.insert pkgPath pkg)
         pure pkg
   ```

3. **Lazy package loading in buildWithDeps** — Worklist algorithm:
   ```haskell
   buildWithDeps tc projectRoot initialPkg targetName = runDICE $ do
     clearTargets
     
     -- Worklist: packages to process
     -- Start with initial package, discover more via deps
     processedRef <- newIORef Set.empty
     cacheRef <- newIORef Map.empty
     
     let registerPackage pkg = do
           forM_ pkg.rules $ \rule -> do
             let name = ruleName rule
                 (localDeps, crossPkgDeps) = partitionDeps (ruleDeps rule)
             
             -- Load cross-package deps (lazy)
             forM_ crossPkgDeps $ \(pkgPath, _) -> do
               processed <- readIORef processedRef
               when (pkgPath `Set.notMember` processed) $ do
                 depPkg <- loadPackage cacheRef projectRoot pkgPath
                 registerPackage depPkg
                 modifyIORef' processedRef (Set.insert pkgPath)
             
             -- Register this target with DICE
             registerTarget name (allDepNames rule) callback
     
     registerPackage initialPkg
     compute targetName
   ```

#### Phase 2: Memory-Aware Scheduling

Use cached `ProfileData` to constrain parallelism:

```haskell
-- Scheduler reads profile data before spawning
data SchedulerState = SchedulerState
  { activeMemory :: !Word64      -- Sum of active job memory estimates
  , maxMemory    :: !Word64      -- --max-memory flag (default: 80% of RAM)
  , activeJobs   :: !(Set Text)  -- Currently running targets
  }

-- Before spawning a new job:
canSpawn :: SchedulerState -> ProfileData -> Bool
canSpawn state profile =
  state.activeMemory + profile.peakMemoryKb * 1024 <= state.maxMemory
```

**CLI addition:**
```
sensenet build --max-memory 32G //pkg:target
```

#### Phase 3: Mile Markers for Full Formalism (Path B)

When we're ready for the full coeffect algebra, these are the integration points:

```haskell
-- MILE MARKER: Replace ProfileData with BuildCoeffect
-- Location: SenseNet/Build.hs, around line 60

-- MILE MARKER: Graded monad for build actions
-- The Build monad would be indexed by its coeffect:
--   newtype Build (r :: BuildCoeffect) a = Build (Env -> IO a)
-- Location: New module SenseNet/Coeffect.hs

-- MILE MARKER: Coeffect discharge proofs
-- When a build completes, produce a witness that requirements were met:
--   discharge :: BuildCoeffect -> ExecutionTrace -> DischargeProof
-- Location: SenseNet/Build.hs, in makeCallback

-- MILE MARKER: Attestation integration
-- Signed attestations carry discharged proof witnesses:
--   data Attestation = Attestation
--     { content      :: Hash
--     , coeffects    :: BuildCoeffect
--     , discharged   :: DischargeProof
--     , signature    :: Ed25519Signature
--     }
-- Location: New module SenseNet/Attestation.hs
-- See: aleph/docs/rfc/aleph-008-continuity/armitage.md

-- MILE MARKER: Dynamic dependencies (IFD-style)
-- For targets that discover deps at build time:
--   analyze :: Build r (Build s a, CoeffectRefinement r' s)
-- This requires suspending scheduler (Shake-style) or two-phase builds
-- Location: SenseNet/DICE.hs, new registerDynamicTarget function
```

### References

- Petricek, Orchard, Mycroft. "Coeffects: A calculus of context-dependent computation" (ICFP 2014)
- Mokhov, Mitchell, Jones. "Build Systems à la Carte" (ICFP 2018, JFP 2020)
- aleph-008: The Continuity Project (aleph/docs/rfc/aleph-008-continuity/)
- Buck2 documentation on `dynamic_output` and anonymous targets

## License

Apache 2.0 (DICE, superconsole derived from Meta OSS)
