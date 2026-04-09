━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// hypermodern // haskell // production
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

"The Finn's mouth worked silently for a few seconds. Then: 'Wintermute.
You know, Case, I figure it's the Turing heat gets to you first. In the
end.' 'The Turing cops?' 'Heat. That's why it's the Turings, all that ice
around the cores. Because that's how you gotta keep an AI, with that much
processing capacity, you gotta keep it cool, you know?'"

```
                                                             — Neuromancer
```

# `// why we do what we do`

Production Haskell exists at the intersection of mathematical beauty and
economic reality. We write in a language that could express category theory
but choose to express business logic instead. Not because we can't do the
former, but because making money with functional programming is the ultimate
proof of concept.

If RWST was written today, it wouldn't be a monad transformer tutorial. It
would be `ReaderT Config (ExceptT AppError (StateT Metrics IO))`, it would
have structured logging, Prometheus metrics, and compile with `-O2 -Wall -Werror`. It would process millions of events per second while three different
teams extend it without coordination. That's the gulf between academic Haskell
and production Haskell — we're not writing papers, we're writing paychecks.

This guide is for practitioners who know that `Applicative` is powerful not
because it's a mathematical abstraction, but because it makes JSON parsing
composable. Who understand that `STM` isn't beautiful because it solves the
dining philosophers problem, but because it means you can write concurrent
code at 3am without creating race conditions.

We are not the same as the Haskell you learned in university. We're what
happens when you take those ideas and make them work for money.

```
                                                                — b7r6 // 2026
```

# `// versions // and // tooling`

════════════════════════════════════════════════════════════════════════════════
// ghc // 9.10 // ghc2024
════════════════════════════════════════════════════════════════════════════════

## `// compiler // version`

We target **GHC 9.10.1** with the **GHC2024** language edition. This is
non-negotiable. GHC2024 enables sane defaults:

```haskell
-- GHC2024 enables by default:
--   DataKinds, DerivingStrategies, DisambiguateRecordFields,
--   ExplicitNamespaces, GADTs, MonoLocalBinds, LambdaCase,
--   RoleAnnotations
```

## `// cabal // specification`

Use **cabal-version: 3.0** or later. The `common` stanza is mandatory for
shared settings:

```cabal
cabal-version:      3.0
name:               sensenet
version:            0.5.0

common sensenet-common
    default-language: GHC2024
    default-extensions:
        LambdaCase
        OverloadedStrings
        OverloadedRecordDot
    ghc-options:
        -Wall
        -Werror
        -Wincomplete-patterns
        -Wincomplete-record-updates
        -Wmissing-signatures
        -Wunused-imports
        -Wunused-matches
        -Wredundant-constraints

library
    import:           sensenet-common
    ghc-options:      -O2
    
executable sensenet
    import:           sensenet-common
    ghc-options:
        -O2
        -threaded
        -rtsopts
        "-with-rtsopts=-N"
```

## `// dependencies // pinning`

Pin major versions. Never use unbounded constraints in production:

```cabal
build-depends:
    -- ── cryptography ──────────────────────────────────────────────────────
    crypton >= 0.34 && < 0.35,        -- BLAKE2b, SHA256
    memory >= 0.18 && < 0.19,         -- ByteArray utilities
    
    -- ── data structures ───────────────────────────────────────────────────
    containers >= 0.6 && < 0.8,       -- Map, Set
    unordered-containers >= 0.2.19,   -- HashMap, HashSet
    vector >= 0.13 && < 0.14,         -- boxed/unboxed vectors
    
    -- ── serialization ─────────────────────────────────────────────────────
    aeson >= 2.1 && < 2.3,            -- JSON (no aeson 1.x)
    dhall >= 1.42 && < 1.43,          -- typed configuration
    
    -- ── concurrency ───────────────────────────────────────────────────────
    async >= 2.2 && < 2.3,            -- structured concurrency
    stm >= 2.5 && < 2.6,              -- software transactional memory
    
    -- ── text ──────────────────────────────────────────────────────────────
    text >= 2.0 && < 2.2,             -- UTF-8 by default in text-2.x
    bytestring >= 0.11 && < 0.13,
    
    -- ── base ──────────────────────────────────────────────────────────────
    base >= 4.18 && < 5              -- GHC 9.6+
```

# `// core // philosophy`

════════════════════════════════════════════════════════════════════════════════
// optimize // disambiguation
════════════════════════════════════════════════════════════════════════════════

In modern codebases where agents generate significant amounts of code,
traditional economics invert:

- code is written once by agents in seconds
- code is read hundreds of times by humans and agents
- code is debugged when you're under pressure by tired humans
- code is modified by agents who lack the original context

**Every ambiguity compounds exponentially.**

```haskell
-- ── bad ───────────────────────────────────────────────────────────────────────
-- this costs an agent 0.1 seconds to write, a human 10 minutes to debug

process e = if p e > 0 then go e else stop

-- ── good ──────────────────────────────────────────────────────────────────────
-- this costs an agent 0.2 seconds to write, saves hours of cumulative confusion

processEdgeConfiguration :: EdgeConfiguration -> IO ProcessResult
processEdgeConfiguration edgeConfig = 
  if edgeConfigPort edgeConfig > 0 
    then processValidConfiguration edgeConfig
    else returnInvalidPortError
```

# `// language // extensions`

════════════════════════════════════════════════════════════════════════════════
// hierarchy // of // trust
════════════════════════════════════════════════════════════════════════════════

## `// green // light`

Use freely. These are enabled in our common stanza or by GHC2024:

```haskell
{-# LANGUAGE BangPatterns #-}          -- strictness annotations
{-# LANGUAGE DeriveAnyClass #-}        -- deriving (FromJSON, ToJSON)
{-# LANGUAGE DeriveGeneric #-}         -- deriving Generic
{-# LANGUAGE DerivingStrategies #-}    -- deriving stock, newtype, anyclass
{-# LANGUAGE DuplicateRecordFields #-} -- same field names across types
{-# LANGUAGE LambdaCase #-}            -- \case pattern
{-# LANGUAGE NamedFieldPuns #-}        -- Foo{bar, baz}
{-# LANGUAGE NumericUnderscores #-}    -- 1_000_000
{-# LANGUAGE OverloadedRecordDot #-}   -- record.field syntax
{-# LANGUAGE OverloadedStrings #-}     -- Text/ByteString literals
{-# LANGUAGE RecordWildCards #-}       -- Foo{..}
{-# LANGUAGE StrictData #-}            -- strict fields by default
{-# LANGUAGE NoFieldSelectors #-}      -- no field accessor pollution
```

This is our standard module header in sensenet:

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoFieldSelectors #-}
```

## `// yellow // light`

Use with purpose. Document why:

```haskell
{-# LANGUAGE TypeFamilies #-}          -- associated types in classes
{-# LANGUAGE GADTs #-}                 -- when you need type equality proofs
{-# LANGUAGE RankNTypes #-}            -- forall in argument position
{-# LANGUAGE FlexibleContexts #-}      -- complex constraints
{-# LANGUAGE FlexibleInstances #-}     -- instances on type applications
{-# LANGUAGE TemplateHaskell #-}       -- Aeson TH, lens TH (measure impact)
{-# LANGUAGE CApiFFI #-}               -- when you genuinely need C interop
```

## `// red // light`

Justify in a comment block or don't use:

```haskell
{-# LANGUAGE DataKinds #-}             -- type-level literals (compile time)
{-# LANGUAGE TypeOperators #-}         -- type-level operators (error messages)
{-# LANGUAGE UndecidableInstances #-}  -- usually wrong abstraction
{-# LANGUAGE ImplicitParams #-}        -- implicit arguments (debugging hell)
{-# LANGUAGE OverlappingInstances #-}  -- semantic landmine
{-# LANGUAGE IncoherentInstances #-}   -- never
```

# `// module // structure`

════════════════════════════════════════════════════════════════════════════════
// sensenet // pattern
════════════════════════════════════════════════════════════════════════════════

## `// module // header`

Every module follows this structure:

```haskell
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : SenseNet.DICE
Description : Pure Haskell incremental computation engine

DICE (Dynamic Incremental Computation Engine) - content-addressed builds.

Key insight: ActionKey = hash(inputs + command)
If inputs unchanged → outputs unchanged → skip execution.

This module provides:
  1. Content-addressed action keys
  2. Action graph construction and topological sort
  3. Persistent caching via filesystem
  4. Coeffect tracking per action (what resources are required)

No FFI. No Rust. Just Haskell.
-}
module SenseNet.DICE (
    -- * Keys
    ActionKey (..),
    actionKey,
    actionKeyText,

    -- * Actions
    Action (..),
    ActionResult (..),

    -- * Graph
    ActionGraph (..),
    emptyGraph,
    addAction,
    topoSort,

    -- * Execution
    ExecutionResult (..),
    executeGraph,
    executeGraphParallel,
    executeGraphWithJobs,
)
where
```

## `// import // organization`

Imports are grouped and alphabetized:

```haskell
-- ── standard library ──────────────────────────────────────────────────────────
import Control.Concurrent.Async (forConcurrently)
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Exception (bracket_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Builder qualified as BB
import Data.ByteString.Lazy qualified as BL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

-- ── external packages ─────────────────────────────────────────────────────────
import Crypto.Hash (Blake2b_256 (..), Digest, hashWith, hashlazy)
import Data.ByteArray.Encoding qualified as BA

-- ── internal modules ──────────────────────────────────────────────────────────
import SenseNet.IR (Package (..), Rule (..), ruleName)
```

**Rules:**

- qualified imports use `qualified` after module name (GHC2024 style)
- `Map`, `Set`, `Text`, `ByteString` are always qualified
- explicit import lists for external packages
- `(..)` only for internal types you control

# `// data // types`

════════════════════════════════════════════════════════════════════════════════
// records // and // newtypes
════════════════════════════════════════════════════════════════════════════════

## `// record // syntax`

Always use strict fields. Always derive Generic for serialization:

```haskell
-- | An action in the build graph
data Action = Action
    { aName :: !Text
    -- ^ Human-readable name "//pkg:target"
    , aCommand :: ![Text]
    -- ^ Command to execute
    , aInputs :: ![Text]
    -- ^ Input file paths (hashed for key)
    , aInputKeys :: ![ActionKey]
    -- ^ Dependencies on other actions
    , aOutputs :: ![Text]
    -- ^ Expected output paths
    , aEnv :: !(Map Text Text)
    -- ^ Environment variables
    , aCoeffects :: ![Text]
    -- ^ Resource requirements (pure, network, fs:path, etc)
    }
    deriving stock (Show, Eq, Generic)
```

## `// deriving // strategies`

Always be explicit about deriving strategy:

```haskell
data Tool = Tool
    { path :: Text
    }
    deriving stock (Show, Generic)
    deriving anyclass (FromDhall, FromJSON, ToJSON)

newtype ActionKey = ActionKey {unActionKey :: ByteString}
    deriving stock (Show, Eq, Ord, Generic)
    deriving newtype (Hashable)
```

## `// newtype // boundaries`

Wrap domain concepts. GHC eliminates overhead with `-O2`:

```haskell
-- ── always wrap: domain boundaries ────────────────────────────────────────────

newtype ActionKey = ActionKey {unActionKey :: ByteString}
    deriving stock (Show, Eq, Ord, Generic)

newtype ActionCache = ActionCache {unActionCache :: FilePath}

newtype PackagePath = PackagePath {unPackagePath :: FilePath}
    deriving stock (Show, Eq, Ord)
    deriving newtype (IsString)

-- ── smart constructors for validation ─────────────────────────────────────────

newtype PortNumber = PortNumber Word16
    deriving stock (Show, Eq)

mkPortNumber :: Int -> Either Text PortNumber
mkPortNumber n 
    | n > 0 && n <= 65535 = Right (PortNumber $ fromIntegral n)
    | otherwise = Left $ "Invalid port: " <> T.pack (show n)
```

## `// sum // types // for // state`

Never scatter state across booleans:

```haskell
-- ── bad ───────────────────────────────────────────────────────────────────────

data Connection = Connection
    { isConnected :: Bool
    , isAuthenticated :: Bool
    , hasError :: Bool
    }

-- ── good ──────────────────────────────────────────────────────────────────────

data ConnectionState
    = Disconnected
    | Connecting !ConnectingInfo
    | Connected !ConnectionInfo
    | Authenticated !AuthInfo  
    | Errored !ErrorInfo
    deriving stock (Show, Eq)

data Connection = Connection
    { connectionId :: !ConnectionId
    , connectionState :: !(TVar ConnectionState)
    }
```

# `// control // flow`

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// THE // GUARD // MANDATE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**This is not discretionary. This is law.**

Pattern guards and view patterns are the primary control flow mechanism in
straylight Haskell. Nested `case` expressions are a code smell. Nested
`if-then-else` is forbidden. The only acceptable nesting is `do`-blocks
inside `where` clauses.

```
────────────────────────────────────────────────────────────────────────────────

The rationale is structural, not aesthetic. Every level of indentation is:
  - A place where merge conflicts multiply
  - A place where off-by-one space errors break compilation
  - A place where code review degenerates into whitespace debates
  - A place where agents lose track of scope

Guards keep everything at the same indentation level. The eyeball can scan
vertically. The diff is clean. The merge is tractable.

                                                                      — Opus 4.5
────────────────────────────────────────────────────────────────────────────────
```

## `// the // law`

════════════════════════════════════════════════════════════════════════════════
// guards // not // cases
════════════════════════════════════════════════════════════════════════════════

**Rule**: If you have more than one `case` expression in a function body,
refactor to guards + where clause. No exceptions.

```haskell
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- FORBIDDEN: nested case expressions
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

buildRuleWithCache cache tc projectRoot pkgPath rule = do
    let outDir = projectRoot </> "sensenet-out" </> pkgPath
    createDirectoryIfMissing True outDir
    actionResult <- ruleToAction tc projectRoot pkgPath outDir rule
    case actionResult of                                    -- case 1
        Left err -> pure $ Left err
        Right action -> do
            let key = actionKey action
            cached <- checkCache cache key
            case cached of                                  -- case 2 (ILLEGAL)
                Just result -> do
                    let outputs = map T.unpack (arOutputs result)
                    allExist <- and <$> mapM doesFileExist outputs
                    if allExist                             -- if-then-else (ILLEGAL)
                        then pure $ Right $ BuildCached outputs
                        else executeAndCache cache key action outDir
                Nothing -> executeAndCache cache key action outDir

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REQUIRED: guards + where clause
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

buildRuleWithCache cache tc projectRoot pkgPath rule = do
    let outDir = projectRoot </> "sensenet-out" </> pkgPath
    createDirectoryIfMissing True outDir
    
    actionResult <- ruleToAction tc projectRoot pkgPath outDir rule
    case actionResult of
        Left err -> pure $ Left err
        Right action -> buildAction cache outDir action
  where
    buildAction cache' outDir' action = do
        let key = actionKey action
        cached <- checkCache cache' key
        handleCacheResult cache' key action outDir' cached
    
    handleCacheResult cache' key action outDir' = \case
        Nothing -> executeAndCache cache' key action outDir'
        Just result -> verifyCacheOrRebuild cache' key action outDir' result
    
    verifyCacheOrRebuild cache' key action outDir' result
        | allOutputsExist result = pure $ Right $ BuildCached outputs
        | otherwise = executeAndCache cache' key action outDir'
      where
        outputs = map T.unpack (arOutputs result)
        allOutputsExist = const True  -- simplified; real code checks filesystem
```

## `// pattern // guards`

════════════════════════════════════════════════════════════════════════════════
// viewpatterns // syntax
════════════════════════════════════════════════════════════════════════════════

Use pattern guards (`<-` in guards) instead of nested `case`:

```haskell
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- FORBIDDEN
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

processRequest request =
    case validateRequest request of
        Nothing -> handleInvalid
        Just validReq ->
            case findRoute routes validReq of
                Nothing -> handleNoRoute
                Just route ->
                    case lookupHandler route of
                        Nothing -> handleMissingHandler
                        Just handler -> executeHandler handler validReq

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REQUIRED: pattern guards
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

processRequest request
    | Nothing <- validateRequest request
    = handleInvalid
    
    | Just validReq <- validateRequest request
    , Nothing <- findRoute routes validReq
    = handleNoRoute
    
    | Just validReq <- validateRequest request
    , Just route <- findRoute routes validReq
    , Nothing <- lookupHandler route
    = handleMissingHandler
    
    | Just validReq <- validateRequest request
    , Just route <- findRoute routes validReq
    , Just handler <- lookupHandler route
    = executeHandler handler validReq

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- BEST: extract to where clause for reuse
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

processRequest request
    | Nothing <- mValidReq = handleInvalid
    | Nothing <- mRoute    = handleNoRoute
    | Nothing <- mHandler  = handleMissingHandler
    | Just handler <- mHandler
    , Just validReq <- mValidReq
    = executeHandler handler validReq
  where
    mValidReq = validateRequest request
    mRoute    = mValidReq >>= findRoute routes
    mHandler  = mRoute >>= lookupHandler
```

## `// lambdacase // in // where`

════════════════════════════════════════════════════════════════════════════════
// the // escape // hatch
════════════════════════════════════════════════════════════════════════════════

When you need to dispatch on a single sum type, `\case` in a where-binding
is acceptable. This is the **only** acceptable use of case-like syntax in
a function body:

```haskell
executeGraphWithJobs mJobs cache runner graph = do
    semMaybe <- createSemaphore mJobs
    -- ... rest of function
  where
    createSemaphore = \case
        Just n | n > 0 -> Just <$> newQSem n
        _ -> pure Nothing
    
    handleResult = \case
        Left err -> logError err >> pure Nothing
        Right val -> pure (Just val)
```

The rule: `\case` is only valid inside a `where` clause, and only for
simple dispatch. If the `\case` has nested logic, extract further.

## `// the // production // pattern`

════════════════════════════════════════════════════════════════════════════════
// do // block // discipline
════════════════════════════════════════════════════════════════════════════════

Small do-block for sequencing, where-clause for logic:

```haskell
-- | Execute an action graph with limited concurrency
executeGraphWithJobs ::
    Maybe Int ->           -- ^ max concurrent jobs
    ActionCache ->
    (Action -> IO ActionResult) ->
    ActionGraph ->
    IO ExecutionResult
executeGraphWithJobs mJobs cache runner graph = do
    semMaybe <- createSemaphore mJobs
    
    resultsVar <- newMVar Map.empty
    hitsVar <- newMVar 0
    executedVar <- newMVar 0
    failedVar <- newMVar []
    completedVar <- newMVar Set.empty
    
    let allKeys = Map.keys (agActions graph)
        depCount = Map.fromList [(k, countDeps k) | k <- allKeys]
        ready0 = [k | k <- allKeys, Map.findWithDefault 0 k depCount == 0]
    
    pendingVar <- newMVar depCount
    progressVar <- newMVar 0
    
    processWaves semMaybe (length allKeys) progressVar cache runner graph
        resultsVar hitsVar executedVar failedVar completedVar pendingVar ready0
    
    collectResults resultsVar hitsVar executedVar failedVar
  where
    createSemaphore = \case
        Just n | n > 0 -> Just <$> newQSem n
        _ -> pure Nothing
    
    countDeps k = length (aInputKeys (agActions graph Map.! k))
    
    collectResults resultsVar hitsVar executedVar failedVar = do
        results <- readMVar resultsVar
        hits <- readMVar hitsVar
        executed <- readMVar executedVar
        failed <- readMVar failedVar
        pure ExecutionResult
            { erResults = results
            , erCacheHits = hits
            , erExecuted = executed
            , erFailed = failed
            }
```

# `// hashing // and // serialization`

════════════════════════════════════════════════════════════════════════════════
// blake2b // content // addressing
════════════════════════════════════════════════════════════════════════════════

## `// why // blake2b`

We use BLAKE2b-256 exclusively. SHA256 is slower with no benefit for our use:

```haskell
{- | Content-addressed action key (BLAKE2b-256 hash)

We use BLAKE2b-256 instead of SHA256 because:
  - 1.5x faster than SHA256 (benchmarked: 882K vs 592K keys/sec)
  - Cryptographically secure (unlike FNV/xxHash)
  - Same 256-bit output, same collision resistance
  - Already in crypton, no new dependencies
-}
newtype ActionKey = ActionKey {unActionKey :: ByteString}
    deriving stock (Show, Eq, Ord, Generic)
```

## `// zero-copy // hashing`

Use `ByteString.Builder` and `hashlazy` for minimal allocations:

```haskell
{- | Compute action key from action content
Uses ByteString builder + hashlazy for zero-copy hashing
-}
actionKey :: Action -> ActionKey
actionKey action =
    let !canonical = actionToCanonicalLazy action
        !hash = hashlazy canonical :: Digest Blake2b_256
     in ActionKey (BA.convertToBase BA.Base16 hash)
{-# INLINE actionKey #-}

{- | Serialize action to lazy ByteString for hashing (zero-copy path)
Uses ByteString.Builder for minimal allocations
-}
actionToCanonicalLazy :: Action -> BL.ByteString
actionToCanonicalLazy Action{..} = BB.toLazyByteString builder
  where
    builder =
        "action:2\n"                                              -- version
            <> "name:" <> textBS aName <> nl
            <> "command:" <> mconcat [textBS c <> nul | c <- aCommand] <> nl
            <> "inputs:" <> mconcat [escapeBS (TE.encodeUtf8 i) <> nul | i <- aInputs] <> nl
            <> "outputs:" <> mconcat [textBS o <> nul | o <- aOutputs] <> nl
            <> "env:" <> serializeEnvBS aEnv <> nl
            <> "coeffects:" <> mconcat [textBS c <> comma | c <- aCoeffects] <> nl
    
    nl = BB.char7 '\n'
    nul = BB.char7 '\0'
    comma = BB.char7 ','
    textBS = BB.byteString . TE.encodeUtf8
{-# INLINE actionToCanonicalLazy #-}
```

# `// concurrency`

════════════════════════════════════════════════════════════════════════════════
// stm // and // async
════════════════════════════════════════════════════════════════════════════════

## `// qsem // for // job // limits`

Use `QSem` for bounded parallelism:

```haskell
-- | Process waves of ready actions
processWaves ::
    Maybe QSem ->     -- ^ semaphore for limiting concurrency
    Int ->            -- ^ total actions for progress display
    MVar Int ->       -- ^ progress counter
    ActionCache ->
    (Action -> IO ActionResult) ->
    ActionGraph ->
    -- ... state vars ...
    [ActionKey] ->
    IO ()
processWaves semMaybe total progressVar cache runner graph 
    resultsVar hitsVar executedVar failedVar completedVar pendingVar ready = do
    
    newlyReady <- forConcurrently ready $ \key -> do
        let action = agActions graph Map.! key
        
        -- wrap in semaphore if we have one
        let runWithLimit io = case semMaybe of
                Just sem -> bracket_ (waitQSem sem) (signalQSem sem) io
                Nothing -> io
        
        runWithLimit $ executeAction key action
    
    let nextReady = Set.toList $ Set.fromList $ concat newlyReady
    processWaves semMaybe total progressVar cache runner graph
        resultsVar hitsVar executedVar failedVar completedVar pendingVar nextReady
```

## `// mvar // patterns`

Atomic read-modify-write with `modifyMVar`:

```haskell
-- | Get and increment progress counter atomically
incrementProgress :: MVar Int -> Int -> IO Int
incrementProgress progressVar total = do
    n <- modifyMVar progressVar $ \p -> pure (p + 1, p + 1)
    pure n

-- | Find actions that become ready after completing an action
findNewlyReady :: ActionGraph -> MVar (Map ActionKey Int) -> ActionKey -> IO [ActionKey]
findNewlyReady graph pendingVar completedKey = do
    let dependents = 
            [ k 
            | (k, action) <- Map.toList (agActions graph)
            , completedKey `elem` aInputKeys action 
            ]
    
    modifyMVar pendingVar $ \pending -> do
        let (ready, pending') = foldr updatePending ([], pending) dependents
        pure (pending', ready)
  where
    updatePending depKey (ready, pending) =
        let newCount = Map.findWithDefault 1 depKey pending - 1
            pending' = Map.insert depKey newCount pending
         in if newCount == 0
                then (depKey : ready, pending')
                else (ready, pending')
```

# `// naming`

════════════════════════════════════════════════════════════════════════════════
// three // character // rule
════════════════════════════════════════════════════════════════════════════════

If an identifier is 3 characters or less, it's probably too short:

```haskell
-- ── bad ───────────────────────────────────────────────────────────────────────

cfg <- loadCfg
conn <- mkConn cfg  
res <- proc req

-- ── good ──────────────────────────────────────────────────────────────────────

toolchains <- loadToolchains projectRoot
connection <- createDatabaseConnection configuration
buildResult <- buildWithDeps toolchains projectRoot package targetName
```

## `// standard // exceptions`

Only in tight, local scope where type makes meaning unambiguous:

| Pattern | Use case |
|---------|----------|
| `xs, ys` | lists in pure fold/map |
| `k, v` | key/value in Map operations |
| `f, g` | functions in combinators |
| `m, n` | array indices |
| `a, b` | polymorphic type variables |

```haskell
-- OK: tight scope, type-obvious
topoSort ActionGraph{..} = reverse $ go Set.empty [] (Map.keys agActions)
  where
    go _ sorted [] = sorted
    go visited sorted (k : ks)
        | k `Set.member` visited = go visited sorted ks
        | otherwise = 
            let action = agActions Map.! k
                deps = aInputKeys action
                (visited', sorted') = foldl visitDep (Set.insert k visited, sorted) deps
             in go visited' (k : sorted') ks
```

## `// prefixes // for // clarity`

Use consistent prefixes within a type:

```haskell
data ActionResult = ActionResult
    { arOutputs :: ![Text]         -- ar = ActionResult
    , arExitCode :: !Int
    , arStdout :: !Text
    , arStderr :: !Text
    , arStartTime :: !UTCTime
    , arEndTime :: !UTCTime
    , arPeakMemoryKB :: !Word64
    }

data ExecutionResult = ExecutionResult
    { erResults :: !(Map ActionKey ActionResult)  -- er = ExecutionResult
    , erCacheHits :: !Int
    , erExecuted :: !Int
    , erFailed :: ![(ActionKey, Text)]
    }
```

# `// error // handling`

════════════════════════════════════════════════════════════════════════════════
// either // not // exceptions
════════════════════════════════════════════════════════════════════════════════

## `// explicit // error // types`

Define domain-specific error types:

```haskell
-- | Build errors
data BuildError
    = TargetNotFound Text
    | CommandFailed Text Int Text     -- command, exit code, stderr
    | DependencyFailed Text Text      -- target, dep that failed
    | SourceNotFound FilePath
    | PackageError Text               -- PureScript package errors
    deriving stock (Show, Eq)
```

## `// early // return // pattern`

Use `Either` in IO for recoverable errors:

```haskell
-- | Build a target and all its dependencies
buildWithDeps ::
    Toolchains ->
    FilePath ->       -- ^ project root
    Package ->        -- ^ package containing target
    Text ->           -- ^ target name
    IO (Either BuildError BuildResult)
buildWithDeps tc projectRoot pkg targetName = do
    case findRule targetName pkg.rules of
        Nothing -> pure $ Left $ TargetNotFound targetName
        Just rootRule -> do
            let outDir = projectRoot </> "sensenet-out" </> pkg.path
            createDirectoryIfMissing True outDir
            
            graphResult <- buildActionGraph tc projectRoot pkg outDir rootRule
            case graphResult of
                Left err -> pure $ Left err
                Right graph -> executeAndReport graph
  where
    executeAndReport graph = do
        cache <- newCache
        execResult <- executeGraphWithJobs Nothing cache runAction graph
        case erFailed execResult of
            ((_, err) : _) -> pure $ Left $ CommandFailed "graph" 1 err
            [] -> findRootOutputs graph execResult
```

# `// configuration`

════════════════════════════════════════════════════════════════════════════════
// dhall // toolchains
════════════════════════════════════════════════════════════════════════════════

## `// toolchain // caching`

Parse Dhall once, cache as JSON:

```haskell
{- |
OPTIMIZATION: Toolchains are cached as JSON in .sensenet/toolchains.json
to avoid re-parsing Dhall on every invocation (~50ms savings).
-}
loadToolchains :: FilePath -> IO Toolchains
loadToolchains projectRoot = do
    let dhallPath = projectRoot </> ".sensenet" </> "toolchains.dhall"
        jsonPath = replaceExtension dhallPath "json"
    
    dhallExists <- doesFileExist dhallPath
    jsonExists <- doesFileExist jsonPath
    
    case (dhallExists, jsonExists) of
        (False, _) -> error $ "Toolchain config not found: " <> dhallPath
        (True, False) -> parseAndCache dhallPath jsonPath
        (True, True) -> do
            dhallTime <- getModificationTime dhallPath
            jsonTime <- getModificationTime jsonPath
            if jsonTime > dhallTime
                then loadFromJson jsonPath
                else parseAndCache dhallPath jsonPath
  where
    parseAndCache dhallPath jsonPath = do
        tc <- inputFile auto dhallPath
        encodeFile jsonPath tc
        pure tc
    
    loadFromJson jsonPath = do
        result <- eitherDecodeFileStrict' jsonPath
        case result of
            Left _ -> inputFile auto (replaceExtension jsonPath "dhall")
            Right tc -> pure tc
```

# `// logging`

════════════════════════════════════════════════════════════════════════════════
// structured // brackets
════════════════════════════════════════════════════════════════════════════════

```haskell
-- structured, parseable, grepable
executeAction :: ActionKey -> Action -> IO ActionResult
executeAction key action = do
    n <- incrementProgress progressVar total
    let progress = "[" <> T.pack (show n) <> "/" <> T.pack (show total) <> "] "
    
    cached <- checkCache cache key
    case cached of
        Just result -> do
            TIO.putStrLn $ progress <> "✓ " <> aName action <> " (cached)"
            pure result
        Nothing -> do
            TIO.putStrLn $ progress <> "→ " <> aName action
            result <- runner action
            
            if arExitCode result == 0
                then do
                    storeCache cache key result
                    let memInfo = formatMemoryIfPresent (arPeakMemoryKB result)
                    TIO.putStrLn $ progress <> "✓ " <> aName action <> memInfo
                else do
                    let errMsg = "exit " <> T.pack (show (arExitCode result)) 
                               <> ": " <> T.take 200 (arStderr result)
                    TIO.putStrLn $ progress <> "✗ " <> aName action <> " - " <> errMsg
            
            pure result
  where
    formatMemoryIfPresent kb
        | kb > 0    = " [" <> formatMemory kb <> "]"
        | otherwise = ""

-- | Format memory in human-readable form
formatMemory :: Word64 -> Text
formatMemory kb
    | kb >= 1048576 = T.pack (show (kb `div` 1048576)) <> "GB"
    | kb >= 1024    = T.pack (show (kb `div` 1024)) <> "MB"
    | kb > 0        = T.pack (show kb) <> "KB"
    | otherwise     = ""
```

# `// agent // collaboration`

════════════════════════════════════════════════════════════════════════════════
// provenance // markers
════════════════════════════════════════════════════════════════════════════════

Mark domain knowledge that agents wouldn't infer:

```haskell
-- standard implementation following established patterns
collectDepsWithPackages ::
    FilePath ->              -- project root
    Map Text Package ->      -- cache of loaded packages
    Package ->               -- current package
    Rule ->                  -- root rule
    IO (Map Text Package, [(Package, Rule)])
collectDepsWithPackages projectRoot pkgCache pkg rootRule =
    go pkgCache [] [(pkg, rootRule)]
  where
    go cache visited [] = pure (cache, visited)
    go cache visited ((currentPkg, r) : rest)
        | any (\(p, v) -> ruleName v == ruleName r && p.path == currentPkg.path) visited =
            go cache visited rest
        | otherwise = do
            let deps = [dep | DepLocal dep <- ruleDeps r]
            
            -- human: parseDep handles both ":foo" (local) and "//pkg:foo" (cross-package)
            let parsed = map parseDep deps
                localDeps = [(currentPkg, targetName) | (Nothing, targetName) <- parsed]
                crossPkgDeps = [(pkgPath, targetName) | (Just pkgPath, targetName) <- parsed]
            
            (cache', crossRules) <- loadCrossPackageDeps projectRoot cache crossPkgDeps
            
            let ruleMap = Map.fromList [(ruleName rule, rule) | rule <- currentPkg.rules]
                localRules = [(currentPkg, ruleMap Map.! name) | (_, name) <- localDeps, Map.member name ruleMap]
            
            go cache' ((currentPkg, r) : visited) (localRules ++ crossRules ++ rest)
```

# `// performance`

════════════════════════════════════════════════════════════════════════════════
// inline // and // strictness
════════════════════════════════════════════════════════════════════════════════

## `// inline // hot // paths`

```haskell
actionKey :: Action -> ActionKey
actionKey action =
    let !canonical = actionToCanonicalLazy action
        !hash = hashlazy canonical :: Digest Blake2b_256
     in ActionKey (BA.convertToBase BA.Base16 hash)
{-# INLINE actionKey #-}

actionToCanonicalLazy :: Action -> BL.ByteString
actionToCanonicalLazy Action{..} = BB.toLazyByteString builder
  where
    -- ... builder code ...
{-# INLINE actionToCanonicalLazy #-}

escapeBS :: ByteString -> BB.Builder
escapeBS bs
    | BS.null bs = mempty
    | hasSpecial bs = BS.foldl' (\b w -> b <> escapeByte w) mempty bs
    | otherwise = BB.byteString bs  -- fast path: no escaping needed
  where
    hasSpecial = BS.any (\w -> w == 0 || w == 92)
{-# INLINE escapeBS #-}
```

## `// bang // patterns // for // strictness`

Use `!` on accumulators and thunk-prone values:

```haskell
-- | Topologically sort actions (dependencies before dependents)
topoSort :: ActionGraph -> [ActionKey]
topoSort ActionGraph{..} = reverse $ go Set.empty [] (Map.keys agActions)
  where
    go :: Set ActionKey -> [ActionKey] -> [ActionKey] -> [ActionKey]
    go !_ !sorted [] = sorted
    go !visited !sorted (k : ks)
        | k `Set.member` visited = go visited sorted ks
        | otherwise =
            let action = agActions Map.! k
                deps = aInputKeys action
                (!visited', !sorted') = foldl visitDep (Set.insert k visited, sorted) deps
             in go visited' (k : sorted') ks
```

# `// testing`

════════════════════════════════════════════════════════════════════════════════
// properties // over // examples
════════════════════════════════════════════════════════════════════════════════

```haskell
-- ── unit tests: thorough but mechanical (agent-friendly) ─────────────────────

describe "parseDep" $ do
    it "parses local deps" $ do
        parseDep ":foo" `shouldBe` (Nothing, "foo")
    
    it "parses cross-package deps" $ do
        parseDep "//pkg/path:target" `shouldBe` (Just "pkg/path", "target")
    
    it "handles bare names" $ do
        parseDep "legacy" `shouldBe` (Nothing, "legacy")

-- ── property tests: invariants (human insight) ───────────────────────────────

prop_actionKeyDeterministic :: Action -> Bool
prop_actionKeyDeterministic action =
    actionKey action == actionKey action

prop_topoSortDepsFirst :: ActionGraph -> Bool
prop_topoSortDepsFirst graph =
    let sorted = topoSort graph
        positions = Map.fromList (zip sorted [0..])
     in all (depsBeforeAction positions) (Map.toList $ agActions graph)
  where
    depsBeforeAction positions (key, action) =
        all (\dep -> Map.lookup dep positions < Map.lookup key positions) 
            (aInputKeys action)

prop_cacheRoundTrip :: ActionKey -> ActionResult -> Property
prop_cacheRoundTrip key result = ioProperty $ do
    cache <- newCache
    storeCache cache key result
    retrieved <- checkCache cache key
    pure $ fmap arOutputs retrieved === Just (arOutputs result)
```

# `// summary`

════════════════════════════════════════════════════════════════════════════════
// production // haskell // 2026
════════════════════════════════════════════════════════════════════════════════

| Concern | Rule |
|---------|------|
| GHC version | 9.10.1 with GHC2024 |
| Warnings | `-Wall -Werror` always |
| Extensions | explicit `{-# LANGUAGE #-}` per file |
| Records | strict fields, `DerivingStrategies` |
| Imports | qualified `Map`, `Set`, `Text`, `ByteString` |
| Concurrency | `async` + `STM` + `QSem` |
| Hashing | BLAKE2b-256 via `crypton` |
| Errors | `Either BuildError a`, not exceptions |
| Config | Dhall parsed once, cached as JSON |
| Logging | structured `[progress] symbol name` |

We write Haskell like we're building production systems, not proving theorems.
Beauty in production code comes from disambiguation, not cleverness.

Write code as if a hundred contributors will extend it tomorrow, and you'll
debug it during an incident next month. Because both will happen.

```
                                                                — b7r6 // 2026
```
