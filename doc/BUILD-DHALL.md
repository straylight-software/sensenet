# BUILD.dhall Schema Reference

Typed build configuration for sensenet.

## Overview

BUILD.dhall files define build targets using typed Dhall records. sensenet parses these directly into its internal representation for DICE-based execution.

```
BUILD.dhall -> SenseNet.Dhall -> SenseNet.IR -> DICE -> execute
```

## File Format

Every BUILD.dhall exports a record with a `targets` field:

```dhall
{ targets : List Rule }
```

### Example

```dhall
let A = ../../../dhall/prelude/package.dhall

let hello = A.cxxBinary "hello" ["main.cpp"] ([] : List A.Dep)
              with std = A.CxxStd.Cxx23

in  { targets = [ A.rule.cxxBinary hello ] }
```

## Rule Types

### C++

```dhall
let A = ./dhall/prelude/package.dhall

-- Binary
let mybin = A.cxxBinary "mybin" ["main.cpp"] ([] : List A.Dep)
              with std = A.CxxStd.Cxx23
              with cflags = ["-Wall", "-O2"]
              with ldflags = ["-lm"]

-- Library
let mylib = A.cxxLibrary "mylib" ["lib.cpp"] ([] : List A.Dep)
              with hdrs = ["lib.h"]
              with std = A.CxxStd.Cxx20

in  { targets =
        [ A.rule.cxxBinary mybin
        , A.rule.cxxLibrary mylib
        ]
    }
```

**Fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | Text | required | Target name |
| `srcs` | List Text | required | Source files |
| `deps` | List Dep | required | Dependencies |
| `std` | CxxStd | `Cxx17` | C++ standard |
| `cflags` | List Text | `[]` | Compiler flags |
| `ldflags` | List Text | `[]` | Linker flags |
| `hdrs` | List Text | `[]` | Exported headers (library) |
| `vis` | Vis | `Public` | Visibility |

**CxxStd:** `Cxx11`, `Cxx14`, `Cxx17`, `Cxx20`, `Cxx23`

### Rust

```dhall
-- Binary
let app = A.rustBinary "myapp" ["src/main.rs"] ([] : List A.Dep)
            with edition = A.RustEdition.E2021

-- Library
let lib = A.rustLibrary "mylib" ["src/lib.rs"] ([] : List A.Dep)
            with crate_name = Some "my_crate"
            with proc_macro = True
            with features = ["async", "serde"]

in  { targets =
        [ A.rule.rustBinary app
        , A.rule.rustLibrary lib
        ]
    }
```

**Fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | Text | required | Target name |
| `srcs` | List Text | required | Source files |
| `deps` | List Dep | required | Dependencies |
| `edition` | Edition | `E2021` | Rust edition |
| `crate_name` | Optional Text | `None` | Crate name override |
| `proc_macro` | Bool | `False` | Is proc macro |
| `features` | List Text | `[]` | Enabled features |
| `vis` | Vis | `Public` | Visibility |

**Edition:** `E2015`, `E2018`, `E2021`, `E2024`

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

in  { targets =
        [ A.rule.haskellBinary app
        , A.rule.haskellLibrary lib
        , A.rule.haskellFFIBinary ffi
        ]
    }
```

**Fields:**

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | Text | required | Target name |
| `srcs` | List Text | required | Source files |
| `main` | Text | `"Main"` | Main module (binary) |
| `packages` | List Text | `["base"]` | GHC packages |
| `language_extensions` | List Text | `[]` | GHC extensions |
| `ghc_options` | List Text | `["-O2", "-Wall"]` | GHC flags |
| `deps` | List Dep | `[]` | Dependencies |
| `vis` | Vis | `Public` | Visibility |

### Lean 4

```dhall
let theorem = A.leanBinary "prover" ["Main.lean"] ([] : List A.Dep)
                with root_module = Some "Prover"

let mathlib = A.leanLibrary "mathlib" ["Algebra.lean", "Topology.lean"] ([] : List A.Dep)

in  { targets =
        [ A.rule.leanBinary theorem
        , A.rule.leanLibrary mathlib
        ]
    }
```

### NVIDIA/CUDA

```dhall
let kernel = A.nvBinary "matmul" ["matmul.cu"] ([] : List A.Dep)

let cudaLib = A.nvLibrary "kernels" ["ops.cu"] ([] : List A.Dep)
                with exported_headers = ["ops.cuh"]

in  { targets =
        [ A.rule.nvBinary kernel
        , A.rule.nvLibrary cudaLib
        ]
    }
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

in  { targets =
        [ A.rule.purescriptApp app
        , A.rule.purescriptBinary cli
        ]
    }
```

### Genrule

```dhall
let gen = A.genrule "generated"
            with srcs = ["input.txt"]
            with out = "output.txt"
            with cmd = "cat $SRCS | process > $OUT"

in  { targets = [ A.rule.genrule gen ] }
```

### Nix C++

```dhall
let app = A.nixCxxBinary "app"
            with srcs = ["main.cpp"]
            with nix_deps = ["nixpkgs#openssl", "nixpkgs#zlib"]
            with compiler_flags = ["-O2"]

in  { targets = [ A.rule.nixCxxBinary app ] }
```

## Dependencies

Dependencies use a union type:

```dhall
let Dep = < Local : Text | Flake : Text >

-- Local target dependency
A.local ":mylib"           -- Same package
A.local "//lib:mylib"      -- Different package

-- Nix flake dependency
A.flake "nixpkgs#openssl"
A.flake "nixpkgs#zlib"
A.nix "nixpkgs#fmt"        -- Alias for flake
```

## Prelude Imports

```dhall
-- Full prelude (recommended)
let A = ./dhall/prelude/package.dhall

-- Individual modules
let C = ./dhall/prelude/Cxx.dhall
let H = ./dhall/prelude/Haskell.dhall
let R = ./dhall/prelude/Rust.dhall
let L = ./dhall/prelude/Lean.dhall
let N = ./dhall/prelude/Nv.dhall
let PS = ./dhall/prelude/PureScript.dhall
let T = ./dhall/prelude/Types.dhall
let TC = ./dhall/prelude/Toolchain.dhall
```

## Rule Constructors

The `A.rule.*` constructors wrap typed records into the `Rule` union:

```dhall
A.rule.cxxBinary      : CxxBinary -> Rule
A.rule.cxxLibrary     : CxxLibrary -> Rule
A.rule.rustBinary     : RustBinary -> Rule
A.rule.rustLibrary    : RustLibrary -> Rule
A.rule.haskellBinary  : HaskellBinary -> Rule
A.rule.haskellLibrary : HaskellLibrary -> Rule
A.rule.haskellFFIBinary : HaskellFFIBinary -> Rule
A.rule.leanBinary     : LeanBinary -> Rule
A.rule.leanLibrary    : LeanLibrary -> Rule
A.rule.nvBinary       : NvBinary -> Rule
A.rule.nvLibrary      : NvLibrary -> Rule
A.rule.purescriptApp  : PureScriptApp -> Rule
A.rule.purescriptBinary : PureScriptBinary -> Rule
A.rule.purescriptLibrary : PureScriptLibrary -> Rule
A.rule.genrule        : Genrule -> Rule
A.rule.nixCxxBinary   : NixCxxBinary -> Rule
A.rule.cratesIo       : CratesIo -> Rule
A.rule.httpArchive    : HttpArchive -> Rule
```

## Visibility

```dhall
let Vis = < Public | Private >

-- Usage
let lib = A.cxxLibrary "internal" ["lib.cpp"] ([] : List A.Dep)
            with vis = A.Vis.Private
```

## Toolchain BUILD.dhall

The `toolchains/BUILD.dhall` defines compiler configurations:

```dhall
let A = ../dhall/prelude/package.dhall
let S = ../dhall/prelude/to-starlark.dhall

let cxx = (A.cxxToolchain "cxx")
            with c_extra_flags = ["-std=c23", "-Wall"]
            with cxx_extra_flags = ["-std=c++23", "-Wall"]
            with link_style = "static"

let haskell = (A.haskellToolchain "haskell")
                with compiler_flags = ["-Wall", "-XGHC2024"]

let rust = (A.rustToolchain "rust")
             with default_edition = "2021"

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
        ]
    , header = ''
        load(":cxx.bzl", "llvm_toolchain")
        load(":haskell.bzl", "haskell_toolchain")
        -- ...
        ''
    }
```

Note: Toolchain BUILD.dhall uses the old format with `rules` and `header` for Buck2 BUCK generation. Regular BUILD.dhall files use the new `targets` format for direct sensenet execution.

## Type Safety

Dhall's type system catches errors at config time:

```dhall
-- Type error: "invalid" is not a valid CxxStd
let bad = A.cxxBinary "test" ["main.cpp"] ([] : List A.Dep)
            with std = "invalid"  -- Compile error!

-- Type error: missing required field
let bad2 = A.cxxBinary "test"  -- Missing srcs and deps!
```
