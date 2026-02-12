{- test/sensenet/build-graph.dhall

   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                                                       // test // build-graph //
   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

   FAILING TEST: Type-safe build graph with proof obligations

   This test exercises the full sense/net build graph typing:
     1. Targets have typed dependencies
     2. Proof obligations propagate through the graph
     3. Resource requirements compose correctly

   Currently fails because:
     1. Buck2 graph audit → Dhall bridge not implemented
     2. Proof obligation propagation not implemented
     3. to-buck2.dhall doesn't emit proof requirements

   ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-}

let Build = ../../dhall/Build.dhall
let Resource = ../../dhall/Resource.dhall
let DischargeProof = ../../dhall/DischargeProof.dhall

--------------------------------------------------------------------------------
-- Target types (simplified from Build.dhall)
--------------------------------------------------------------------------------

let TargetName : Type = Text

let Visibility : Type = < Public | Private | Package >

let Dependency
    : Type
    = { target : TargetName
      , visibility : Visibility
      }

let Target
    : Type
    = { name : TargetName
      , deps : List Dependency
      , srcs : List Text
      , coeffects : Resource.Resources
      }

--------------------------------------------------------------------------------
-- Test 1: Pure target with no dependencies
--
-- A target that compiles local sources with no external requirements
-- Coeffects: Pure
--------------------------------------------------------------------------------

let pure-target : Target =
    { name = "//src/examples/cxx:hello"
    , deps = [] : List Dependency
    , srcs = [ "hello.cpp" ]
    , coeffects = Resource.pure
    }

--------------------------------------------------------------------------------
-- Test 2: Target with local dependencies
--
-- Depends on another target in the same repo
-- Coeffects: should be union of self + dependency coeffects
--------------------------------------------------------------------------------

let lib-target : Target =
    { name = "//src/lib:utils"
    , deps = [] : List Dependency
    , srcs = [ "utils.cpp", "utils.hpp" ]
    , coeffects = Resource.pure
    }

let app-target : Target =
    { name = "//src/app:main"
    , deps = [ { target = "//src/lib:utils", visibility = Visibility.Public } ]
    , srcs = [ "main.cpp" ]
    -- FAILING: coeffects should be inferred from dependency graph
    , coeffects = Resource.pure
    }

--------------------------------------------------------------------------------
-- Test 3: Target with network-fetched dependency
--
-- Depends on a target that fetches from network
-- Coeffects: should inherit network requirement
--------------------------------------------------------------------------------

let fetched-target : Target =
    { name = "//third_party:external-lib"
    , deps = [] : List Dependency
    , srcs = [ "FETCH:https://github.com/example/lib/archive/v1.0.tar.gz" ]
    -- This target needs network access
    , coeffects = Resource.network
    }

let uses-external : Target =
    { name = "//src/app:uses-external"
    , deps =
        [ { target = "//third_party:external-lib", visibility = Visibility.Public }
        ]
    , srcs = [ "app.cpp" ]
    -- FAILING: Should automatically inherit Resource.network from dependency
    , coeffects = Resource.pure  -- BUG: should be Resource.network
    }

--------------------------------------------------------------------------------
-- Test 4: Build graph with proof requirements
--
-- A complete build graph that should be verifiable
--------------------------------------------------------------------------------

let BuildGraph
    : Type
    = { targets : List Target
      , root : TargetName
      }

let test-graph : BuildGraph =
    { targets =
        [ pure-target
        , lib-target
        , app-target
        , fetched-target
        , uses-external
        ]
    , root = "//src/app:uses-external"
    }

--------------------------------------------------------------------------------
-- Test 5: Proof obligation for build graph
--
-- Given a build graph, we should be able to:
--   1. Compute total coeffects (union of all target coeffects)
--   2. Generate a proof obligation
--   3. Verify the proof after build completes
--------------------------------------------------------------------------------

-- FAILING: This function should exist but doesn't
-- let computeGraphCoeffects : BuildGraph → Resource.Resources = ...

-- Manual calculation for test-graph:
-- pure-target: pure
-- lib-target: pure
-- app-target: pure (depends on lib-target which is pure)
-- fetched-target: network
-- uses-external: should be network (depends on fetched-target)
--
-- Total: network

let expected-graph-coeffects : Resource.Resources = Resource.network

--------------------------------------------------------------------------------
-- Test 6: Verify proof structure for build graph
--
-- After building test-graph, we should get a DischargeProof that:
--   1. Has coeffects = network
--   2. Has NetworkAccess evidence for the fetch
--------------------------------------------------------------------------------

let expected-proof-structure : DischargeProof.DischargeProof =
    { coeffects = expected-graph-coeffects
    , networkAccess =
        [ { url = "https://github.com/example/lib/archive/v1.0.tar.gz"
          , method = "GET"
          , contentHash = "sha256-PLACEHOLDER"
          , timestamp = "2025-02-12T00:00:00Z"
          }
        ]
    , filesystemAccess = [] : List DischargeProof.FilesystemAccess
    , authUsage = [] : List DischargeProof.AuthUsage
    , buildId = "graph-build-001"
    , derivationHash = "sha256-PLACEHOLDER"
    , outputHashes =
        [ { name = "//src/app:uses-external", hash = "sha256-PLACEHOLDER" }
        ]
    , startTime = "2025-02-12T00:00:00Z"
    , endTime = "2025-02-12T00:01:00Z"
    , signature = None { publicKey : Text, sig : Text }
    }

--------------------------------------------------------------------------------
-- Export tests
--------------------------------------------------------------------------------

in  { -- Individual targets
      pure-target
    , lib-target
    , app-target
    , fetched-target
    , uses-external
      -- Build graph
    , test-graph
      -- Expected results
    , expected-graph-coeffects
    , expected-proof-structure
      -- Test metadata
    , __tests =
        { coeffect-propagation =
            { description = "Coeffects propagate through dependency graph"
            , status = "FAILING"
            , reason = "computeGraphCoeffects not implemented"
            }
        , proof-generation =
            { description = "Generate proof obligations from build graph"
            , status = "FAILING"
            , reason = "to-buck2.dhall doesn't emit proof requirements"
            }
        , graph-verification =
            { description = "Verify completed build satisfies proof obligations"
            , status = "FAILING"
            , reason = "Lean4 verifier not integrated"
            }
        }
    }
