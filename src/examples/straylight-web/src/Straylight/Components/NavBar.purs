-- | Ultraviolence Navigation Bar
-- | // villa straylight // [← back] █ STATUS
module Straylight.Components.NavBar
  ( navBar
  ) where

import Prelude

import Data.Maybe (Maybe(..), fromMaybe)
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

import Straylight.Components.StatusBlock as Status

-- | Navigation bar
-- | logo: displayed in center with // delimiters
-- | backHref: optional back link
-- | status: optional status indicator
navBar 
  :: forall w i
   . { logo :: String
     , backHref :: Maybe String
     , backLabel :: Maybe String  
     , status :: Maybe Status.StatusVariant
     }
  -> HH.HTML w i
navBar opts =
  HH.nav
    [ HP.class_ (HH.ClassName "uv-nav") ]
    [ HH.span
        [ HP.class_ (HH.ClassName "uv-nav-logo") ]
        [ HH.text opts.logo ]
    , case opts.backHref of
        Nothing -> HH.text ""
        Just href -> 
          HH.a
            [ HP.href href ]
            [ HH.text ("← " <> fromMaybe "back" opts.backLabel) ]
    , case opts.status of
        Nothing -> HH.text ""
        Just s -> Status.status s
    ]
