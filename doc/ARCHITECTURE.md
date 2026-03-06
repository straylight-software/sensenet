# sensenet Architecture

Direct builds with Dhall + DICE. No Buck2, no Starlark.

## Overview

sensenet is a build system that combines:

- **Dhall** for typed, total configuration
- **DICE** for incremental computation (extracted from Buck2)
- **Nix** for hermetic toolchains
- **NativeLink** for remote execution

The key insight: Buck2's value is DICE, not Starlark. sensenet extracts DICE via FFI and drives it directly from Haskell, bypassing the Starlark layer entirely.

## Data Flow

```
BUILD.dhall
    |
    v
+-------------------+
| SenseNet.Dhall    |  Dhall library parses typed config
+-------------------+
    |
    v
+-------------------+
| SenseNet.IR       |  Haskell types: Package, Rule, Dep, etc.
+-------------------+
    |
    v
+-------------------+
| SenseNet.Build    |  Orchestrates build execution
+-------------------+
    |
    +---> SenseNet.DICE (FFI to Rust)
    |         |
    |         v
    |     dice_ffi.so
    |         |
    |         v
    |     DICE engine (incremental computation)
    |
    +---> SenseNet.Console (FFI to Rust)
    |         |
    |         v
    |     superconsole_ffi.so
    |         |
    |         v
    |     Terminal UI
    |
    +---> SenseNet.Remote (gRPC)
              |
              v
          NativeLink (remote execution)
```

## Components

### Haskell Frontend

The frontend handles configuration and orchestration:

| Module | Purpose |
|--------|---------|
| `Main.hs` | CLI entry point |
| `SenseNet.IR` | Internal representation - typed build graph |
| `SenseNet.Dhall` | BUILD.dhall parser using dhall library |
| `SenseNet.Discover` | Finds BUILD.dhall files in project |
| `SenseNet.Build` | Build orchestration with DICE |
| `SenseNet.Toolchains` | Toolchain configuration loading |
| `SenseNet.Remote` | NativeLink gRPC client |

### Internal Representation (SenseNet.IR)

The IR is the source of truth - typed Haskell data derived from Dhall:

```haskell
-- Dependency reference
data Dep
  = DepLocal Text      -- ":foo" or "//pkg:foo"
  | DepFlake Text      -- "nixpkgs#openssl.dev"

-- Rules (18 rule types)
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

-- A package is a directory with a BUILD.dhall
data Package = Package
  { path  :: FilePath
  , rules :: [Rule]
  }
```

### DICE Integration (SenseNet.DICE)

DICE (Dynamic Incremental Computation Engine) provides:

- Content-addressed caching
- Automatic dependency invalidation
- Parallel execution with correct ordering

The DICE monad wraps FFI calls to the Rust engine:

```haskell
-- The DICE Monad
newtype DICE a = DICE (ReaderT DICEEnv IO a)

-- Core operations
inject :: Text -> Text -> Word64 -> DICE ()  -- Register source file
compute :: Text -> DICE [Text]               -- Request computation
registerTarget :: Text -> [Text] -> Callback -> DICE ()

-- Run a DICE computation
runDICE :: DICE a -> IO (Either DICEError a)
```

### Superconsole TUI (SenseNet.Console)

Terminal UI for build progress, also via Rust FFI:

```haskell
-- Console operations
withBuildConsole :: (Console -> BuildProgress -> IO a) -> IO (Maybe a)
updateProgress :: BuildProgress -> Word64 -> Word64 -> Word64 -> Word64 -> IO ()
startAction :: BuildProgress -> Word64 -> Text -> IO ()
finishAction :: BuildProgress -> Word64 -> ActionStatus -> IO ()
```

Falls back gracefully when stderr is not a TTY.

### NativeLink Client (SenseNet.Remote)

gRPC client for Remote Execution API v2:

```haskell
data RemoteConfig = RemoteConfig
  { host :: String
  , port :: Int
  , useTLS :: Bool
  , instanceName :: Text
  }

remoteBuild :: RemoteConfig -> Toolchains -> FilePath -> Package -> Text
            -> IO (Either Text [FilePath])
```

Uses proto-lens for protobuf and grapesy for HTTP/2.

## Rust Backend (src/vendor/)

Extracted/adapted from Buck2:

### DICE (src/vendor/dice/)

The incremental computation engine:

```
dice/
+-- dice/           # Core DICE library
+-- dice_futures/   # Async execution
+-- dice_error/     # Error types
+-- allocative/     # Memory tracking
+-- gazebo/         # Utility traits
+-- dupe/           # Clone utilities
+-- lock_free_hashtable/
```

Exposed via C ABI in `dice_ffi`:

```c
// Engine lifecycle
dice_engine_t* dice_engine_new(void);
void dice_engine_free(dice_engine_t* engine);

// Transactions
dice_transaction_t* dice_transaction_new(dice_engine_t* engine);
void dice_transaction_commit(dice_transaction_t* txn);

// Operations
void dice_inject(dice_transaction_t* txn, const char* key, ...);
char** dice_compute(dice_engine_t* engine, const char* key, ...);
```

### Superconsole (src/vendor/superconsole/)

Terminal UI library:

```
superconsole/
+-- superconsole/      # Core library
+-- superconsole_ffi/  # C ABI wrapper
```

## Build Execution

When `sensenet build //pkg:target` runs:

1. **Discovery**: Find BUILD.dhall at `pkg/BUILD.dhall`
2. **Parse**: Evaluate Dhall to `Package` with typed `[Rule]`
3. **Register**: Add all rules to DICE with their dependencies
4. **Compute**: Request target computation from DICE
5. **Execute**: DICE schedules actions in dependency order
6. **Cache**: Results cached by content hash (BLAKE3)

```haskell
buildWithDeps :: Toolchains -> FilePath -> Package -> Text
              -> IO (Either BuildError BuildResult)
buildWithDeps tc projectRoot pkg targetName = do
  runDICE $ do
    clearTargets
    forM_ pkg.rules $ \rule -> do
      let name = ruleName rule
          deps = extractLocalDepNames (ruleDeps rule)
      registerTarget name deps (makeCallback tc projectRoot pkg.path ruleMap)
    compute targetName
```

## Output Directories

| Mode | Output | Description |
|------|--------|-------------|
| `sensenet build` | `sensenet-out/` | Direct DICE execution |
| `buck2 build` | `buck-out/` | Buck2 with generated BUCK files |

## Toolchain Resolution

Toolchains are loaded from `.buckconfig.local` (generated by Nix devshell):

```ini
[cxx]
cc = /nix/store/xxx/bin/clang
cxx = /nix/store/xxx/bin/clang++

[haskell]
ghc = /nix/store/yyy/bin/ghc

[rust]
rustc = /nix/store/zzz/bin/rustc
```

The `SenseNet.Toolchains` module parses these paths.

## File Structure

```
src/sensenet/
+-- Main.hs                    # CLI (353 lines)
+-- SenseNet/
|   +-- IR.hs                  # Internal representation (518 lines)
|   +-- Dhall.hs               # Dhall parser
|   +-- Discover.hs            # BUILD.dhall discovery
|   +-- Build.hs               # Build execution
|   +-- DICE.hs                # DICE monad
|   +-- DICE/FFI.hs            # Rust FFI bindings
|   +-- Console.hs             # Superconsole integration
|   +-- Console/FFI.hs         # Rust FFI bindings
|   +-- Remote.hs              # NativeLink client
|   +-- Toolchains.hs          # Toolchain loading
+-- NativeLink/
|   +-- Client.hs              # gRPC client
|   +-- Execution.hs           # Remote execution
|   +-- Proto.hs               # Protobuf helpers
+-- Proto/                     # Proto-lens generated (REAPI)
```

## Comparison with Buck2

| Aspect | Buck2 | sensenet |
|--------|-------|----------|
| Config language | Starlark | Dhall |
| Type checking | Runtime | Compile time |
| Rule definitions | .bzl files | Haskell types |
| Incremental engine | DICE | DICE (same) |
| CLI | buck2 | sensenet |
| Output | buck-out/ | sensenet-out/ |

sensenet uses the same DICE engine as Buck2 but with a typed frontend.

## Dependencies

From `sensenet.cabal`:

```
extra-libraries:  dice_ffi superconsole_ffi

build-depends:
  , dhall          >= 1.42   -- Dhall parsing
  , crypton        >= 0.34   -- BLAKE3 hashing
  , grapesy        >= 0.1    -- HTTP/2 gRPC
  , proto-lens     >= 0.7    -- Protobuf
  , aeson          >= 2.0    -- JSON
```

## Future Work

1. **Full remote execution** - Complete NativeLink integration
2. **Parallel builds** - Multi-target parallel DICE computation
3. **Watch mode** - Incremental rebuilds on file change
4. **Query language** - Dhall-native target queries
