-- | Nar.io Settings Page
-- | Account settings, billing, team management
module Nar.Pages.Settings where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Nullable (toMaybe)
import Effect.Aff.Class (class MonadAff, liftAff)
import Effect.Class (liftEffect)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Type.Proxy (Proxy(..))

import Radix.Pure.Tabs as Tabs

import Nar.UI (cls)
import Nar.Auth (ClerkUser, openUserProfile)
import Nar.Billing (Plan(..), getPlanDetails, openCustomerPortal)

-- ============================================================
-- TYPES
-- ============================================================

type Input = { user :: ClerkUser }

type State =
  { user :: ClerkUser
  , activeTab :: String
  , currentPlan :: Plan
  , loading :: Boolean
  }

type Slots =
  ( tabs :: Tabs.Slot Unit
  )

_tabs :: Proxy "tabs"
_tabs = Proxy

data Action
  = HandleTabsOutput Tabs.Output
  | OpenProfile
  | OpenBillingPortal
  | UpgradeTo Plan

-- ============================================================
-- COMPONENT
-- ============================================================

settings :: forall q o m. MonadAff m => H.Component q Input o m
settings = H.mkComponent
  { initialState
  , render
  , eval: H.mkEval H.defaultEval
      { handleAction = handleAction
      }
  }

initialState :: Input -> State
initialState { user } =
  { user
  , activeTab: "account"
  , currentPlan: Free  -- TODO: read from user metadata
  , loading: false
  }

handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action Slots o m Unit
handleAction = case _ of
  HandleTabsOutput (Tabs.ValueChanged tab) -> 
    H.modify_ _ { activeTab = tab }
  
  OpenProfile -> liftEffect openUserProfile
  
  OpenBillingPortal -> do
    H.modify_ _ { loading = true }
    _ <- liftAff $ openCustomerPortal "/settings"
    H.modify_ _ { loading = false }
  
  UpgradeTo _plan -> do
    -- TODO: Create checkout session
    pure unit

-- ============================================================
-- RENDER
-- ============================================================

render :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
render state =
  HH.div
    [ cls [ "max-w-[1100px] mx-auto px-6 py-8" ] ]
    [ headerSection
    , HH.div
        [ cls [ "grid grid-cols-1 lg:grid-cols-[200px_1fr] gap-8" ] ]
        [ sidebar
        , content state
        ]
    ]

headerSection :: forall m. MonadAff m => H.ComponentHTML Action Slots m
headerSection =
  HH.div
    [ cls [ "mb-8" ] ]
    [ HH.h1
        [ cls [ "text-2xl font-bold text-text" ] ]
        [ HH.text "Settings" ]
    ]

sidebar :: forall m. MonadAff m => H.ComponentHTML Action Slots m
sidebar =
  HH.div
    [ cls [ "lg:pt-2" ] ]
    [ HH.slot _tabs unit Tabs.component tabsInput HandleTabsOutput ]
  where
  tabsInput = Tabs.defaultInput
    { tabs =
        [ { value: "account", label: "Account", disabled: false }
        , { value: "billing", label: "Billing", disabled: false }
        , { value: "team", label: "Team", disabled: false }
        , { value: "security", label: "Security", disabled: false }
        ]
    , defaultValue = Just "account"
    , orientation = Tabs.Vertical
    , activationMode = Tabs.Automatic
    , loop = true
    }

content :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
content state = case state.activeTab of
  "account" -> accountTab state
  "billing" -> billingTab state
  "team" -> teamTab state
  "security" -> securityTab state
  _ -> accountTab state

-- ============================================================
-- ACCOUNT TAB
-- ============================================================

accountTab :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
accountTab state =
  HH.div
    [ cls [ "space-y-6" ] ]
    [ -- Profile section
      HH.div
        [ cls [ "bg-card border border-border rounded-lg p-6" ] ]
        [ HH.h3 [ cls [ "text-lg font-semibold text-text mb-4" ] ] [ HH.text "Profile" ]
        , HH.div
            [ cls [ "flex items-center gap-4 mb-4" ] ]
            [ HH.img
                [ HP.src state.user.imageUrl
                , HP.alt "Profile"
                , cls [ "w-16 h-16 rounded-full" ]
                ]
            , HH.div_
                [ HH.p [ cls [ "text-text font-medium" ] ] 
                    [ HH.text $ displayName state.user ]
                , HH.p [ cls [ "text-sm text-muted-foreground" ] ] 
                    [ HH.text state.user.email ]
                ]
            ]
        , HH.button
            [ cls [ "px-4 py-2 border border-border text-text text-sm font-medium rounded-md hover:bg-card transition-colors cursor-pointer" ]
            , HE.onClick \_ -> OpenProfile
            , HP.type_ HP.ButtonButton
            ]
            [ HH.text "Edit Profile" ]
        ]
    
      -- Danger zone
    , HH.div
        [ cls [ "bg-card border border-danger/30 rounded-lg p-6" ] ]
        [ HH.h3 [ cls [ "text-lg font-semibold text-danger mb-4" ] ] [ HH.text "Danger Zone" ]
        , HH.p [ cls [ "text-sm text-muted-foreground mb-4" ] ] 
            [ HH.text "Once you delete your account, there is no going back. Please be certain." ]
        , HH.button
            [ cls [ "px-4 py-2 border border-danger text-danger text-sm font-medium rounded-md hover:bg-danger/10 transition-colors cursor-pointer" ]
            , HP.type_ HP.ButtonButton
            ]
            [ HH.text "Delete Account" ]
        ]
    ]

displayName :: ClerkUser -> String
displayName user = 
  case toMaybe user.firstName, toMaybe user.lastName of
    Just f, Just l -> f <> " " <> l
    Just f, Nothing -> f
    Nothing, _ -> case toMaybe user.username of
      Just u -> u
      Nothing -> user.email

-- ============================================================
-- BILLING TAB
-- ============================================================

billingTab :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
billingTab state =
  HH.div
    [ cls [ "space-y-6" ] ]
    [ -- Current plan
      HH.div
        [ cls [ "bg-card border border-border rounded-lg p-6" ] ]
        [ HH.div
            [ cls [ "flex items-center justify-between mb-4" ] ]
            [ HH.h3 [ cls [ "text-lg font-semibold text-text" ] ] [ HH.text "Current Plan" ]
            , HH.button
                [ cls [ "text-sm text-primary hover:text-primary/80 cursor-pointer" ]
                , HE.onClick \_ -> OpenBillingPortal
                , HP.type_ HP.ButtonButton
                ]
                [ HH.text "Manage Billing" ]
            ]
        , planBadge state.currentPlan
        , HH.div
            [ cls [ "mt-4 grid grid-cols-2 md:grid-cols-4 gap-4" ] ]
            [ planStat "Storage" (getPlanDetails state.currentPlan).storage
            , planStat "Transfer" (getPlanDetails state.currentPlan).transfer
            , planStat "Caches" (getPlanDetails state.currentPlan).caches
            , planStat "Seats" (getPlanDetails state.currentPlan).seats
            ]
        ]
    
      -- Upgrade options
    , HH.div
        [ cls [ "bg-card border border-border rounded-lg p-6" ] ]
        [ HH.h3 [ cls [ "text-lg font-semibold text-text mb-4" ] ] [ HH.text "Upgrade" ]
        , HH.div
            [ cls [ "grid grid-cols-1 md:grid-cols-3 gap-4" ] ]
            [ upgradePlanCard state Pro
            , upgradePlanCard state Team
            , upgradePlanCard state Enterprise
            ]
        ]
    ]

planBadge :: forall w i. Plan -> HH.HTML w i
planBadge plan =
  let details = getPlanDetails plan
  in HH.div
    [ cls [ "inline-flex items-center gap-2" ] ]
    [ HH.span
        [ cls [ "text-2xl font-bold text-text" ] ]
        [ HH.text details.name ]
    , if plan /= Free
        then HH.span [ cls [ "text-muted-foreground" ] ] 
            [ HH.text $ "$" <> show (details.price / 100) <> "/mo" ]
        else HH.text ""
    ]

planStat :: forall w i. String -> String -> HH.HTML w i
planStat label value =
  HH.div_
    [ HH.p [ cls [ "text-xs text-muted-foreground" ] ] [ HH.text label ]
    , HH.p [ cls [ "text-sm text-text font-medium" ] ] [ HH.text value ]
    ]

upgradePlanCard :: forall m. MonadAff m => State -> Plan -> H.ComponentHTML Action Slots m
upgradePlanCard state plan =
  let 
    details = getPlanDetails plan
    isCurrent = state.currentPlan == plan
  in HH.div
    [ cls [ "border rounded-lg p-4"
          , if isCurrent then "border-primary bg-primary/5" else "border-border"
          ]
    ]
    [ HH.h4 [ cls [ "font-semibold text-text mb-1" ] ] [ HH.text details.name ]
    , HH.p [ cls [ "text-sm text-muted-foreground mb-3" ] ] 
        [ HH.text $ if details.price > 0 
            then "$" <> show (details.price / 100) <> "/mo"
            else "Contact us"
        ]
    , if isCurrent
        then HH.span [ cls [ "text-xs text-primary" ] ] [ HH.text "Current plan" ]
        else HH.button
            [ cls [ "w-full py-2 text-sm font-medium rounded transition-colors cursor-pointer"
                  , if plan == Enterprise
                      then "border border-border text-text hover:bg-card"
                      else "bg-primary text-background hover:bg-primary/90"
                  ]
            , HE.onClick \_ -> UpgradeTo plan
            , HP.type_ HP.ButtonButton
            ]
            [ HH.text $ if plan == Enterprise then "Contact Sales" else "Upgrade" ]
    ]

-- ============================================================
-- TEAM TAB
-- ============================================================

teamTab :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
teamTab state =
  HH.div
    [ cls [ "space-y-6" ] ]
    [ HH.div
        [ cls [ "bg-card border border-border rounded-lg p-6" ] ]
        [ HH.div
            [ cls [ "flex items-center justify-between mb-4" ] ]
            [ HH.h3 [ cls [ "text-lg font-semibold text-text" ] ] [ HH.text "Team Members" ]
            , HH.button
                [ cls [ "px-4 py-2 bg-primary text-background text-sm font-medium rounded-md hover:bg-primary/90 transition-colors cursor-pointer" ]
                , HP.type_ HP.ButtonButton
                ]
                [ HH.text "+ Invite Member" ]
            ]
        , HH.div
            [ cls [ "space-y-3" ] ]
            [ teamMemberRow state.user.imageUrl (displayName state.user) state.user.email "Owner"
            ]
        ]
    ]

teamMemberRow :: forall w i. String -> String -> String -> String -> HH.HTML w i
teamMemberRow avatar name email role =
  HH.div
    [ cls [ "flex items-center justify-between py-3 border-b border-border last:border-0" ] ]
    [ HH.div
        [ cls [ "flex items-center gap-3" ] ]
        [ HH.img [ HP.src avatar, HP.alt name, cls [ "w-8 h-8 rounded-full" ] ]
        , HH.div_
            [ HH.p [ cls [ "text-sm text-text font-medium" ] ] [ HH.text name ]
            , HH.p [ cls [ "text-xs text-muted-foreground" ] ] [ HH.text email ]
            ]
        ]
    , HH.span
        [ cls [ "text-xs px-2 py-1 rounded bg-muted text-muted-foreground" ] ]
        [ HH.text role ]
    ]

-- ============================================================
-- SECURITY TAB
-- ============================================================

securityTab :: forall m. MonadAff m => State -> H.ComponentHTML Action Slots m
securityTab _ =
  HH.div
    [ cls [ "space-y-6" ] ]
    [ HH.div
        [ cls [ "bg-card border border-border rounded-lg p-6" ] ]
        [ HH.h3 [ cls [ "text-lg font-semibold text-text mb-4" ] ] [ HH.text "Two-Factor Authentication" ]
        , HH.p [ cls [ "text-sm text-muted-foreground mb-4" ] ] 
            [ HH.text "Add an extra layer of security to your account." ]
        , HH.button
            [ cls [ "px-4 py-2 border border-border text-text text-sm font-medium rounded-md hover:bg-card transition-colors cursor-pointer" ]
            , HE.onClick \_ -> OpenProfile
            , HP.type_ HP.ButtonButton
            ]
            [ HH.text "Configure 2FA" ]
        ]
    , HH.div
        [ cls [ "bg-card border border-border rounded-lg p-6" ] ]
        [ HH.h3 [ cls [ "text-lg font-semibold text-text mb-4" ] ] [ HH.text "Active Sessions" ]
        , HH.p [ cls [ "text-sm text-muted-foreground mb-4" ] ] 
            [ HH.text "Manage your active sessions across devices." ]
        , HH.button
            [ cls [ "px-4 py-2 border border-border text-text text-sm font-medium rounded-md hover:bg-card transition-colors cursor-pointer" ]
            , HE.onClick \_ -> OpenProfile
            , HP.type_ HP.ButtonButton
            ]
            [ HH.text "View Sessions" ]
        ]
    ]
