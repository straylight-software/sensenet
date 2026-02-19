━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                              // nar.io // purescript // production
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

   "Case was twenty-four. At twenty-two, he'd been a cowboy, a rustler, one of
    the best in the Sprawl. He'd been trained by the best, by McCoy Pauley and
    Bobby Quine, legends in the biz. He'd operated on an almost permanent
    adrenaline high, a byproduct of youth and proficiency, jacked into a custom
    cyberspace deck that projected his disembodied consciousness into the
    consensual hallucination that was the matrix.

    A thief, he'd worked for other, wealthier thieves, employers who provided
    the exotic software required to penetrate the bright walls of corporate
    systems, opening windows into rich fields of data."

                                                              — Neuromancer

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Why We Do What We Do

Production PureScript exists at the intersection of type safety and shipping product. We write in a
language that compiles to JavaScript but choose to express business logic with algebraic data types.
Not because we can't use TypeScript, but because making money with functional programming on the
frontend is the ultimate proof of concept.

If Halogen was written for academics, it would be a paper about component algebras. Instead it's
`HalogenM state action slots output m`, it has subscription management, query algebras, and compiles
to JavaScript that runs in every browser. It processes user interactions while three different
teams extend it without coordination. That's the gulf between academic FP and production FP—we're
not writing papers, we're writing paychecks.

This guide is for practitioners who know that `Applicative` is powerful not because it's a
mathematical abstraction, but because it makes form validation composable. Who understand that
`Aff` isn't beautiful because it models asynchronous computation, but because it means you can
write async code without callback hell.

We are not the same as the PureScript you learned from tutorials. We're what happens when you take
those ideas and make them work for money.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                          // core philosophy
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Optimize for Disambiguation

In modern codebases where agents generate significant amounts of code, traditional economics invert:

- Code is written once by agents in seconds
- Code is read hundreds of times by humans and agents
- Code is debugged when you're under pressure by tired humans
- Code is modified by agents who lack the original context

**Every ambiguity compounds exponentially.**

```purescript
-- This costs an agent 0.1 seconds to write, a human 10 minutes to debug
handle e = if p e then go e else stop

-- This costs an agent 0.2 seconds to write, saves hours of cumulative confusion
handleAuthAction :: AuthAction -> H.HalogenM State Action Slots Output m Unit
handleAuthAction authAction =
  case authAction of
    SignInRequested -> initiateSignInFlow
    SignOutRequested -> performSignOut
    SessionExpired -> redirectToLogin
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                              // naming
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## The Three-Character Rule

If an identifier is 3 characters or less, it's probably too short for production code:

```purescript
-- BAD: Abbreviated names multiply confusion
st <- get
res <- proc req
cfg <- loadCfg

-- GOOD: Full words tell the story
currentState <- H.get
response <- processRequest request
configuration <- loadConfiguration
```

### Standard Exceptions (Use Sparingly)

Only in local scope where type makes it unambiguous:

- `xs, ys` — lists in pure functions
- `n, i` — indices in array operations
- `k, v` — key/value in map operations
- `f, g` — functions in higher-order contexts

But even here, consider being explicit:

```purescript
-- OK for simple pure functions
map f xs = ...

-- Better for production code where context matters
mapWithIndex :: forall a b. (Int -> a -> b) -> Array a -> Array b
mapWithIndex indexedTransform inputArray = ...
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                          // module structure
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## File Organization

Every module follows the same structure:

```purescript
-- | Module description (one line)
-- | Extended description if needed
module Nar.Pages.Dashboard where

import Prelude

-- External imports (alphabetical)
import Data.Maybe (Maybe(..))
import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.HTML as HH

-- Internal imports (alphabetical)
import Nar.Auth (ClerkUser)
import Nar.UI (cls)

-- ============================================================
-- TYPES
-- ============================================================

type State = { ... }

data Action = ...

-- ============================================================
-- COMPONENT
-- ============================================================

component :: forall q o m. MonadAff m => H.Component q Input o m
component = ...

-- ============================================================
-- RENDER
-- ============================================================

render :: forall m. State -> H.ComponentHTML Action () m
render state = ...

-- ============================================================
-- HELPERS
-- ============================================================

helperFunction :: ...
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                            // halogen patterns
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Component Architecture

### State Machines in Types

```purescript
-- BAD: State scattered across booleans
type State =
  { isLoading :: Boolean
  , hasError :: Boolean
  , isAuthenticated :: Boolean
  }

-- GOOD: State machine can't be in impossible states
data PageState
  = Loading
  | LoadError ErrorMessage
  | Ready ReadyState

data AuthState
  = Checking
  | SignedOut
  | SignedIn ClerkUser ClerkSession
```

### Action Naming

Actions describe what happened, not what to do:

```purescript
-- BAD: Imperative names
data Action
  = LoadData
  | SetUser User
  | ShowError String

-- GOOD: Event names
data Action
  = Initialize
  | UserDataReceived (Either Error User)
  | SignOutClicked
  | SessionExpired
  | FormSubmitted FormData
```

### Handler Structure

```purescript
handleAction :: forall o m. MonadAff m => Action -> H.HalogenM State Action Slots o m Unit
handleAction = case _ of
  Initialize -> do
    -- Load initial data
    authState <- liftEffect getAuthState
    H.modify_ _ { auth = authState }
    
    -- Subscribe to changes
    { emitter, listener } <- liftEffect HS.create
    void $ H.subscribe emitter

  UserDataReceived result -> case result of
    Left errorMessage -> H.modify_ _ { pageState = LoadError errorMessage }
    Right userData -> H.modify_ _ { pageState = Ready { user: userData } }

  SignOutClicked -> do
    H.modify_ _ { auth = Loading }
    liftAff signOut
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                                  // html
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Render Functions

### Extract Named Sections

```purescript
-- BAD: Monolithic render
render state =
  HH.div_
    [ HH.header_ [ ... 50 lines ... ]
    , HH.main_ [ ... 100 lines ... ]
    , HH.footer_ [ ... 30 lines ... ]
    ]

-- GOOD: Named sections
render :: forall m. State -> H.ComponentHTML Action () m
render state =
  HH.div
    [ cls [ "min-h-screen" ] ]
    [ renderHeader state
    , renderMainContent state
    , renderFooter
    ]

renderHeader :: forall m. State -> H.ComponentHTML Action () m
renderHeader state = ...

renderMainContent :: forall m. State -> H.ComponentHTML Action () m
renderMainContent state = ...
```

### CSS Classes

Use the `cls` helper, never raw class strings:

```purescript
-- BAD: String concatenation
HH.div [ HP.class_ $ HH.ClassName $ "flex " <> if active then "bg-primary" else "" ]

-- GOOD: Array of classes, filter empty
HH.div
  [ cls [ "flex items-center gap-4"
        , if state.isActive then "bg-primary" else ""
        ]
  ]
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                                    // ffi
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Foreign Function Interface

### File Pairing

Every FFI module has two files:

```
src/Nar/Auth.purs    -- PureScript types and foreign imports
src/Nar/Auth.js      -- JavaScript implementation
```

### PureScript Side

```purescript
module Nar.Auth where

import Prelude
import Effect (Effect)
import Effect.Aff (Aff)
import Effect.Aff.Compat (EffectFnAff, fromEffectFnAff)

-- Types first
type ClerkUser = { id :: String, email :: String, ... }

-- Foreign imports grouped
foreign import initClerkImpl :: String -> EffectFnAff Unit
foreign import signInImpl :: Effect Unit
foreign import signOutImpl :: EffectFnAff Unit

-- Public API wraps foreign imports
initClerk :: String -> Aff Unit
initClerk key = fromEffectFnAff (initClerkImpl key)

signIn :: Effect Unit
signIn = signInImpl

signOut :: Aff Unit
signOut = fromEffectFnAff signOutImpl
```

### JavaScript Side

```javascript
// Nar/Auth.js

// Always use explicit exports
export const initClerkImpl = (key) => async (onError, onSuccess) => {
  try {
    // Implementation
    onSuccess();
  } catch (e) {
    onError(e);
  }
  // Cancellation handler
  return (cancelError, onCancelerError, onCancelerSuccess) => {
    onCancelerSuccess();
  };
};

export const signInImpl = () => {
  // Synchronous Effect
};
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                              // routing
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Client-Side Routing

### Route as Sum Type

```purescript
data Route
  = Home
  | Pricing
  | Docs
  | Dashboard    -- protected
  | Settings     -- protected
  | Login
  | Signup

derive instance eqRoute :: Eq Route

-- Route properties as functions
isProtected :: Route -> Boolean
isProtected = case _ of
  Dashboard -> true
  Settings -> true
  _ -> false

isAuthRoute :: Route -> Boolean
isAuthRoute = case _ of
  Login -> true
  Signup -> true
  _ -> false
```

### Parse and Render

```purescript
parseRoute :: String -> Route
parseRoute path = case path of
  "/" -> Home
  "/pricing" -> Pricing
  "/dashboard" -> Dashboard
  "/settings" -> Settings
  _ -> Home  -- fallback

routeToPath :: Route -> String
routeToPath = case _ of
  Home -> "/"
  Pricing -> "/pricing"
  Dashboard -> "/dashboard"
  Settings -> "/settings"
  Login -> "/login"
  Signup -> "/signup"
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                          // error handling
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Errors as Data

```purescript
-- Domain-specific error types
data AuthError
  = SessionExpired
  | InvalidCredentials
  | NetworkError String

data ApiError
  = Unauthorized
  | NotFound
  | RateLimited
  | ServerError Int String

-- Render errors for users
renderAuthError :: forall w i. AuthError -> HH.HTML w i
renderAuthError = case _ of
  SessionExpired -> 
    HH.text "Your session has expired. Please sign in again."
  InvalidCredentials -> 
    HH.text "Invalid email or password."
  NetworkError message -> 
    HH.text $ "Connection error: " <> message
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                      // agent collaboration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Code Provenance

Mark human insights that agents might miss:

```purescript
handleAuthAction :: Action -> H.HalogenM State Action Slots Output m Unit
handleAuthAction = case _ of
  SessionTokenReceived token -> do
    -- human: clerk sometimes sends empty tokens during redirect, ignore them
    when (token /= "") do
      validateAndStoreToken token

  SignOutClicked -> do
    -- human: clear local storage before clerk signout to prevent stale state
    liftEffect clearLocalStorage
    liftAff signOut
```


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                            // the vibe test
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


Good production PureScript passes these checks:

- Could you debug it in browser devtools without the source?
- Could a colleague (human or AI) extend it without breaking invariants?
- Do the types prevent tomorrow's bug?
- Is every abbreviation worth the confusion it creates?
- Does it compile fast enough for flow state?
- Will it still make sense after multiple contributors have touched it?


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                                // summary
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


## Production PureScript for the Modern Era

We write PureScript like we're building production systems, not proving theorems. In codebases
where agents contribute significantly:

1. **Optimize for disambiguation** — Every ambiguity compounds
2. **Make invalid states unrepresentable** — Use sum types for state machines
3. **Be explicit about effects** — Aff vs Effect vs pure must be obvious
4. **Use the type system** — If it compiles, it should work
5. **Keep render functions small** — Extract named sections
6. **Name things fully** — Three characters is too short

The PureScript community optimized for elegance. We optimize for clarity at scale. Beauty in
production code comes from disambiguation, not cleverness.

Write code as if a hundred contributors will extend it tomorrow, and you'll debug it during an
incident next month. Because both will happen.


━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

   "She went to the stairs and climbed them. The master bedroom was dark.
    She undressed and put on a robe and lay down on the bed. The ceiling was
    white and far away.

    She thought about the girl, the one who had Angie's face.

    What would it be like, she wondered, to be that girl? To be Mona?"

                                                        — Mona Lisa Overdrive

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
