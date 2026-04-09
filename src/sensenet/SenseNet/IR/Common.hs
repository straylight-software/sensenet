{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SenseNet.IR.Common
-- Description : Common types shared across rule definitions
--
-- Provides Visibility, Dependency, and Common fields that are shared
-- by all rule types in the IR.
--
-- This is part of the incremental migration from stringly-typed to
-- properly typed build rules.
module SenseNet.IR.Common
  ( -- * Visibility
    Visibility (..),
    visibilityToText,
    textToVisibility,

    -- * Dependencies (typed)
    DepTyped (..),
    depTypedToText,

    -- * Common fields
    Common (..),
    emptyCommon,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import SenseNet.IR.Coeffect (Coeffects)

-- ════════════════════════════════════════════════════════════════════════════
-- Visibility
-- ════════════════════════════════════════════════════════════════════════════

-- | Target visibility controls who can depend on this target.
data Visibility
  = -- | Anyone can depend on this target
    VisPublic
  | -- | Only targets in the same package can depend on this
    VisPrivate
  | -- | Only targets in the same package tree can depend on this
    VisPackage
  | -- | Only the specified targets can depend on this
    VisTargets ![Text]
  deriving stock (Show, Eq, Generic)

visibilityToText :: Visibility -> Text
visibilityToText = \case
  VisPublic -> "public"
  VisPrivate -> "private"
  VisPackage -> "package"
  VisTargets ts -> "targets:" <> T.intercalate "," ts

textToVisibility :: Text -> Maybe Visibility
textToVisibility t
  | t == "public" = Just VisPublic
  | t == "private" = Just VisPrivate
  | t == "package" = Just VisPackage
  | Just rest <- T.stripPrefix "targets:" t = Just $ VisTargets (T.splitOn "," rest)
  | otherwise = Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- Typed Dependencies
-- ════════════════════════════════════════════════════════════════════════════

-- | Typed dependency reference (replaces stringly-typed Dep)
--
-- NOTE: Constructors prefixed with "Dep2" to avoid clash with legacy Dep type.
-- Will be renamed once migration is complete.
data DepTyped
  = -- | Local dependency: :target or //pkg:target
    Dep2Local !Text
  | -- | Nix flake dependency: flake#attr
    Dep2Flake !Text !Text
  | -- | External package (for Haskell, Rust, etc.)
    Dep2Package !Text
  deriving stock (Show, Eq, Generic)

depTypedToText :: DepTyped -> Text
depTypedToText = \case
  Dep2Local target -> target
  Dep2Flake flake attr -> flake <> "#" <> attr
  Dep2Package pkg -> "pkg:" <> pkg

-- ════════════════════════════════════════════════════════════════════════════
-- Common Fields
-- ════════════════════════════════════════════════════════════════════════════

-- | Common fields shared by all rule types
data Common = Common
  { -- | Target name (e.g., "hello-world")
    cName :: !Text,
    -- | Visibility scope
    cVisibility :: !Visibility,
    -- | Labels for filtering (e.g., "test", "slow", "cuda")
    cLabels :: ![Text],
    -- | Required coeffects (what the build needs)
    cCoeffects :: !Coeffects
  }
  deriving stock (Show, Eq, Generic)

-- | Empty common fields with default visibility
emptyCommon :: Text -> Common
emptyCommon name =
  Common
    { cName = name,
      cVisibility = VisPrivate,
      cLabels = [],
      cCoeffects = []
    }
