-- | Razorgirl Page - Assets, diagrams, swag
module Straylight.Pages.Razorgirl where

import Prelude

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Straylight.UI (cls, sectionHeader, keyword)
import Straylight.Components.Tag (tags)

-- ============================================================
-- DATA
-- ============================================================

type Asset =
  { filename :: String
  , href :: String
  , desc :: String
  , category :: String
  }

assets :: Array Asset
assets =
  -- Architecture diagrams
  [ { filename: "straylight-cube.svg"
    , href: "/straylight-cube.svg"
    , desc: "aleph-008 continuity architecture. rfl at the top."
    , category: "diagrams"
    }
  , { filename: "lambda-hierarchy.svg"
    , href: "/assets/lambda-hierarchy.svg"
    , desc: "tiered proof hierarchy. PROVEN to cryptographic substrate."
    , category: "diagrams"
    }
  , { filename: "proof-carrying-purescript.svg"
    , href: "/assets/proof-carrying-purescript.svg"
    , desc: "verified purescript. parse, prove, print."
    , category: "diagrams"
    }
  , { filename: "radix-diagram.svg"
    , href: "/assets/radix-diagram.svg"
    , desc: "purescript-radix component flow."
    , category: "diagrams"
    }
  , { filename: "straylight-brand-system.svg"
    , href: "/assets/straylight-brand-system.svg"
    , desc: "full brand system. chromatic series."
    , category: "diagrams"
    }
  -- Wallpapers
  , { filename: "droids-on-squad.svg"
    , href: "/droids-on-squad.svg"
    , desc: "i am stochastic omega. you are the oracle."
    , category: "wallpaper"
    }
  , { filename: "wallpaper-razorgirl.svg"
    , href: "/assets/wallpaper-razorgirl.svg"
    , desc: "villa straylight. myelin tactics. 2560x1440."
    , category: "wallpaper"
    }
  , { filename: "wallpaper-continuity.svg"
    , href: "/assets/wallpaper-continuity.svg"
    , desc: "continuity is continuity."
    , category: "wallpaper"
    }
  , { filename: "wallpaper-4k.png"
    , href: "/assets/wallpaper-4k.png"
    , desc: "4k raster. 3840x2160."
    , category: "wallpaper"
    }
  -- Branding
  , { filename: "logo.svg"
    , href: "/assets/logo.svg"
    , desc: "vector mark. primary."
    , category: "brand"
    }
  -- Theme sheets
  , { filename: "agency-sheet-ono-sendai.svg"
    , href: "/assets/agency-sheet-ono-sendai.svg"
    , desc: "ono-sendai dark. base16 palette."
    , category: "themes"
    }
  , { filename: "agency-sheet-maas.svg"
    , href: "/assets/agency-sheet-maas.svg"
    , desc: "maas biolabs light. base16 palette."
    , category: "themes"
    }
  ]

type Quote =
  { source :: String
  , text :: String
  , attribution :: String
  , accent :: String
  }

quotes :: Array Quote
quotes =
  [ { source: "GIBSON"
    , text: "\"The Panther Moderns differ from other terrorists precisely in their degree of self-consciousness, in their awareness of the extent to which media divorce the act of terrorism from the original sociopolitical intent.\""
    , attribution: "\"Skip it,\" Case said."
    , accent: "primary"
    }
  , { source: "GIBSON"
    , text: "\"The sky above the port was the color of television, tuned to a dead channel.\""
    , attribution: ""
    , accent: "status"
    }
  , { source: "GIBSON"
    , text: "\"Night City was like a deranged experiment in social Darwinism, designed by a bored researcher who kept one thumb permanently on the fast-forward button.\""
    , attribution: ""
    , accent: "primary"
    }
  ]

-- ============================================================
-- COMPONENT
-- ============================================================

razorgirlPage :: forall q i o m. H.Component q i o m
razorgirlPage = H.mkComponent
  { initialState: const unit
  , render: const render
  , eval: H.mkEval H.defaultEval
  }

render :: forall w i. HH.HTML w i
render =
  HH.div_
    [ sectionHeader "razorgirl"
    , HH.p
        [ cls [ "mb-4" ] ]
        [ HH.text "it was the style that mattered and the style was the same." ]
    , HH.p
        [ cls [ "mb-4" ] ]
        [ HH.text "the moderns were mercenaries, practical jokers, "
        , keyword 3 "nihilistic technofetishists"
        , HH.text "."
        ]
    , HH.div
        [ cls [ "mb-8" ] ]
        [ tags ["swag", "assets", "diagrams", "themes", "wallpapers"] ]
    
    -- Wallpapers section - hero treatment
    , sectionHeader "wallpapers"
    , HH.div
        [ cls [ "grid grid-cols-1 gap-4 mb-8" ] ]
        [ assetCard "/droids-on-squad.svg" "droids-on-squad.svg" "i am stochastic omega. you are the oracle."
        , assetCard "/assets/wallpaper-razorgirl.svg" "wallpaper-razorgirl.svg" "villa straylight. myelin tactics. 2560x1440."
        ]
    , HH.div
        [ cls [ "grid grid-cols-2 gap-4 mb-12" ] ]
        [ assetCard "/assets/wallpaper-continuity.svg" "wallpaper-continuity.svg" "continuity is continuity."
        , assetCard "/assets/wallpaper-4k.png" "wallpaper-4k.png" "4k raster. 3840x2160."
        ]
    
    , HH.hr [ cls [ "uv-hr" ] ]
    
    -- Architecture diagrams
    , sectionHeader "architecture"
    , HH.div
        [ cls [ "grid grid-cols-1 gap-4 mb-8" ] ]
        [ assetCard "/straylight-cube.svg" "straylight-cube.svg" "aleph-008 continuity. rfl at the top."
        ]
    , HH.div
        [ cls [ "grid grid-cols-2 gap-4 mb-12" ] ]
        [ assetCard "/assets/lambda-hierarchy.svg" "lambda-hierarchy.svg" "tiered proof flow."
        , assetCard "/assets/proof-carrying-purescript.svg" "proof-carrying-purescript.svg" "verified ps round-trip."
        , assetCard "/assets/radix-diagram.svg" "radix-diagram.svg" "radix component flow."
        , assetCard "/assets/straylight-brand-system.svg" "straylight-brand-system.svg" "chromatic series."
        ]
    
    , HH.hr [ cls [ "uv-hr" ] ]
    
    -- Theme sheets + brand
    , sectionHeader "themes"
    , HH.div
        [ cls [ "grid grid-cols-2 md:grid-cols-3 gap-4 mb-12" ] ]
        [ assetCard "/assets/agency-sheet-ono-sendai.svg" "ono-sendai.svg" "dark. base16."
        , assetCard "/assets/agency-sheet-maas.svg" "maas.svg" "light. base16."
        , assetCard "/assets/logo.svg" "logo.svg" "vector mark."
        ]
    
    , HH.hr [ cls [ "uv-hr" ] ]
    
    -- Transmissions
    , sectionHeader "transmissions"
    , HH.div_ (map quoteBlock quotes)
    ]

assetCard :: forall w i. String -> String -> String -> HH.HTML w i
assetCard href filename desc =
  HH.a
    [ HP.href href
    , HP.target "_blank"
    , cls [ "block bg-card border border-border hover:border-primary transition-all group" ]
    ]
    [ HH.div
        [ cls [ "relative aspect-[16/9] bg-black/50 overflow-hidden" ] ]
        [ HH.img
            [ HP.src href
            , HP.alt filename
            , cls [ "absolute inset-0 w-full h-full object-cover group-hover:scale-[1.02] transition-transform duration-200" ]
            ]
        ]
    , HH.div
        [ cls [ "p-3" ] ]
        [ HH.div
            [ cls [ "text-[0.8rem] text-text font-mono" ] ]
            [ HH.text filename ]
        , HH.div
            [ cls [ "text-[0.7rem] text-muted-foreground mt-1" ] ]
            [ HH.text desc ]
        ]
    ]

quoteBlock :: forall w i. Quote -> HH.HTML w i
quoteBlock q =
  HH.div
    [ cls [ "bg-card border-l-4 px-6 py-4 my-6 quote-breathe"
          , if q.accent == "primary" then "border-l-primary" else "border-l-status"
          ]
    ]
    [ HH.div
        [ cls [ "text-[0.75rem] text-muted-foreground uppercase tracking-wide mb-3 flex items-center gap-2" ] ]
        [ HH.span [ cls [ "text-primary" ] ] [ HH.text "i" ]
        , HH.text q.source
        ]
    , HH.div
        [ cls [ "text-text italic text-[0.9rem] leading-relaxed" ] ]
        [ HH.text q.text ]
    , if q.attribution == "" 
        then HH.text ""
        else HH.div
          [ cls [ "mt-3 text-muted-foreground text-[0.9rem]" ] ]
          [ HH.text q.attribution ]
    ]

assetRow :: forall w i. Asset -> HH.HTML w i
assetRow a =
  HH.div
    [ cls [ "grid grid-cols-[200px_1fr] gap-4 items-baseline group py-1" ] ]
    [ HH.a
        [ HP.href a.href
        , HP.attr (HH.AttrName "download") ""
        , cls [ "text-text hover:text-primary transition-colors font-mono text-[0.85rem]" ]
        ]
        [ HH.text a.filename ]
    , HH.span
        [ cls [ "text-muted-foreground text-[0.85rem] group-hover:text-text/70 transition-colors" ] ]
        [ HH.text a.desc ]
    ]
