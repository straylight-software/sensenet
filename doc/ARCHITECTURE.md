# SENSE // NET

A build system for the age of acceleration.

## Overview

SENSENET is a next-generation build system that combines:

- **Dhall** for typed, total configuration
- **DICE** for incremental computation
- **Nix** for hermetic toolchains
- **NativeLink** for remote execution

No Starlark. No BXL. No runtime type errors. Just types, all the way down.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        SENSE // NET                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    HASKELL FRONTEND                          │   │
│  │                                                              │   │
│  │  BUILD.dhall ──▶ Dhall eval ──▶ Target Graph ──▶ Scheduler   │   │
│  │                                                              │   │
│  │  • Dhall parsing & typechecking (dhall library)              │   │
│  │  • Target graph construction                                 │   │
│  │  • Dependency resolution                                     │   │
│  │  • Nix toolchain integration                                 │   │
│  │  • CLI & query interface                                     │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                              │                                       │
│                              │ FFI (C ABI)                          │
│                              ▼                                       │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                      RUST BACKEND                            │   │
│  │                                                              │   │
│  │  • DICE - incremental computation engine                     │   │
│  │  • Superconsole - terminal UI                                │   │
│  │  • RE client - NativeLink protocol                           │   │
│  │  • CAS - content-addressed storage (BLAKE3)                  │   │
│  │  • Action cache - local & remote                             │   │
│  │  • Materializer - deferred artifact materialization          │   │
│  └──────────────────────────────────────────────────────────────┘   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

## Components

### Haskell Frontend

The frontend handles everything before execution:

```haskell
-- Target definition (derived from Dhall types)
data Target = Target
  { name       :: Text
  , srcs       :: [FilePath]
  , deps       :: [Dep]
  , toolchain  :: Toolchain
  , rule       :: Rule
  }

-- Dependency reference
data Dep
  = Local Text              -- ":foo" or "//pkg:foo"
  | Flake Text              -- "nixpkgs#openssl"
  | External Hash Text      -- content-addressed

-- Rule defines how to build
data Rule
  = CxxBinary CxxConfig
  | CxxLibrary CxxConfig
  | RustBinary RustConfig
  | RustLibrary RustConfig
  | HaskellBinary HaskellConfig
  | HaskellLibrary HaskellConfig
  | LeanBinary LeanConfig
  | PureScriptApp PureScriptConfig
  | Genrule GenruleConfig
```

The frontend:

1. Finds all `BUILD.dhall` files
2. Evaluates them to typed Haskell values
3. Constructs the target graph
4. Resolves Nix flake references to store paths
5. Schedules actions for execution
6. Calls into Rust backend via FFI

### Rust Backend

The backend handles execution and caching:

```rust
// Core DICE computation
pub trait DiceCompute {
    fn compute(&self, key: &ActionKey) -> Result<ActionResult>;
    fn invalidate(&self, keys: &[ActionKey]);
}

// Action execution
pub struct Action {
    pub inputs: Vec<Artifact>,
    pub outputs: Vec<OutputPath>,
    pub command: Command,
    pub env: HashMap<String, String>,
}

// Remote execution
pub trait RemoteExecutor {
    fn execute(&self, action: &Action) -> Result<ActionResult>;
    fn cache_lookup(&self, digest: &Digest) -> Option<ActionResult>;
    fn cache_store(&self, digest: &Digest, result: &ActionResult);
}
```

Extracted/adapted from Buck2:

- `dice/` - incremental computation
- `execute/` - action execution
- `re_client/` - remote execution protocol
- `cas/` - content-addressed storage
- `materializer/` - deferred materialization

Added as dependency:

- `superconsole` - terminal UI (separate crate)

### FFI Boundary

C ABI interface between Haskell and Rust:

```c
// dice_c.h

typedef struct SenseContext* sense_ctx_t;
typedef struct ActionDigest { uint8_t bytes[32]; } action_digest_t;

// Lifecycle
sense_ctx_t sense_init(const char* config_json);
void sense_shutdown(sense_ctx_t ctx);

// DICE operations
int32_t sense_compute(
    sense_ctx_t ctx,
    const char* action_json,
    size_t action_len,
    char** result_json,
    size_t* result_len
);
void sense_invalidate(sense_ctx_t ctx, const action_digest_t* keys, size_t count);

// Console
void sense_console_start(sense_ctx_t ctx);
void sense_console_render(sense_ctx_t ctx, const char* state_json, size_t len);
void sense_console_finish(sense_ctx_t ctx);

// Cache
int32_t sense_cache_lookup(sense_ctx_t ctx, action_digest_t digest, char** result, size_t* len);
void sense_cache_store(sense_ctx_t ctx, action_digest_t digest, const char* result, size_t len);

// Free allocated memory
void sense_free_string(char* ptr);
```

### Build Configuration

All configuration in Dhall:

```dhall
-- BUILD.dhall
let S = ../sensenet/package.dhall

let hello = S.cxxBinary {
  name = "hello",
  srcs = ["main.cpp"],
  deps = [S.flake "nixpkgs#fmt"],
  std = S.Cxx23,
  flags = ["-O2", "-Wall"]
}

in { targets = [hello] }
```

Types enforce correctness:

```dhall
-- sensenet/Cxx.dhall
let CxxStd = < Cxx11 | Cxx14 | Cxx17 | Cxx20 | Cxx23 >

let CxxBinary = {
  name : Text,
  srcs : List Text,
  deps : List Dep,
  std : CxxStd,
  flags : List Text
}
```

### Toolchain Resolution

Nix provides hermetic toolchains:

```haskell
-- Resolve flake reference to Nix store path
resolveFlake :: Text -> IO StorePath
resolveFlake ref = do
  -- nix build --no-link --print-out-paths nixpkgs#fmt
  path <- readProcess "nix" ["build", "--no-link", "--print-out-paths", ref]
  pure (StorePath path)

-- Extract compiler flags from Nix derivation
getCompilerFlags :: StorePath -> IO CompilerFlags
getCompilerFlags path = do
  -- Query pkg-config or nix-support
  includes <- glob (path </> "include")
  libs <- glob (path </> "lib")
  pure CompilerFlags { includeFlags = ["-I" <> i | i <- includes], ... }
```

## Bootstrap

Single cabal build to bootstrap:

```bash
# Bootstrap SENSENET
nix develop
cabal build sensenet

# Now self-hosting
./sensenet build //...
```

The bootstrap builds:

1. Haskell frontend (dhall + FFI bindings)
2. Rust backend (DICE + superconsole + RE)
3. Links them together

After bootstrap, SENSENET builds itself.

## Queries

Queries are just Dhall evaluation + jq:

```bash
# List all targets
sense query 'targets(//...)'

# Dependencies of a target
sense query 'deps(//src:hello)'

# Reverse dependencies
sense query 'rdeps(//..., //lib:core)'

# Filtered by rule type
sense query 'kind(cxx_binary, //...)'
```

Internally:

```bash
dhall-to-json <<< './BUILD.dhall' | jq '.targets[] | select(.rule == "cxx_binary")'
```

No BXL needed. The target graph is typed data, queryable with standard tools.

## Remote Execution

NativeLink protocol for remote execution:

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  SENSENET   │────▶│  NativeLink │────▶│   Workers   │
│   client    │     │   server    │     │             │
└─────────────┘     └─────────────┘     └─────────────┘
       │                   │
       │                   ▼
       │            ┌─────────────┐
       └───────────▶│     CAS     │
                    │   (S3/GCS)  │
                    └─────────────┘
```

Configuration:

```dhall
-- .sensenet/config.dhall
let Config = {
  remote_execution = Some {
    endpoint = "grpc://nativelink.example.com:8980",
    cas_endpoint = "grpc://cas.example.com:8980",
    instance_name = "main"
  },
  cache = {
    local = { path = ".sensenet/cache", max_size_gb = 10 },
    remote = Some { endpoint = "grpc://cache.example.com:8980" }
  }
}
in Config
```

## Directory Structure

```
sensenet/
├── app/
│   └── Main.hs                 # CLI entrypoint
├── cbits/
│   ├── sense_c.h               # C ABI header
│   └── sense_c.cpp             # Rust FFI shim
├── crates/
│   ├── sense-dice/             # DICE (from Buck2)
│   ├── sense-execute/          # Action execution
│   ├── sense-re/               # Remote execution client
│   ├── sense-cas/              # Content-addressed storage
│   └── sense-ffi/              # C ABI exports
├── dhall/
│   ├── package.dhall           # Prelude
│   ├── Cxx.dhall               # C++ types
│   ├── Rust.dhall              # Rust types
│   ├── Haskell.dhall           # Haskell types
│   └── ...
├── src/
│   └── Sensenet/
│       ├── Target.hs           # Target types
│       ├── Graph.hs            # Target graph
│       ├── Resolve.hs          # Nix resolution
│       ├── Schedule.hs         # Action scheduling
│       ├── Dice/
│       │   └── FFI.hs          # Rust FFI bindings
│       ├── Console/
│       │   └── FFI.hs          # Superconsole FFI
│       └── Query.hs            # Query interface
├── sensenet.cabal
├── Cargo.toml                  # Rust workspace
├── flake.nix
└── BUILD.dhall                 # Self-hosting
```

## Comparison

| Feature          | Buck2          | SENSENET     |
| ---------------- | -------------- | ------------ |
| Config language  | Starlark       | Dhall        |
| Type checking    | Runtime        | Compile time |
| Rule definitions | .bzl files     | Dhall types  |
| Queries          | BXL            | dhall + jq   |
| Toolchains       | Starlark       | Nix          |
| Bootstrap        | Buck2 or Cargo | Cabal (once) |
| Incremental      | DICE           | DICE         |
| Remote exec      | RE API         | NativeLink   |

## Milestones

### M1: Bootstrap

- [ ] Haskell CLI scaffold
- [ ] Rust workspace with DICE extraction
- [ ] FFI bridge (hello world)
- [ ] Superconsole integration
- [ ] `sense --version` works

### M2: Local Execution

- [ ] Dhall target loading
- [ ] Nix toolchain resolution
- [ ] Action graph construction
- [ ] Local action execution
- [ ] `sense build //examples:hello` works

### M3: Caching

- [ ] Content-addressed storage
- [ ] Local action cache
- [ ] Deferred materialization
- [ ] `sense build` is incremental

### M4: Remote Execution

- [ ] NativeLink client
- [ ] Remote cache
- [ ] Remote execution
- [ ] `sense build --remote` works

### M5: Self-Hosting

- [ ] SENSENET builds itself
- [ ] All toolchains migrated
- [ ] Documentation complete
- [ ] v0.1.0 release

## License

Apache 2.0 (DICE, superconsole derived from Meta OSS)
