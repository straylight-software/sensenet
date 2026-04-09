-- | Header Component
module Straylight.Layout.Header where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import Straylight.UI (cls, svgNS)

-- ============================================================
-- FFI
-- ============================================================

foreign import setThemeImpl :: String -> Effect Unit
foreign import getStoredThemeImpl :: String -> Effect String

-- ============================================================
-- TYPES
-- ============================================================

type State =
  { mobileMenuOpen :: Boolean
  , themeMenuOpen :: Boolean
  , currentTheme :: String
  , themeLock :: Maybe String
  }

data Action
  = Initialize
  | Receive Input
  | ToggleMobileMenu
  | ToggleThemeMenu
  | SetTheme String

type Input = 
  { currentPath :: String
  , themeLock :: Maybe String  -- Just "ono-memphis" = page locks theme
  }

-- ============================================================
-- COMPONENT
-- ============================================================

header :: forall q o m. MonadAff m => H.Component q Input o m
header = H.mkComponent
  { initialState
  , render
  , eval: H.mkEval H.defaultEval 
      { handleAction = handleAction
      , initialize = Just Initialize
      , receive = Just <<< Receive
      }
  }

initialState :: Input -> State
initialState input =
  { mobileMenuOpen: false
  , themeMenuOpen: false
  , currentTheme: "ono-tuned"
  , themeLock: input.themeLock
  }

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  Initialize -> do
    state <- H.get
    -- If page has theme lock, use that; otherwise use stored preference
    case state.themeLock of
      Just lockedTheme -> do
        liftEffect $ setThemeImpl lockedTheme
        H.modify_ _ { currentTheme = lockedTheme }
      Nothing -> do
        theme <- liftEffect $ getStoredThemeImpl "ono-tuned"
        liftEffect $ setThemeImpl theme
        H.modify_ _ { currentTheme = theme }

  Receive input -> do
    -- Update theme lock when navigating to new page
    H.modify_ _ { themeLock = input.themeLock }
    case input.themeLock of
      Just lockedTheme -> do
        liftEffect $ setThemeImpl lockedTheme
        H.modify_ _ { currentTheme = lockedTheme }
      Nothing -> do
        -- Restore user preference when leaving locked page
        theme <- liftEffect $ getStoredThemeImpl "ono-tuned"
        liftEffect $ setThemeImpl theme
        H.modify_ _ { currentTheme = theme }

  ToggleMobileMenu -> 
    H.modify_ \s -> s { mobileMenuOpen = not s.mobileMenuOpen }
  
  ToggleThemeMenu -> do
    state <- H.get
    -- Don't open theme menu if locked
    case state.themeLock of
      Just _ -> pure unit
      Nothing -> H.modify_ \s -> s { themeMenuOpen = not s.themeMenuOpen }
  
  SetTheme theme -> do
    state <- H.get
    -- Can't change theme if locked
    case state.themeLock of
      Just _ -> pure unit
      Nothing -> do
        liftEffect $ setThemeImpl theme
        H.modify_ _ { currentTheme = theme, themeMenuOpen = false }

-- ============================================================
-- RENDER
-- ============================================================

render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.header
    [ cls [ "sticky top-0 z-50 bg-background border-b border-border" ] ]
    [ HH.div
        [ cls [ "max-w-[900px] mx-auto px-8 py-4" ] ]
        [ HH.div
            [ cls [ "flex justify-between items-center" ] ]
            [ -- Logo / Theme switcher
              themeSwitcher state
              
              -- Desktop Nav
            , HH.nav
                [ cls [ "hidden md:flex items-center gap-6" ] ]
                [ navLink "/plan" ".plan"
                , navLink "/razorgirl" "razorgirl"
                , navLink "/software" "software"
                , externalLink "https://github.com/straylight-software" "github"
                , externalLink "https://tangled.sh/straylight.software" "tangled"
                , navLink "/irc" "irc"
                , navLink "/discord" "discord"
                ]
              
              -- Status indicator
            , HH.div
                [ cls [ "flex items-center gap-2 text-xs text-muted-foreground" ] ]
                [ HH.span [ cls [ "w-2 h-2 bg-status inline-block status-pulse" ] ] []
                , HH.text "NOMINAL"
                ]
              
              -- Mobile menu button
            , HH.button
                [ cls [ "md:hidden p-2 cursor-pointer text-text" ]
                , HE.onClick \_ -> ToggleMobileMenu
                , HP.type_ HP.ButtonButton
                ]
                [ if state.mobileMenuOpen then closeIcon else menuIcon ]
            ]
          
          -- Mobile menu
        , if state.mobileMenuOpen then mobileMenu else HH.text ""
        ]
    ]

-- ============================================================
-- SUB-COMPONENTS
-- ============================================================

themeSwitcher :: forall m. State -> H.ComponentHTML Action () m
themeSwitcher state =
  HH.div
    [ cls [ "relative flex items-center" ] ]
    [ HH.button
        [ cls [ "text-text font-medium text-sm transition-colors geo-hover"
              , case state.themeLock of
                  Just _ -> "cursor-default"
                  Nothing -> "hover:text-primary cursor-pointer"
              ]
        , HE.onClick \_ -> ToggleThemeMenu
        , HP.type_ HP.ButtonButton
        ]
        [ HH.span [ cls [ "text-primary" ] ] [ HH.text "//" ]
        , HH.text " straylight "
        , HH.span [ cls [ "text-primary" ] ] [ HH.text "//" ]
        ]
    , themeLockIndicator state
    , if state.themeMenuOpen then themeMenu state else HH.text ""
    ]

themeLockIndicator :: forall m. State -> H.ComponentHTML Action () m
themeLockIndicator state =
  case state.themeLock of
    Nothing -> HH.text ""
    Just lockedTheme ->
      HH.span
        [ cls [ "ml-4 text-[11px] text-muted-foreground" ] ]
        [ HH.text (themeDisplayName lockedTheme)
        , HH.span [ cls [ "ml-1 text-primary" ] ] [ HH.text "■" ]
        ]

themeDisplayName :: String -> String
themeDisplayName = case _ of
  "ono-tuned" -> "ono-tuned"
  "ono-sprawl" -> "ono-sprawl"
  "ono-memphis" -> "ono-memphis"
  "ono-github" -> "ono-github"
  "maas-neoform" -> "maas-neoform"
  "maas-bioptic" -> "maas-bioptic"
  "maas-ghost" -> "maas-ghost"
  "maas-tessier" -> "maas-tessier"
  other -> other

themeMenu :: forall m. State -> H.ComponentHTML Action () m
themeMenu state =
  HH.div
    [ cls [ "absolute top-full left-0 mt-2 bg-card border border-border p-4 min-w-[320px] z-50 theme-menu" ] ]
    [ HH.div
        [ cls [ "text-[10px] text-muted-foreground uppercase tracking-widest mb-3" ] ]
        [ HH.text "// chromatic series" ]
    
      -- Ono-Sendai Dark
    , HH.div
        [ cls [ "mb-4" ] ]
        [ HH.div
            [ cls [ "text-[9px] text-primary uppercase tracking-wider mb-2 flex items-center gap-2" ] ]
            [ HH.span [ cls [ "w-1.5 h-1.5 bg-primary inline-block" ] ] []
            , HH.text "ONO-SENDAI DARK"
            ]
        , HH.div
            [ cls [ "flex flex-col gap-1" ] ]
            [ themeOption state "ono-tuned" "TUNED" "HSL perceptual / daily driver"
            , themeOption state "ono-sprawl" "SPRAWL" "carbon black / best compromise"
            , themeOption state "ono-memphis" "MEMPHIS" "true black / OLED perfect"
            , themeOption state "ono-github" "GITHUB" "robust default / maximum compat"
            ]
        ]
    
      -- MAAS Light
    , HH.div_
        [ HH.div
            [ cls [ "text-[9px] text-status uppercase tracking-wider mb-2 flex items-center gap-2" ] ]
            [ HH.span [ cls [ "w-1.5 h-1.5 bg-status inline-block" ] ] []
            , HH.text "MAAS BIOLABS LIGHT"
            ]
        , HH.div
            [ cls [ "flex flex-col gap-1" ] ]
            [ themeOption state "maas-neoform" "NEOFORM" "clean room schematics / daily driver"
            , themeOption state "maas-bioptic" "BIOPTIC" "warm cream paper / long reading"
            , themeOption state "maas-ghost" "GHOST" "low contrast / photosensitivity"
            , themeOption state "maas-tessier" "TESSIER" "maximum contrast / clinical QA"
            ]
        ]
    
    , HH.div
        [ cls [ "mt-4 pt-3 border-t border-border" ] ]
        [ HH.div
            [ cls [ "text-[8px] text-muted-foreground uppercase tracking-wider" ] ]
            [ HH.text "211° hue lock / base16 compatible" ]
        ]
    ]

themeOption :: forall m. State -> String -> String -> String -> H.ComponentHTML Action () m
themeOption state themeId name desc =
  HH.button
    [ cls [ "text-left px-2 py-1.5 transition-colors flex items-center justify-between group cursor-pointer"
          , if state.currentTheme == themeId 
              then "bg-primary/10 text-text" 
              else "hover:bg-card text-muted-foreground hover:text-text"
          ]
    , HE.onClick \_ -> SetTheme themeId
    , HP.type_ HP.ButtonButton
    ]
    [ HH.span [ cls [ "text-[11px]" ] ] [ HH.text name ]
    , HH.span [ cls [ "text-[9px] text-muted-foreground group-hover:text-base02" ] ] [ HH.text desc ]
    ]

navLink :: forall w i. String -> String -> HH.HTML w i
navLink href label =
  HH.a
    [ HP.href href
    , cls [ "text-muted-foreground text-[13px] hover:text-text transition-colors link-trace" ]
    ]
    [ HH.text label ]

externalLink :: forall w i. String -> String -> HH.HTML w i
externalLink href label =
  HH.a
    [ HP.href href
    , HP.target "_blank"
    , HP.rel "noopener noreferrer"
    , cls [ "text-muted-foreground text-[13px] hover:text-text transition-colors link-trace" ]
    ]
    [ HH.text label ]

mobileMenu :: forall m. H.ComponentHTML Action () m
mobileMenu =
  HH.div
    [ cls [ "md:hidden py-4 border-t border-border mt-4" ] ]
    [ HH.div
        [ cls [ "flex flex-col gap-4" ] ]
        [ navLink "/plan" ".plan"
        , navLink "/razorgirl" "razorgirl"
        , navLink "/software" "software"
        , externalLink "https://github.com/straylight-software" "github"
        , externalLink "https://tangled.sh/straylight.software" "tangled"
        , navLink "/irc" "irc"
        , navLink "/discord" "discord"
        ]
    ]

-- ============================================================
-- ICONS
-- ============================================================

menuIcon :: forall w i. HH.HTML w i
menuIcon =
  HH.elementNS svgNS (HH.ElemName "svg")
    [ cls [ "w-6 h-6" ]
    , HP.attr (HH.AttrName "fill") "none"
    , HP.attr (HH.AttrName "stroke") "currentColor"
    , HP.attr (HH.AttrName "viewBox") "0 0 24 24"
    ]
    [ HH.elementNS svgNS (HH.ElemName "path")
        [ HP.attr (HH.AttrName "stroke-linecap") "round"
        , HP.attr (HH.AttrName "stroke-linejoin") "round"
        , HP.attr (HH.AttrName "stroke-width") "2"
        , HP.attr (HH.AttrName "d") "M4 6h16M4 12h16M4 18h16"
        ]
        []
    ]

closeIcon :: forall w i. HH.HTML w i
closeIcon =
  HH.elementNS svgNS (HH.ElemName "svg")
    [ cls [ "w-6 h-6" ]
    , HP.attr (HH.AttrName "fill") "none"
    , HP.attr (HH.AttrName "stroke") "currentColor"
    , HP.attr (HH.AttrName "viewBox") "0 0 24 24"
    ]
    [ HH.elementNS svgNS (HH.ElemName "path")
        [ HP.attr (HH.AttrName "stroke-linecap") "round"
        , HP.attr (HH.AttrName "stroke-linejoin") "round"
        , HP.attr (HH.AttrName "stroke-width") "2"
        , HP.attr (HH.AttrName "d") "M6 18L18 6M6 6l12 12"
        ]
        []
    ]
