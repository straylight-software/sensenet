-- | Stripe Billing FFI
-- | Handles checkout and customer portal redirects
module Nar.Billing
  ( Plan(..)
  , PlanDetails
  , createCheckoutSession
  , openCustomerPortal
  , getPlanDetails
  ) where

import Prelude

import Effect.Aff (Aff)
import Effect.Aff.Compat (EffectFnAff, fromEffectFnAff)

-- ============================================================
-- TYPES
-- ============================================================

data Plan
  = Free
  | Pro
  | Team
  | Enterprise

derive instance eqPlan :: Eq Plan

type PlanDetails =
  { name :: String
  , price :: Int  -- cents/month
  , storage :: String
  , transfer :: String
  , caches :: String
  , seats :: String
  , stripePriceId :: String
  }

-- ============================================================
-- PLAN DETAILS
-- ============================================================

getPlanDetails :: Plan -> PlanDetails
getPlanDetails = case _ of
  Free ->
    { name: "Free"
    , price: 0
    , storage: "5GB"
    , transfer: "50GB/mo"
    , caches: "1 private"
    , seats: "1"
    , stripePriceId: ""
    }
  Pro ->
    { name: "Pro"
    , price: 1000
    , storage: "100GB"
    , transfer: "500GB/mo"
    , caches: "5 private"
    , seats: "1"
    , stripePriceId: "price_pro_monthly"
    }
  Team ->
    { name: "Team"
    , price: 2500
    , storage: "500GB"
    , transfer: "2TB/mo"
    , caches: "Unlimited"
    , seats: "5 included"
    , stripePriceId: "price_team_monthly"
    }
  Enterprise ->
    { name: "Enterprise"
    , price: 0  -- custom
    , storage: "Unlimited"
    , transfer: "Unlimited"
    , caches: "Unlimited"
    , seats: "Unlimited"
    , stripePriceId: ""
    }

-- ============================================================
-- FFI IMPORTS
-- ============================================================

foreign import createCheckoutSessionImpl :: String -> String -> EffectFnAff String
foreign import openCustomerPortalImpl :: String -> EffectFnAff String

-- ============================================================
-- PUBLIC API
-- ============================================================

-- | Create Stripe Checkout session and redirect
-- | Takes price ID and success URL, returns checkout URL
createCheckoutSession :: String -> String -> Aff String
createCheckoutSession priceId successUrl = 
  fromEffectFnAff (createCheckoutSessionImpl priceId successUrl)

-- | Open Stripe Customer Portal for billing management
-- | Takes return URL, returns portal URL
openCustomerPortal :: String -> Aff String
openCustomerPortal returnUrl =
  fromEffectFnAff (openCustomerPortalImpl returnUrl)
