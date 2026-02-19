-- | Nar.io Docs Page
module Nar.Pages.Docs where

import Prelude

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Nar.UI (cls, codeBlock, codeLine)

-- ============================================================
-- COMPONENT
-- ============================================================

docsPage :: forall q i o m. H.Component q i o m
docsPage = H.mkComponent
  { initialState: const unit
  , render: const render
  , eval: H.mkEval H.defaultEval
  }

-- ============================================================
-- RENDER
-- ============================================================

render :: forall w i. HH.HTML w i
render =
  HH.div
    [ cls [ "max-w-[1100px] mx-auto px-6 py-12" ] ]
    [ HH.div
        [ cls [ "grid grid-cols-1 lg:grid-cols-[250px_1fr] gap-12" ] ]
        [ sidebar
        , content
        ]
    ]

-- ============================================================
-- SIDEBAR
-- ============================================================

sidebar :: forall w i. HH.HTML w i
sidebar =
  HH.nav
    [ cls [ "lg:sticky lg:top-24 lg:self-start" ] ]
    [ HH.div
        [ cls [ "space-y-6" ] ]
        [ sidebarSection "Getting Started"
            [ sidebarLink "/docs" "Overview" true
            , sidebarLink "/docs/quickstart" "Quick Start" false
            , sidebarLink "/docs/installation" "Installation" false
            ]
        , sidebarSection "Guides"
            [ sidebarLink "/docs/nixos" "NixOS Configuration" false
            , sidebarLink "/docs/flakes" "Flakes Integration" false
            , sidebarLink "/docs/github-actions" "GitHub Actions" false
            , sidebarLink "/docs/migration" "Migrate from Cachix" false
            ]
        , sidebarSection "Reference"
            [ sidebarLink "/docs/cli" "CLI Reference" false
            , sidebarLink "/docs/api" "REST API" false
            , sidebarLink "/docs/config" "Configuration" false
            ]
        ]
    ]

sidebarSection :: forall w i. String -> Array (HH.HTML w i) -> HH.HTML w i
sidebarSection title children =
  HH.div_
    [ HH.h3
        [ cls [ "text-xs font-semibold text-muted-foreground uppercase tracking-wider mb-3" ] ]
        [ HH.text title ]
    , HH.ul
        [ cls [ "space-y-1" ] ]
        children
    ]

sidebarLink :: forall w i. String -> String -> Boolean -> HH.HTML w i
sidebarLink href label active =
  HH.li_
    [ HH.a
        [ HP.href href
        , cls [ "block py-1.5 px-3 rounded text-sm transition-colors"
              , if active 
                  then "bg-primary/10 text-primary font-medium" 
                  else "text-muted-foreground hover:text-text hover:bg-card"
              ]
        ]
        [ HH.text label ]
    ]

-- ============================================================
-- CONTENT
-- ============================================================

content :: forall w i. HH.HTML w i
content =
  HH.article
    [ cls [ "prose prose-invert max-w-none" ] ]
    [ HH.h1
        [ cls [ "text-3xl font-bold text-text mb-6" ] ]
        [ HH.text "Documentation" ]
    , HH.p
        [ cls [ "text-lg text-muted-foreground mb-8" ] ]
        [ HH.text "Everything you need to start using nar.io as your Nix binary cache." ]
    
      -- Quick links
    , HH.div
        [ cls [ "grid grid-cols-1 md:grid-cols-2 gap-4 mb-12" ] ]
        [ docCard "/docs/quickstart" "Quick Start" "Get up and running in under a minute."
        , docCard "/docs/migration" "Migrate from Cachix" "Move your existing cache with zero downtime."
        , docCard "/docs/github-actions" "GitHub Actions" "Set up CI caching for your workflows."
        , docCard "/docs/cli" "CLI Reference" "Full command documentation."
        ]
    
      -- Overview section
    , HH.h2
        [ cls [ "text-2xl font-semibold text-text mt-12 mb-4" ] ]
        [ HH.text "What is nar.io?" ]
    , HH.p
        [ cls [ "text-muted-foreground mb-4" ] ]
        [ HH.text "nar.io is a Nix binary cache backed by content-addressed storage (CAS). Unlike traditional Nix caches that store each NAR file separately, nar.io deduplicates at the chunk level - meaning you only pay for unique bytes." ]
    , HH.p
        [ cls [ "text-muted-foreground mb-4" ] ]
        [ HH.text "The server is "
        , HH.code [ cls [ "bg-card px-1.5 py-0.5 rounded text-sm" ] ] [ HH.text "nix-serve-cas" ]
        , HH.text ", an MIT-licensed Nix binary cache implementation. You can self-host it, or use our managed service."
        ]
    
      -- How it works
    , HH.h2
        [ cls [ "text-2xl font-semibold text-text mt-12 mb-4" ] ]
        [ HH.text "How it works" ]
    , HH.ol
        [ cls [ "list-decimal list-inside space-y-2 text-muted-foreground mb-6" ] ]
        [ HH.li_ [ HH.text "You push store paths to nar.io using the CLI or API" ]
        , HH.li_ [ HH.text "We chunk and deduplicate the NAR contents using CAS" ]
        , HH.li_ [ HH.text "Your CI and team members pull from our global edge network" ]
        , HH.li_ [ HH.text "You only pay for unique storage and actual transfer" ]
        ]
    
      -- Example
    , HH.h2
        [ cls [ "text-2xl font-semibold text-text mt-12 mb-4" ] ]
        [ HH.text "Quick example" ]
    , codeBlock
        [ codeLine "# " "Build and push in one command"
        , codeLine "$ " "nix build .#mypackage --json | nar push"
        , HH.text "\n"
        , codeLine "# " "Or push an existing store path"
        , codeLine "$ " "nar push /nix/store/abc123-mypackage"
        , HH.text "\n"
        , codeLine "# " "Configure as a substituter in your flake"
        , HH.span [ cls [ "text-muted-foreground" ] ] [ HH.text "# flake.nix" ]
        , HH.text "\n"
        , HH.span [ cls [ "text-text" ] ] [ HH.text "nixConfig.extra-substituters = [\"https://cache.nar.io/yourorg\"];" ]
        ]
    
      -- Next steps
    , HH.h2
        [ cls [ "text-2xl font-semibold text-text mt-12 mb-4" ] ]
        [ HH.text "Next steps" ]
    , HH.ul
        [ cls [ "list-disc list-inside space-y-2 text-muted-foreground" ] ]
        [ HH.li_ 
            [ HH.a 
                [ HP.href "/docs/quickstart"
                , cls [ "text-primary hover:text-primary/80" ]
                ] 
                [ HH.text "Follow the quickstart guide" ]
            , HH.text " to set up your first cache"
            ]
        , HH.li_
            [ HH.text "Configure "
            , HH.a 
                [ HP.href "/docs/github-actions"
                , cls [ "text-primary hover:text-primary/80" ]
                ] 
                [ HH.text "GitHub Actions" ]
            , HH.text " for CI caching"
            ]
        , HH.li_
            [ HH.text "Check out the "
            , HH.a 
                [ HP.href "/docs/api"
                , cls [ "text-primary hover:text-primary/80" ]
                ] 
                [ HH.text "REST API" ]
            , HH.text " for programmatic access"
            ]
        ]
    ]

docCard :: forall w i. String -> String -> String -> HH.HTML w i
docCard href title description =
  HH.a
    [ HP.href href
    , cls [ "block p-4 bg-card border border-border rounded-lg hover:border-primary/50 transition-colors" ]
    ]
    [ HH.h3
        [ cls [ "text-text font-medium mb-1" ] ]
        [ HH.text title ]
    , HH.p
        [ cls [ "text-muted-foreground text-sm" ] ]
        [ HH.text description ]
    ]
