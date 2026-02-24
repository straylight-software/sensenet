--| Continuity Build System Prelude
--|
--| The unified build definition language for Straylight.
--|
--| Merges:
--|   - sensenet/dhall/prelude - Working rule types
--|   - armitage/dhall - Typed triples, FFI bridges
--|   - Continuity.lean - Formal model (coeffects, cosets)
--|
--| NO STRINGS for targets. Real types.
--| NO GLOBS. Explicit file lists.
--| COEFFECTS track what builds need from the environment.
--|
--| straylight.software · 2026

let Triple = ./Triple.dhall
let Toolchain = ./Toolchain.dhall
let Coeffect = ./Coeffect.dhall
let Rules = ./Rules.dhall
let Source = ./Source.dhall
let DischargeProof = ./DischargeProof.dhall

in  { -- ═══════════════════════════════════════════════════════════════════════
      -- TARGET TRIPLES
      -- ═══════════════════════════════════════════════════════════════════════
      
      -- Types
      Arch = Triple.Arch
    , OS = Triple.OS
    , ABI = Triple.ABI
    , Vendor = Triple.Vendor
    , Cpu = Triple.Cpu
    , Gpu = Triple.Gpu
    , Triple = Triple.Triple
      -- Converters
    , tripleToString = Triple.tripleToString
    , cpuToMarch = Triple.cpuToMarch
    , gpuToArch = Triple.gpuToArch
      -- Common targets
    , x86_64_linux = Triple.x86_64_linux
    , x86_64_linux_znver4 = Triple.x86_64_linux_znver4
    , x86_64_linux_sapphire = Triple.x86_64_linux_sapphire
    , aarch64_linux = Triple.aarch64_linux
    , aarch64_linux_graviton3 = Triple.aarch64_linux_graviton3
    , aarch64_linux_orin = Triple.aarch64_linux_orin
    , aarch64_darwin_m3 = Triple.aarch64_darwin_m3
    , wasm32_wasi = Triple.wasm32_wasi
    , x86_64_linux_blackwell = Triple.x86_64_linux_blackwell
    , x86_64_linux_hopper = Triple.x86_64_linux_hopper

      -- ═══════════════════════════════════════════════════════════════════════
      -- TOOLCHAINS
      -- ═══════════════════════════════════════════════════════════════════════
      
    , Hash = Toolchain.Hash
    , Artifact = Toolchain.Artifact
    , artifact = Toolchain.artifact
    , OptLevel = Toolchain.OptLevel
    , LTOMode = Toolchain.LTOMode
    , DebugInfo = Toolchain.DebugInfo
    , Flag = Toolchain.Flag
    , CompilerKind = Toolchain.CompilerKind
    , Compiler = Toolchain.Compiler
    , Linker = Toolchain.Linker
    , Toolchain = Toolchain.Toolchain
      -- Constructors
    , clang = Toolchain.clang
    , gcc = Toolchain.gcc
    , rustc = Toolchain.rustc
    , ghc = Toolchain.ghc
    , lean = Toolchain.lean
    , purs = Toolchain.purs
    , nativeToolchain = Toolchain.nativeToolchain
    , crossToolchain = Toolchain.crossToolchain
      -- Defaults
    , defaultRelease = Toolchain.defaultRelease
    , defaultDebug = Toolchain.defaultDebug

      -- ═══════════════════════════════════════════════════════════════════════
      -- COEFFECTS
      -- ═══════════════════════════════════════════════════════════════════════
      
    , Coeffect = Coeffect.Coeffect
    , Coeffects = Coeffect.Coeffects
    , purityLevel = Coeffect.purityLevel
    , isReproducibleCoeffect = Coeffect.isReproducibleCoeffect
      -- Constructors
    , pure = Coeffect.pure
    , filesystem = Coeffect.filesystem
    , filesystemCA = Coeffect.filesystemCA
    , network = Coeffect.network
    , networkCA = Coeffect.networkCA
    , env = Coeffect.env
    , auth = Coeffect.auth
    , gpu = Coeffect.gpu
    , sandbox = Coeffect.sandbox
      -- Common sets
    , cratesIo = Coeffect.cratesIo
    , pypi = Coeffect.pypi
    , npm = Coeffect.npm
    , nixCache = Coeffect.nixCache
    , github = Coeffect.github

      -- ═══════════════════════════════════════════════════════════════════════
      -- RULES
      -- ═══════════════════════════════════════════════════════════════════════
      
      -- Common
    , Visibility = Rules.Visibility
    , Dep = Rules.Dep
    , local = Rules.local
    , flake = Rules.flake
    , nixpkgs = Rules.nixpkgs
    
      -- C++
    , CxxStandard = Rules.CxxStandard
    , CxxLibrary = Rules.CxxLibrary
    , cxx_library = Rules.cxx_library
    , CxxBinary = Rules.CxxBinary
    , cxx_binary = Rules.cxx_binary
    
      -- NVIDIA/CUDA
    , NvBinary = Rules.NvBinary
    , nv_binary = Rules.nv_binary
    , nv_binary_blackwell = Rules.nv_binary_blackwell
    
      -- Nix-integrated C++
    , NixCxxBinary = Rules.NixCxxBinary
    , nix_cxx_binary = Rules.nix_cxx_binary
    
      -- Rust
    , RustEdition = Rules.RustEdition
    , CrateType = Rules.CrateType
    , RustLibrary = Rules.RustLibrary
    , rust_library = Rules.rust_library
    , RustBinary = Rules.RustBinary
    , rust_binary = Rules.rust_binary
    
      -- Haskell
    , HaskellLibrary = Rules.HaskellLibrary
    , haskell_library = Rules.haskell_library
    , HaskellBinary = Rules.HaskellBinary
    , haskell_binary = Rules.haskell_binary
    , HaskellFFIBinary = Rules.HaskellFFIBinary
    , haskell_ffi_binary = Rules.haskell_ffi_binary
    
      -- Lean
    , LeanLibrary = Rules.LeanLibrary
    , lean_library = Rules.lean_library
    , LeanBinary = Rules.LeanBinary
    , lean_binary = Rules.lean_binary
    
      -- PureScript
    , PureScriptApp = Rules.PureScriptApp
    , purescript_app = Rules.purescript_app
    
      -- WebAssembly
    , WasmOptLevel = Rules.WasmOptLevel
    , WasmFeature = Rules.WasmFeature
    , WasmModule = Rules.WasmModule
    , wasm_module = Rules.wasm_module
    
      -- Genrule (escape hatch)
    , Genrule = Rules.Genrule
    , genrule = Rules.genrule
    
      -- Rule union
    , Rule = Rules.Rule
    
      -- ═══════════════════════════════════════════════════════════════════════
      -- RULE CONSTRUCTORS (for BUILD.dhall files)
      -- ═══════════════════════════════════════════════════════════════════════
      
    , rule =
        { cxxLibrary = \(r : Rules.CxxLibrary) -> Rules.Rule.CxxLibrary r
        , cxxBinary = \(r : Rules.CxxBinary) -> Rules.Rule.CxxBinary r
        , nvBinary = \(r : Rules.NvBinary) -> Rules.Rule.NvBinary r
        , nixCxxBinary = \(r : Rules.NixCxxBinary) -> Rules.Rule.NixCxxBinary r
        , rustLibrary = \(r : Rules.RustLibrary) -> Rules.Rule.RustLibrary r
        , rustBinary = \(r : Rules.RustBinary) -> Rules.Rule.RustBinary r
        , haskellLibrary = \(r : Rules.HaskellLibrary) -> Rules.Rule.HaskellLibrary r
        , haskellBinary = \(r : Rules.HaskellBinary) -> Rules.Rule.HaskellBinary r
        , haskellFFIBinary = \(r : Rules.HaskellFFIBinary) -> Rules.Rule.HaskellFFIBinary r
        , leanLibrary = \(r : Rules.LeanLibrary) -> Rules.Rule.LeanLibrary r
        , leanBinary = \(r : Rules.LeanBinary) -> Rules.Rule.LeanBinary r
        , purescriptApp = \(r : Rules.PureScriptApp) -> Rules.Rule.PureScriptApp r
        , wasmModule = \(r : Rules.WasmModule) -> Rules.Rule.WasmModule r
        , genrule = \(r : Rules.Genrule) -> Rules.Rule.Genrule r
        }

      -- ═══════════════════════════════════════════════════════════════════════
      -- SOURCES
      -- ═══════════════════════════════════════════════════════════════════════
      
    , Src = Source.Src
    , files = Source.files
    , fetch = Source.fetch
    , gitSrc = Source.git               -- renamed to avoid conflict with Rule.git
    , CratesIoSrc = Source.CratesIo     -- renamed to avoid conflict with Coeffect.cratesIo
    , cratesIoSrc = Source.cratesIo     -- renamed to avoid conflict with Coeffect.cratesIo
    , HttpArchive = Source.HttpArchive
    , httpArchive = Source.httpArchive
    , NpmPackage = Source.NpmPackage
    , npmPackageSrc = Source.npmPackage -- renamed to avoid conflict with Coeffect.npm
    , PyPIPackage = Source.PyPIPackage
    , pypiPackageSrc = Source.pypiPackage -- renamed to avoid conflict with Coeffect.pypi

      -- ═══════════════════════════════════════════════════════════════════════
      -- DISCHARGE PROOFS
      -- ═══════════════════════════════════════════════════════════════════════
      
    , NetworkAccess = DischargeProof.NetworkAccess
    , FilesystemAccessMode = DischargeProof.FilesystemAccessMode
    , FilesystemAccess = DischargeProof.FilesystemAccess
    , AuthUsage = DischargeProof.AuthUsage
    , OutputHash = DischargeProof.OutputHash
    , Signature = DischargeProof.Signature
    , DischargeProof = DischargeProof.DischargeProof
    , pureProof = DischargeProof.pureProof
    , isPure = DischargeProof.isPure
    , hasNetworkEvidence = DischargeProof.hasNetworkEvidence
    , isSigned = DischargeProof.isSigned
    , hasHybridSignature = DischargeProof.hasHybridSignature
    }
