# sensenet v0.5 Rewrite Design

## Overview

Incremental rewrite of sensenet to use the evring Continuity build prelude.
Each change is a single working commit that passes all tests.

## Two Artifacts

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            ARTIFACT STRATEGY                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  sensenet-local                      sensenet                               │
│  ════════════════                    ════════════════════════════════════   │
│                                                                             │
│  For bootstrap & local dev           Full production build system           │
│                                                                             │
│  Dependencies:                       Dependencies:                          │
│  - ~20 packages                      - ~35 packages                         │
│  - aeson, dhall, crypton             - everything in sensenet-local         │
│  - NO grapesy, NO katip              - PLUS: grapesy, grpc-spec             │
│                                      - PLUS: katip, hostname                │
│                                      - PLUS: nativelink-hs                  │
│                                                                             │
│  Features:                           Features:                              │
│  - Parse BUILD.dhall                 - Everything in sensenet-local         │
│  - Local DICE caching                - Remote execution (NativeLink)        │
│  - Build C++/Rust/Haskell/CUDA       - Structured logging (Katip)           │
│  - Parallel local execution          - Remote caching                       │
│                                      - Coeffect-aware scheduling            │
│                                                                             │
│  Use case:                           Use case:                              │
│  - Bootstrap sensenet itself         - CI/CD pipelines                      │
│  - Quick local iteration             - Distributed builds                   │
│  - Offline development               - Production deployments               │
│                                                                             │
│  Compile time: ~2 min                Compile time: ~3 min                   │
│  Binary size: ~12 MB                 Binary size: ~18 MB                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Cabal Flags

```cabal
flag remote
  description: Enable NativeLink remote execution (grapesy, grpc)
  default: True
  manual: True

flag logging  
  description: Enable Katip structured logging
  default: True
  manual: True

library
  -- Core deps (always)
  build-depends:
    aeson, async, base, bytestring, containers, crypton, deepseq,
    dhall, directory, either, filepath, hashable, memory, microlens,
    process, text, text-short, time, unix, unordered-containers, vector

  -- Remote execution (optional)
  if flag(remote)
    build-depends: grapesy, grpc-spec, network, stm
    cpp-options: -DREMOTE
    other-modules:
      SenseNet.Remote
      SenseNet.Remote.Client
      SenseNet.Remote.Action

  -- Structured logging (optional)
  if flag(logging)
    build-depends: katip, hostname
    cpp-options: -DLOGGING
    other-modules:
      SenseNet.Log
```

### Nix Packages

```nix
# nix/packages/sensenet-local.nix
# Bootstrap/local - NO remote, NO logging
mkDerivation {
  pname = "sensenet";
  version = "0.5.0";
  configureFlags = [
    "-f-remote"    # Disable grapesy/grpc
    "-f-logging"   # Disable katip
  ];
  libraryHaskellDepends = coreDeps;  # ~20 packages
}

# nix/packages/sensenet.nix
# Full production - WITH remote, WITH logging
mkDerivation {
  pname = "sensenet";
  version = "0.5.0";
  configureFlags = [
    "-fremote"     # Enable grapesy/grpc
    "-flogging"    # Enable katip
  ];
  libraryHaskellDepends = coreDeps ++ remoteDeps ++ loggingDeps;  # ~35 packages
}
```

### Bootstrap Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              BOOTSTRAP                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Stage 0: Nix builds sensenet-local                                         │
│  ═══════════════════════════════════                                        │
│    nix build .#sensenet-local                                               │
│         │                                                                   │
│         ▼                                                                   │
│    sensenet-local binary (no remote, no logging)                            │
│                                                                             │
│  Stage 1: sensenet-local builds sensenet                                    │
│  ═══════════════════════════════════════                                    │
│    sensenet-local build //src/sensenet:sensenet                             │
│         │                                                                   │
│         ▼                                                                   │
│    sensenet binary (full features)                                          │
│    - Uses DICE cache                                                        │
│    - Compiles grapesy, katip as Haskell targets                             │
│                                                                             │
│  Stage 2: sensenet verifies itself                                          │
│  ═════════════════════════════════                                          │
│    sensenet build //src/sensenet:sensenet                                   │
│         │                                                                   │
│         ▼                                                                   │
│    Hash matches Stage 1 (reproducible)                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## DICE Properties to Preserve

The current DICE implementation has these critical properties that **must be retained**:

### 1. Content-Addressed Action Keys

```haskell
ActionKey = BLAKE2b-256(canonical_serialization(Action))
```

- Deterministic: same inputs → same key
- Uses BLAKE2b-256 (1.5x faster than SHA256)
- Zero-copy hashing via `ByteString.Builder` + `hashlazy`

### 2. Canonical Serialization Format

```
action:2
name:<name>
command:<cmd0>\0<cmd1>\0...
inputs:<input0>\0<input1>\0...
outputs:<output0>\0<output1>\0...
env:<k0>=<v0>\0<k1>=<v1>\0...
coeffects:<c0>,<c1>,...
```

- Version prefix (`action:2`) for forward compatibility
- Null-separated lists for unambiguous parsing
- Sorted env vars for determinism
- **Coeffects already tracked** (as `[Text]`)

### 3. Action Graph with Topo Sort

- `ActionGraph = Map ActionKey Action + roots`
- `topoSort` ensures deps before dependents
- Handles external deps gracefully (skip if not in graph)

### 4. Parallel Execution with Waves

- `executeGraphWithJobs` with `QSem` for job limiting
- Wave-based: execute ready actions, find newly ready, repeat
- Progress display: `[n/total] → target`
- Memory tracking: `arPeakMemoryKB` from `getrusage`

### 5. Persistent File Cache

- XDG cache: `~/.cache/sensenet/actions/<hex-key>`
- Simple format: null-separated output paths
- Fast existence check, lazy content read

### 6. Coeffects in Action

```haskell
data Action = Action
  { ...
  , aCoeffects :: ![Text]  -- "pure", "network", "fs:/path", etc.
  }
```

- Already part of canonical hash
- Already serialized in action key
- **Just need to upgrade from `[Text]` to typed `[Coeffect]`**

______________________________________________________________________

## Incremental Change Plan

Each step is a **single working commit** that passes `sensenet build //...`.

### Step 1: Add IR.Coeffect module

**File**: `src/sensenet/SenseNet/IR/Coeffect.hs` (new)

```haskell
module SenseNet.IR.Coeffect where

data Coeffect
  = Pure
  | Filesystem Text
  | FilesystemCA Text  -- sha256
  | Network Text Natural  -- host, port
  | NetworkCA Text  -- sha256
  | Environment Text
  | Time
  | Random
  | Identity
  | Auth Text
  | CoeffectGpu Text
  | Sandbox Text
  deriving (Show, Eq, Generic)

type Coeffects = [Coeffect]

-- Render to text (for DICE compatibility)
coeffectToText :: Coeffect -> Text
coeffectToText = \case
  Pure -> "pure"
  Filesystem p -> "fs:" <> p
  FilesystemCA h -> "fs-ca:" <> h
  Network h p -> "net:" <> h <> ":" <> T.pack (show p)
  NetworkCA h -> "net-ca:" <> h
  Environment v -> "env:" <> v
  Time -> "time"
  Random -> "random"
  Identity -> "identity"
  Auth p -> "auth:" <> p
  CoeffectGpu d -> "gpu:" <> d
  Sandbox s -> "sandbox:" <> s

-- Parse from text (for backward compat)
textToCoeffect :: Text -> Maybe Coeffect
textToCoeffect t
  | t == "pure" = Just Pure
  | "fs:" `T.isPrefixOf` t = Just (Filesystem (T.drop 3 t))
  | "fs-ca:" `T.isPrefixOf` t = Just (FilesystemCA (T.drop 6 t))
  | "env:" `T.isPrefixOf` t = Just (Environment (T.drop 4 t))
  | t == "time" = Just Time
  | t == "random" = Just Random
  | t == "identity" = Just Identity
  | "auth:" `T.isPrefixOf` t = Just (Auth (T.drop 5 t))
  | "gpu:" `T.isPrefixOf` t = Just (CoeffectGpu (T.drop 4 t))
  | "sandbox:" `T.isPrefixOf` t = Just (Sandbox (T.drop 8 t))
  | otherwise = Nothing

-- Check if coeffects allow caching
isCacheable :: Coeffects -> Bool
isCacheable = all isReproducible

isReproducible :: Coeffect -> Bool
isReproducible = \case
  Pure -> True
  FilesystemCA _ -> True
  NetworkCA _ -> True
  Time -> False
  Random -> False
  _ -> True
```

**Test**: Existing builds still work (coeffects still render to text in DICE).

______________________________________________________________________

### Step 2: Add IR.Triple module

**File**: `src/sensenet/SenseNet/IR/Triple.hs` (new)

```haskell
module SenseNet.IR.Triple where

data Arch = X86_64 | Aarch64 | Wasm32 | Riscv64 | Armv7
  deriving (Show, Eq, Generic)

data OS = Linux | Darwin | Wasi | Windows | OSNone
  deriving (Show, Eq, Generic)

data Gpu 
  = Sm80 | Sm86 | Sm87 | Sm89 
  | Sm90 | Sm90a 
  | Sm100 | Sm100a | Sm120 
  | GpuNone
  deriving (Show, Eq, Generic)

-- Render GPU to nvcc arch string
gpuToArch :: Gpu -> Text
gpuToArch = \case
  Sm80 -> "sm_80"
  Sm86 -> "sm_86"
  Sm87 -> "sm_87"
  Sm89 -> "sm_89"
  Sm90 -> "sm_90"
  Sm90a -> "sm_90a"
  Sm100 -> "sm_100"
  Sm100a -> "sm_100a"
  Sm120 -> "sm_120"
  GpuNone -> ""

-- Parse from text (for backward compat with existing BUILD.dhall)
textToGpu :: Text -> Maybe Gpu
textToGpu = \case
  "sm_80" -> Just Sm80
  "sm_86" -> Just Sm86
  "sm_89" -> Just Sm89
  "sm_90" -> Just Sm90
  "sm_90a" -> Just Sm90a
  "sm_100" -> Just Sm100
  "sm_100a" -> Just Sm100a
  "sm_120" -> Just Sm120
  _ -> Nothing
```

**Test**: Existing builds still work.

______________________________________________________________________

### Step 3: Add IR.Flag module

**File**: `src/sensenet/SenseNet/IR/Flag.hs` (new)

```haskell
module SenseNet.IR.Flag where

data OptLevel = O0 | O1 | O2 | O3 | Oz | Os
  deriving (Show, Eq, Generic)

data LTOMode = LTOOff | LTOThin | LTOFat
  deriving (Show, Eq, Generic)

data DebugInfo = DebugNone | DebugLineTablesOnly | DebugFull
  deriving (Show, Eq, Generic)

data Flag
  = FlagOptLevel OptLevel
  | FlagLTO LTOMode
  | FlagDebug DebugInfo
  | FlagDefine Text (Maybe Text)
  | FlagInclude Text
  | FlagLink Text
  | FlagRaw Text  -- escape hatch
  deriving (Show, Eq, Generic)

-- Render flag to command-line args
renderFlag :: Flag -> [Text]
renderFlag = \case
  FlagOptLevel O0 -> ["-O0"]
  FlagOptLevel O1 -> ["-O1"]
  FlagOptLevel O2 -> ["-O2"]
  FlagOptLevel O3 -> ["-O3"]
  FlagOptLevel Oz -> ["-Oz"]
  FlagOptLevel Os -> ["-Os"]
  FlagLTO LTOOff -> []
  FlagLTO LTOThin -> ["-flto=thin"]
  FlagLTO LTOFat -> ["-flto"]
  FlagDebug DebugNone -> []
  FlagDebug DebugLineTablesOnly -> ["-gline-tables-only"]
  FlagDebug DebugFull -> ["-g"]
  FlagDefine n Nothing -> ["-D" <> n]
  FlagDefine n (Just v) -> ["-D" <> n <> "=" <> v]
  FlagInclude p -> ["-I" <> p]
  FlagLink l -> ["-l" <> l]
  FlagRaw t -> [t]

renderFlags :: [Flag] -> [Text]
renderFlags = concatMap renderFlag
```

**Test**: Existing builds still work.

______________________________________________________________________

### Step 4: Add IR.Common module

**File**: `src/sensenet/SenseNet/IR/Common.hs` (new)

```haskell
module SenseNet.IR.Common where

import SenseNet.IR.Coeffect

data Visibility 
  = VisPublic 
  | VisPrivate 
  | VisPackage 
  | VisTargets [Text]
  deriving (Show, Eq, Generic)

data DepNew
  = DepLocalNew Text           -- :target or //pkg:target
  | DepFlakeNew Text Text      -- flake, attr
  deriving (Show, Eq, Generic)

data Common = Common
  { cName :: Text
  , cVisibility :: Visibility
  , cLabels :: [Text]
  , cCoeffects :: Coeffects
  }
  deriving (Show, Eq, Generic)
```

**Test**: Existing builds still work.

______________________________________________________________________

### Step 5: Update IR.hs to re-export new modules

**File**: `src/sensenet/SenseNet/IR.hs` (modify)

Add imports and re-exports at the top, keeping all existing exports:

```haskell
module SenseNet.IR
  ( -- NEW: Re-exports from new modules
    module SenseNet.IR.Coeffect,
    module SenseNet.IR.Triple,
    module SenseNet.IR.Flag,
    module SenseNet.IR.Common,
    
    -- EXISTING: Keep all current exports
    Dep(..),
    Vis(..),
    CxxStd(..),
    ...
  ) where

import SenseNet.IR.Coeffect
import SenseNet.IR.Triple  
import SenseNet.IR.Flag
import SenseNet.IR.Common

-- ... rest of existing file unchanged
```

**Test**: Existing builds still work. New types available but not yet used.

______________________________________________________________________

### Step 6: Update DICE.hs to use typed Coeffects

**File**: `src/sensenet/SenseNet/DICE.hs` (modify)

Change Action to use typed coeffects:

```haskell
import SenseNet.IR.Coeffect (Coeffect, Coeffects, coeffectToText)

data Action = Action
  { ...
  , aCoeffects :: !Coeffects  -- Changed from ![Text]
  }

-- Update canonical serialization (SAME OUTPUT FORMAT)
actionToCanonicalLazy Action{..} = BB.toLazyByteString builder
  where
    builder = ...
        <> "coeffects:"
        <> mconcat [textBS (coeffectToText c) <> comma | c <- aCoeffects]
        <> nl
```

**CRITICAL**: The serialization format is unchanged! `coeffectToText` produces
the same strings as the old `[Text]` approach. Cache keys remain compatible.

**Test**:

1. Existing builds still work
1. Cache hits still work (keys unchanged)
1. `sensenet build //...` all pass

______________________________________________________________________

### Step 7: Update Build.hs to use typed Coeffects

**File**: `src/sensenet/SenseNet/Build.hs` (modify)

Update action construction to use typed coeffects:

```haskell
import SenseNet.IR.Coeffect (Coeffect(..))

-- When constructing actions, use typed coeffects
cxxBinaryAction :: ... -> Action
cxxBinaryAction ... = Action
  { ...
  , aCoeffects = [Pure]  -- Instead of ["pure"]
  }

nvBinaryAction :: ... -> Action  
nvBinaryAction ... = Action
  { ...
  , aCoeffects = [CoeffectGpu "cuda"]  -- Instead of ["gpu:cuda"]
  }
```

**Test**: All 41 targets still build.

______________________________________________________________________

### Step 8: Update NvBinary to use typed Gpu

**File**: `src/sensenet/SenseNet/IR.hs` (modify NvBinary)

```haskell
import SenseNet.IR.Triple (Gpu, gpuToArch, textToGpu)

data NvBinary = NvBinary
  { name :: Text
  , srcs :: [Text]
  , deps :: [Dep]
  , archs :: [Gpu]  -- Changed from [Text]
  , vis :: Vis
  }
```

**File**: `src/sensenet/SenseNet/Dhall.hs` (modify)

Update parser to convert Text → Gpu:

```haskell
toIRRule (NvBinary r) = IR.RNvBinary IR.NvBinary
  { ...
  , archs = mapMaybe textToGpu r.archs  -- Parse text to Gpu
  }
```

**File**: `src/sensenet/SenseNet/Build.hs` (modify nvBinaryAction)

```haskell
nvBinaryAction tc r = 
  let archFlags = concatMap (\g -> ["-arch=" <> gpuToArch g]) r.archs
  in ...
```

**Test**: `sensenet build //src/examples/nv:...` still works.

______________________________________________________________________

### Step 9: Add optional Katip logging (conditional)

**File**: `src/sensenet/sensenet.cabal` (modify)

```cabal
flag logging
  description: Enable Katip structured logging
  default: False
  manual: True

library
  if flag(logging)
    build-depends: katip >= 0.8
    cpp-options: -DLOGGING
    other-modules: SenseNet.Log
```

**File**: `src/sensenet/SenseNet/Log.hs` (new, conditional)

```haskell
{-# LANGUAGE CPP #-}
module SenseNet.Log 
#ifdef LOGGING
  ( LogEnv
  , initLogging
  , withBuildTarget
  , withPhase
  ) where

import Katip
...

#else
  ( LogEnv
  , initLogging  
  , withBuildTarget
  , withPhase
  ) where

-- Stub implementation when logging disabled
type LogEnv = ()

initLogging :: IO LogEnv
initLogging = pure ()

withBuildTarget :: LogEnv -> Text -> IO a -> IO a
withBuildTarget _ _ = id

withPhase :: LogEnv -> Text -> IO a -> IO a  
withPhase _ _ = id

#endif
```

**Test**:

- Without `-flogging`: builds work, no katip dep
- With `-flogging`: builds work with Katip logging

______________________________________________________________________

### Step 10: Wire logging into Build.hs

**File**: `src/sensenet/SenseNet/Build.hs` (modify)

```haskell
import SenseNet.Log (LogEnv, withBuildTarget)

build :: LogEnv -> ... -> IO BuildResult
build logEnv projectRoot target = do
  ...
  withBuildTarget logEnv target $ do
    result <- executeGraphWithJobs ...
    ...
```

**Test**: All builds still work. Logging is noop without `-flogging`.

______________________________________________________________________

### Step 11: Migrate BUILD.dhall files (one at a time)

For each BUILD.dhall:

**Old**:

```dhall
let A = ../../../dhall/prelude/package.dhall
let hello = A.cxxBinary "hello" ["hello.cpp"] ([] : List A.Dep)
in { targets = [ A.rule.cxxBinary hello ] }
```

**New**:

```dhall
let E = ../../../dhall/evring/package.dhall
let hello = E.cxx_binary "hello" ["hello.cpp"]
in { targets = [ E.rule.cxxBinary hello ] }
```

Do one package at a time, test after each:

1. `src/examples/cxx/BUILD.dhall`
1. `src/examples/nv/BUILD.dhall`
1. ... (19 total)

______________________________________________________________________

### Step 12: Update Dhall.hs to parse evring schema

**File**: `src/sensenet/SenseNet/Dhall.hs` (modify)

Add support for new schema while keeping old schema working:

```haskell
-- Detect schema by checking for 'common' field
data DhallCxxBinaryNew = DhallCxxBinaryNew
  { common :: DhallCommon
  , srcs :: [Text]
  , deps :: [DhallDep]
  , copts :: [DhallFlag]
  , ldflags :: [Text]
  , standard :: DhallCxxStandard
  }

-- Try new schema first, fall back to old
instance FromDhall DhallRule where
  ...
```

**Test**: Both old and new BUILD.dhall formats work.

______________________________________________________________________

### Step 13: Update dhall/prelude to re-export evring

**File**: `dhall/prelude/package.dhall` (modify)

```dhall
-- Re-export evring as the canonical prelude
../evring/package.dhall
```

**Test**: All BUILD.dhall files work with new prelude.

______________________________________________________________________

### Step 14: Delete old prelude files

Once all BUILD.dhall files are migrated:

```bash
rm dhall/prelude/Types.dhall
rm dhall/prelude/Cxx.dhall
rm dhall/prelude/Rust.dhall
rm dhall/prelude/Haskell.dhall
rm dhall/prelude/Lean.dhall
rm dhall/prelude/Nv.dhall
rm dhall/prelude/PureScript.dhall
rm dhall/prelude/Toolchain.dhall
rm dhall/prelude/Genrule.dhall
rm dhall/prelude/RustCrate.dhall
rm dhall/prelude/NixCxx.dhall
rm dhall/prelude/Rule.dhall
rm dhall/prelude/Prelude.dhall
rm dhall/prelude/to-starlark.dhall
rm dhall/prelude/extract-deps.dhall
```

Keep only:

- `dhall/prelude/package.dhall` (re-exports evring)
- `dhall/evring/*` (canonical)

______________________________________________________________________

### Step 15: Add Common record to rules (optional, v0.6)

**File**: `src/sensenet/SenseNet/IR.hs` (modify)

Update rule types to use nested Common:

```haskell
data CxxBinary = CxxBinary
  { common :: Common
  , srcs :: [Text]
  , deps :: [Dep]
  , copts :: [Flag]  -- New: typed flags
  , ldflags :: [Text]
  , standard :: CxxStd
  }
```

This is optional for v0.5 and can be done in v0.6.

______________________________________________________________________

## Summary Table

| Step | Change | Risk | Breaks Cache? | Test |
|------|--------|------|---------------|------|
| 1 | Add IR.Coeffect | None | No | Builds pass |
| 2 | Add IR.Triple | None | No | Builds pass |
| 3 | Add IR.Flag | None | No | Builds pass |
| 4 | Add IR.Common | None | No | Builds pass |
| 5 | Re-export from IR.hs | Low | No | Builds pass |
| 6 | DICE typed Coeffect | **Medium** | **No** | Cache compat! |
| 7 | Build.hs typed Coeffects | Low | No | All 41 pass |
| 8 | NvBinary typed Gpu | Low | No | NV targets |
| 9 | Add optional Katip | None | No | Builds pass |
| 10 | Wire logging | None | No | Builds pass |
| 11 | Migrate BUILD.dhall | **Breaking** | No | One at a time |
| 12 | Dhall.hs new schema | Medium | No | Both formats |
| 13 | Prelude re-export | Low | No | Builds pass |
| 14 | Delete old prelude | None | No | Builds pass |
| 15 | Common in rules | Medium | No | All pass |

______________________________________________________________________

## DICE Cache Compatibility

The key insight is that Step 6 (typed Coeffects in DICE) preserves cache keys:

```haskell
-- OLD: aCoeffects = ["pure", "gpu:cuda"]
-- NEW: aCoeffects = [Pure, CoeffectGpu "cuda"]

-- Serialization produces IDENTICAL bytes:
-- "coeffects:pure,gpu:cuda,\n"

-- Therefore: ActionKey is unchanged!
-- Cache hits work across the upgrade.
```

This is achieved by `coeffectToText`:

```haskell
coeffectToText Pure = "pure"
coeffectToText (CoeffectGpu d) = "gpu:" <> d
-- etc.
```

______________________________________________________________________

## Remote Execution (nativelink-hs)

The key difference between `sensenet-local` and `sensenet` is remote execution
via NativeLink. This is implemented in `SenseNet.Remote`:

```haskell
-- SenseNet/Remote.hs (only compiled with -fremote)
module SenseNet.Remote
  ( RemoteClient
  , connectToScheduler
  , executeRemote
  , uploadAction
  , downloadOutputs
  ) where

import GrpcSpec.NativeLink  -- Generated from .proto
import Grapesy

-- Connect to NativeLink scheduler
connectToScheduler :: RemoteConfig -> IO RemoteClient

-- Execute action on remote worker
executeRemote :: RemoteClient -> Action -> IO ActionResult

-- Upload action inputs to CAS
uploadAction :: RemoteClient -> Action -> IO ActionDigest

-- Download outputs from CAS  
downloadOutputs :: RemoteClient -> ActionDigest -> IO [FilePath]
```

### Remote vs Local Decision

```haskell
-- In Build.hs
executeAction :: LogEnv -> RemoteClient -> Action -> IO ActionResult
executeAction logEnv remote action = do
  -- Check coeffects to decide local vs remote
  if shouldRunRemote action.aCoeffects
    then do
      withPhase logEnv "remote" $ executeRemote remote action
    else do
      withPhase logEnv "local" $ executeLocal action

-- Coeffects determine remote eligibility
shouldRunRemote :: Coeffects -> Bool
shouldRunRemote cs = all isRemoteable cs
  where
    isRemoteable = \case
      Pure -> True
      FilesystemCA _ -> True  -- CA inputs can be uploaded
      NetworkCA _ -> True     -- CA network deps ok
      CoeffectGpu _ -> True   -- Remote GPU workers exist
      Filesystem _ -> False   -- Non-CA fs = must be local
      Environment _ -> False  -- Env vars = local only
      Time -> False           -- Non-deterministic
      Random -> False         -- Non-deterministic
      _ -> False
```

______________________________________________________________________

## Proposed Source Tree

```
sensenet/
├── docs/
│   └── REWRITE.md                    # This document
│
├── dhall/
│   ├── evring/                       # Vendored canonical types
│   │   ├── Coeffect.dhall
│   │   ├── DischargeProof.dhall
│   │   ├── package.dhall
│   │   ├── Rules.dhall
│   │   ├── Source.dhall
│   │   ├── Toolchain.dhall
│   │   └── Triple.dhall
│   │
│   └── prelude/
│       └── package.dhall             # Re-exports evring
│
├── src/sensenet/
│   ├── sensenet.cabal
│   │
│   ├── SenseNet/
│   │   ├── IR.hs                     # Re-exports IR/*
│   │   ├── IR/                       # NEW: Split modules
│   │   │   ├── Coeffect.hs
│   │   │   ├── Triple.hs
│   │   │   ├── Flag.hs
│   │   │   └── Common.hs
│   │   │
│   │   ├── Build.hs                  # Build execution
│   │   ├── DICE.hs                   # Content-addressed cache
│   │   ├── Dhall.hs                  # FromDhall instances
│   │   ├── Discover.hs
│   │   ├── Toolchains.hs
│   │   ├── Nix.hs
│   │   ├── PureScript.hs
│   │   ├── RustCrate.hs
│   │   └── Log.hs                    # NEW: Conditional Katip
│   │
│   ├── DhallFast/
│   │   └── ...
│   │
│   └── app/
│       └── Main.hs
│
└── src/examples/
    └── */BUILD.dhall                 # 19 files to migrate
```

______________________________________________________________________

## Verification Checklist

After each step:

- [ ] `sensenet build //src/examples/cxx:hello-cxx` works
- [ ] `sensenet build //src/examples/nv:hello` works (if CUDA available)
- [ ] Existing cache entries still hit
- [ ] No new compile warnings

Final verification:

- [ ] All 41 targets build
- [ ] Cache keys unchanged (grep for "cached" in output)
- [ ] Bootstrap compiles in \<3 minutes
- [ ] Self-host produces same binary hash
