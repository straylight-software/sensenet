-- | Nar.io Dashboard Page
-- | Main admin portal for cache management
module Nar.Pages.Dashboard where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Nullable (toMaybe)
import Effect.Aff.Class (class MonadAff)

import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Type.Proxy (Proxy(..))

import Radix.Pure.Tabs as Tabs

import Nar.UI (cls, codeBlock, codeLine, modalOverlay, modalContent, modalHeader, modalFooter, formField)
import Nar.Auth (ClerkUser)

-- ============================================================
-- TYPES
-- ============================================================

type Input = { user :: ClerkUser }

type State =
  { user :: ClerkUser
  , activeTab :: String
  , showNewKeyModal :: Boolean
  , newKeyName :: String
  , createdKey :: Maybe String
  }

type Slots =
  ( tabs :: Tabs.Slot Unit
  )

_tabs :: Proxy "tabs"
_tabs = Proxy

data Action
  = HandleTabsOutput Tabs.Output
  | OpenNewKeyModal
  | CloseNewKeyModal
  | SetNewKeyName String
  | CreateApiKey

-- ============================================================
-- COMPONENT
-- ============================================================

dashboard :: forall q o m. MonadAff m => H.Component q Input o m
dashboard = H.mkComponent
  { initialState
  , render
  , eval: H.mkEval H.defaultEval
      { handleAction = handleAction
      }
  }

initialState :: Input -> State
initialState { user } =
  { user
  , activeTab: "overview"
  , showNewKeyModal: false
  , newKeyName: ""
  , createdKey: Nothing
  }

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action Slots o m Unit
handleAction = case _ of
  HandleTabsOutput (Tabs.ValueChanged tab) -> 
    H.modify_ _ { activeTab = tab }
  
  OpenNewKeyModal ->
    H.modify_ _ { showNewKeyModal = true, createdKey = Nothing }
  
  CloseNewKeyModal ->
    H.modify_ _ { showNewKeyModal = false, newKeyName = "", createdKey = Nothing }
  
  SetNewKeyName name ->
    H.modify_ _ { newKeyName = name }
  
  CreateApiKey -> do
    state <- H.get
    -- TODO: API call to create key - for now simulate with fake key
    let fakeKey = "nar_live_" <> state.newKeyName <> "_abc123xyz789"
    H.modify_ _ { createdKey = Just fakeKey }

-- ============================================================
-- RENDER
-- ============================================================

render :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
render state =
  HH.div
    [ cls [ "max-w-[1100px] mx-auto px-6 py-8" ] ]
    [ header state
    , tabsSlot
    , content state
    , if state.showNewKeyModal then newKeyModal state else HH.text ""
    ]

header :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
header state =
  HH.div
    [ cls [ "mb-8" ] ]
    [ HH.h1
        [ cls [ "text-2xl font-bold text-text mb-2" ] ]
        [ HH.text $ "Welcome, " <> displayName state.user ]
    , HH.p
        [ cls [ "text-muted-foreground" ] ]
        [ HH.text "Manage your caches, API keys, and billing." ]
    ]

displayName :: ClerkUser -> String
displayName user = 
  case toMaybe user.firstName of
    Just name -> name
    Nothing -> case toMaybe user.username of
      Just uname -> uname
      Nothing -> user.email

tabsSlot :: forall m. MonadAff m => H.ComponentHTML Action Slots m
tabsSlot =
  HH.div
    [ cls [ "mb-8" ] ]
    [ HH.slot _tabs unit Tabs.component tabsInput HandleTabsOutput ]
  where
  tabsInput = Tabs.defaultInput
    { tabs =
        [ { value: "overview", label: "Overview", disabled: false }
        , { value: "caches", label: "Caches", disabled: false }
        , { value: "apikeys", label: "API Keys", disabled: false }
        , { value: "usage", label: "Usage", disabled: false }
        ]
    , defaultValue = Just "overview"
    , orientation = Tabs.Horizontal
    , activationMode = Tabs.Automatic
    , loop = true
    }

content :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
content state = case state.activeTab of
  "overview" -> overviewTab state
  "caches" -> cachesTab state
  "apikeys" -> apiKeysTab state
  "usage" -> usageTab state
  _ -> overviewTab state

newKeyModal :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
newKeyModal state =
  modalOverlay
    [ modalContent ""
        [ case state.createdKey of
            Nothing -> newKeyForm state
            Just key -> newKeySuccess key
        ]
    ]

newKeyForm :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
newKeyForm state =
  HH.div_
    [ modalHeader "Create API Key"
    , HH.p
        [ cls [ "text-sm text-muted-foreground mb-4" ] ]
        [ HH.text "Give your API key a name to help you identify it later." ]
    , formField "Key Name"
        ( HH.input
            [ cls [ "w-full px-3 py-2 bg-background border border-border rounded-md text-text text-sm placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-primary" ]
            , HP.placeholder "e.g., CI Pipeline, Local Dev"
            , HP.value state.newKeyName
            , HE.onValueInput SetNewKeyName
            ]
        )
    , modalFooter
        [ HH.button
            [ cls [ "px-4 py-2 text-sm font-medium text-muted-foreground hover:text-text transition-colors cursor-pointer" ]
            , HP.type_ HP.ButtonButton
            , HE.onClick \_ -> CloseNewKeyModal
            ]
            [ HH.text "Cancel" ]
        , HH.button
            [ cls [ "px-4 py-2 bg-primary text-background text-sm font-medium rounded-md hover:bg-primary/90 transition-colors cursor-pointer disabled:opacity-50 disabled:cursor-not-allowed" ]
            , HP.type_ HP.ButtonButton
            , HP.disabled (state.newKeyName == "")
            , HE.onClick \_ -> CreateApiKey
            ]
            [ HH.text "Create Key" ]
        ]
    ]

newKeySuccess :: forall m. MonadAff m => String -> H.ComponentHTML Action Slots m
newKeySuccess key =
  HH.div_
    [ modalHeader "API Key Created"
    , HH.div
        [ cls [ "mb-4" ] ]
        [ HH.p
            [ cls [ "text-sm text-muted-foreground mb-3" ] ]
            [ HH.text "Your API key has been created. Copy it now - you won't be able to see it again!" ]
        , HH.div
            [ cls [ "p-3 bg-background border border-primary/30 rounded-md" ] ]
            [ HH.code
                [ cls [ "text-sm font-mono text-primary break-all" ] ]
                [ HH.text key ]
            ]
        ]
    , HH.p
        [ cls [ "text-xs text-muted-foreground mb-4" ] ]
        [ HH.text "Store this key securely. For security, it will only be shown once." ]
    , modalFooter
        [ HH.button
            [ cls [ "px-4 py-2 bg-primary text-background text-sm font-medium rounded-md hover:bg-primary/90 transition-colors cursor-pointer" ]
            , HP.type_ HP.ButtonButton
            , HE.onClick \_ -> CloseNewKeyModal
            ]
            [ HH.text "Done" ]
        ]
    ]

-- ============================================================
-- OVERVIEW TAB
-- ============================================================

overviewTab :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
overviewTab _ =
  HH.div_
    [ -- Stats grid
      HH.div
        [ cls [ "grid grid-cols-1 md:grid-cols-4 gap-4 mb-8" ] ]
        [ statCard "Storage Used" "2.3 GB" "of 5 GB"
        , statCard "Transfer" "12.4 GB" "of 50 GB this month"
        , statCard "Caches" "3" "active"
        , statCard "API Calls" "1,247" "this month"
        ]
    
      -- Quick start
    , HH.div
        [ cls [ "bg-card border border-border rounded-lg p-6 mb-8" ] ]
        [ HH.h3
            [ cls [ "text-lg font-semibold text-text mb-4" ] ]
            [ HH.text "Quick Start" ]
        , codeBlock
            [ codeLine "# " "Push to your cache"
            , codeLine "$ " "nix build .#mypackage --json | nar push"
            , HH.text "\n"
            , codeLine "# " "Add as substituter"
            , codeLine "" "extra-substituters = https://cache.nar.io/yourorg"
            , codeLine "" "extra-trusted-public-keys = yourorg.nar.io:abc123..."
            ]
        ]
    
      -- Recent activity
    , HH.div
        [ cls [ "bg-card border border-border rounded-lg p-6" ] ]
        [ HH.h3
            [ cls [ "text-lg font-semibold text-text mb-4" ] ]
            [ HH.text "Recent Activity" ]
        , HH.div
            [ cls [ "space-y-3" ] ]
            [ activityItem "Push" "nixpkgs#hello" "2 minutes ago" "1.2 MB"
            , activityItem "Push" "myproject#default" "15 minutes ago" "45.3 MB"
            , activityItem "Pull" "nixpkgs#gcc" "1 hour ago" "234 MB"
            ]
        ]
    ]

statCard :: forall w i. String -> String -> String -> HH.HTML w i
statCard label value subtitle =
  HH.div
    [ cls [ "bg-card border border-border rounded-lg p-4" ] ]
    [ HH.p
        [ cls [ "text-sm text-muted-foreground mb-1" ] ]
        [ HH.text label ]
    , HH.p
        [ cls [ "text-2xl font-bold text-text" ] ]
        [ HH.text value ]
    , HH.p
        [ cls [ "text-xs text-muted-foreground" ] ]
        [ HH.text subtitle ]
    ]

activityItem :: forall w i. String -> String -> String -> String -> HH.HTML w i
activityItem action path time size =
  HH.div
    [ cls [ "flex items-center justify-between py-2 border-b border-border last:border-0" ] ]
    [ HH.div
        [ cls [ "flex items-center gap-3" ] ]
        [ HH.span
            [ cls [ "text-xs px-2 py-0.5 rounded font-medium"
                  , if action == "Push" then "bg-primary/20 text-primary" else "bg-muted text-muted-foreground"
                  ]
            ]
            [ HH.text action ]
        , HH.span [ cls [ "text-sm text-text font-mono" ] ] [ HH.text path ]
        ]
    , HH.div
        [ cls [ "text-right" ] ]
        [ HH.p [ cls [ "text-sm text-muted-foreground" ] ] [ HH.text time ]
        , HH.p [ cls [ "text-xs text-muted-foreground" ] ] [ HH.text size ]
        ]
    ]

-- ============================================================
-- CACHES TAB
-- ============================================================

cachesTab :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
cachesTab _ =
  HH.div_
    [ HH.div
        [ cls [ "flex items-center justify-between mb-6" ] ]
        [ HH.h2 [ cls [ "text-lg font-semibold text-text" ] ] [ HH.text "Your Caches" ]
        , HH.button
            [ cls [ "px-4 py-2 bg-primary text-background text-sm font-medium rounded-md hover:bg-primary/90 transition-colors cursor-pointer" ]
            , HP.type_ HP.ButtonButton
            ]
            [ HH.text "+ New Cache" ]
        ]
    , HH.div
        [ cls [ "space-y-4" ] ]
        [ cacheCard "default" true "2.1 GB" "Last push: 2 min ago"
        , cacheCard "ci-builds" true "145 MB" "Last push: 1 hour ago"
        , cacheCard "experiments" false "12 MB" "Last push: 3 days ago"
        ]
    ]

cacheCard :: forall w i. String -> Boolean -> String -> String -> HH.HTML w i
cacheCard name isPrivate size lastActivity =
  HH.div
    [ cls [ "bg-card border border-border rounded-lg p-4" ] ]
    [ HH.div
        [ cls [ "flex items-center justify-between mb-2" ] ]
        [ HH.div
            [ cls [ "flex items-center gap-3" ] ]
            [ HH.span [ cls [ "text-text font-medium" ] ] [ HH.text name ]
            , HH.span
                [ cls [ "text-xs px-2 py-0.5 rounded"
                      , if isPrivate then "bg-muted text-muted-foreground" else "bg-primary/20 text-primary"
                      ]
                ]
                [ HH.text $ if isPrivate then "private" else "public" ]
            ]
        , HH.button
            [ cls [ "text-sm text-muted-foreground hover:text-text cursor-pointer" ]
            , HP.type_ HP.ButtonButton
            ]
            [ HH.text "Settings" ]
        ]
    , HH.div
        [ cls [ "flex items-center gap-6 text-sm text-muted-foreground" ] ]
        [ HH.span_ [ HH.text $ "Size: " <> size ]
        , HH.span_ [ HH.text lastActivity ]
        ]
    ]

-- ============================================================
-- API KEYS TAB
-- ============================================================

apiKeysTab :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
apiKeysTab _ =
  HH.div_
    [ HH.div
        [ cls [ "flex items-center justify-between mb-6" ] ]
        [ HH.h2 [ cls [ "text-lg font-semibold text-text" ] ] [ HH.text "API Keys" ]
        , HH.button
            [ cls [ "px-4 py-2 bg-primary text-background text-sm font-medium rounded-md hover:bg-primary/90 transition-colors cursor-pointer" ]
            , HP.type_ HP.ButtonButton
            , HE.onClick \_ -> OpenNewKeyModal
            ]
            [ HH.text "+ New Key" ]
        ]
    , HH.div
        [ cls [ "space-y-4" ] ]
        [ apiKeyCard "CI Pipeline" "nar_***************abc" "Created 3 days ago" "Last used: 2 min ago"
        , apiKeyCard "Local Dev" "nar_***************xyz" "Created 2 weeks ago" "Last used: yesterday"
        ]
    , HH.div
        [ cls [ "mt-8 p-4 bg-card border border-border rounded-lg" ] ]
        [ HH.h3 [ cls [ "text-sm font-medium text-text mb-2" ] ] [ HH.text "Public Key" ]
        , HH.p [ cls [ "text-sm text-muted-foreground mb-2" ] ] [ HH.text "Add this to your Nix configuration:" ]
        , HH.code
            [ cls [ "block bg-background p-3 rounded text-sm font-mono text-muted-foreground" ] ]
            [ HH.text "yourorg.nar.io:H+abc123...==" ]
        ]
    ]

apiKeyCard :: forall w i. String -> String -> String -> String -> HH.HTML w i
apiKeyCard name key created lastUsed =
  HH.div
    [ cls [ "bg-card border border-border rounded-lg p-4" ] ]
    [ HH.div
        [ cls [ "flex items-center justify-between mb-2" ] ]
        [ HH.span [ cls [ "text-text font-medium" ] ] [ HH.text name ]
        , HH.button
            [ cls [ "text-sm text-danger hover:text-danger/80 cursor-pointer" ]
            , HP.type_ HP.ButtonButton
            ]
            [ HH.text "Revoke" ]
        ]
    , HH.code
        [ cls [ "block text-sm font-mono text-muted-foreground mb-2" ] ]
        [ HH.text key ]
    , HH.div
        [ cls [ "flex items-center gap-4 text-xs text-muted-foreground" ] ]
        [ HH.span_ [ HH.text created ]
        , HH.span_ [ HH.text lastUsed ]
        ]
    ]

-- ============================================================
-- USAGE TAB
-- ============================================================

usageTab :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
usageTab _ =
  HH.div_
    [ HH.div
        [ cls [ "grid grid-cols-1 md:grid-cols-2 gap-6 mb-8" ] ]
        [ usageCard "Storage" 2300 5000 "MB"
        , usageCard "Transfer" 12400 50000 "MB"
        ]
    , HH.div
        [ cls [ "bg-card border border-border rounded-lg p-6" ] ]
        [ HH.h3 [ cls [ "text-lg font-semibold text-text mb-4" ] ] [ HH.text "Current Plan: Free" ]
        , HH.p [ cls [ "text-muted-foreground mb-4" ] ] [ HH.text "Upgrade to Pro for 100GB storage and 500GB transfer." ]
        , HH.a
            [ HP.href "/settings"
            , cls [ "inline-block px-4 py-2 bg-primary text-background text-sm font-medium rounded-md hover:bg-primary/90 transition-colors" ]
            ]
            [ HH.text "Upgrade Plan" ]
        ]
    ]

usageCard :: forall w i. String -> Int -> Int -> String -> HH.HTML w i
usageCard label used total unit =
  HH.div
    [ cls [ "bg-card border border-border rounded-lg p-6" ] ]
    [ HH.div
        [ cls [ "flex items-center justify-between mb-2" ] ]
        [ HH.span [ cls [ "text-sm text-muted-foreground" ] ] [ HH.text label ]
        , HH.span [ cls [ "text-sm text-muted-foreground" ] ] 
            [ HH.text $ show used <> " / " <> show total <> " " <> unit ]
        ]
    , HH.div
        [ cls [ "h-2 bg-muted rounded-full overflow-hidden" ] ]
        [ HH.div
            [ cls [ "h-full bg-primary rounded-full" ]
            , HP.style $ "width: " <> show (used * 100 / total) <> "%"
            ]
            []
        ]
    ]
