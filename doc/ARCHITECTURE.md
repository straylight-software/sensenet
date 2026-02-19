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

**Cross-Package Dependencies** (Completed — commit `a45a402`):
- `DepLocal` can be `:foo` (same package) or `//pkg:target` (cross-package)
- `ParsedDep` type and `parseDep`/`parseFqName` functions
- `BuildContext` with `PackageCache` for lazy loading
- Worklist algorithm in `discoverAndRegisterDeps` for transitive closure

### Implementation Plan

#### Phase 1: Cross-Package Dependencies (Completed)

Fixed the transitive dependency gap so builds can span packages:

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

The goal: **don't OOM the build machine**. Use cached `ProfileData` to predict
memory requirements and throttle parallelism accordingly.

##### The Problem

Current state: DICE calls our callback for each target, potentially in parallel.
We have no control over how many concurrent builds run. With 64 cores and 64
parallel compiles each using 1GB, we need 64GB RAM or we OOM.

The insight: after the first "profiling build", we know each target's peak memory.
Use that to decide whether to start a new job.

##### Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│  DICE Engine (Rust)                                                     │
│                                                                         │
│  Computes dependency graph, calls Haskell callbacks for each target.    │
│  Currently: fires all ready targets in parallel.                        │
│  We can't change this (DICE is upstream).                               │
└─────────────────────────────────────────────────────────────────────────┘
                              │
                              │ FFI callback
                              ▼
┌─────────────────────────────────────────────────────────────────────────┐
│  Scheduler (Haskell)                                                    │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │  SchedulerState (MVar)                                          │    │
│  │                                                                 │    │
│  │  activeMemoryBytes :: Word64    -- Sum of running job estimates │    │
│  │  maxMemoryBytes    :: Word64    -- From --max-memory or auto    │    │
│  │  activeJobs        :: Map Text ProfileData  -- Running targets  │    │
│  │  profileCache      :: Map Text ProfileData  -- Known profiles   │    │
│  │  waitingJobs       :: TQueue (Text, MVar ()) -- Throttled jobs  │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  Callback flow:                                                         │
│  1. DICE calls makeCallback for target T                                │
│  2. Look up T in profileCache (from prior DICE result or default)       │
│  3. If activeMemory + T.peakMem <= maxMemory: proceed                   │
│  4. Else: block on waitingJobs queue until memory available             │
│  5. When job completes: subtract from activeMemory, wake waiting jobs   │
└─────────────────────────────────────────────────────────────────────────┘
```

##### Profile Cache Sources

Where do we get `ProfileData` for scheduling decisions?

1. **DICE cache hit** — Target was built before, profile stored in `TargetResult`
   - DICE returns cached result immediately, no callback invoked
   - No scheduling needed (it's instant)

2. **DICE cache miss, profile known** — Target rebuilt, but we profiled it before
   - Store profiles in a separate persistent cache: `.sensenet/profiles.json`
   - Even if DICE invalidates (source changed), memory estimate likely similar

3. **DICE cache miss, profile unknown** — First build of this target
   - Use conservative default: `defaultProfileKb = 512 * 1024` (512 MB)
   - Or infer from rule type: Rust link = 2GB, C++ compile = 500MB, etc.
   - Profile the actual run, update cache for next time

##### Profile Persistence

```haskell
-- .sensenet/profiles.json
data ProfileCache = ProfileCache
  { version  :: Int
  , profiles :: Map Text ProfileEntry
  }

data ProfileEntry = ProfileEntry
  { peakMemoryKb :: Word64
  , wallTimeMs   :: Word64
  , lastUpdated  :: UTCTime
  , inputHash    :: Text  -- Hash of inputs, for staleness detection
  }

-- Load on startup, save after each build
loadProfileCache :: FilePath -> IO ProfileCache
saveProfileCache :: FilePath -> ProfileCache -> IO ()
```

##### Scheduler Implementation

```haskell
data SchedulerState = SchedulerState
  { ssActiveMemory  :: !Word64              -- Bytes currently committed
  , ssMaxMemory     :: !Word64              -- Limit (--max-memory or 80% RAM)
  , ssActiveJobs    :: !(Map Text Word64)   -- target -> estimated bytes
  , ssProfileCache  :: !ProfileCache        -- Persistent profile data
  , ssWaiters       :: !(TQueue (Word64, MVar ()))  -- (needed bytes, wake signal)
  }

-- Called by DICE callback before doing work
acquireMemory :: MVar SchedulerState -> Text -> Word64 -> IO ()
acquireMemory stateVar target neededBytes = do
  -- Try to acquire
  canProceed <- modifyMVar stateVar $ \ss ->
    if ssActiveMemory ss + neededBytes <= ssMaxMemory ss
      then pure (ss { ssActiveMemory = ssActiveMemory ss + neededBytes
                    , ssActiveJobs = Map.insert target neededBytes (ssActiveJobs ss)
                    }, True)
      else pure (ss, False)

  if canProceed
    then pure ()
    else do
      -- Must wait - add to queue
      wakeVar <- newEmptyMVar
      atomically $ writeTQueue (ssWaiters ss) (neededBytes, wakeVar)
      takeMVar wakeVar  -- Block until woken

-- Called by DICE callback after work completes
releaseMemory :: MVar SchedulerState -> Text -> Word64 -> IO ()
releaseMemory stateVar target actualBytes = do
  modifyMVar_ stateVar $ \ss -> do
    let released = fromMaybe 0 (Map.lookup target (ssActiveJobs ss))
    let ss' = ss { ssActiveMemory = ssActiveMemory ss - released
                 , ssActiveJobs = Map.delete target (ssActiveJobs ss)
                 }
    -- Wake waiting jobs if possible
    wakeWaiters ss'
    pure ss'

-- Wake jobs that now fit in memory budget
wakeWaiters :: SchedulerState -> IO SchedulerState
wakeWaiters ss = do
  mWaiter <- atomically $ tryReadTQueue (ssWaiters ss)
  case mWaiter of
    Nothing -> pure ss
    Just (needed, wakeVar)
      | ssActiveMemory ss + needed <= ssMaxMemory ss -> do
          putMVar wakeVar ()
          wakeWaiters ss { ssActiveMemory = ssActiveMemory ss + needed }
      | otherwise -> do
          -- Put it back, can't wake yet
          atomically $ unGetTQueue (ssWaiters ss) (needed, wakeVar)
          pure ss
```

##### Callback Integration

```haskell
-- Modified callback wrapper
makeScheduledCallback ::
  MVar SchedulerState ->
  BuildContext ->
  Text ->          -- Fully qualified target name
  Text -> Text ->  -- DICE callback args
  IO Text
makeScheduledCallback schedVar ctx fqName targetName depsJson = do
  -- Look up expected memory
  ss <- readMVar schedVar
  let profile = lookupProfile (ssProfileCache ss) fqName
      estimatedBytes = profilePeakMemoryKb profile * 1024

  -- Acquire memory budget (may block)
  acquireMemory schedVar fqName estimatedBytes

  -- Run the actual build with profiling
  (result, actualProfile) <- withProfiling $ doBuild ctx fqName depsJson

  -- Release memory and update profile cache
  releaseMemory schedVar fqName (profilePeakMemoryKb actualProfile * 1024)
  updateProfileCache schedVar fqName actualProfile

  pure result
```

##### CLI and Defaults

```
sensenet build --max-memory 32G //pkg:target   # Explicit limit
sensenet build --max-memory 80%  //pkg:target  # Percentage of total RAM
sensenet build //pkg:target                    # Default: 80% of total RAM

sensenet build --profile //pkg:target          # Force profiling mode (sequential)
sensenet build --jobs 1 //pkg:target           # Sequential build (like make -j1)
```

```haskell
data BuildOptions = BuildOptions
  { optMaxMemory    :: Maybe MemoryLimit    -- Nothing = 80% of RAM
  , optJobs         :: Maybe Int            -- Nothing = unlimited
  , optProfile      :: Bool                 -- Force sequential profiling
  , optTarget       :: Text
  }

data MemoryLimit
  = MemoryBytes Word64
  | MemoryPercent Int  -- 1-100

getMaxMemoryBytes :: BuildOptions -> IO Word64
getMaxMemoryBytes opts = case optMaxMemory opts of
  Just (MemoryBytes b) -> pure b
  Just (MemoryPercent p) -> do
    total <- getSystemMemory  -- From /proc/meminfo or sysctl
    pure $ (total * fromIntegral p) `div` 100
  Nothing -> do
    total <- getSystemMemory
    pure $ (total * 80) `div` 100  -- Default 80%
```

##### First Build Behavior

The "burn one build going slow" insight: first build of a target has no profile.

Options:
1. **Conservative default** — Assume 512MB, may over-parallelize
2. **Rule-based heuristics** — Rust link = 2GB, C++ compile = 500MB
3. **Sequential mode** — `--profile` runs everything sequentially to gather data
4. **Adaptive** — Start with default, if OOM detected (exit 137), halve parallelism

Recommendation: **Rule-based heuristics + adaptive backoff**

```haskell
defaultProfileForRule :: Rule -> ProfileData
defaultProfileForRule = \case
  RRustBinary _    -> ProfileData { peakMemoryKb = 2 * 1024 * 1024 }  -- 2GB
  RRustLibrary _   -> ProfileData { peakMemoryKb = 1 * 1024 * 1024 }  -- 1GB
  RHaskellBinary _ -> ProfileData { peakMemoryKb = 1 * 1024 * 1024 }  -- 1GB
  RCxxBinary _     -> ProfileData { peakMemoryKb = 512 * 1024 }       -- 512MB
  RCxxLibrary _    -> ProfileData { peakMemoryKb = 256 * 1024 }       -- 256MB
  RLeanBinary _    -> ProfileData { peakMemoryKb = 4 * 1024 * 1024 }  -- 4GB (Lean is hungry)
  _                -> ProfileData { peakMemoryKb = 512 * 1024 }       -- 512MB default
```

##### Integration Points

```haskell
-- MILE MARKER: Scheduler state is seed for coeffect discharge tracking
-- In Path B, SchedulerState.ssActiveJobs becomes evidence that
-- memory coeffects are being respected

-- MILE MARKER: Profile cache is seed for coeffect inference
-- In Path B, ProfileCache becomes the learned BuildCoeffect database

-- MILE MARKER: acquireMemory/releaseMemory bracket is coeffect discharge
-- In Path B, this becomes a proper linear/affine resource protocol
```

##### Testing

```bash
# Profile a build (sequential, accurate profiling)
sensenet build --profile //src/sensenet:sensenet

# Check profile cache
cat .sensenet/profiles.json | jq '.profiles | to_entries | sort_by(.value.peakMemoryKb) | reverse | .[0:5]'

# Build with memory limit
sensenet build --max-memory 8G //src/sensenet:sensenet

# Watch memory usage
sensenet build --max-memory 8G //... 2>&1 | grep -E "(active memory|waiting)"
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
