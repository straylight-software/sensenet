--| Toolchain Definitions
--|
--| compiler + target + flags = toolchain
--| Toolchains come from Nix (flake refs) during transition.

let Types = ./Types.dhall

-- =============================================================================
-- Compiler Kinds
-- =============================================================================

let Version = { major : Natural, minor : Natural, patch : Natural }

let Compiler =
      < Clang : { version : Version }
      | GCC : { version : Version }
      | Rustc : { version : Version }
      | GHC : { version : Version }
      | Lean : { version : Version }
      | Purs : { version : Version }
      | NvClang : { version : Version }  -- CUDA LLVM
      >

-- =============================================================================
-- Linkers
-- =============================================================================

let Linker = < LLD | Mold | Gold | BFD | System >

-- =============================================================================
-- Toolchain Definition
-- =============================================================================

let Toolchain =
      { compiler : Compiler
      , host : Types.Triple
      , target : Types.Triple
      , flags : List Types.Flag
      , linker : Linker
      , sysroot : Optional Text  -- Flake ref or store path
      }

-- =============================================================================
-- Standard Triples
-- =============================================================================

let x86_64_linux : Types.Triple =
      { arch = Types.Arch.x86_64
      , vendor = Types.Vendor.unknown
      , os = Types.OS.linux
      , abi = Types.ABI.gnu
      }

let x86_64_linux_musl : Types.Triple =
      { arch = Types.Arch.x86_64
      , vendor = Types.Vendor.unknown
      , os = Types.OS.linux
      , abi = Types.ABI.musl
      }

let aarch64_linux : Types.Triple =
      { arch = Types.Arch.aarch64
      , vendor = Types.Vendor.unknown
      , os = Types.OS.linux
      , abi = Types.ABI.gnu
      }

let wasm32_wasi : Types.Triple =
      { arch = Types.Arch.wasm32
      , vendor = Types.Vendor.unknown
      , os = Types.OS.wasi
      , abi = Types.ABI.unknown
      }

let orin : Types.Triple =
      { arch = Types.Arch.aarch64
      , vendor = Types.Vendor.nvidia
      , os = Types.OS.linux
      , abi = Types.ABI.gnu
      }

-- =============================================================================
-- Toolchain Constructors
-- =============================================================================

let defaultToolchain : Toolchain =
      { compiler = Compiler.Clang { version = { major = 18, minor = 1, patch = 0 } }
      , host = x86_64_linux
      , target = x86_64_linux
      , flags = [] : List Types.Flag
      , linker = Linker.System
      , sysroot = None Text
      }

let clang =
      \(major : Natural) ->
      \(minor : Natural) ->
        defaultToolchain // { compiler = Compiler.Clang { version = { major, minor, patch = 0 } } }

let gcc =
      \(major : Natural) ->
      \(minor : Natural) ->
        defaultToolchain // { compiler = Compiler.GCC { version = { major, minor, patch = 0 } } }

let nvClang =
      \(target : Types.Triple) ->
        defaultToolchain
          // { compiler = Compiler.NvClang { version = { major = 22, minor = 0, patch = 0 } }
             , target
             }

-- =============================================================================
-- Preset Toolchains
-- =============================================================================

let presets =
      { clang-18 = clang 18 1
      , clang-19 = clang 19 1
      , gcc-14 = gcc 14 2
      , gcc-15 = gcc 15 2
      , nv-clang-h100 = nvClang x86_64_linux // { flags = [ Types.Flag.TargetCpu Types.Cpu.sm_90 ] }
      , nv-clang-blackwell = nvClang x86_64_linux // { flags = [ Types.Flag.TargetCpu Types.Cpu.sm_120 ] }
      }

-- =============================================================================
-- Exports
-- =============================================================================

in  { Version
    , Compiler
    , Linker
    , Toolchain
    , x86_64_linux
    , x86_64_linux_musl
    , aarch64_linux
    , wasm32_wasi
    , orin
    , defaultToolchain
    , clang
    , gcc
    , nvClang
    , presets
    }
