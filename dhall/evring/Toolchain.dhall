--| Toolchain.dhall - Typed Toolchains
--|
--| compiler + host + target + flags = toolchain
--| That's it. The rest is ceremony.
--|
--| Merges armitage/Toolchain.dhall with Continuity.Toolchain.lean
--|
--| straylight.software · 2026

let Triple = ./Triple.dhall

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CONTENT-ADDRESSED ARTIFACT
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Hash =
      { sha256 : Text
      }

let Artifact =
      { hash : Hash
      , path : Text
      }

let artifact
    : Text -> Text -> Artifact
    = \(sha256 : Text) ->
      \(path : Text) ->
        { hash = { sha256 }, path }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- OPTIMIZATION FLAGS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let OptLevel =
      < O0 | O1 | O2 | O3 | Oz | Os >

let optLevelToFlag
    : OptLevel -> Text
    = \(o : OptLevel) ->
        merge
          { O0 = "-O0"
          , O1 = "-O1"
          , O2 = "-O2"
          , O3 = "-O3"
          , Oz = "-Oz"
          , Os = "-Os"
          }
          o

let LTOMode =
      < off | thin | fat >

let ltoToFlag
    : LTOMode -> Text
    = \(l : LTOMode) ->
        merge
          { off = ""
          , thin = "-flto=thin"
          , fat = "-flto"
          }
          l

let DebugInfo =
      < none | lineTablesOnly | full >

let debugToFlag
    : DebugInfo -> Text
    = \(d : DebugInfo) ->
        merge
          { none = ""
          , lineTablesOnly = "-gline-tables-only"
          , full = "-g"
          }
          d

let PanicStrategy =
      < unwind | abort >

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TYPED FLAGS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Flag =
      < OptLevel : OptLevel
      | LTO : LTOMode
      | Debug : DebugInfo
      | Panic : PanicStrategy
      | TargetCpu : Triple.Cpu
      | PIC : Bool
      | RelocationModel : Text
      | CodeModel : Text
      | Feature : { enable : Bool, name : Text }
      | Define : { name : Text, value : Optional Text }
      | Include : Text
      | LibPath : Text
      | Link : Text
      | Raw : Text  -- Escape hatch (logged + warned)
      >

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COMPILER KIND
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let CompilerKind =
      < Clang : { version : Text }
      | GCC : { version : Text }
      | Rustc : { version : Text }
      | GHC : { version : Text }
      | Lean : { version : Text }
      | Purs : { version : Text }
      >

let Compiler =
      { kind : CompilerKind
      , artifact : Artifact
      }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- LINKER
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Linker =
      < LLD
      | Gold
      | BFD
      | Mold
      | System
      >

let linkerToFlag
    : Linker -> Text
    = \(l : Linker) ->
        merge
          { LLD = "-fuse-ld=lld"
          , Gold = "-fuse-ld=gold"
          , BFD = "-fuse-ld=bfd"
          , Mold = "-fuse-ld=mold"
          , System = ""
          }
          l

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- TOOLCHAIN
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Toolchain =
      { compiler : Compiler
      , host : Triple.Triple
      , target : Triple.Triple
      , flags : List Flag
      , linker : Optional Linker
      , sysroot : Optional Artifact
      }

-- Smart constructors

let clang
    : Text -> Artifact -> Compiler
    = \(version : Text) ->
      \(art : Artifact) ->
        { kind = CompilerKind.Clang { version }, artifact = art }

let gcc
    : Text -> Artifact -> Compiler
    = \(version : Text) ->
      \(art : Artifact) ->
        { kind = CompilerKind.GCC { version }, artifact = art }

let rustc
    : Text -> Artifact -> Compiler
    = \(version : Text) ->
      \(art : Artifact) ->
        { kind = CompilerKind.Rustc { version }, artifact = art }

let ghc
    : Text -> Artifact -> Compiler
    = \(version : Text) ->
      \(art : Artifact) ->
        { kind = CompilerKind.GHC { version }, artifact = art }

let lean
    : Text -> Artifact -> Compiler
    = \(version : Text) ->
      \(art : Artifact) ->
        { kind = CompilerKind.Lean { version }, artifact = art }

let purs
    : Text -> Artifact -> Compiler
    = \(version : Text) ->
      \(art : Artifact) ->
        { kind = CompilerKind.Purs { version }, artifact = art }

-- Native toolchain (host == target)
let nativeToolchain
    : Compiler -> List Flag -> Toolchain
    = \(compiler : Compiler) ->
      \(flags : List Flag) ->
        { compiler
        , host = Triple.x86_64_linux
        , target = Triple.x86_64_linux
        , flags
        , linker = Some Linker.LLD
        , sysroot = None Artifact
        }

-- Cross toolchain
let crossToolchain
    : Compiler -> Triple.Triple -> Artifact -> List Flag -> Toolchain
    = \(compiler : Compiler) ->
      \(target : Triple.Triple) ->
      \(sysroot : Artifact) ->
      \(flags : List Flag) ->
        { compiler
        , host = Triple.x86_64_linux
        , target
        , flags
        , linker = Some Linker.LLD
        , sysroot = Some sysroot
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- DEFAULT FLAGS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let defaultRelease : List Flag =
      [ Flag.OptLevel OptLevel.O3
      , Flag.LTO LTOMode.thin
      , Flag.Debug DebugInfo.lineTablesOnly
      ]

let defaultDebug : List Flag =
      [ Flag.OptLevel OptLevel.O0
      , Flag.Debug DebugInfo.full
      ]

in  { -- Types
      Hash
    , Artifact
    , artifact
    , OptLevel
    , LTOMode
    , DebugInfo
    , PanicStrategy
    , Flag
    , CompilerKind
    , Compiler
    , Linker
    , Toolchain
    -- Converters
    , optLevelToFlag
    , ltoToFlag
    , debugToFlag
    , linkerToFlag
    -- Constructors
    , clang
    , gcc
    , rustc
    , ghc
    , lean
    , purs
    , nativeToolchain
    , crossToolchain
    -- Defaults
    , defaultRelease
    , defaultDebug
    }
