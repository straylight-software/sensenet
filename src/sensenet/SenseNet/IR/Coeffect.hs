{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SenseNet.IR.Coeffect
-- Description : Typed coeffect algebra for build actions
--
-- Coeffects describe what a computation NEEDS from the world (as opposed to
-- effects, which describe what a computation DOES to the world).
--
-- A pure build needs nothing external (coeffects = []).
-- An impure build needs things like network, filesystem, time, random, auth.
--
-- This is a direct port from Continuity.Coeffect.lean and dhall/evring/Coeffect.dhall.
--
-- CRITICAL: coeffectToText must produce the SAME strings as the old [Text] approach
-- to preserve DICE cache key compatibility.
module SenseNet.IR.Coeffect
  ( -- * Types
    Coeffect (..),
    Coeffects,

    -- * Serialization (DICE compatible)
    coeffectToText,
    textToCoeffect,

    -- * Analysis
    isCacheable,
    isReproducible,
    purityLevel,

    -- * Constructors
    pure,
    filesystem,
    filesystemCA,
    network,
    networkCA,
    env,
    auth,
    gpu,
    sandbox,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prelude hiding (pure)

-- | A single coeffect: what an action needs from the environment.
--
-- Ordered roughly by purity level (Pure = most pure, Random/Time = least).
data Coeffect
  = -- | Needs nothing (fully reproducible)
    Pure
  | -- | Needs file content by path (non-content-addressed, non-reproducible)
    Filesystem !Text
  | -- | Needs file content by hash (content-addressed, reproducible)
    FilesystemCA !Text
  | -- | Needs network endpoint (host:port, non-content-addressed)
    Network !Text !Natural
  | -- | Needs network content by hash (content-addressed, reproducible)
    NetworkCA !Text
  | -- | Needs environment variable
    Environment !Text
  | -- | Needs wall clock time (non-reproducible!)
    Time
  | -- | Needs entropy (non-reproducible!)
    Random
  | -- | Needs uid/gid
    Identity
  | -- | Needs credential (provider name)
    Auth !Text
  | -- | Needs GPU device
    CoeffectGpu !Text
  | -- | Needs sandbox environment
    Sandbox !Text
  deriving (Show, Eq, Generic)

-- | A set of coeffects (list = tensor product in the coeffect algebra)
type Coeffects = [Coeffect]

-- ════════════════════════════════════════════════════════════════════════════
-- Serialization (DICE compatible)
-- ════════════════════════════════════════════════════════════════════════════

-- | Render a coeffect to text for DICE canonical serialization.
--
-- CRITICAL: This MUST produce the same strings as the old @[Text]@ approach
-- to preserve cache key compatibility. The format is:
--
-- @
--   Pure         -> "pure"
--   Filesystem p -> "fs:" <> p
--   Network h p  -> "net:" <> h <> ":" <> show p
--   etc.
-- @
coeffectToText :: Coeffect -> Text
coeffectToText = \case
  Pure -> "pure"
  Filesystem p -> "fs:" <> p
  FilesystemCA h -> "fs-ca:" <> h
  Network h p -> "net:" <> h <> ":" <> T.pack (show p)
  NetworkCA h -> "net-ca:" <> h
  Environment v -> "env:" <> v
  Time -> "time"
  Random -> "random"
  Identity -> "identity"
  Auth p -> "auth:" <> p
  CoeffectGpu d -> "gpu:" <> d
  Sandbox s -> "sandbox:" <> s

-- | Parse a coeffect from text (for backward compatibility with existing BUILD.dhall).
textToCoeffect :: Text -> Maybe Coeffect
textToCoeffect t
  | t == "pure" = Just Pure
  | t == "time" = Just Time
  | t == "random" = Just Random
  | t == "identity" = Just Identity
  | Just rest <- T.stripPrefix "fs-ca:" t = Just (FilesystemCA rest)
  | Just rest <- T.stripPrefix "fs:" t = Just (Filesystem rest)
  | Just rest <- T.stripPrefix "net-ca:" t = Just (NetworkCA rest)
  | Just rest <- T.stripPrefix "net:" t = parseNetwork rest
  | Just rest <- T.stripPrefix "env:" t = Just (Environment rest)
  | Just rest <- T.stripPrefix "auth:" t = Just (Auth rest)
  | Just rest <- T.stripPrefix "gpu:" t = Just (CoeffectGpu rest)
  | Just rest <- T.stripPrefix "sandbox:" t = Just (Sandbox rest)
  | otherwise = Nothing
  where
    parseNetwork :: Text -> Maybe Coeffect
    parseNetwork s =
      case T.breakOnEnd ":" s of
        ("", _) -> Nothing
        (hostColon, portText) ->
          let host = T.dropEnd 1 hostColon
           in case reads (T.unpack portText) of
                [(port, "")] -> Just (Network host port)
                _ -> Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- Analysis
-- ════════════════════════════════════════════════════════════════════════════

-- | Check if a set of coeffects allows caching.
-- All coeffects must be reproducible for caching to be safe.
isCacheable :: Coeffects -> Bool
isCacheable = all isReproducible

-- | Is a single coeffect reproducible?
--
-- Reproducible coeffects can be cached because they produce deterministic
-- outputs given the same inputs.
isReproducible :: Coeffect -> Bool
isReproducible = \case
  Pure -> True
  FilesystemCA _ -> True -- Content-addressed = reproducible
  NetworkCA _ -> True -- Content-addressed = reproducible
  Auth _ -> True -- OK if handled properly
  CoeffectGpu _ -> True -- Deterministic if seeded
  Sandbox _ -> True -- Controlled environment
  Filesystem _ -> False -- Non-CA filesystem = ambient dependency
  Network _ _ -> False -- Non-CA network = ambient dependency
  Environment _ -> False -- Ambient
  Identity -> False -- Ambient
  Time -> False -- Non-deterministic!
  Random -> False -- Non-deterministic!

-- | Purity level: higher = purer.
--
-- Used for scheduling decisions (prefer pure actions, they're cacheable).
purityLevel :: Coeffect -> Natural
purityLevel = \case
  Pure -> 3
  FilesystemCA _ -> 2
  NetworkCA _ -> 2
  Auth _ -> 2
  CoeffectGpu _ -> 2
  Sandbox _ -> 2
  Filesystem _ -> 1
  Network _ _ -> 1
  Environment _ -> 1
  Identity -> 1
  Time -> 0
  Random -> 0

-- ════════════════════════════════════════════════════════════════════════════
-- Constructors
-- ════════════════════════════════════════════════════════════════════════════

-- | The empty coeffect set (pure action, needs nothing)
pure :: Coeffects
pure = []

-- | Needs a file by path (non-content-addressed)
filesystem :: Text -> Coeffect
filesystem = Filesystem

-- | Needs file content by hash (content-addressed)
filesystemCA :: Text -> Coeffect
filesystemCA = FilesystemCA

-- | Needs network endpoint
network :: Text -> Natural -> Coeffect
network = Network

-- | Needs network content by hash (content-addressed)
networkCA :: Text -> Coeffect
networkCA = NetworkCA

-- | Needs environment variable
env :: Text -> Coeffect
env = Environment

-- | Needs credential
auth :: Text -> Coeffect
auth = Auth

-- | Needs GPU device
gpu :: Text -> Coeffect
gpu = CoeffectGpu

-- | Needs sandbox environment
sandbox :: Text -> Coeffect
sandbox = Sandbox
