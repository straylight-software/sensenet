-- | Client-side routing
module Straylight.Router where

import Prelude


import Effect (Effect)

-- ============================================================
-- ROUTES
-- ============================================================

data Route
  = Home
  | Plan
  | Lean
  | Razorgirl
  | Software
  | Irc
  | Discord

derive instance eqRoute :: Eq Route

-- ============================================================
-- PARSING
-- ============================================================

parseRoute :: String -> Route
parseRoute path = case path of
  "/" -> Home
  "/plan" -> Plan
  "/plan/" -> Plan
  "/plan/lean" -> Lean
  "/plan/lean/" -> Lean
  "/razorgirl" -> Razorgirl
  "/razorgirl/" -> Razorgirl
  "/software" -> Software
  "/software/" -> Software
  "/irc" -> Irc
  "/irc/" -> Irc
  "/discord" -> Discord
  "/discord/" -> Discord
  _ -> Home

routeToPath :: Route -> String
routeToPath = case _ of
  Home -> "/"
  Plan -> "/plan"
  Lean -> "/plan/lean"
  Razorgirl -> "/razorgirl"
  Software -> "/software"
  Irc -> "/irc"
  Discord -> "/discord"

-- ============================================================
-- FFI
-- ============================================================

foreign import getPathname :: Effect String
foreign import pushState :: String -> Effect Unit
foreign import onPopState :: (String -> Effect Unit) -> Effect Unit
