-- | Footer Component
module Straylight.Layout.Footer where

import Prelude

import Data.Array (length, (!!))
import Data.Maybe (Maybe(..), fromMaybe)
import Effect (Effect)
import Effect.Aff (Milliseconds(..))
import Effect.Aff as Aff
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS

import Straylight.UI (cls)

-- ============================================================
-- FFI
-- ============================================================

foreign import setIntervalImpl :: Int -> Effect Unit -> Effect Int
foreign import clearIntervalImpl :: Int -> Effect Unit

-- ============================================================
-- QUOTES
-- ============================================================

quotes :: Array String
quotes =
  [ "the mythform is usually encountered in one of two modes. one mode assumes that the cyberspace matrix is inhabited, or perhaps visited, by entities whose characteristics correspond with the primary mythoform of a hidden people."
  , "it was the style that mattered and the style was the same. the moderns were mercenaries, practical jokers, nihilistic technofetishists."
  , "all the speed he took, all the turns he'd taken and the corners he'd cut in night city, and still he'd see the matrix in his sleep, bright lattices of logic unfolding across that colorless void..."
  , "mirrors, someone had once said, were in some way essentially unwholesome. constructs were more so, she decided."
  , "power, in case's world, meant corporate power. the zaibatsus, the multinationals that shaped the course of human history, had transcended old barriers."
  , "you're always building models. stone circles. cathedrals. pipe-organs. adding machines. i got no idea why i'm here now."
  , "a gothic folly. endless series of chambers linked by passages, by stairwells vaulted like intestines."
  , "senior is wealthy. senior enjoys any number of means of manifestation."
  , "and arranged to become a patron of the aeschmann collection. the aeschmann collection was restricted to the work of psychotics."
  , "he'd always imagined it as a gradual and willing accommodation of the machine, the parent organism."
  , "well it feels like i am, kid, but i'm really just a bunch of rom."
  ]

-- ============================================================
-- TYPES
-- ============================================================

type State = { quoteIndex :: Int, fade :: Boolean }

data Action 
  = Initialize
  | Tick

-- ============================================================
-- COMPONENT
-- ============================================================

footer :: forall q o m. MonadAff m => H.Component q Unit o m
footer = H.mkComponent
  { initialState: const { quoteIndex: 0, fade: true }
  , render
  , eval: H.mkEval H.defaultEval 
      { handleAction = handleAction
      , initialize = Just Initialize
      }
  }

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Initialize -> do
    { emitter, listener } <- liftEffect HS.create
    _ <- liftEffect $ setIntervalImpl 8000 (HS.notify listener Tick)
    void $ H.subscribe emitter
  
  Tick -> do
    -- Fade out
    H.modify_ _ { fade = false }
    -- Wait for CSS transition
    liftAff $ Aff.delay (Milliseconds 300.0)
    -- Change quote and fade in
    H.modify_ \s -> s 
      { quoteIndex = (s.quoteIndex + 1) `mod` length quotes
      , fade = true 
      }

-- ============================================================
-- RENDER
-- ============================================================

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.footer
    [ cls [ "border-t border-border py-12" ] ]
    [ HH.div
        [ cls [ "max-w-[900px] mx-auto px-8 text-right" ] ]
        [ -- Rotating quote
          HH.p
            [ cls [ "italic text-base02 text-[0.85rem] transition-opacity duration-300"
                  , if state.fade then "opacity-100" else "opacity-0"
                  ]
            ]
            [ HH.text $ fromMaybe "" (quotes !! state.quoteIndex) ]
        
          -- Links
        , HH.div
            [ cls [ "mt-4 text-[0.85rem]" ] ]
            [ footerLink "https://github.com/straylight-software" "github"
            , footerLink "https://weyl.ai" "weyl.ai"
            , footerLink "https://fleek.sh" "fleek.sh"
            ]
        ]
    ]

footerLink :: forall w i. String -> String -> HH.HTML w i
footerLink href label =
  HH.a
    [ HP.href href
    , HP.target "_blank"
    , HP.rel "noopener noreferrer"
    , cls [ "text-muted-foreground hover:text-text transition-colors ml-6 link-float inline-block" ]
    ]
    [ HH.text label ]
