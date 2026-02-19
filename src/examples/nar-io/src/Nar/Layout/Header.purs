-- | Nar.io Header Component
module Nar.Layout.Header where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Nullable (toMaybe)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import Nar.UI (cls, svgNS)
import Nar.Auth (AuthState(..), ClerkUser, signIn, signUp, signOut, openUserProfile)

-- ============================================================
-- TYPES
-- ============================================================

type State =
  { mobileMenuOpen :: Boolean
  , userMenuOpen :: Boolean
  , auth :: AuthState
  }

data Action
  = ToggleMobileMenu
  | ToggleUserMenu
  | SignIn
  | SignUp
  | SignOut
  | OpenProfile
  | Receive Input

type Input = 
  { currentPath :: String
  , auth :: AuthState
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
      , receive = Just <<< Receive
      }
  }

initialState :: Input -> State
initialState input =
  { mobileMenuOpen: false
  , userMenuOpen: false
  , auth: input.auth
  }

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action () o m Unit
handleAction = case _ of
  ToggleMobileMenu -> 
    H.modify_ \s -> s { mobileMenuOpen = not s.mobileMenuOpen, userMenuOpen = false }
  
  ToggleUserMenu ->
    H.modify_ \s -> s { userMenuOpen = not s.userMenuOpen }
  
  SignIn -> liftEffect signIn
  
  SignUp -> liftEffect signUp
  
  SignOut -> do
    H.modify_ _ { userMenuOpen = false }
    liftAff signOut
  
  OpenProfile -> do
    H.modify_ _ { userMenuOpen = false }
    liftEffect openUserProfile
  
  Receive input ->
    H.modify_ _ { auth = input.auth }

-- ============================================================
-- RENDER
-- ============================================================

render :: forall m. MonadAff m => State -> H.ComponentHTML Action () m
render state =
  HH.header
    [ cls [ "sticky top-0 z-50 bg-background/95 backdrop-blur border-b border-border" ] ]
    [ HH.div
        [ cls [ "max-w-[1100px] mx-auto px-6 py-4" ] ]
        [ HH.div
            [ cls [ "flex justify-between items-center" ] ]
            [ -- Logo
              HH.a
                [ HP.href "/"
                , cls [ "flex items-center gap-2 text-text font-bold text-xl hover:text-primary transition-colors" ]
                ]
                [ HH.span [ cls [ "text-primary" ] ] [ HH.text ">" ]
                , HH.text "nar.io"
                ]
              
              -- Desktop Nav
            , HH.nav
                [ cls [ "hidden md:flex items-center gap-8" ] ]
                (publicNavLinks <> authNavLinks state)
              
              -- Auth / User Menu
            , HH.div
                [ cls [ "hidden md:flex items-center gap-4" ] ]
                [ renderAuthSection state ]
              
              -- Mobile menu button
            , HH.button
                [ cls [ "md:hidden p-2 cursor-pointer text-text" ]
                , HE.onClick \_ -> ToggleMobileMenu
                , HP.type_ HP.ButtonButton
                ]
                [ if state.mobileMenuOpen then closeIcon else menuIcon ]
            ]
          
          -- Mobile menu
        , if state.mobileMenuOpen then mobileMenu state else HH.text ""
        ]
    ]

publicNavLinks :: forall m. Array (H.ComponentHTML Action () m)
publicNavLinks =
  [ navLink "/" "Home"
  , navLink "/pricing" "Pricing"
  , navLink "/docs" "Docs"
  , externalLink "https://github.com/straylight-software/nix-serve-cas" "GitHub"
  ]

authNavLinks :: forall m. State -> Array (H.ComponentHTML Action () m)
authNavLinks state = case state.auth of
  SignedIn _ _ ->
    [ navLink "/dashboard" "Dashboard" ]
  _ -> []

renderAuthSection :: forall m. MonadAff m => State -> H.ComponentHTML Action () m
renderAuthSection state = case state.auth of
  Loading ->
    HH.div [ cls [ "w-8 h-8 bg-muted rounded-full animate-pulse" ] ] []
  
  SignedOut ->
    HH.div
      [ cls [ "flex items-center gap-3" ] ]
      [ HH.button
          [ cls [ "text-muted-foreground text-sm hover:text-text transition-colors cursor-pointer" ]
          , HE.onClick \_ -> SignIn
          , HP.type_ HP.ButtonButton
          ]
          [ HH.text "Log in" ]
      , HH.button
          [ cls [ "px-4 py-2 bg-primary text-background text-sm font-medium rounded-md hover:bg-primary/90 transition-colors cursor-pointer" ]
          , HE.onClick \_ -> SignUp
          , HP.type_ HP.ButtonButton
          ]
          [ HH.text "Get Started" ]
      ]
  
  SignedIn user _ ->
    HH.div
      [ cls [ "relative" ] ]
      [ HH.button
          [ cls [ "flex items-center gap-2 cursor-pointer" ]
          , HE.onClick \_ -> ToggleUserMenu
          , HP.type_ HP.ButtonButton
          ]
          [ HH.img
              [ HP.src user.imageUrl
              , HP.alt "Profile"
              , cls [ "w-8 h-8 rounded-full" ]
              ]
          , HH.span [ cls [ "text-sm text-text" ] ] [ HH.text $ displayName user ]
          , chevronIcon
          ]
      , if state.userMenuOpen then userMenu else HH.text ""
      ]

displayName :: ClerkUser -> String
displayName user = 
  case toMaybe user.firstName of
    Just name -> name
    Nothing -> case toMaybe user.username of
      Just uname -> uname
      Nothing -> "User"

userMenu :: forall m. MonadAff m => H.ComponentHTML Action () m
userMenu =
  HH.div
    [ cls [ "absolute right-0 top-full mt-2 w-48 bg-card border border-border rounded-lg shadow-lg py-1 z-50" ] ]
    [ menuLink "/dashboard" "Dashboard"
    , menuLink "/settings" "Settings"
    , HH.hr [ cls [ "my-1 border-border" ] ]
    , HH.button
        [ cls [ "w-full text-left px-4 py-2 text-sm text-muted-foreground hover:text-text hover:bg-muted/50 cursor-pointer" ]
        , HE.onClick \_ -> OpenProfile
        , HP.type_ HP.ButtonButton
        ]
        [ HH.text "Edit Profile" ]
    , HH.button
        [ cls [ "w-full text-left px-4 py-2 text-sm text-danger hover:bg-danger/10 cursor-pointer" ]
        , HE.onClick \_ -> SignOut
        , HP.type_ HP.ButtonButton
        ]
        [ HH.text "Sign Out" ]
    ]

menuLink :: forall w i. String -> String -> HH.HTML w i
menuLink href label =
  HH.a
    [ HP.href href
    , cls [ "block px-4 py-2 text-sm text-muted-foreground hover:text-text hover:bg-muted/50" ]
    ]
    [ HH.text label ]

-- ============================================================
-- MOBILE MENU
-- ============================================================

mobileMenu :: forall m. MonadAff m => State -> H.ComponentHTML Action () m
mobileMenu state =
  HH.div
    [ cls [ "md:hidden py-4 border-t border-border mt-4" ] ]
    [ HH.div
        [ cls [ "flex flex-col gap-4" ] ]
        ( [ navLink "/" "Home"
          , navLink "/pricing" "Pricing"
          , navLink "/docs" "Docs"
          , externalLink "https://github.com/straylight-software/nix-serve-cas" "GitHub"
          ] <> mobileAuthLinks state
        )
    ]

mobileAuthLinks :: forall m. MonadAff m => State -> Array (H.ComponentHTML Action () m)
mobileAuthLinks state = case state.auth of
  SignedIn _ _ ->
    [ HH.hr [ cls [ "border-border" ] ]
    , navLink "/dashboard" "Dashboard"
    , navLink "/settings" "Settings"
    , HH.button
        [ cls [ "text-left text-sm text-danger cursor-pointer" ]
        , HE.onClick \_ -> SignOut
        , HP.type_ HP.ButtonButton
        ]
        [ HH.text "Sign Out" ]
    ]
  _ ->
    [ HH.hr [ cls [ "border-border" ] ]
    , HH.button
        [ cls [ "text-left text-sm text-muted-foreground cursor-pointer" ]
        , HE.onClick \_ -> SignIn
        , HP.type_ HP.ButtonButton
        ]
        [ HH.text "Log in" ]
    , HH.button
        [ cls [ "text-center px-4 py-2 bg-primary text-background text-sm font-medium rounded-md cursor-pointer" ]
        , HE.onClick \_ -> SignUp
        , HP.type_ HP.ButtonButton
        ]
        [ HH.text "Get Started" ]
    ]

-- ============================================================
-- LINKS
-- ============================================================

navLink :: forall w i. String -> String -> HH.HTML w i
navLink href label =
  HH.a
    [ HP.href href
    , cls [ "text-muted-foreground text-sm hover:text-text transition-colors" ]
    ]
    [ HH.text label ]

externalLink :: forall w i. String -> String -> HH.HTML w i
externalLink href label =
  HH.a
    [ HP.href href
    , HP.target "_blank"
    , HP.rel "noopener noreferrer"
    , cls [ "text-muted-foreground text-sm hover:text-text transition-colors" ]
    ]
    [ HH.text label ]

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

chevronIcon :: forall w i. HH.HTML w i
chevronIcon =
  HH.elementNS svgNS (HH.ElemName "svg")
    [ cls [ "w-4 h-4 text-muted-foreground" ]
    , HP.attr (HH.AttrName "fill") "none"
    , HP.attr (HH.AttrName "stroke") "currentColor"
    , HP.attr (HH.AttrName "viewBox") "0 0 24 24"
    ]
    [ HH.elementNS svgNS (HH.ElemName "path")
        [ HP.attr (HH.AttrName "stroke-linecap") "round"
        , HP.attr (HH.AttrName "stroke-linejoin") "round"
        , HP.attr (HH.AttrName "stroke-width") "2"
        , HP.attr (HH.AttrName "d") "M19 9l-7 7-7-7"
        ]
        []
    ]
