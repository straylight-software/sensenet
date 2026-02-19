-- | Nar.io Landing Page
module Nar.Pages.Home where

import Prelude

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Nar.UI (cls, primaryButton, secondaryButton, featureCard, codeBlock, codeLine, comparisonRow)

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
    , features
    , comparison
    , quickstart
    , cta
    ]

-- ============================================================
-- HERO
-- ============================================================

hero :: forall w i. HH.HTML w i
hero =
  HH.section
    [ cls [ "py-24 md:py-32" ] ]
    [ HH.div
        [ cls [ "max-w-[1100px] mx-auto px-6 text-center" ] ]
        [ -- Badge
          HH.div
            [ cls [ "inline-flex items-center gap-2 px-3 py-1 bg-primary/10 border border-primary/20 rounded-full text-primary text-sm mb-8" ] ]
            [ HH.span [ cls [ "w-2 h-2 bg-primary rounded-full animate-pulse" ] ] []
            , HH.text "Now in public beta"
            ]
          
          -- Headline
        , HH.h1
            [ cls [ "text-4xl md:text-6xl font-bold text-text mb-6 leading-tight" ] ]
            [ HH.text "Nix binary cache"
            , HH.br_
            , HH.text "that doesn't "
            , HH.span [ cls [ "text-primary" ] ] [ HH.text "suck" ]
            ]
          
          -- Subheadline
        , HH.p
            [ cls [ "text-xl text-muted-foreground mb-10 max-w-2xl mx-auto" ] ]
            [ HH.text "10x cheaper than Cachix. Content-addressed storage means you only pay for unique bytes. Edge distribution. Actually open source." ]
          
          -- CTAs
        , HH.div
            [ cls [ "flex flex-col sm:flex-row items-center justify-center gap-4" ] ]
            [ primaryButton "/signup" "Start for free"
            , secondaryButton "/docs" "Read the docs"
            ]
          
          -- Social proof placeholder
        , HH.p
            [ cls [ "mt-12 text-sm text-muted-foreground" ] ]
            [ HH.text "Trusted by teams shipping with Nix" ]
        ]
    ]

-- ============================================================
-- FEATURES
-- ============================================================

features :: forall w i. HH.HTML w i
features =
  HH.section
    [ cls [ "py-24 border-t border-border" ] ]
    [ HH.div
        [ cls [ "max-w-[1100px] mx-auto px-6" ] ]
        [ HH.div
            [ cls [ "text-center mb-16" ] ]
            [ HH.h2
                [ cls [ "text-3xl font-bold text-text mb-4" ] ]
                [ HH.text "Why nar.io?" ]
            , HH.p
                [ cls [ "text-muted-foreground max-w-xl mx-auto" ] ]
                [ HH.text "Built by Nix users who got tired of paying too much for too little." ]
            ]
        , HH.div
            [ cls [ "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-6" ] ]
            [ featureCard "$" "10x cheaper" 
                "CAS deduplication means you only store unique content. Most teams see 70-90% storage reduction vs traditional caches."
            , featureCard ">" "Faster builds"
                "Edge distribution via Fly.io. Streaming downloads. Your CI doesn't wait."
            , featureCard "{}" "Actually open source"
                "MIT licensed server. No bait-and-switch. Self-host if you want, or let us run it."
            , featureCard "++" "Multi-tenant"
                "Teams, orgs, granular permissions from day one. Not bolted on later."
            , featureCard "=" "Usage-based pricing"
                "Pay for what you store and transfer. No arbitrary tier limits. No surprise bills."
            , featureCard "!" "NativeLink CAS"
                "Backed by battle-tested content-addressed storage. The same tech powering Google's remote execution."
            ]
        ]
    ]

-- ============================================================
-- COMPARISON
-- ============================================================

comparison :: forall w i. HH.HTML w i
comparison =
  HH.section
    [ cls [ "py-24 border-t border-border" ] ]
    [ HH.div
        [ cls [ "max-w-[900px] mx-auto px-6" ] ]
        [ HH.div
            [ cls [ "text-center mb-16" ] ]
            [ HH.h2
                [ cls [ "text-3xl font-bold text-text mb-4" ] ]
                [ HH.text "vs. Cachix" ]
            , HH.p
                [ cls [ "text-muted-foreground" ] ]
                [ HH.text "The numbers speak for themselves." ]
            ]
        , HH.div
            [ cls [ "overflow-x-auto" ] ]
            [ HH.table
                [ cls [ "w-full" ] ]
                [ HH.thead_
                    [ HH.tr
                        [ cls [ "border-b border-border" ] ]
                        [ HH.th [ cls [ "py-3 text-left text-muted-foreground font-medium" ] ] [ HH.text "" ]
                        , HH.th [ cls [ "py-3 text-center text-primary font-bold" ] ] [ HH.text "nar.io" ]
                        , HH.th [ cls [ "py-3 text-center text-muted-foreground font-medium" ] ] [ HH.text "Cachix" ]
                        ]
                    ]
                , HH.tbody_
                    [ comparisonRow "100GB storage" "$10/mo" "$50/mo"
                    , comparisonRow "500GB transfer" "included" "$25 extra"
                    , comparisonRow "Team seats" "unlimited" "$10/seat"
                    , comparisonRow "Self-host option" "yes (MIT)" "no"
                    , comparisonRow "Edge CDN" "global" "EU only"
                    , comparisonRow "API" "REST + CLI" "CLI only"
                    ]
                ]
            ]
        ]
    ]

-- ============================================================
-- QUICKSTART
-- ============================================================

quickstart :: forall w i. HH.HTML w i
quickstart =
  HH.section
    [ cls [ "py-24 border-t border-border" ] ]
    [ HH.div
        [ cls [ "max-w-[800px] mx-auto px-6" ] ]
        [ HH.div
            [ cls [ "text-center mb-12" ] ]
            [ HH.h2
                [ cls [ "text-3xl font-bold text-text mb-4" ] ]
                [ HH.text "Get started in 30 seconds" ]
            ]
        , codeBlock
            [ codeLine "# " "Install the CLI"
            , codeLine "$ " "nix profile install github:straylight-software/nar-cli"
            , HH.text "\n"
            , codeLine "# " "Authenticate"
            , codeLine "$ " "nar login"
            , HH.text "\n"
            , codeLine "# " "Push your first derivation"
            , codeLine "$ " "nix build .#mypackage | nar push"
            , HH.text "\n"
            , codeLine "# " "Configure as substituter"
            , codeLine "$ " "nar configure --substituter"
            ]
        , HH.div
            [ cls [ "mt-8 text-center" ] ]
            [ HH.a
                [ HP.href "/docs/quickstart"
                , cls [ "text-primary hover:text-primary/80 transition-colors" ]
                ]
                [ HH.text "Full quickstart guide ->" ]
            ]
        ]
    ]

-- ============================================================
-- CTA
-- ============================================================

cta :: forall w i. HH.HTML w i
cta =
  HH.section
    [ cls [ "py-24 border-t border-border" ] ]
    [ HH.div
        [ cls [ "max-w-[800px] mx-auto px-6 text-center" ] ]
        [ HH.h2
            [ cls [ "text-3xl font-bold text-text mb-4" ] ]
            [ HH.text "Ready to stop overpaying?" ]
        , HH.p
            [ cls [ "text-muted-foreground mb-8" ] ]
            [ HH.text "Free tier includes 5GB storage and 50GB transfer. No credit card required." ]
        , HH.div
            [ cls [ "flex flex-col sm:flex-row items-center justify-center gap-4" ] ]
            [ primaryButton "/signup" "Create free account"
            , secondaryButton "/pricing" "See all plans"
            ]
        ]
    ]
