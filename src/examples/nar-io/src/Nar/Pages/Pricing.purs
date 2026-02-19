-- | Nar.io Pricing Page
module Nar.Pages.Pricing where

import Prelude

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Nar.UI (cls, pricingCard)

-- ============================================================
-- COMPONENT
-- ============================================================

pricingPage :: forall q i o m. H.Component q i o m
pricingPage = H.mkComponent
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
    , plans
    , faq
    , enterprise
    ]

-- ============================================================
-- HERO
-- ============================================================

hero :: forall w i. HH.HTML w i
hero =
  HH.section
    [ cls [ "py-24" ] ]
    [ HH.div
        [ cls [ "max-w-[1100px] mx-auto px-6 text-center" ] ]
        [ HH.h1
            [ cls [ "text-4xl md:text-5xl font-bold text-text mb-6" ] ]
            [ HH.text "Simple, honest pricing" ]
        , HH.p
            [ cls [ "text-xl text-muted-foreground max-w-2xl mx-auto" ] ]
            [ HH.text "Pay for what you use. No hidden fees. No surprise bills. Cancel anytime." ]
        ]
    ]

-- ============================================================
-- PLANS
-- ============================================================

plans :: forall w i. HH.HTML w i
plans =
  HH.section
    [ cls [ "pb-24" ] ]
    [ HH.div
        [ cls [ "max-w-[1100px] mx-auto px-6" ] ]
        [ HH.div
            [ cls [ "grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6" ] ]
            [ pricingCard
                { name: "Free"
                , price: "$0"
                , period: "/month"
                , description: "For personal projects and experiments."
                , features:
                    [ "5GB storage"
                    , "50GB transfer/month"
                    , "1 private cache"
                    , "Community support"
                    , "Public caches unlimited"
                    ]
                , cta: "Get started"
                , ctaHref: "/signup"
                , highlighted: false
                }
            , pricingCard
                { name: "Pro"
                , price: "$10"
                , period: "/month"
                , description: "For individual developers and small projects."
                , features:
                    [ "100GB storage"
                    , "500GB transfer/month"
                    , "5 private caches"
                    , "Email support"
                    , "Webhook notifications"
                    , "Cache analytics"
                    ]
                , cta: "Start free trial"
                , ctaHref: "/signup?plan=pro"
                , highlighted: true
                }
            , pricingCard
                { name: "Team"
                , price: "$25"
                , period: "/month"
                , description: "For teams shipping production software."
                , features:
                    [ "500GB storage"
                    , "2TB transfer/month"
                    , "Unlimited private caches"
                    , "5 team seats included"
                    , "Priority support"
                    , "SSO/SAML"
                    , "Audit logs"
                    ]
                , cta: "Start free trial"
                , ctaHref: "/signup?plan=team"
                , highlighted: false
                }
            , pricingCard
                { name: "Enterprise"
                , price: "Custom"
                , period: ""
                , description: "For organizations with compliance needs."
                , features:
                    [ "Unlimited storage"
                    , "Unlimited transfer"
                    , "Unlimited seats"
                    , "Dedicated support"
                    , "SLA guarantee"
                    , "Self-hosted option"
                    , "Custom integrations"
                    ]
                , cta: "Contact sales"
                , ctaHref: "/contact"
                , highlighted: false
                }
            ]
        , HH.p
            [ cls [ "text-center text-muted-foreground text-sm mt-8" ] ]
            [ HH.text "All plans include: Unlimited public caches, REST API access, GitHub Actions integration, Nix flake support" ]
        ]
    ]

-- ============================================================
-- FAQ
-- ============================================================

faq :: forall w i. HH.HTML w i
faq =
  HH.section
    [ cls [ "py-24 border-t border-border" ] ]
    [ HH.div
        [ cls [ "max-w-[800px] mx-auto px-6" ] ]
        [ HH.h2
            [ cls [ "text-2xl font-bold text-text mb-12 text-center" ] ]
            [ HH.text "Frequently asked questions" ]
        , HH.div
            [ cls [ "space-y-8" ] ]
            [ faqItem 
                "How does content-addressed storage reduce costs?"
                "Traditional caches store every NAR file separately. CAS deduplicates at the chunk level - if two derivations share dependencies, we only store the unique parts once. Most teams see 70-90% storage reduction."
            , faqItem
                "Can I migrate from Cachix?"
                "Yes. Our CLI includes a migration command that pulls your existing cache and re-uploads to nar.io. Zero downtime, usually under an hour."
            , faqItem
                "What happens if I exceed my limits?"
                "We don't cut you off. You'll get a notification and we'll work with you to either upgrade or optimize. No surprise bills."
            , faqItem
                "Is the server really open source?"
                "Yes, MIT licensed. nix-serve-cas is on GitHub. You can self-host on your own infrastructure, or use our managed service."
            , faqItem
                "Do you support private caches?"
                "Yes, all paid plans include private caches with fine-grained access control. Free tier includes 1 private cache."
            ]
        ]
    ]

faqItem :: forall w i. String -> String -> HH.HTML w i
faqItem question answer =
  HH.div_
    [ HH.h3
        [ cls [ "text-text font-medium mb-2" ] ]
        [ HH.text question ]
    , HH.p
        [ cls [ "text-muted-foreground" ] ]
        [ HH.text answer ]
    ]

-- ============================================================
-- ENTERPRISE
-- ============================================================

enterprise :: forall w i. HH.HTML w i
enterprise =
  HH.section
    [ cls [ "py-24 border-t border-border" ] ]
    [ HH.div
        [ cls [ "max-w-[800px] mx-auto px-6 text-center" ] ]
        [ HH.h2
            [ cls [ "text-2xl font-bold text-text mb-4" ] ]
            [ HH.text "Need something custom?" ]
        , HH.p
            [ cls [ "text-muted-foreground mb-8" ] ]
            [ HH.text "We work with enterprises on custom deployments, SLAs, and integrations. Let's talk." ]
        , HH.a
            [ HP.href "mailto:enterprise@nar.io"
            , cls [ "inline-flex items-center justify-center px-6 py-3 bg-primary text-background font-medium rounded-md hover:bg-primary/90 transition-colors" ]
            ]
            [ HH.text "Contact sales" ]
        ]
    ]
