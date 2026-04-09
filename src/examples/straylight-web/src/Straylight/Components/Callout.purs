-- | Ultraviolence Callout
-- | Info/Warning/Danger boxes with icon and border-left accent
-- | Based on weyl.ai villa straylight papers style
module Straylight.Components.Callout
  ( callout
  , CalloutVariant(..)
  , info
  , warning
  , danger
  , tip
  ) where

import Prelude

import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

-- | Callout variants
data CalloutVariant
  = Info      -- i icon, blue accent
  | Warning   -- ! icon, orange accent  
  | Danger    -- ! icon, red accent
  | Tip       -- * icon, green accent

-- | Get the icon character for a variant
variantIcon :: CalloutVariant -> String
variantIcon = case _ of
  Info -> "i"
  Warning -> "!"
  Danger -> "!"
  Tip -> "*"

-- | Get the CSS class for a variant
variantClass :: CalloutVariant -> String
variantClass = case _ of
  Info -> "callout-info"
  Warning -> "callout-warning"
  Danger -> "callout-danger"
  Tip -> "callout-tip"

-- | Main callout component
callout :: forall w i. CalloutVariant -> String -> Array (HH.HTML w i) -> HH.HTML w i
callout variant title children =
  HH.aside
    [ HP.class_ (HH.ClassName ("callout " <> variantClass variant))
    , HP.attr (HH.AttrName "role") "note"
    ]
    [ HH.div
        [ HP.class_ (HH.ClassName "callout-title") ]
        [ HH.span
            [ HP.class_ (HH.ClassName "callout-icon")
            , HP.attr (HH.AttrName "aria-hidden") "true"
            ]
            [ HH.text (variantIcon variant) ]
        , HH.strong_ [ HH.text title ]
        ]
    , HH.div
        [ HP.class_ (HH.ClassName "callout-content") ]
        children
    ]

-- | Convenience constructors
info :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
info = callout Info

warning :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
warning = callout Warning

danger :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
danger = callout Danger

tip :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
tip = callout Tip
