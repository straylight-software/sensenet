--| Core Types for Aleph Prelude
--|
--| Typed build configuration. No strings where enums suffice.
--| Flake references for Nix dependencies.

-- =============================================================================
-- Target Triples
-- =============================================================================

let Arch = < x86_64 | aarch64 | wasm32 | riscv64 >

let OS = < linux | darwin | wasi | none >

let ABI = < gnu | musl | eabi | unknown >

let Vendor = < unknown | apple | pc | nvidia >

let Cpu =
      < generic
      | native
      -- x86_64
      | znver3
      | znver4
      | skylake
      | sapphirerapids
      -- aarch64
      | cortex_a78ae  -- Orin
      | neoverse_n1   -- Graviton 2
      | neoverse_v1   -- Graviton 3
      | apple_m1
      | apple_m2
      -- GPU
      | sm_89         -- Ada Lovelace (RTX 40xx)
      | sm_90         -- Hopper (H100)
      | sm_120        -- Blackwell
      >

let Triple =
      { arch : Arch
      , vendor : Vendor
      , os : OS
      , abi : ABI
      }

-- =============================================================================
-- Compiler Flags (Typed, not strings)
-- =============================================================================

let OptLevel = < O0 | O1 | O2 | O3 | Oz | Os >

let LTOMode = < Off | Thin | Fat >

let DebugInfo = < None | LineTablesOnly | Full >

let PanicStrategy = < Unwind | Abort >

let Sanitizer = < Address | Thread | Memory | Undefined | Leak >

let Flag =
      < OptLevel : OptLevel
      | LTO : LTOMode
      | Debug : DebugInfo
      | Panic : PanicStrategy
      | Sanitizer : Sanitizer
      | TargetCpu : Cpu
      | TargetFeature : { enable : Bool, name : Text }
      | PIC : Bool
      | Define : { name : Text, value : Optional Text }
      | Include : Text
      | LibPath : Text
      | Link : Text
      | Std : Text           -- C/C++ standard
      | Warnings : < All | None | Error >
      | Raw : Text           -- Escape hatch, logged
      >

-- =============================================================================
-- Visibility
-- =============================================================================

let Visibility =
      < Public
      | Private
      | Package
      | Targets : List Text
      >

-- =============================================================================
-- Dependencies
-- =============================================================================

-- The key insight: flake refs are first-class
let Dep =
      < Local : Text          -- ":foo" or "//pkg:foo"
      | Flake : Text          -- "nixpkgs#zlib", ".#mylib"
      >

-- Convenience constructors
let local = Dep.Local
let flake = Dep.Flake
let nixpkgs = \(pkg : Text) -> Dep.Flake "nixpkgs#${pkg}"

-- =============================================================================
-- C++ Standards
-- =============================================================================

let CxxStandard = < Cxx11 | Cxx14 | Cxx17 | Cxx20 | Cxx23 >

let CStandard = < C99 | C11 | C17 | C23 >

-- =============================================================================
-- Exports
-- =============================================================================

in  { Arch
    , OS
    , ABI
    , Vendor
    , Cpu
    , Triple
    , OptLevel
    , LTOMode
    , DebugInfo
    , PanicStrategy
    , Sanitizer
    , Flag
    , Visibility
    , Dep
    , local
    , flake
    , nixpkgs
    , CxxStandard
    , CStandard
    }
