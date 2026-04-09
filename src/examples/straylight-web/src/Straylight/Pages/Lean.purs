-- | Lean Proof Viewer - VillaStraylight.lean with syntax highlighting
module Straylight.Pages.Lean where

import Prelude

import Data.Maybe (Maybe(..))
import Effect.Aff (Aff)
import Effect.Aff.Class (class MonadAff, liftAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Straylight.UI (cls)
import Straylight.Pages.Lean.Highlight (highlightLean)

-- ============================================================
-- COMPONENT
-- ============================================================

type State = 
  { content :: String
  , loading :: Boolean
  }

data Action = Initialize | SetContent String

leanPage :: forall q i o m. MonadAff m => H.Component q i o m
leanPage = H.mkComponent
  { initialState: const { content: "", loading: true }
  , render
  , eval: H.mkEval $ H.defaultEval 
      { handleAction = handleAction
      , initialize = Just Initialize
      }
  }

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Initialize -> do
    content <- liftAff fetchLeanFile
    H.modify_ _ { content = content, loading = false }
  SetContent content -> 
    H.modify_ _ { content = content }

foreign import fetchLeanFile :: Aff String

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div_
    [ HH.div
        [ cls [ "mb-6" ] ]
        [ HH.h1 
            [ cls [ "text-xl font-medium text-text mb-2" ] ]
            [ HH.text "VillaStraylight.lean" ]
        , HH.p 
            [ cls [ "text-muted-foreground text-sm" ] ]
            [ HH.text "21 theorems from nvfuser. 0 sorry. 1575 lines of Lean 4." ]
        ]
    , if state.loading
        then HH.div [ cls [ "text-muted-foreground" ] ] [ HH.text "loading..." ]
        else HH.div
          [ cls [ "bg-[#0d1117] border border-border rounded overflow-x-auto" ] ]
          [ HH.pre
              [ cls [ "p-4 text-[0.8rem] leading-relaxed font-mono" ] ]
              [ HH.code
                  [ HP.attr (HH.AttrName "id") "lean-code"
                  , cls [ "language-lean4" ]
                  ]
                  (highlightLean state.content)
              ]
          ]
    , HH.div
        [ cls [ "mt-4 text-sm" ] ]
        [ HH.a
            [ HP.href "/assets/VillaStraylight.lean"
            , HP.attr (HH.AttrName "download") ""
            , cls [ "text-primary hover:underline" ]
            ]
            [ HH.text "download raw" ]
        ]
    ]
