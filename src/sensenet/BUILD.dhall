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

-- DICE FFI bindings (requires libdice_ffi from Nix)
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

-- Console FFI bindings (requires libsuperconsole_ffi from Nix)
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

-- Build engine
let build =
      (A.haskellLibrary "build"
        [ "SenseNet/Build.hs"
        , "SenseNet/Remote.hs"
        ])
        with packages =
          [ "base"
          , "bytestring"
          , "containers"
          , "directory"
          , "filepath"
          , "process"
          , "proto-lens"
          , "text"
          ]
        with deps =
          [ A.local ":sensenet-core"
          , A.local ":nativelink"
          , A.local ":dice"
          , A.local ":console"
          ]

-- The sensenet CLI
let sensenet =
      (A.haskellBinary "sensenet" [ "Main.hs" ])
        with packages =
          [ "async"
          , "base"
          , "bytestring"
          , "containers"
          , "directory"
          , "filepath"
          , "process"
          , "text"
          ]
        with deps =
          [ A.local ":sensenet-core"
          , A.local ":build"
          , A.local ":nativelink"
          , A.local ":dice"
          , A.local ":console"
          ]
        with ghc_options =
          [ "-O2"
          , "-Wall"
          , "-threaded"
          , "-rtsopts"
          , "-with-rtsopts=-N"
          ]

in  { targets =
        [ A.rule.haskellLibrary sensenet-core
        , A.rule.haskellLibrary proto
        , A.rule.haskellLibrary nativelink
        , A.rule.haskellLibrary dice
        , A.rule.haskellLibrary console
        , A.rule.haskellLibrary build
        , A.rule.haskellBinary sensenet
        ]
    }
