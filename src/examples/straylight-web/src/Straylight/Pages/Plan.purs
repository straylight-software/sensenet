-- | .plan Page - Blog index
module Straylight.Pages.Plan where

import Prelude

import Data.Array (filter, head, tail)
import Data.Maybe (Maybe(..), fromMaybe)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Straylight.UI (cls, sectionHeader)

-- ============================================================
-- DATA
-- ============================================================

type Post = 
  { title :: String
  , subtitle :: String
  , date :: String
  , readTime :: String
  , postTags :: Array String
  , href :: String
  , featured :: Boolean
  }

posts :: Array Post
posts =
  [ { title: "The Villa Straylight Papers"
    , subtitle: "Jensen's Razor and the malevolent combinatorics of CUDA architecture. Encoding NVIDIA's theorems as types through Gibson's lens."
    , date: "January 8, 2026"
    , readTime: "13 min"
    , postTags: ["CUDA", "NVIDIA", "Lean", "Formal Methods"]
    , href: "/plan/papers"
    , featured: true
    }
  , { title: "Part I: The Rectilinear Chamber"
    , subtitle: "Layouts, Coordinate Spaces, and the CuTe Contract. The tensor core at the center of the Gothic folly."
    , date: "January 8, 2026"
    , readTime: "5 min"
    , postTags: ["CuTe", "Layouts", "Lean"]
    , href: "/plan/part-1"
    , featured: false
    }
  , { title: "Part II: The Sense/Net Pyramid"
    , subtitle: "Coalescence, Noetherian Reduction, and Why the Gothic Folly Terminates."
    , date: "January 8, 2026"
    , readTime: "4 min"
    , postTags: ["Coalescence", "Termination"]
    , href: "/plan/part-2"
    , featured: false
    }
  , { title: "Part III: Built Him up From Nothing"
    , subtitle: "Complementation, the FTTC, and the Holes in Your Iteration Space. The theorem that should terrify you."
    , date: "January 8, 2026"
    , readTime: "4 min"
    , postTags: ["FTTC", "TMA", "Holes"]
    , href: "/plan/part-3"
    , featured: false
    }
  , { title: "Part IV: Take Your Word, Thief"
    , subtitle: "Composition, the Tensor Core Cathedral, and Jensen's Razor. Never attribute to search what can be proven by construction."
    , date: "January 8, 2026"
    , readTime: "5 min"
    , postTags: ["razorgirl", "Composition"]
    , href: "/plan/part-4"
    , featured: false
    }
  ]

-- ============================================================
-- COMPONENT
-- ============================================================

planPage :: forall q i o m. H.Component q i o m
planPage = H.mkComponent
  { initialState: const unit
  , render: const render
  , eval: H.mkEval H.defaultEval
  }

render :: forall w i. HH.HTML w i
render =
  HH.div_
    [ sectionHeader ".plan"
    , HH.p
        [ cls [ "mb-8 text-muted-foreground" ] ]
        [ HH.text "it doesn't matter who we are. what matters is our .plan" ]
    
    -- Featured post
    , case featuredPost of
        Just post -> featuredCard post
        Nothing -> HH.text ""
    
    , HH.hr [ cls [ "uv-hr" ] ]
    
    -- Other posts
    , HH.div
        [ cls [ "flex flex-col gap-4" ] ]
        (map postCard otherPosts)
    ]
  where
  featuredPost = head (filter _.featured posts)
  otherPosts = filter (not <<< _.featured) posts

featuredCard :: forall w i. Post -> HH.HTML w i
featuredCard post =
  HH.a
    [ HP.href post.href
    , cls [ "block mb-8 group" ]
    ]
    [ HH.div
        [ cls [ "bg-card border border-border p-6 hover:border-primary transition-colors" ] ]
        [ HH.div
            [ cls [ "flex items-center gap-2 mb-3" ] ]
            [ HH.span 
                [ cls [ "text-[0.7rem] text-primary uppercase tracking-wider" ] ] 
                [ HH.text "Featured" ]
            , HH.span 
                [ cls [ "text-[0.7rem] text-muted-foreground" ] ] 
                [ HH.text (post.date <> " // " <> post.readTime) ]
            ]
        , HH.h2
            [ cls [ "text-text text-[1.5rem] font-medium mb-2 group-hover:text-primary transition-colors" ] ]
            [ HH.text post.title ]
        , HH.p
            [ cls [ "text-muted-foreground mb-4" ] ]
            [ HH.text post.subtitle ]
        , HH.div
            [ cls [ "flex flex-wrap gap-2" ] ]
            (map postTag post.postTags)
        ]
    ]

postCard :: forall w i. Post -> HH.HTML w i
postCard post =
  HH.a
    [ HP.href post.href
    , cls [ "block p-4 bg-card border-l-4 border-l-primary hover:border-l-status transition-colors group" ]
    ]
    [ HH.div
        [ cls [ "flex items-baseline justify-between mb-1" ] ]
        [ HH.div
            [ cls [ "text-text font-medium group-hover:text-primary transition-colors" ] ]
            [ HH.text post.title ]
        , HH.div
            [ cls [ "text-[0.75rem] text-muted-foreground" ] ]
            [ HH.text post.date ]
        ]
    , HH.div
        [ cls [ "text-[0.85rem] text-muted-foreground mb-2" ] ]
        [ HH.text post.subtitle ]
    , HH.div
        [ cls [ "flex flex-wrap gap-2" ] ]
        (map postTag post.postTags)
    ]

postTag :: forall w i. String -> HH.HTML w i
postTag t =
  HH.span
    [ cls [ "text-[0.7rem] text-primary/70" ] ]
    [ HH.text ("// " <> t) ]
