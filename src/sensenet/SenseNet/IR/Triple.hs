{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SenseNet.IR.Triple
-- Description : Typed target triples (arch, OS, GPU)
--
-- NO STRINGS for target triples - use real types!
--
-- This is a direct port from dhall/evring/Triple.dhall.
module SenseNet.IR.Triple
  ( -- * Architecture
    Arch (..),
    archToText,
    textToArch,

    -- * Operating System
    OS (..),
    osToText,
    textToOS,

    -- * GPU Architecture
    Gpu (..),
    gpuToArch,
    gpuToGencode,
    textToGpu,

    -- * CPU features
    Cpu (..),
    cpuToText,
    textToCpu,

    -- * Target Triple
    Triple (..),
    tripleToText,
    hostTriple,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- ════════════════════════════════════════════════════════════════════════════
-- Architecture
-- ════════════════════════════════════════════════════════════════════════════

-- | CPU architecture
data Arch
  = X86_64
  | Aarch64
  | Wasm32
  | Riscv64
  | Armv7
  deriving (Show, Eq, Ord, Generic)

archToText :: Arch -> Text
archToText = \case
  X86_64 -> "x86_64"
  Aarch64 -> "aarch64"
  Wasm32 -> "wasm32"
  Riscv64 -> "riscv64"
  Armv7 -> "armv7"

textToArch :: Text -> Maybe Arch
textToArch = \case
  "x86_64" -> Just X86_64
  "aarch64" -> Just Aarch64
  "wasm32" -> Just Wasm32
  "riscv64" -> Just Riscv64
  "armv7" -> Just Armv7
  _ -> Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- Operating System
-- ════════════════════════════════════════════════════════════════════════════

-- | Operating system
data OS
  = Linux
  | Darwin
  | Wasi
  | Windows
  | OSNone
  deriving (Show, Eq, Ord, Generic)

osToText :: OS -> Text
osToText = \case
  Linux -> "linux"
  Darwin -> "darwin"
  Wasi -> "wasi"
  Windows -> "windows"
  OSNone -> "none"

textToOS :: Text -> Maybe OS
textToOS = \case
  "linux" -> Just Linux
  "darwin" -> Just Darwin
  "wasi" -> Just Wasi
  "windows" -> Just Windows
  "none" -> Just OSNone
  _ -> Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- GPU Architecture
-- ════════════════════════════════════════════════════════════════════════════

-- | NVIDIA GPU compute capability
data Gpu
  = -- | Ampere
    Sm80
  | Sm86
  | Sm87
  | -- | Ada Lovelace
    Sm89
  | -- | Hopper
    Sm90
  | Sm90a
  | -- | Blackwell
    Sm100
  | Sm100a
  | Sm120
  | -- | No GPU
    GpuNone
  deriving (Show, Eq, Ord, Generic)

-- | Render GPU to nvcc -arch flag value
gpuToArch :: Gpu -> Text
gpuToArch = \case
  Sm80 -> "sm_80"
  Sm86 -> "sm_86"
  Sm87 -> "sm_87"
  Sm89 -> "sm_89"
  Sm90 -> "sm_90"
  Sm90a -> "sm_90a"
  Sm100 -> "sm_100"
  Sm100a -> "sm_100a"
  Sm120 -> "sm_120"
  GpuNone -> ""

-- | Render GPU to nvcc -gencode flag value
gpuToGencode :: Gpu -> Text
gpuToGencode g =
  let arch = gpuToArch g
   in if T.null arch
        then ""
        else "arch=compute_" <> T.drop 3 arch <> ",code=" <> arch

-- | Parse GPU from text (e.g., "sm_90")
textToGpu :: Text -> Maybe Gpu
textToGpu = \case
  "sm_80" -> Just Sm80
  "sm_86" -> Just Sm86
  "sm_87" -> Just Sm87
  "sm_89" -> Just Sm89
  "sm_90" -> Just Sm90
  "sm_90a" -> Just Sm90a
  "sm_100" -> Just Sm100
  "sm_100a" -> Just Sm100a
  "sm_120" -> Just Sm120
  "" -> Just GpuNone
  "none" -> Just GpuNone
  _ -> Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- CPU Features
-- ════════════════════════════════════════════════════════════════════════════

-- | CPU microarchitecture / feature set
data Cpu
  = -- | Generic baseline
    CpuGeneric
  | -- | AMD Zen 4
    Znver4
  | -- | AMD Zen 5
    Znver5
  | -- | Intel Sapphire Rapids
    Sapphirerapids
  | -- | Intel Emerald Rapids
    Emeraldrapids
  | -- | Apple M1
    Apple_m1
  | -- | Apple M2
    Apple_m2
  | -- | Apple M3
    Apple_m3
  | -- | Apple M4
    Apple_m4
  deriving (Show, Eq, Ord, Generic)

cpuToText :: Cpu -> Text
cpuToText = \case
  CpuGeneric -> "generic"
  Znver4 -> "znver4"
  Znver5 -> "znver5"
  Sapphirerapids -> "sapphirerapids"
  Emeraldrapids -> "emeraldrapids"
  Apple_m1 -> "apple-m1"
  Apple_m2 -> "apple-m2"
  Apple_m3 -> "apple-m3"
  Apple_m4 -> "apple-m4"

textToCpu :: Text -> Maybe Cpu
textToCpu = \case
  "generic" -> Just CpuGeneric
  "znver4" -> Just Znver4
  "znver5" -> Just Znver5
  "sapphirerapids" -> Just Sapphirerapids
  "emeraldrapids" -> Just Emeraldrapids
  "apple-m1" -> Just Apple_m1
  "apple-m2" -> Just Apple_m2
  "apple-m3" -> Just Apple_m3
  "apple-m4" -> Just Apple_m4
  _ -> Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- Target Triple
-- ════════════════════════════════════════════════════════════════════════════

-- | Full target triple
data Triple = Triple
  { arch :: !Arch,
    os :: !OS,
    cpu :: !Cpu,
    gpu :: !Gpu
  }
  deriving (Show, Eq, Generic)

-- | Render triple to text (e.g., "x86_64-linux-znver4")
tripleToText :: Triple -> Text
tripleToText t =
  archToText t.arch <> "-" <> osToText t.os <> "-" <> cpuToText t.cpu
    <> case t.gpu of
      GpuNone -> ""
      g -> "-" <> gpuToArch g

-- | Host triple (detected at compile time or runtime)
-- For now, assume x86_64-linux-generic
hostTriple :: Triple
hostTriple =
  Triple
    { arch = X86_64,
      os = Linux,
      cpu = CpuGeneric,
      gpu = GpuNone
    }
