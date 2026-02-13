-- | Home Page
module Straylight.Pages.Home where

import Prelude

import Halogen as H
import Halogen.HTML as HH

import Straylight.UI (cls, rail, keyword, sectionHeader, codeBlock, inlineCode, blockCursor)
import Straylight.Components.Callout as Callout
import Straylight.Components.Tag (tags)
import Straylight.Components.StatusBlock as Status

-- ============================================================
-- COMPONENT
-- ============================================================

homePage :: forall q i o m. H.Component q i o m
homePage = H.mkComponent
  { initialState: const unit
  , render: const render
  , eval: H.mkEval H.defaultEval
  }

-- ============================================================
-- RENDER
-- ============================================================

render :: forall w i. HH.HTML w i
render =
  HH.div_
    [ hero
    , premise
    , primitives
    , method
    , ultraviolence
    ]

-- ============================================================
-- SECTIONS
-- ============================================================

hero :: forall w i. HH.HTML w i
hero =
  HH.section
    [ cls [ "py-24 pb-16 text-right" ] ]
    [ rail
    , HH.h1
        [ cls [ "text-text text-[2rem] font-medium mt-6" ] ]
        [ HH.span [ cls [ "text-primary" ] ] [ HH.text "//" ]
        , HH.text " straylight "
        , HH.span [ cls [ "text-primary" ] ] [ HH.text "//" ]
        , HH.text " software "
        , HH.span [ cls [ "text-primary" ] ] [ HH.text "//" ]
        ]
    , HH.div [ cls [ "h-[3px] rail mt-6" ] ] []
    
    , HH.p
        [ cls [ "mt-12 text-left text-lg text-muted-foreground hover:text-text transition-colors duration-200 cursor-default" ] ]
        [ HH.text "the continuity project." ]
    , HH.p
        [ cls [ "mt-6 text-left italic text-base02 text-[0.95rem] hover:text-text transition-colors duration-200 cursor-default" ] ]
        [ HH.text "continuity is continuity. continuity is continuity's job." ]
    ]

premise :: forall w i. HH.HTML w i
premise =
  HH.section
    [ cls [ "py-12 border-t border-border" ] ]
    [ sectionHeader "premise"
    , HH.p
        [ cls [ "mb-4" ] ]
        [ HH.text "all computations run on "
        , keyword 1 "perfect conceptual computers"
        , HH.text "."
        ]
    , HH.p
        [ cls [ "mb-4" ] ]
        [ keyword 2 "correct by construction"
        , HH.text ". the result is saved."
        ]
    , HH.p
        [ cls [ "mb-4" ] ]
        [ HH.text "one "
        , keyword 3 "content addressing"
        , HH.text " scheme. the hash is the artifact."
        ]
    , HH.p
        [ cls [ "mb-4" ] ]
        [ keyword 4 "ca-derivations"
        , HH.text " and buck2 and bazel are supports for a coset. they can have the same cache keys."
        ]
    , HH.p_
        [ HH.text "who container registry. what nix cache. what waste." ]
    ]

primitives :: forall w i. HH.HTML w i
primitives =
  HH.section
    [ cls [ "py-12 border-t border-border" ] ]
    [ sectionHeader "primitives"
    , HH.div
        [ cls [ "flex flex-col gap-2" ] ]
        [ primitiveItem 5 "orthogonal." "one thing, well."
        , primitiveItem 6 "composable." "outputs are inputs."
        , primitiveItem 7 "deterministic." "same input, same hash, same artifact."
        ]
    ]

primitiveItem :: forall w i. Int -> String -> String -> HH.HTML w i
primitiveItem n name desc =
  HH.div
    [ cls [ "grid grid-cols-[140px_1fr] gap-4" ] ]
    [ keyword n name
    , HH.span_ [ HH.text desc ]
    ]

method :: forall w i. HH.HTML w i
method =
  HH.section
    [ cls [ "py-12 border-t border-border" ] ]
    [ sectionHeader "method"
    , codeBlock
        [ inlineCode "razorgirl on railgun ~"
        , HH.text "\n"
        , inlineCode "❯ "
        , HH.code
            [ cls [ "text-text" ] ]
            [ HH.text "ssh -A anywhere.straylight.software \\\n  'nix run -L github:straylight-software/isospin-builder -- nvidia-sdk | straylight-cas'" ]
        , blockCursor
        ]
    , HH.p
        [ cls [ "mt-6 text-text" ] ]
        [ keyword 1 "conceptual computers"
        , HH.text " are free now."
        ]
    ]

ultraviolence :: forall w i. HH.HTML w i
ultraviolence =
  HH.section
    [ cls [ "py-12 border-t border-border" ] ]
    [ sectionHeader "ultraviolence"
    , HH.div
        [ cls [ "mb-6" ] ]
        [ tags ["Lean", "CUDA", "Formal Methods", "rfl"] ]
    , HH.div
        [ cls [ "flex items-center gap-4 mb-6" ] ]
        [ Status.nominal
        , Status.degraded
        , Status.offline
        ]
    , Callout.info "Gibson's Epigraph"
        [ HH.p_
            [ HH.em_ [ HH.text "\"The Villa Straylight is a body grown in upon itself, a Gothic folly. Each space in Straylight is in some way secret, this endless series of chambers linked by passages, by stairwells vaulted like intestines, where the eye is trapped in narrow curves, carried past ornate screens, empty alcoves.\"" ]
            ]
        ]
    , Callout.warning "FTTC - Theorem 6"
        [ HH.p_
            [ HH.text "Theorem 6 describes when strong correctness is achievable. It is so powerful that it deserves a fancier name: "
            , HH.strong_ [ HH.text "\"The fundamental theorem of TMA correctness.\"" ]
            ]
        ]
    , Callout.danger "The Catch"
        [ HH.p_
            [ HH.text "NVIDIA documented when strong correctness is "
            , HH.strong_ [ HH.text "impossible" ]
            , HH.text ". And their stack doesn't always enforce these constraints as types. That's what we're fixing."
            ]
        ]
    , Callout.tip "Tools of the Blade"
        [ HH.p_ [ HH.strong_ [ HH.text "Lean 4" ], HH.text " for the proofs. The polyhedral model is lattices and affine spaces." ]
        , HH.p_ [ HH.strong_ [ HH.text "Haskell" ], HH.text " for the glue. Algebraic data types for CuTe layouts." ]
        , HH.p_ [ HH.strong_ [ HH.text "The blade" ], HH.text " for everything else." ]
        ]
    ]
