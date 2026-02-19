-- | Nar.io Entry Point
-- | Nix binary cache landing site + admin portal
module Main where

import Prelude

import Data.Const (Const)
import Data.Maybe (Maybe(..))
import Type.Proxy (Proxy(..))
import Effect (Effect)
import Effect.Aff (launchAff_)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.Aff as HA
import Halogen.HTML as HH

import Halogen.Subscription as HS
import Halogen.VDom.Driver (runUI)
import Web.DOM.ParentNode (QuerySelector(..), querySelector)
import Web.HTML (window)
import Web.HTML.HTMLDocument as HTMLDocument
import Web.HTML.HTMLElement as HTMLElement
import Web.HTML.Window (document)
import Web.Event.Event (preventDefault)
import Web.UIEvent.MouseEvent (MouseEvent, toEvent)

import Nar.UI (cls)
import Nar.Router (Route(..), parseRoute, pushState, getPathname, onPopState, isProtected, isAuthRoute, routeToPath)
import Nar.Auth (AuthState(..), initClerk, getAuthState, onAuthStateChange, signIn)
import Nar.Layout.Header as Header
import Nar.Layout.Footer as Footer
import Nar.Pages.Home as Home
import Nar.Pages.Pricing as Pricing
import Nar.Pages.Docs as Docs
import Nar.Pages.Dashboard as Dashboard
import Nar.Pages.Settings as Settings

-- ============================================================
-- CONFIG
-- ============================================================

-- | Clerk publishable key (safe for frontend - this is NOT a secret)
clerkPublishableKey :: String
clerkPublishableKey = "pk_test_cmFwaWQtd2FzcC04Ny5jbGVyay5hY2NvdW50cy5kZXYk"

-- ============================================================
-- MAIN ENTRY
-- ============================================================

main :: Effect Unit
main = launchAff_ do
  HA.awaitLoad
  doc <- liftEffect $ window >>= document
  let parent = HTMLDocument.toParentNode doc
  mbContainer <- liftEffect $ querySelector (QuerySelector "#nar-app") parent
  case mbContainer >>= HTMLElement.fromElement of
    Nothing -> pure unit
    Just container -> void $ runUI appComponent unit container

-- ============================================================
-- APP COMPONENT
-- ============================================================

type AppState = 
  { route :: Route
  , auth :: AuthState
  }

data AppAction
  = Initialize
  | Navigate Route MouseEvent
  | RouteChanged String
  | AuthChanged

type AppSlots =
  ( header :: H.Slot (Const Void) Void Unit
  , footer :: H.Slot (Const Void) Void Unit
  , home :: H.Slot (Const Void) Void Unit
  , pricing :: H.Slot (Const Void) Void Unit
  , docs :: H.Slot (Const Void) Void Unit
  , dashboard :: H.Slot (Const Void) Void Unit
  , settings :: H.Slot (Const Void) Void Unit
  )

_header :: Proxy "header"
_header = Proxy

_footer :: Proxy "footer"
_footer = Proxy

_home :: Proxy "home"
_home = Proxy

_pricing :: Proxy "pricing"
_pricing = Proxy

_docs :: Proxy "docs"
_docs = Proxy

_dashboard :: Proxy "dashboard"
_dashboard = Proxy

_settings :: Proxy "settings"
_settings = Proxy

appComponent :: forall q i o m. MonadAff m => H.Component q i o m
appComponent = H.mkComponent
  { initialState: const { route: Home, auth: Loading }
  , render
  , eval: H.mkEval H.defaultEval
      { handleAction = handleAction
      , initialize = Just Initialize
      }
  }

handleAction :: forall o m. MonadAff m => AppAction -> H.HalogenM AppState AppAction AppSlots o m Unit
handleAction = case _ of
  Initialize -> do
    -- Initialize Clerk
    liftAff $ initClerk clerkPublishableKey
    
    -- Get initial auth state
    authState <- liftEffect getAuthState
    H.modify_ _ { auth = authState }
    
    -- Get initial route
    path <- liftEffect getPathname
    let route = parseRoute path
    
    -- Redirect if needed
    case authState of
      SignedIn _ _ -> 
        -- If signed in and on auth route, go to dashboard
        if isAuthRoute route
          then do
            liftEffect $ pushState "/dashboard"
            H.modify_ _ { route = Dashboard }
          else H.modify_ _ { route = route }
      _ ->
        -- If not signed in and on protected route, go to login
        if isProtected route
          then do
            liftEffect $ pushState "/login"
            H.modify_ _ { route = Login }
          else H.modify_ _ { route = route }
    
    -- Subscribe to popstate
    { emitter: routeEmitter, listener: routeListener } <- liftEffect HS.create
    liftEffect $ onPopState (\p -> HS.notify routeListener (RouteChanged p))
    void $ H.subscribe routeEmitter
    
    -- Subscribe to auth state changes
    { emitter: authEmitter, listener: authListener } <- liftEffect HS.create
    _ <- liftEffect $ onAuthStateChange (HS.notify authListener AuthChanged)
    void $ H.subscribe authEmitter
  
  Navigate route event -> do
    liftEffect $ preventDefault (toEvent event)
    state <- H.get
    
    -- Check if route requires auth
    case state.auth of
      SignedIn _ _ -> do
        liftEffect $ pushState $ routeToPath route
        H.modify_ _ { route = route }
      _ ->
        if isProtected route
          then liftEffect signIn
          else do
            liftEffect $ pushState $ routeToPath route
            H.modify_ _ { route = route }
  
  RouteChanged path -> do
    state <- H.get
    let route = parseRoute path
    
    -- Check auth for protected routes
    case state.auth of
      SignedIn _ _ -> H.modify_ _ { route = route }
      _ ->
        if isProtected route
          then do
            liftEffect $ pushState "/login"
            H.modify_ _ { route = Login }
          else H.modify_ _ { route = route }
  
  AuthChanged -> do
    authState <- liftEffect getAuthState
    H.modify_ _ { auth = authState }
    
    state <- H.get
    case authState of
      SignedIn _ _ ->
        -- Redirect to dashboard if on auth page
        when (isAuthRoute state.route) do
          liftEffect $ pushState "/dashboard"
          H.modify_ _ { route = Dashboard }
      SignedOut ->
        -- Redirect to home if on protected page
        when (isProtected state.route) do
          liftEffect $ pushState "/"
          H.modify_ _ { route = Home }
      Loading -> pure unit

render :: forall m. MonadAff m => AppState -> H.ComponentHTML AppAction AppSlots m
render state =
  HH.div
    [ cls [ "min-h-screen bg-background text-muted-foreground" ] ]
    [ HH.slot_ _header unit Header.header 
        { currentPath: routeToPath state.route
        , auth: state.auth 
        }
    , HH.main_
        [ renderPage state ]
    , -- Only show footer on public pages
      if not (isProtected state.route)
        then HH.slot_ _footer unit Footer.footer unit
        else HH.text ""
    ]

renderPage :: forall m. MonadAff m => AppState -> H.ComponentHTML AppAction AppSlots m
renderPage state = case state.route of
  Home -> HH.slot_ _home unit Home.homePage unit
  Pricing -> HH.slot_ _pricing unit Pricing.pricingPage unit
  Docs -> HH.slot_ _docs unit Docs.docsPage unit
  DocsQuickstart -> HH.slot_ _docs unit Docs.docsPage unit
  DocsCli -> HH.slot_ _docs unit Docs.docsPage unit
  DocsApi -> HH.slot_ _docs unit Docs.docsPage unit
  Dashboard -> case state.auth of
    SignedIn user _ -> HH.slot_ _dashboard unit Dashboard.dashboard { user }
    _ -> loadingSpinner
  Settings -> case state.auth of
    SignedIn user _ -> HH.slot_ _settings unit Settings.settings { user }
    _ -> loadingSpinner
  Login -> loginPage
  Signup -> signupPage

loadingSpinner :: forall w i. HH.HTML w i
loadingSpinner =
  HH.div
    [ cls [ "flex items-center justify-center min-h-[60vh]" ] ]
    [ HH.div
        [ cls [ "w-8 h-8 border-2 border-primary border-t-transparent rounded-full animate-spin" ] ]
        []
    ]

loginPage :: forall w i. HH.HTML w i
loginPage =
  HH.div
    [ cls [ "flex flex-col items-center justify-center min-h-[60vh] px-6" ] ]
    [ HH.h1
        [ cls [ "text-2xl font-bold text-text mb-4" ] ]
        [ HH.text "Sign in to nar.io" ]
    , HH.p
        [ cls [ "text-muted-foreground mb-8 text-center max-w-md" ] ]
        [ HH.text "Access your caches, manage API keys, and view usage." ]
    , HH.div
        [ cls [ "space-y-3 w-full max-w-sm" ] ]
        [ authButton "github" "Continue with GitHub"
        , authButton "google" "Continue with Google"
        ]
    ]

signupPage :: forall w i. HH.HTML w i
signupPage =
  HH.div
    [ cls [ "flex flex-col items-center justify-center min-h-[60vh] px-6" ] ]
    [ HH.h1
        [ cls [ "text-2xl font-bold text-text mb-4" ] ]
        [ HH.text "Create your account" ]
    , HH.p
        [ cls [ "text-muted-foreground mb-8 text-center max-w-md" ] ]
        [ HH.text "Get started with 5GB free storage and 50GB transfer." ]
    , HH.div
        [ cls [ "space-y-3 w-full max-w-sm" ] ]
        [ authButton "github" "Sign up with GitHub"
        , authButton "google" "Sign up with Google"
        ]
    ]

authButton :: forall w i. String -> String -> HH.HTML w i
authButton _provider label =
  HH.button
    [ cls [ "w-full flex items-center justify-center gap-3 px-4 py-3 border border-border rounded-md text-text font-medium hover:bg-card transition-colors cursor-pointer" ]
    ]
    [ HH.span_ [ HH.text label ] ]
