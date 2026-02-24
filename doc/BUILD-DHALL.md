# BUILD.dhall Schema Reference

> Zero Starlark: Typed build configs that generate BUCK files.

## Overview

BUILD.dhall files define build targets using typed Dhall records. The `sense` CLI or shell hook automatically generates BUCK files from these definitions.

```
BUILD.dhall  →  dhall-to-buck  →  BUCK  →  buck2 build
```

Users only edit BUILD.dhall; BUCK files are derived artifacts.

## File Format

Every BUILD.dhall exports a record with two fields:

```dhall
{ rules : List Text    -- Rendered Starlark rule calls
, header : Text        -- Load statements and file header
}
```

### Example

```dhall
let A = ./dhall/prelude/package.dhall
let S = ./dhall/prelude/to-starlark.dhall

let hello = A.haskellBinary "hello" ["Main.hs"]
              with packages = ["base", "text"]

in  { rules = [ S.haskellBinary hello ]
    , header = ''load("@toolchains//:haskell.bzl", "haskell_binary")''
    }
```

Generates:

```python
# Generated from BUILD.dhall
load("@toolchains//:haskell.bzl", "haskell_binary")

haskell_binary(
    name = "hello",
    srcs = ["Main.hs"],
    main = "Main",
    packages = ["base", "text"],
    ghc_options = ["-O2", "-Wall"],
    visibility = ["PUBLIC"],
)
```

## Rule Types

### C++

```dhall
let A = ./dhall/prelude/package.dhall

-- Binary
let mybin = A.cxxBinary "mybin" ["main.cpp"] deps
              with std = A.CxxStd.Cxx23
              with cflags = ["-Wall"]
              with ldflags = ["-lm"]

-- Library  
let mylib = A.cxxLibrary "mylib" ["lib.cpp"] deps
              with hdrs = ["lib.h"]
              with std = A.CxxStd.Cxx20
```

**Fields:**
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | Text | required | Target name |
| `srcs` | List Text | required | Source files |
| `deps` | List Dep | `[]` | Dependencies |
| `std` | CxxStd | `Cxx17` | C++ standard |
| `cflags` | List Text | `[]` | Compiler flags |
| `ldflags` | List Text | `[]` | Linker flags |
| `hdrs` | List Text | `[]` | Exported headers (library only) |
| `vis` | Vis | `Public` | Visibility |

**CxxStd:** `Cxx11`, `Cxx14`, `Cxx17`, `Cxx20`, `Cxx23`

### Haskell

```dhall
-- Binary
let app = A.haskellBinary "app" ["Main.hs"]
            with packages = ["base", "aeson", "text"]
            with language_extensions = ["OverloadedStrings", "DeriveGeneric"]
            with ghc_options = ["-threaded", "-rtsopts"]

-- Library
let lib = A.haskellLibrary "mylib" ["Lib.hs", "Util.hs"]
            with packages = ["base", "containers"]

-- FFI Binary (Haskell + C++)
let ffi = A.haskellFFIBinary "ffi-app"
            with hs_srcs = ["Main.hs"]
            with cxx_srcs = ["wrapper.cpp"]
            with cxx_headers = ["wrapper.h"]
            with packages = ["base"]
            with extra_libs = ["stdc++"]
```

**Fields:**
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | Text | required | Target name |
| `srcs` | List Text | required | Source files |
| `main` | Text | `"Main"` | Main module (binary only) |
| `packages` | List Text | `["base"]` | GHC packages |
| `language_extensions` | List Text | `[]` | GHC extensions |
| `ghc_options` | List Text | `["-O2", "-Wall"]` | GHC flags |
| `vis` | Vis | `Public` | Visibility |

### Rust

```dhall
-- Binary
let app = A.rustBinary "myapp" ["src/main.rs"]
            with edition = A.RustEdition.E2021

-- Library
let lib = A.rustLibrary "mylib" ["src/lib.rs"]
            with crate_name = Some "my_crate"
            with proc_macro = True
            with features = ["async", "serde"]
```

**Fields:**
| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | Text | required | Target name |
| `srcs` | List Text | required | Source files |
| `deps` | List Dep | `[]` | Dependencies |
| `edition` | Edition | `E2021` | Rust edition |
| `crate_name` | Optional Text | `None` | Crate name override |
| `proc_macro` | Bool | `False` | Is proc macro |
| `features` | List Text | `[]` | Enabled features |
| `vis` | Vis | `Public` | Visibility |

**Edition:** `E2015`, `E2018`, `E2021`, `E2024`

### Lean

```dhall
let theorem = A.leanBinary "prover" ["Main.lean"]
                with root_module = Some "Prover"

let mathlib = A.leanLibrary "mathlib" ["Algebra.lean", "Topology.lean"]
```

### NVIDIA/CUDA

```dhall
let kernel = A.nvBinary "matmul" ["matmul.cu"]

let cudaLib = A.nvLibrary "kernels" ["ops.cu"]
                with exported_headers = ["ops.cuh"]
```

### PureScript

```dhall
-- Web app with HTML/CSS
let app = A.purescriptApp "dashboard"
            with srcs = A.SrcSpec.Glob "src/**/*.purs"
            with spago_yaml = "spago.yaml"
            with main = "Main"
            with index_html = Some "index.html"
            with style_css = Some "style.css"

-- CLI binary
let cli = A.purescriptBinary "cli"
            with srcs = A.SrcSpec.Explicit ["src/Main.purs"]
            with spago_yaml = "spago.yaml"
            with main = "Main"

-- Library
let lib = A.purescriptLibrary "components"
            with srcs = A.SrcSpec.Globs ["src/**/*.purs", "lib/**/*.purs"]
```

### Genrule

```dhall
let gen = A.genrule "generated"
            with srcs = ["input.txt"]
            with out = "output.txt"
            with cmd = "cat $SRCS | process > $OUT"
```

### Nix C++ (with Nix dependencies)

```dhall
let app = A.nixCxxBinary "app"
            with srcs = ["main.cpp"]
            with nix_deps = ["nixpkgs#openssl", "nixpkgs#zlib"]
            with compiler_flags = ["-O2"]
```

## Dependencies

Dependencies use a union type:

```dhall
let Dep = < Local : Text | Flake : Text >

-- Local target dependency
A.local "//lib:mylib"

-- Flake dependency (resolved via nix-analyze)
A.flake "nixpkgs#openssl"
```

## Toolchains

Toolchain BUILD.dhall defines available compilers:

```dhall
let A = ./dhall/prelude/package.dhall
let S = ./dhall/prelude/to-starlark.dhall

let cxx = (A.cxxToolchain "cxx")
            with c_extra_flags = ["-std=c23", "-Wall"]
            with cxx_extra_flags = ["-std=c++23", "-Wall", "-fno-exceptions"]
            with link_style = "static"

let haskell = (A.haskellToolchain "haskell")
                with compiler_flags = ["-Wall", "-XGHC2024", "-fwrite-ide-info"]

let rust = (A.rustToolchain "rust")
             with default_edition = "2021"
             with rustc_flags = ["-C", "opt-level=2"]

let nv = (A.nvToolchain "nv")
           with nv_archs = ["sm_90", "sm_100", "sm_120"]

let lre = (A.executionPlatform "lre")
            with local_enabled = True
            with remote_enabled = True

in  { rules =
        [ S.cxxToolchain cxx
        , S.haskellToolchain haskell
        , S.rustToolchain rust
        , S.nvToolchain nv
        , S.executionPlatform lre
        , S.pythonBootstrap (A.pythonBootstrap "python_bootstrap")
        , S.genruleToolchain (A.genruleToolchain "genrule")
        ]
    , header = ''
        load(":cxx.bzl", "llvm_toolchain")
        load(":haskell.bzl", "haskell_toolchain")
        load(":rust.bzl", "rust_toolchain")
        load(":nv.bzl", "nv_toolchain")
        load(":execution.bzl", "lre_execution_platform", "host_configuration")
        load("@aleph//toolchains:python.bzl", "system_python_bootstrap_toolchain")
        load("@aleph//toolchains:genrule.bzl", "system_genrule_toolchain")
        ''
    }
```

## Zero Starlark Modes

### Simple Mode (Default)

BUCK files are generated on shell entry and gitignored:

```bash
nix develop  # Generates BUCK files
buck2 build //...
```

Add to `.gitignore`:

```
BUCK
```

### Overlay Mode

BUCK files exist only in memory via Linux user namespaces:

```bash
sense-overlay buck2 build //...
```

How it works:

1. Generates BUCK files into tmpdir
1. Creates isolated mount namespace with `unshare`
1. Bind-mounts BUCK files into source tree
1. Runs buck2 in this namespace
1. On exit, mounts disappear - no files on disk

Requirements:

- Linux with user namespaces (`kernel.unprivileged_userns_clone=1`)
- util-linux (unshare, mount)

### sense CLI

The `sense` CLI wraps buck2 and regenerates BUCK files automatically:

```bash
sense build //target      # Regenerate + build
sense run //target        # Regenerate + run
sense gen                 # Regenerate all BUILD.dhall → BUCK
sense targets             # List targets
sense query <expr>        # Query build graph
sense clean               # Clean outputs
```

## String Escaping

The `q` function in `to-starlark.dhall` uses `Text/show` for proper escaping:

```dhall
-- Handles backslashes, quotes, newlines correctly
let q = \(t : Text) -> Text/show t

-- "hello \"world\""  →  "\"hello \\\"world\\\"\""
```

This ensures generated Starlark is always syntactically valid.

## Prelude Imports

```dhall
-- All types and constructors
let A = ./dhall/prelude/package.dhall

-- Starlark renderers
let S = ./dhall/prelude/to-starlark.dhall

-- Raw type definitions
let C = ./dhall/prelude/Cxx.dhall
let H = ./dhall/prelude/Haskell.dhall
let R = ./dhall/prelude/Rust.dhall
let L = ./dhall/prelude/Lean.dhall
let N = ./dhall/prelude/Nv.dhall
let PS = ./dhall/prelude/PureScript.dhall
let TC = ./dhall/prelude/Toolchain.dhall
let T = ./dhall/prelude/Types.dhall
```

## Migration from BUCK

To convert existing BUCK files to BUILD.dhall:

1. Create BUILD.dhall with equivalent Dhall definitions
1. Add `BUCK` to `.gitignore`
1. Run `sense gen` to verify output matches
1. Delete the old BUCK file
