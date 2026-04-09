-- | Ultraviolence Tag
-- | Renders as // TAG //
module Straylight.Components.Tag
  ( tag
  , tags
  ) where

import Prelude

import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

-- | Single tag: // content //
tag :: forall w i. String -> HH.HTML w i
tag content =
  HH.span
    [ HP.class_ (HH.ClassName "uv-tag") ]
    [ HH.text content ]

-- | Multiple tags in a row
tags :: forall w i. Array String -> HH.HTML w i
tags ts =
  HH.div
    [ HP.class_ (HH.ClassName "flex flex-wrap gap-2") ]
    (map tag ts)
