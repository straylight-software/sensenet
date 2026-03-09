--| Toolchains configuration for sensenet
--|
--| A toolchain is defined by what a remote execution container needs:
--| - A container image (for RE) or a Nix derivation (for local)
--| - Executables at absolute paths
--| - Include paths for headers
--| - Library paths for linking
--|
--| This same shape works for:
--| - Local execution (paths are Nix store paths)
--| - Remote execution (paths are container paths, image is specified)
--|
--| The image field is None for local execution, Some for remote.

-- ══════════════════════════════════════════════════════════════════════════════
-- Core Types
-- ══════════════════════════════════════════════════════════════════════════════

-- | A single executable tool
let Tool = { path : Text }

-- | Include/library search paths
let Paths = { includes : List Text, libs : List Text }

-- ══════════════════════════════════════════════════════════════════════════════
-- C++ Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let Cxx =
      { image : Optional Text      -- Container image (None = local)
      , cc : Tool                  -- C compiler
      , cxx : Tool                 -- C++ compiler
      , ar : Tool                  -- Archiver
      , ld : Tool                  -- Linker
      , paths : Paths              -- Search paths
      , sysroot : Text             -- Sysroot (for cross-compilation)
      , target : Text              -- Target triple (aarch64-unknown-linux-gnu)
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- NVIDIA Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let Nv =
      { image : Optional Text      -- Container image (None = local)
      , clang : Tool               -- Clang with CUDA support
      , ptxas : Tool               -- PTX assembler
      , fatbinary : Tool           -- Fat binary tool
      , sdk_path : Text            -- NVIDIA SDK root (for --cuda-path)
      , sdk : Paths                -- CUDA SDK include/lib paths
      , archs : List Text          -- Target SM architectures
      , cxx : Cxx                  -- C++ toolchain (for stdlib)
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- Rust Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let Rust =
      { image : Optional Text
      , rustc : Tool
      , cargo : Tool
      , edition : Text             -- Default edition
      , target : Text              -- Target triple
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- Haskell Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let Haskell =
      { image : Optional Text
      , ghc : Tool
      , ghc_pkg : Tool
      , paths : Paths              -- Package DB, lib paths
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- Lean Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let Lean =
      { image : Optional Text
      , lean : Tool
      , leanc : Tool
      , paths : Paths
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- PureScript Toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let PureScript =
      { image : Optional Text
      , purs : Tool
      , spago : Tool
      , node : Tool
      , esbuild : Tool
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- Complete Toolchains
-- ══════════════════════════════════════════════════════════════════════════════

let Toolchains =
      { cxx : Cxx
      , nv : Optional Nv
      , rust : Rust
      , haskell : Haskell
      , lean : Lean
      , purescript : PureScript
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- Constructors
-- ══════════════════════════════════════════════════════════════════════════════

let tool = \(path : Text) -> { path }

let paths = 
      \(includes : List Text) -> 
      \(libs : List Text) -> 
      { includes, libs }

let emptyPaths = { includes = [] : List Text, libs = [] : List Text }

in  { Tool
    , Paths
    , Cxx
    , Nv
    , Rust
    , Haskell
    , Lean
    , PureScript
    , Toolchains
    , tool
    , paths
    , emptyPaths
    }
