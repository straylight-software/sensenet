--| sensenet — the build system builds itself

let A = ../../dhall/prelude/package.dhall

-- Core SenseNet modules
let sensenet-core =
      (A.haskellLibrary "sensenet-core"
        [ "SenseNet/IR.hs"
        , "SenseNet/Dhall.hs"
        , "SenseNet/Discover.hs"
        , "SenseNet/Toolchains.hs"
        , "SenseNet/Config.hs"
        , "SenseNet/Emit.hs"
        ])
        with packages =
          [ "base"
          , "bytestring"
          , "containers"
          , "dhall"
          , "directory"
          , "filepath"
          , "text"
          ]

-- Proto-lens generated modules (REAPI)
let proto =
      (A.haskellLibrary "proto"
        [ "Proto/RemoteExecution.hs"
        , "Proto/RemoteExecution_Fields.hs"
        , "Proto/Bytestream.hs"
        , "Proto/Bytestream_Fields.hs"
        , "Proto/Google/Longrunning/Operations.hs"
        , "Proto/Google/Longrunning/Operations_Fields.hs"
        , "Proto/Google/Protobuf/Any.hs"
        , "Proto/Google/Protobuf/Any_Fields.hs"
        , "Proto/Google/Protobuf/Duration.hs"
        , "Proto/Google/Protobuf/Duration_Fields.hs"
        , "Proto/Google/Protobuf/Empty.hs"
        , "Proto/Google/Protobuf/Empty_Fields.hs"
        , "Proto/Google/Protobuf/Timestamp.hs"
        , "Proto/Google/Protobuf/Timestamp_Fields.hs"
        , "Proto/Google/Protobuf/Wrappers.hs"
        , "Proto/Google/Protobuf/Wrappers_Fields.hs"
        , "Proto/Google/Protobuf/Descriptor.hs"
        , "Proto/Google/Protobuf/Descriptor_Fields.hs"
        , "Proto/Google/Rpc/Status.hs"
        , "Proto/Google/Rpc/Status_Fields.hs"
        , "Proto/Google/Api/Annotations.hs"
        , "Proto/Google/Api/Annotations_Fields.hs"
        , "Proto/Google/Api/Client.hs"
        , "Proto/Google/Api/Client_Fields.hs"
        , "Proto/Google/Api/FieldBehavior.hs"
        , "Proto/Google/Api/FieldBehavior_Fields.hs"
        , "Proto/Google/Api/Http.hs"
        , "Proto/Google/Api/Http_Fields.hs"
        , "Proto/Google/Api/LaunchStage.hs"
        , "Proto/Google/Api/LaunchStage_Fields.hs"
        , "Proto/Build/Bazel/Semver/Semver.hs"
        , "Proto/Build/Bazel/Semver/Semver_Fields.hs"
        ])
        with packages =
          [ "base"
          , "bytestring"
          , "proto-lens"
          , "proto-lens-runtime"
          , "text"
          , "vector"
          , "microlens"
          ]

-- NativeLink client (gRPC to CAS/Scheduler)
let nativelink =
      (A.haskellLibrary "nativelink"
        [ "NativeLink.hs"
        , "NativeLink/Client.hs"
        , "NativeLink/Execution.hs"
        , "NativeLink/Proto.hs"
        ])
        with packages =
          [ "base"
          , "aeson"
          , "bytestring"
          , "conduit"
          , "containers"
          , "crypton"
          , "grapesy"
          , "grpc-spec"
          , "memory"
          , "microlens"
          , "network"
          , "process"
          , "proto-lens"
          , "proto-lens-runtime"
          , "text"
          , "vector"
          ]
        with deps = [ A.local ":proto" ]

-- DICE FFI bindings (requires libdice_ffi)
let dice =
      (A.haskellLibrary "dice"
        [ "SenseNet/DICE.hs"
        , "SenseNet/DICE/FFI.hs"
        ])
        with packages =
          [ "base"
          , "bytestring"
          , "containers"
          , "text"
          ]

-- Build engine (temporarily relaxed warnings for Buck2 bootstrap)
-- NOTE: Includes TUI module for Brick-based console
-- Build submodules are split by language to reduce compilation times
let build =
      (A.haskellLibrary "build"
        [ "SenseNet/Build.hs"
        , "SenseNet/Build/Types.hs"
        , "SenseNet/Build/Helpers.hs"
        , "SenseNet/Build/Cxx.hs"
        , "SenseNet/Build/Rust.hs"
        , "SenseNet/Build/Haskell.hs"
        , "SenseNet/Build/Lean.hs"
        , "SenseNet/Build/Nv.hs"
        , "SenseNet/Build/PureScript.hs"
        , "SenseNet/Build/Genrule.hs"
        , "SenseNet/Build/Nix.hs"
        , "SenseNet/Remote.hs"
        , "SenseNet/TUI.hs"
        , "SenseNet/Scheduler.hs"
        ])
        with packages =
          [ "aeson"
          , "base"
          , "brick"
          , "bytestring"
          , "containers"
          , "directory"
          , "filepath"
          , "microlens"
          , "microlens-mtl"
          , "microlens-th"
          , "process"
          , "proto-lens"
          , "text"
          , "time"
          , "unix"
          , "vector"
          , "vty"
          , "vty-crossplatform"
          ]
        with ghc_options =
          [ "-O2"
          , "-Wno-error=unused-imports"
          , "-Wno-error=x-partial"
          , "-Wno-error=unused-matches"
          , "-Wno-error=unused-top-binds"
          , "-Wno-error=name-shadowing"
          ]
        with deps =
          [ A.local ":sensenet-core"
          , A.local ":nativelink"
          , A.local ":dice"
          , A.local ":console"
          ]

-- Console FFI bindings (requires libsuperconsole_ffi)
let console =
      (A.haskellLibrary "console"
        [ "SenseNet/Console.hs"
        , "SenseNet/Console/FFI.hs"
        ])
        with packages =
          [ "base"
          , "bytestring"
          , "text"
          ]

-- The sensenet CLI (links against dice_ffi and superconsole_ffi)
-- Temporarily relaxed warnings for Buck2 bootstrap
let sensenet =
      (A.haskellFFIBinary "sensenet" [ "Main.hs" ] ([] : List Text))
        with packages =
          [ "async"
          , "base"
          , "bytestring"
          , "containers"
          , "dhall"
          , "directory"
          , "filepath"
          , "process"
          , "text"
          ]
        with deps =
          [ A.local ":sensenet-core"
          , A.local ":build"
          , A.local ":dice"
          , A.local ":console"
          ]
        with ghc_options =
          [ "-O2"
          , "-Wno-error=unused-imports"
          , "-Wno-error=x-partial"
          , "-Wno-error=unused-matches"
          , "-Wno-error=unused-top-binds"
          , "-Wno-error=name-shadowing"
          ]
        with extra_libs = [ "dice_ffi", "superconsole_ffi" ]
        with extra_lib_dirs =
          [ "/nix/store/5y0fp06cg9nfi7srriwmhpi973r17w2g-dice-ffi-0.1.0/lib"
          , "/nix/store/wp4lb87sym278f3bnijwjjqkp8q4wiy2-superconsole-ffi-0.1.0/lib"
          ]
        with include_dirs =
          [ "/nix/store/5y0fp06cg9nfi7srriwmhpi973r17w2g-dice-ffi-0.1.0/include"
          , "/nix/store/wp4lb87sym278f3bnijwjjqkp8q4wiy2-superconsole-ffi-0.1.0/include"
          ]

in  { targets =
        [ A.rule.haskellLibrary sensenet-core
        , A.rule.haskellLibrary proto
        , A.rule.haskellLibrary nativelink
        , A.rule.haskellLibrary dice
        , A.rule.haskellLibrary console
        , A.rule.haskellLibrary build
        , A.rule.haskellFFIBinary sensenet
        ]
    }
