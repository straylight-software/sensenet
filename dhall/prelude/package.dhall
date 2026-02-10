--| Aleph Prelude
--|
--| The typed interface for builds.
--|
--| Usage:
--|   let A = ./dhall/prelude/package.dhall
--|   in [ A.cxx_binary "hello" ["main.cpp"] [A.nixpkgs "zlib"] ]

let Types = ./Types.dhall
let Toolchain = ./Toolchain.dhall
let Cxx = ./Cxx.dhall

in  {
    -- ==========================================================================
    -- Types
    -- ==========================================================================
      Arch = Types.Arch
    , OS = Types.OS
    , ABI = Types.ABI
    , Vendor = Types.Vendor
    , Cpu = Types.Cpu
    , Triple = Types.Triple
    , OptLevel = Types.OptLevel
    , LTOMode = Types.LTOMode
    , DebugInfo = Types.DebugInfo
    , Flag = Types.Flag
    , Visibility = Types.Visibility
    , Dep = Types.Dep
    , CxxStandard = Types.CxxStandard
    , CStandard = Types.CStandard

    -- ==========================================================================
    -- Dependency constructors
    -- ==========================================================================
    , local = Types.local
    , flake = Types.flake
    , nixpkgs = Types.nixpkgs

    -- ==========================================================================
    -- Toolchains
    -- ==========================================================================
    , Compiler = Toolchain.Compiler
    , Linker = Toolchain.Linker
    , Toolchain = Toolchain.Toolchain
    , x86_64_linux = Toolchain.x86_64_linux
    , aarch64_linux = Toolchain.aarch64_linux
    , wasm32_wasi = Toolchain.wasm32_wasi
    , orin = Toolchain.orin
    , defaultToolchain = Toolchain.defaultToolchain
    , clang = Toolchain.clang
    , gcc = Toolchain.gcc
    , nvClang = Toolchain.nvClang
    , toolchains = Toolchain.presets

    -- ==========================================================================
    -- C/C++
    -- ==========================================================================
    , LinkStyle = Cxx.LinkStyle
    , CxxLibrary = Cxx.CxxLibrary
    , cxx_library = Cxx.cxx_library
    , CxxBinary = Cxx.CxxBinary
    , cxx_binary = Cxx.cxx_binary
    , CxxTest = Cxx.CxxTest
    , cxx_test = Cxx.cxx_test
    }
