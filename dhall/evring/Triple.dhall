--| Triple.dhall - Typed Target Triples
--|
--| NO STRINGS. Real types for architecture, OS, ABI, CPU, GPU.
--| Merges armitage/Target.dhall with Continuity.Toolchain.lean
--|
--| straylight.software · 2026

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ARCHITECTURE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Arch =
      < x86_64
      | aarch64
      | wasm32
      | riscv64
      | armv7
      >

let archToString
    : Arch -> Text
    = \(a : Arch) ->
        merge
          { x86_64 = "x86_64"
          , aarch64 = "aarch64"
          , wasm32 = "wasm32"
          , riscv64 = "riscv64"
          , armv7 = "armv7"
          }
          a

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- OPERATING SYSTEM
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let OS =
      < linux
      | darwin
      | wasi
      | windows
      | none
      >

let osToString
    : OS -> Text
    = \(o : OS) ->
        merge
          { linux = "unknown-linux"
          , darwin = "apple-darwin"
          , wasi = "wasi"
          , windows = "pc-windows"
          , none = "unknown-none"
          }
          o

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- ABI
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let ABI =
      < gnu
      | musl
      | eabi
      | eabihf
      | msvc
      | none
      >

let abiToString
    : ABI -> Text
    = \(abi : ABI) ->
        merge
          { gnu = "gnu"
          , musl = "musl"
          , eabi = "eabi"
          , eabihf = "eabihf"
          , msvc = "msvc"
          , none = ""
          }
          abi

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- VENDOR
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Vendor =
      < unknown
      | pc
      | apple
      | nvidia
      >

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CPU MICROARCHITECTURE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Cpu =
      < generic
      | native
      -- x86_64 levels
      | x86_64_v2
      | x86_64_v3
      | x86_64_v4
      -- AMD Zen
      | znver3
      | znver4
      | znver5
      -- Intel datacenter
      | skylake
      | icelake_server
      | sapphirerapids
      | emeraldrapids
      -- aarch64 datacenter
      | neoverse_n1      -- Graviton 2
      | neoverse_v1      -- Graviton 3
      | neoverse_v2      -- Graviton 4
      -- aarch64 edge
      | cortex_a78ae     -- Jetson Orin
      | cortex_a76
      -- Apple Silicon
      | apple_m1
      | apple_m2
      | apple_m3
      | apple_m4
      >

let cpuToMarch
    : Cpu -> Text
    = \(cpu : Cpu) ->
        merge
          { generic = "generic"
          , native = "native"
          , x86_64_v2 = "x86-64-v2"
          , x86_64_v3 = "x86-64-v3"
          , x86_64_v4 = "x86-64-v4"
          , znver3 = "znver3"
          , znver4 = "znver4"
          , znver5 = "znver5"
          , skylake = "skylake"
          , icelake_server = "icelake-server"
          , sapphirerapids = "sapphirerapids"
          , emeraldrapids = "emeraldrapids"
          , neoverse_n1 = "neoverse-n1"
          , neoverse_v1 = "neoverse-v1"
          , neoverse_v2 = "neoverse-v2"
          , cortex_a78ae = "cortex-a78ae"
          , cortex_a76 = "cortex-a76"
          , apple_m1 = "apple-m1"
          , apple_m2 = "apple-m2"
          , apple_m3 = "apple-m3"
          , apple_m4 = "apple-m4"
          }
          cpu

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- GPU SM VERSION (CUDA)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Gpu =
      < none
      -- Ampere
      | sm_80
      | sm_86
      | sm_87           -- Jetson Orin
      | sm_89           -- Ada Lovelace
      -- Hopper
      | sm_90
      | sm_90a
      -- Blackwell
      | sm_100
      | sm_100a
      | sm_120
      >

let gpuToArch
    : Gpu -> Text
    = \(gpu : Gpu) ->
        merge
          { none = ""
          , sm_80 = "sm_80"
          , sm_86 = "sm_86"
          , sm_87 = "sm_87"
          , sm_89 = "sm_89"
          , sm_90 = "sm_90"
          , sm_90a = "sm_90a"
          , sm_100 = "sm_100"
          , sm_100a = "sm_100a"
          , sm_120 = "sm_120"
          }
          gpu

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TARGET TRIPLE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Triple =
      { arch : Arch
      , vendor : Vendor
      , os : OS
      , abi : ABI
      , cpu : Cpu
      , gpu : Gpu
      }

let hasABI
    : ABI -> Bool
    = \(abi : ABI) ->
        merge
          { gnu = True
          , musl = True
          , eabi = True
          , eabihf = True
          , msvc = True
          , none = False
          }
          abi

let tripleToString
    : Triple -> Text
    = \(t : Triple) ->
        let arch = archToString t.arch
        let os = osToString t.os
        let abi = abiToString t.abi
        in  "${arch}-${os}${if hasABI t.abi then "-${abi}" else ""}"

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COMMON TARGETS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let x86_64_linux
    : Triple
    = { arch = Arch.x86_64
      , vendor = Vendor.unknown
      , os = OS.linux
      , abi = ABI.gnu
      , cpu = Cpu.generic
      , gpu = Gpu.none
      }

let x86_64_linux_znver4
    : Triple
    = x86_64_linux // { cpu = Cpu.znver4 }

let x86_64_linux_sapphire
    : Triple
    = x86_64_linux // { cpu = Cpu.sapphirerapids }

let aarch64_linux
    : Triple
    = { arch = Arch.aarch64
      , vendor = Vendor.unknown
      , os = OS.linux
      , abi = ABI.gnu
      , cpu = Cpu.generic
      , gpu = Gpu.none
      }

let aarch64_linux_graviton3
    : Triple
    = aarch64_linux // { cpu = Cpu.neoverse_v1 }

let aarch64_linux_orin
    : Triple
    = aarch64_linux // { cpu = Cpu.cortex_a78ae, gpu = Gpu.sm_87 }

let aarch64_darwin_m3
    : Triple
    = { arch = Arch.aarch64
      , vendor = Vendor.apple
      , os = OS.darwin
      , abi = ABI.none
      , cpu = Cpu.apple_m3
      , gpu = Gpu.none
      }

let wasm32_wasi
    : Triple
    = { arch = Arch.wasm32
      , vendor = Vendor.unknown
      , os = OS.wasi
      , abi = ABI.none
      , cpu = Cpu.generic
      , gpu = Gpu.none
      }

-- Blackwell GPU targets
let x86_64_linux_blackwell
    : Triple
    = x86_64_linux // { gpu = Gpu.sm_100 }

let x86_64_linux_hopper
    : Triple
    = x86_64_linux // { gpu = Gpu.sm_90 }

in  { -- Types
      Arch
    , OS
    , ABI
    , Vendor
    , Cpu
    , Gpu
    , Triple
    -- Converters
    , archToString
    , osToString
    , abiToString
    , cpuToMarch
    , gpuToArch
    , tripleToString
    -- Common targets
    , x86_64_linux
    , x86_64_linux_znver4
    , x86_64_linux_sapphire
    , aarch64_linux
    , aarch64_linux_graviton3
    , aarch64_linux_orin
    , aarch64_darwin_m3
    , wasm32_wasi
    , x86_64_linux_blackwell
    , x86_64_linux_hopper
    }
