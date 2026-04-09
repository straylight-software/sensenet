-- | Ultraviolence Status Block
-- | █ NOMINAL / █ DEGRADED / █ OFFLINE
module Straylight.Components.StatusBlock
  ( status
  , StatusVariant(..)
  , nominal
  , degraded
  , offline
  ) where

import Prelude

import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

-- | Status variants
data StatusVariant
  = Nominal
  | Degraded
  | Offline

-- | Get CSS class for variant
variantClass :: StatusVariant -> String
variantClass = case _ of
  Nominal -> "uv-status-nominal"
  Degraded -> "uv-status-degraded"
  Offline -> "uv-status-offline"

-- | Get label for variant
variantLabel :: StatusVariant -> String
variantLabel = case _ of
  Nominal -> "NOMINAL"
  Degraded -> "DEGRADED"
  Offline -> "OFFLINE"

-- | Status block: █ LABEL
status :: forall w i. StatusVariant -> HH.HTML w i
status variant =
  HH.span
    [ HP.class_ (HH.ClassName ("uv-status " <> variantClass variant)) ]
    [ HH.span
        [ HP.class_ (HH.ClassName "uv-status-block") ]
        [ HH.text "█" ]
    , HH.text (" " <> variantLabel variant)
    ]

-- | Convenience constructors
nominal :: forall w i. HH.HTML w i
nominal = status Nominal

degraded :: forall w i. HH.HTML w i
degraded = status Degraded

offline :: forall w i. HH.HTML w i
offline = status Offline
