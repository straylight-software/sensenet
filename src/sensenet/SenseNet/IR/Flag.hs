{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SenseNet.IR.Flag
-- Description : Typed compiler flags
--
-- NO STRINGS for flags - use typed representations!
--
-- This is a direct port from dhall/evring/Toolchain.dhall (Flag type).
module SenseNet.IR.Flag
  ( -- * Optimization
    OptLevel (..),
    optLevelToFlag,

    -- * LTO
    LTOMode (..),
    ltoToFlags,

    -- * Debug Info
    DebugInfo (..),
    debugToFlag,

    -- * Unified Flag type
    Flag (..),
    renderFlag,
    renderFlags,

    -- * Parsing
    textToOptLevel,
    textToLTOMode,
    textToDebugInfo,
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)

-- ════════════════════════════════════════════════════════════════════════════
-- Optimization Level
-- ════════════════════════════════════════════════════════════════════════════

-- | Optimization level
data OptLevel
  = O0 -- No optimization
  | O1 -- Basic optimization
  | O2 -- Standard optimization
  | O3 -- Aggressive optimization
  | Oz -- Size optimization (aggressive)
  | Os -- Size optimization
  deriving (Show, Eq, Ord, Generic)

optLevelToFlag :: OptLevel -> Text
optLevelToFlag = \case
  O0 -> "-O0"
  O1 -> "-O1"
  O2 -> "-O2"
  O3 -> "-O3"
  Oz -> "-Oz"
  Os -> "-Os"

textToOptLevel :: Text -> Maybe OptLevel
textToOptLevel = \case
  "-O0" -> Just O0
  "O0" -> Just O0
  "-O1" -> Just O1
  "O1" -> Just O1
  "-O2" -> Just O2
  "O2" -> Just O2
  "-O3" -> Just O3
  "O3" -> Just O3
  "-Oz" -> Just Oz
  "Oz" -> Just Oz
  "-Os" -> Just Os
  "Os" -> Just Os
  _ -> Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- LTO Mode
-- ════════════════════════════════════════════════════════════════════════════

-- | Link-Time Optimization mode
data LTOMode
  = LTOOff -- No LTO
  | LTOThin -- Thin LTO (faster, parallel)
  | LTOFat -- Full LTO (slower, better codegen)
  deriving (Show, Eq, Ord, Generic)

ltoToFlags :: LTOMode -> [Text]
ltoToFlags = \case
  LTOOff -> []
  LTOThin -> ["-flto=thin"]
  LTOFat -> ["-flto"]

textToLTOMode :: Text -> Maybe LTOMode
textToLTOMode = \case
  "off" -> Just LTOOff
  "thin" -> Just LTOThin
  "fat" -> Just LTOFat
  "full" -> Just LTOFat
  _ -> Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- Debug Info
-- ════════════════════════════════════════════════════════════════════════════

-- | Debug information level
data DebugInfo
  = DebugNone -- No debug info
  | DebugLineTablesOnly -- Line tables only (stack traces)
  | DebugFull -- Full debug info (DWARF)
  deriving (Show, Eq, Ord, Generic)

debugToFlag :: DebugInfo -> [Text]
debugToFlag = \case
  DebugNone -> []
  DebugLineTablesOnly -> ["-gline-tables-only"]
  DebugFull -> ["-g"]

textToDebugInfo :: Text -> Maybe DebugInfo
textToDebugInfo = \case
  "none" -> Just DebugNone
  "line-tables-only" -> Just DebugLineTablesOnly
  "full" -> Just DebugFull
  _ -> Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- Unified Flag Type
-- ════════════════════════════════════════════════════════════════════════════

-- | A typed compiler/linker flag
data Flag
  = -- | Optimization level (-O0, -O2, etc.)
    FlagOptLevel !OptLevel
  | -- | LTO mode (-flto, -flto=thin)
    FlagLTO !LTOMode
  | -- | Debug info (-g, -gline-tables-only)
    FlagDebug !DebugInfo
  | -- | Preprocessor define (-DFOO or -DFOO=BAR)
    FlagDefine !Text !(Maybe Text)
  | -- | Include path (-I/path)
    FlagInclude !Text
  | -- | Link library (-lfoo)
    FlagLink !Text
  | -- | Library path (-L/path)
    FlagLibPath !Text
  | -- | Warning flag (-Werror, -Wall, etc.)
    FlagWarning !Text
  | -- | Language standard (-std=c++20, etc.)
    FlagStandard !Text
  | -- | Raw flag (escape hatch for unsupported flags)
    FlagRaw !Text
  deriving (Show, Eq, Generic)

-- | Render a single flag to command-line arguments
renderFlag :: Flag -> [Text]
renderFlag = \case
  FlagOptLevel opt -> [optLevelToFlag opt]
  FlagLTO lto -> ltoToFlags lto
  FlagDebug dbg -> debugToFlag dbg
  FlagDefine name Nothing -> ["-D" <> name]
  FlagDefine name (Just val) -> ["-D" <> name <> "=" <> val]
  FlagInclude path -> ["-I" <> path]
  FlagLink lib -> ["-l" <> lib]
  FlagLibPath path -> ["-L" <> path]
  FlagWarning w -> ["-W" <> w]
  FlagStandard std -> ["-std=" <> std]
  FlagRaw t -> [t]

-- | Render multiple flags to command-line arguments
renderFlags :: [Flag] -> [Text]
renderFlags = concatMap renderFlag
