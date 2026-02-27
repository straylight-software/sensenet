--| sensenet — the build system builds itself
--|
--| Module structure:
--|   - DhallFast/*   : Optimized Dhall evaluator (2-10x faster)
--|   - SenseNet/IR   : Rule types
--|   - SenseNet/Dhall: Package parser (uses DhallFast)
--|   - SenseNet/Discover: Package discovery
--|   - SenseNet/Toolchains: Toolchain config
--|   - SenseNet/DICE : Content-addressed caching
--|   - SenseNet/Build: Build orchestration
--|   - Main.hs       : CLI entry point

let A = ../../dhall/prelude/package.dhall

-- DhallFast: optimized Dhall evaluator (de Bruijn indices, cache-friendly)
let dhallfast =
      (A.haskellLibrary "dhallfast"
        [ "DhallFast/Core.hs"
        , "DhallFast/Eval.hs"
        , "DhallFast/Convert.hs"
        , "DhallFast/Input.hs"
        ])
        with packages =
          [ "base"
          , "bytestring"
          , "containers"
          , "deepseq"
          , "dhall"
          , "hashable"
          , "microlens"
          , "text"
          , "text-short"
          , "unordered-containers"
          , "vector"
          ]

-- Core types and Dhall parsing
-- NOTE: Uses standard Dhall for now (DhallFast disabled pending vector fix)
let sensenet-core =
      (A.haskellLibrary "sensenet-core"
        [ "SenseNet/IR.hs"
        , "SenseNet/IR/Coeffect.hs"
        , "SenseNet/IR/Common.hs"
        , "SenseNet/IR/Flag.hs"
        , "SenseNet/IR/Triple.hs"
        , "SenseNet/Dhall.hs"
        , "SenseNet/Discover.hs"
        , "SenseNet/Toolchains.hs"
        ])
        with packages =
          [ "aeson"
          , "base"
          , "containers"
          , "dhall"
          , "directory"
          , "filepath"
          , "text"
          ]

-- DICE incremental computation engine
let sensenet-dice =
      (A.haskellLibrary "sensenet-dice"
        [ "SenseNet/DICE.hs"
        ])
        with packages =
          [ "async"
          , "base"
          , "bytestring"
          , "containers"
          , "crypton"
          , "directory"
          , "memory"
          , "text"
          , "time"
          ]

-- Build orchestration (depends on core + dice)
let sensenet-build =
      (A.haskellLibrary "sensenet-build"
        [ "SenseNet/Build.hs"
        , "SenseNet/Log.hs"
        , "SenseNet/Nix.hs"
        , "SenseNet/PureScript.hs"
        , "SenseNet/RustCrate.hs"
        , "SenseNet/Output.hs"
        , "SenseNet/TUI.hs"
        , "SenseNet/Complete.hs"
        ])
        with packages =
          [ "aeson"
          , "ansi-terminal"
          , "base"
          , "bytestring"
          , "colour"
          , "containers"
          , "directory"
          , "filepath"
          , "hostname"
          , "hyperconsole"
          , "katip"
          , "process"
          , "text"
          , "time"
          , "unix"
          ]
        with deps =
          [ A.local ":sensenet-core"
          , A.local ":sensenet-dice"
          ]

-- The sensenet CLI binary
let sensenet =
      (A.haskellBinary "sensenet" [ "app/Main.hs" ])
        with packages =
          [ "aeson"
          , "async"
          , "base"
          , "bytestring"
          , "containers"
          , "directory"
          , "filepath"
          , "text"
          ]
        with deps =
          [ A.local ":sensenet-core"
          , A.local ":sensenet-dice"
          , A.local ":sensenet-build"
          ]
        with ghc_options =
          [ "-O2"
          , "-threaded"
          , "-rtsopts"
          -- NOTE: We do NOT set -N here because:
          -- 1. Single-threaded startup is 3x faster (44ms vs 120ms)
          -- 2. Parallelism is only useful during action execution
          -- 3. The async library handles parallelism via forkIO, not -N
          -- Users can still pass +RTS -N -RTS if needed
          ]

-- Combined library for tests (re-exports all modules)
let sensenet-lib =
      (A.haskellLibrary "sensenet-lib"
        [ "SenseNet/IR.hs"
        , "SenseNet/IR/Coeffect.hs"
        , "SenseNet/IR/Common.hs"
        , "SenseNet/IR/Flag.hs"
        , "SenseNet/IR/Triple.hs"
        , "SenseNet/Dhall.hs"
        , "SenseNet/Discover.hs"
        , "SenseNet/Toolchains.hs"
        , "SenseNet/DICE.hs"
        , "SenseNet/Build.hs"
        , "SenseNet/Log.hs"
        , "SenseNet/Nix.hs"
        , "SenseNet/PureScript.hs"
        , "SenseNet/RustCrate.hs"
        , "SenseNet/Output.hs"
        , "SenseNet/TUI.hs"
        , "SenseNet/Complete.hs"
        ])
        with packages =
          [ "aeson"
          , "ansi-terminal"
          , "async"
          , "base"
          , "bytestring"
          , "colour"
          , "containers"
          , "crypton"
          , "dhall"
          , "directory"
          , "filepath"
          , "hostname"
          , "hyperconsole"
          , "katip"
          , "memory"
          , "process"
          , "text"
          , "time"
          , "unix"
          ]

in  { targets =
        [ A.rule.haskellLibrary dhallfast
        , A.rule.haskellLibrary sensenet-core
        , A.rule.haskellLibrary sensenet-dice
        , A.rule.haskellLibrary sensenet-build
        , A.rule.haskellLibrary sensenet-lib
        , A.rule.haskellBinary sensenet
        ]
    }
