-- | Discord Page
module Straylight.Pages.Discord where

import Prelude

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Straylight.UI (cls, sectionHeader)

-- ============================================================
-- COMPONENT
-- ============================================================

discordPage :: forall q i o m. H.Component q i o m
discordPage = H.mkComponent
  { initialState: const unit
  , render: const render
  , eval: H.mkEval H.defaultEval
  }

render :: forall w i. HH.HTML w i
render =
  HH.div_
    [ sectionHeader "discord"
    , HH.p
        [ cls [ "mb-6" ] ]
        [ HH.text "real-time coordination. less formal than irc." ]
    , HH.a
        [ HP.href "https://discord.gg/straylight"
        , HP.target "_blank"
        , HP.rel "noopener noreferrer"
        , cls [ "inline-block text-text hover:text-primary transition-colors geo-hover" ]
        ]
        [ HH.text "discord.gg/straylight" ]
    ]
