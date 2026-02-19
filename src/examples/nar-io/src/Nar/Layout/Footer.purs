-- | Nar.io Footer Component
module Nar.Layout.Footer where

import Prelude

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Nar.UI (cls)

-- ============================================================
-- COMPONENT
-- ============================================================

footer :: forall q i o m. H.Component q i o m
footer = H.mkComponent
  { initialState: const unit
  , render: const render
  , eval: H.mkEval H.defaultEval
  }

-- ============================================================
-- RENDER
-- ============================================================

render :: forall w i. HH.HTML w i
render =
  HH.footer
    [ cls [ "border-t border-border py-12 mt-24" ] ]
    [ HH.div
        [ cls [ "max-w-[1100px] mx-auto px-6" ] ]
        [ HH.div
            [ cls [ "grid grid-cols-1 md:grid-cols-4 gap-8" ] ]
            [ -- Brand column
              HH.div_
                [ HH.div
                    [ cls [ "flex items-center gap-2 text-text font-bold text-lg mb-4" ] ]
                    [ HH.span [ cls [ "text-primary" ] ] [ HH.text ">" ]
                    , HH.text "nar.io"
                    ]
                , HH.p
                    [ cls [ "text-muted-foreground text-sm" ] ]
                    [ HH.text "Nix binary cache that doesn't suck." ]
                , HH.p
                    [ cls [ "text-muted-foreground text-sm mt-2" ] ]
                    [ HH.text "Built by "
                    , footerLink "https://straylight.software" "Straylight"
                    , HH.text "."
                    ]
                ]
              
              -- Product column
            , HH.div_
                [ HH.h4
                    [ cls [ "text-text font-medium mb-4" ] ]
                    [ HH.text "Product" ]
                , HH.ul
                    [ cls [ "space-y-2" ] ]
                    [ linkItem "/" "Features"
                    , linkItem "/pricing" "Pricing"
                    , linkItem "/docs" "Documentation"
                    , linkItem "/docs/api" "API Reference"
                    ]
                ]
              
              -- Resources column
            , HH.div_
                [ HH.h4
                    [ cls [ "text-text font-medium mb-4" ] ]
                    [ HH.text "Resources" ]
                , HH.ul
                    [ cls [ "space-y-2" ] ]
                    [ linkItem "/docs/quickstart" "Quick Start"
                    , linkItem "/docs/cli" "CLI Reference"
                    , externalLinkItem "https://github.com/straylight-software/nix-serve-cas" "GitHub"
                    , externalLinkItem "https://status.nar.io" "Status"
                    ]
                ]
              
              -- Company column
            , HH.div_
                [ HH.h4
                    [ cls [ "text-text font-medium mb-4" ] ]
                    [ HH.text "Company" ]
                , HH.ul
                    [ cls [ "space-y-2" ] ]
                    [ externalLinkItem "https://straylight.software" "About"
                    , externalLinkItem "https://github.com/straylight-software" "Open Source"
                    , linkItem "/privacy" "Privacy"
                    , linkItem "/terms" "Terms"
                    ]
                ]
            ]
          
          -- Bottom bar
        , HH.div
            [ cls [ "mt-12 pt-8 border-t border-border flex flex-col md:flex-row justify-between items-center gap-4" ] ]
            [ HH.p
                [ cls [ "text-muted-foreground text-sm" ] ]
                [ HH.text "2026 Straylight Software. MIT License." ]
            , HH.div
                [ cls [ "flex items-center gap-6" ] ]
                [ externalLinkItem "https://github.com/straylight-software" "GitHub"
                , externalLinkItem "https://discord.gg/straylight" "Discord"
                , externalLinkItem "https://twitter.com/straylightsw" "Twitter"
                ]
            ]
        ]
    ]

-- ============================================================
-- HELPERS
-- ============================================================

linkItem :: forall w i. String -> String -> HH.HTML w i
linkItem href label =
  HH.li_
    [ HH.a
        [ HP.href href
        , cls [ "text-muted-foreground text-sm hover:text-text transition-colors" ]
        ]
        [ HH.text label ]
    ]

externalLinkItem :: forall w i. String -> String -> HH.HTML w i
externalLinkItem href label =
  HH.li_
    [ HH.a
        [ HP.href href
        , HP.target "_blank"
        , HP.rel "noopener noreferrer"
        , cls [ "text-muted-foreground text-sm hover:text-text transition-colors" ]
        ]
        [ HH.text label ]
    ]

footerLink :: forall w i. String -> String -> HH.HTML w i
footerLink href label =
  HH.a
    [ HP.href href
    , HP.target "_blank"
    , HP.rel "noopener noreferrer"
    , cls [ "text-primary hover:text-primary/80 transition-colors" ]
    ]
    [ HH.text label ]
