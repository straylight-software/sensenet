-- | IRC Page
module Straylight.Pages.Irc where

import Prelude

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Straylight.UI (cls, sectionHeader, codeBlock, inlineCode)

-- ============================================================
-- COMPONENT
-- ============================================================

webchatUrl :: String
webchatUrl = "https://web.libera.chat/#straylight"

ircPage :: forall q i o m. H.Component q i o m
ircPage = H.mkComponent
  { initialState: const unit
  , render: const render
  , eval: H.mkEval H.defaultEval
  }

render :: forall w i. HH.HTML w i
render =
  HH.div_
    [ sectionHeader "irc"
    , HH.div
        [ cls [ "flex flex-col gap-4 mb-6" ] ]
        [ row "network" "libera.chat"
        , row "channel" "#straylight"
        ]
    , HH.a
        [ HP.href webchatUrl
        , HP.target "_blank"
        , HP.rel "noopener"
        , cls [ "inline-block px-4 py-2 border border-border text-text hover:bg-accent transition-colors" ]
        ]
        [ HH.text "open webchat" ]
    , HH.p
        [ cls [ "mt-6 text-[0.85rem] text-muted-foreground" ] ]
        [ HH.text "or connect with your client:" ]
    , codeBlock
        [ inlineCode "/connect"
        , HH.text " irc.libera.chat\n"
        , inlineCode "/join"
        , HH.text " #straylight"
        ]
    ]

row :: forall w i. String -> String -> HH.HTML w i
row label value =
  HH.div
    [ cls [ "grid grid-cols-[100px_1fr] gap-4 items-baseline" ] ]
    [ HH.span [ cls [ "text-text" ] ] [ HH.text label ]
    , HH.span [ cls [ "text-muted-foreground" ] ] [ HH.text value ]
    ]
