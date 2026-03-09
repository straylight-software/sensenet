{- |
Module      : SenseNet.Target
Description : Target graph representation

Targets are the core abstraction — everything is a target.
Toolchains are targets that produce tools.
Macros are functions that produce targets.

The Dhall schema is self-describing; we just evaluate it
and get a typed graph.
-}
{-# LANGUAGE OverloadedStrings #-}

module SenseNet.Target
  ( Target(..)
  , TargetGraph
  , emitBuck
  ) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

-- | A build target
data Target = Target
  { targetName :: Text
  , targetRule :: Text           -- ^ e.g. "haskell_binary", "cxx_library"
  , targetAttrs :: Map Text Text -- ^ rule attributes
  , targetDeps :: [Text]         -- ^ dependency target names
  }
  deriving (Show, Eq)

-- | A graph of targets, keyed by package path
type TargetGraph = Map FilePath [Target]

-- | Emit BUCK file content for a list of targets
emitBuck :: [Target] -> Text
emitBuck targets = T.unlines $ map emitTarget targets

emitTarget :: Target -> Text
emitTarget t = T.unlines
  [ targetRule t <> "("
  , "    name = \"" <> targetName t <> "\","
  , emitAttrs (targetAttrs t)
  , emitDeps (targetDeps t)
  , ")"
  , ""
  ]

emitAttrs :: Map Text Text -> Text
emitAttrs attrs = T.unlines $ map emitAttr $ Map.toList attrs
  where
    emitAttr (k, v) = "    " <> k <> " = " <> v <> ","

emitDeps :: [Text] -> Text
emitDeps [] = ""
emitDeps deps = "    deps = [" <> T.intercalate ", " (map quote deps) <> "],"
  where
    quote d = "\"" <> d <> "\""
