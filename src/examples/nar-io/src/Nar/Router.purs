-- | Nar.io Client-side routing
module Nar.Router where

import Prelude

import Effect (Effect)

-- ============================================================
-- ROUTES
-- ============================================================

data Route
  = Home
  | Pricing
  | Docs
  | DocsQuickstart
  | DocsCli
  | DocsApi
  -- Protected routes (require auth)
  | Dashboard
  | Settings
  | Login
  | Signup

derive instance eqRoute :: Eq Route

-- | Check if a route requires authentication
isProtected :: Route -> Boolean
isProtected = case _ of
  Dashboard -> true
  Settings -> true
  _ -> false

-- | Check if a route is auth-related (login/signup)
isAuthRoute :: Route -> Boolean
isAuthRoute = case _ of
  Login -> true
  Signup -> true
  _ -> false

-- ============================================================
-- PARSING
-- ============================================================

parseRoute :: String -> Route
parseRoute path = case path of
  "/" -> Home
  "/pricing" -> Pricing
  "/pricing/" -> Pricing
  "/docs" -> Docs
  "/docs/" -> Docs
  "/docs/quickstart" -> DocsQuickstart
  "/docs/quickstart/" -> DocsQuickstart
  "/docs/cli" -> DocsCli
  "/docs/cli/" -> DocsCli
  "/docs/api" -> DocsApi
  "/docs/api/" -> DocsApi
  "/dashboard" -> Dashboard
  "/dashboard/" -> Dashboard
  "/settings" -> Settings
  "/settings/" -> Settings
  "/login" -> Login
  "/login/" -> Login
  "/signup" -> Signup
  "/signup/" -> Signup
  _ -> Home

routeToPath :: Route -> String
routeToPath = case _ of
  Home -> "/"
  Pricing -> "/pricing"
  Docs -> "/docs"
  DocsQuickstart -> "/docs/quickstart"
  DocsCli -> "/docs/cli"
  DocsApi -> "/docs/api"
  Dashboard -> "/dashboard"
  Settings -> "/settings"
  Login -> "/login"
  Signup -> "/signup"

-- ============================================================
-- FFI
-- ============================================================

foreign import getPathname :: Effect String
foreign import pushState :: String -> Effect Unit
foreign import onPopState :: (String -> Effect Unit) -> Effect Unit
