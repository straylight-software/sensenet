-- | Clerk Authentication FFI
-- | Wraps @clerk/clerk-js for PureScript
module Nar.Auth
  ( ClerkUser
  , ClerkSession
  , AuthState(..)
  , initClerk
  , getAuthState
  , signIn
  , signUp
  , signOut
  , openUserProfile
  , onAuthStateChange
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Nullable (Nullable, toMaybe)
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff.Compat (EffectFnAff, fromEffectFnAff)

-- ============================================================
-- TYPES
-- ============================================================

type ClerkUser =
  { id :: String
  , email :: String
  , firstName :: Nullable String
  , lastName :: Nullable String
  , imageUrl :: String
  , username :: Nullable String
  , publicMetadata :: { plan :: Nullable String, stripeCustomerId :: Nullable String }
  }

type ClerkSession =
  { id :: String
  , userId :: String
  , expireAt :: Number
  }

data AuthState
  = Loading
  | SignedOut
  | SignedIn ClerkUser ClerkSession

-- ============================================================
-- FFI IMPORTS
-- ============================================================

foreign import initClerkImpl :: String -> EffectFnAff Unit
foreign import getAuthStateImpl :: Effect { user :: Nullable ClerkUser, session :: Nullable ClerkSession, isLoaded :: Boolean }
foreign import signInImpl :: Effect Unit
foreign import signUpImpl :: Effect Unit
foreign import signOutImpl :: EffectFnAff Unit
foreign import openUserProfileImpl :: Effect Unit
foreign import onAuthStateChangeImpl :: (Effect Unit) -> Effect (Effect Unit)

-- ============================================================
-- PUBLIC API
-- ============================================================

-- | Initialize Clerk with publishable key
initClerk :: String -> Aff Unit
initClerk key = fromEffectFnAff (initClerkImpl key)

-- | Get current auth state
getAuthState :: Effect AuthState
getAuthState = do
  state <- getAuthStateImpl
  if not state.isLoaded
    then pure Loading
    else case toMaybe state.user of
      Just user -> case toMaybe state.session of
        Just session -> pure $ SignedIn user session
        Nothing -> pure SignedOut
      Nothing -> pure SignedOut

-- | Open Clerk sign-in modal
signIn :: Effect Unit
signIn = signInImpl

-- | Open Clerk sign-up modal
signUp :: Effect Unit
signUp = signUpImpl

-- | Sign out current user
signOut :: Aff Unit
signOut = fromEffectFnAff signOutImpl

-- | Open Clerk user profile modal
openUserProfile :: Effect Unit
openUserProfile = openUserProfileImpl

-- | Subscribe to auth state changes, returns unsubscribe function
onAuthStateChange :: Effect Unit -> Effect (Effect Unit)
onAuthStateChange = onAuthStateChangeImpl
