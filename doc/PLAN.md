# SENSE // NET Implementation Plan

## Current Phase: Internal Representation + Buck2 Fiction

sensenet reads the filesystem, constructs a typed internal representation, then generates
exactly what Buck2 needs to see. The generated artifacts are ephemeral — they exist only
to extract DICE + TUI behavior from Buck2.

### Principles

1. **sensenet is the source of truth** — BUILD.dhall files define targets, sensenet.dhall
   configures the project, the Dhall prelude defines rules and toolchains
2. **Buck2 sees a fiction** — .buckconfig, BUCK, .bzl are generated into tmpdir, bind-mounted
   over the project, and discarded after build
3. **No Starlark in repo** — users never write or edit .bzl files; they exist only as
   generated compilation targets
4. **Dhall evaluation moves into Haskell** — replace shelling out to `dhall` CLI with the
   dhall Haskell library for parsing and evaluation
5. **CLI exposes internals** — debugging commands like `sensenet emit-buck`, `sensenet emit-bzl`,
   `sensenet graph` let users inspect what sensenet constructs

### Implementation Steps

#### Step 1: Internal Representation (SenseNet.IR)

Define Haskell types mirroring the Dhall schema. These are the typed internal representation
that sensenet constructs from BUILD.dhall files.

```haskell
-- SenseNet/IR.hs
module SenseNet.IR where

-- Target triple (typed, not strings)
data Arch = X86_64 | Aarch64 | Wasm32 | Riscv64
data OS = Linux | Darwin | Wasi | None
data ABI = Gnu | Musl | Eabi | Unknown
data Triple = Triple { arch :: Arch, os :: OS, abi :: ABI }

-- Toolchain
data CompilerKind = Clang Text | GCC Text | Rustc Text | GHC Text | Lean Text
data Linker = LLD | Gold | BFD | Mold | System
data Toolchain = Toolchain
  { compiler :: CompilerKind
  , host :: Triple
  , target :: Triple
  , flags :: [Flag]
  , linker :: Maybe Linker
  , sysroot :: Maybe Artifact
  }

-- Dependency reference
data Dep
  = DepLocal Text           -- ":foo" or "//pkg:foo"
  | DepFlake Text           -- "nixpkgs#openssl.dev"
  | DepExternal Hash Text   -- content-addressed

-- Rules
data CxxStd = Cxx11 | Cxx14 | Cxx17 | Cxx20 | Cxx23
data Visibility = Public | Private | Package | Targets [Text]

data Rule
  = CxxBinary { name :: Text, srcs :: [FilePath], deps :: [Dep], std :: CxxStd, ... }
  | CxxLibrary { ... }
  | RustBinary { ... }
  | RustLibrary { ... }
  | HaskellBinary { ... }
  | HaskellLibrary { ... }
  | LeanBinary { ... }
  | LeanLibrary { ... }
  | PureScriptApp { ... }
  | Genrule { ... }

-- A package is a directory with a BUILD.dhall
data Package = Package
  { path :: FilePath       -- relative path from project root
  , rules :: [Rule]
  }

-- The complete build graph
data BuildGraph = BuildGraph
  { packages :: [Package]
  , toolchains :: [Toolchain]
  }
```

#### Step 2: Dhall Parsing (SenseNet.Dhall)

Use the dhall Haskell library to parse and evaluate BUILD.dhall files into the IR.

```haskell
-- SenseNet/Dhall.hs
module SenseNet.Dhall where

import Dhall
import SenseNet.IR

-- Parse a BUILD.dhall into a Package
parsePackage :: FilePath -> IO Package

-- Parse sensenet.dhall into project config
parseConfig :: FilePath -> IO ProjectConfig

-- Parse toolchains/BUILD.dhall into toolchain definitions
parseToolchains :: FilePath -> IO [Toolchain]
```

#### Step 3: Starlark Emission (SenseNet.Emit)

Generate Buck2 artifacts from the IR. This replaces shelling out to dhall and the
to-starlark.dhall pattern.

```haskell
-- SenseNet/Emit.hs
module SenseNet.Emit where

import SenseNet.IR

-- Emit a BUCK file for a package
emitBuck :: Package -> Text

-- Emit a .bzl file for a toolchain
emitToolchainBzl :: Toolchain -> Text

-- Emit .buckconfig
emitBuckconfig :: ProjectConfig -> Text

-- Emit the complete Buck2 fiction to a directory
emitAll :: BuildGraph -> FilePath -> IO ()
```

#### Step 4: nix-analyze Integration (SenseNet.Nix)

Resolve `nixpkgs#foo.dev` references to concrete Nix store paths and compiler flags.
This may absorb the standalone nix-analyze tool.

```haskell
-- SenseNet/Nix.hs
module SenseNet.Nix where

-- Resolve a flake reference to store path + flags
data NixResolution = NixResolution
  { storePath :: FilePath
  , includeFlags :: [Text]
  , linkFlags :: [Text]
  , defines :: [(Text, Maybe Text)]
  }

resolveFlake :: Text -> IO NixResolution

-- Batch resolution (single nix invocation)
resolveFlakes :: [Text] -> IO (Map Text NixResolution)
```

#### Step 5: CLI Commands (Main.hs)

Expose the internals via CLI for debugging.

```
sensenet build <target>       -- build via Buck2 (current behavior)
sensenet graph                -- dump the build graph as JSON/Dhall
sensenet emit-buck <package>  -- print generated BUCK for a package
sensenet emit-bzl <toolchain> -- print generated .bzl for a toolchain
sensenet emit-config          -- print generated .buckconfig
sensenet resolve <flake-ref>  -- resolve a Nix flake reference
sensenet targets              -- list all targets (current behavior)
sensenet lint                 -- typecheck all BUILD.dhall files
```

#### Step 6: Namespace Execution (SenseNet.Namespace)

Current implementation is mostly correct. Refinements:

- Ensure target directories exist before bind mount (rm symlink, mkdir if needed)
- Support --dry-run to show what would be mounted
- Better error messages when Buck2 fails

### File Structure After Implementation

```
src/sensenet/
├── Main.hs                 -- CLI entrypoint
├── SenseNet/
│   ├── Config.hs           -- Project configuration (exists)
│   ├── Discover.hs         -- File discovery (exists)
│   ├── IR.hs               -- Internal representation (new)
│   ├── Dhall.hs            -- Dhall parsing (new)
│   ├── Emit.hs             -- Starlark emission (new)
│   ├── Emit/
│   │   ├── Buck.hs         -- BUCK file emission
│   │   ├── Bzl.hs          -- .bzl file emission
│   │   └── Buckconfig.hs   -- .buckconfig emission
│   ├── Nix.hs              -- Nix resolution (new)
│   ├── Namespace.hs        -- Linux namespace (exists)
│   ├── Generate.hs         -- Orchestration (refactor)
│   └── Target.hs           -- Legacy, merge into IR.hs
```

### Dependencies to Add

```cabal
build-depends:
  , dhall         >= 1.42    -- Dhall parsing
  , aeson         >= 2.0     -- JSON for graph output
  , prettyprinter >= 1.7     -- Starlark pretty printing
```

### Testing Strategy

1. **Keep existing .bzl files as reference** — the current toolchains/ directory works;
   compare generated output against it until identical
2. **Golden tests** — emit BUCK for each src/examples/\*/BUILD.dhall, compare to expected
3. **Round-trip test** — parse BUILD.dhall -> IR -> emit BUCK -> Buck2 parse succeeds
4. **Integration test** — `sensenet build //src/examples/cxx:hello` produces working binary

### Definition of Done

- [ ] `sensenet emit-buck //src/examples/cxx` outputs valid BUCK matching current behavior
- [ ] `sensenet emit-bzl cxx` outputs valid .bzl matching toolchains/cxx.bzl
- [ ] `sensenet build //src/examples/cxx:hello` works end-to-end
- [ ] All .bzl and BUCK files deleted from repo (generated at runtime)
- [ ] No shelling out to `dhall` CLI (all evaluation in Haskell)

### Open Questions

1. **SCM integration** — should sensenet consult git for file lists? Pros: hermetic, no
   accidental untracked files. Cons: slower, complexity.
2. **nix-analyze fate** — fold entirely into sensenet, or keep as separate tool?
3. **Caching Dhall evaluation** — cache normalized Dhall to avoid re-evaluation?
