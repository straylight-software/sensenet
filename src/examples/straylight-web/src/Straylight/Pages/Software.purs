-- | Software Page - Projects list
module Straylight.Pages.Software where

import Prelude

import Data.Array (filter)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Straylight.UI (cls, sectionHeader)

-- ============================================================
-- DATA
-- ============================================================

type Project =
  { name :: String
  , desc :: String
  , category :: String
  }

projects :: Array Project
projects =
  -- rfl nexus
  [ { name: "verified-purescript", desc: "proof-carrying PureScript from Lean 4. 21 theorems, 0 sorry.", category: "rfl" }
  , { name: "purescript-radix", desc: "shadcn-style component generator. Lean 4 compiler, Halogen output.", category: "rfl" }
  -- infrastructure
  , { name: "nix", desc: "our fork. correct, modern, apolitical.", category: "infra" }
  , { name: "aleph", desc: "typed infrastructure. System Fω. droids ship code that works.", category: "infra" }
  , { name: "isospin-microvm", desc: "microvm orchestration. GPUs appear inside firecracker.", category: "infra" }
  -- tools
  , { name: "hacker-flake", desc: "nix flake for NVIDIA dev. just compile some shit.", category: "tools" }
  , { name: "zeitschrift", desc: "scope graph publishing. references resolve or the build fails.", category: "tools" }
  ]

-- ============================================================
-- COMPONENT
-- ============================================================

softwarePage :: forall q i o m. H.Component q i o m
softwarePage = H.mkComponent
  { initialState: const unit
  , render: const render
  , eval: H.mkEval H.defaultEval
  }

render :: forall w i. HH.HTML w i
render =
  HH.div_
    [ sectionHeader "software"
    , HH.p
        [ cls [ "mb-8 text-muted-foreground" ] ]
        [ HH.text "correct by construction. the result is saved." ]
    
    -- rfl nexus
    , categoryHeader "rfl nexus"
    , HH.div
        [ cls [ "flex flex-col gap-4 mb-8" ] ]
        (map projectRow (filter (\p -> p.category == "rfl") projects))
    
    -- infrastructure
    , categoryHeader "infrastructure" 
    , HH.div
        [ cls [ "flex flex-col gap-4 mb-8" ] ]
        (map projectRow (filter (\p -> p.category == "infra") projects))
    
    -- tools
    , categoryHeader "tools"
    , HH.div
        [ cls [ "flex flex-col gap-4" ] ]
        (map projectRow (filter (\p -> p.category == "tools") projects))
    ]

categoryHeader :: forall w i. String -> HH.HTML w i
categoryHeader title =
  HH.div
    [ cls [ "text-[0.75rem] text-primary uppercase tracking-wider mb-3" ] ]
    [ HH.text ("// " <> title) ]

projectRow :: forall w i. Project -> HH.HTML w i
projectRow p =
  HH.div
    [ cls [ "grid grid-cols-[140px_1fr] gap-4 items-baseline group" ] ]
    [ HH.a
        [ HP.href $ "https://github.com/straylight-software/" <> p.name
        , HP.target "_blank"
        , HP.rel "noopener noreferrer"
        , cls [ "text-text hover:text-primary transition-colors geo-hover" ]
        ]
        [ HH.text p.name ]
    , HH.span
        [ cls [ "text-muted-foreground group-hover:text-text/70 transition-colors" ] ]
        [ HH.text p.desc ]
    ]
