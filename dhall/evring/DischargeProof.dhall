--| DischargeProof.dhall - Evidence of Coeffect Satisfaction
--|
--| A DischargeProof is cryptographic evidence that:
--| 1. The declared coeffects were actually satisfied during build
--| 2. The environment provided what was promised
--| 3. The output hashes match the claimed derivation
--|
--| This enables:
--| - Verified caching (only cache if proof is valid)
--| - Trust propagation (trust proof signers)
--| - Formal verification (Lean can check proof structure)
--|
--| Ported from sensenet/DischargeProof.dhall
--|
--| straylight.software · 2026

let Coeffect = ./Coeffect.dhall
let Toolchain = ./Toolchain.dhall

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- NETWORK ACCESS WITNESS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Recorded by TLS MITM proxy during build
let NetworkAccess =
      { url : Text
      , method : Text                 -- GET, POST, etc.
      , contentHash : Text            -- SHA256 of response body
      , timestamp : Text              -- ISO 8601
      }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- FILESYSTEM ACCESS WITNESS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let FilesystemAccessMode =
      < Read | Write | Execute >

-- Recorded for non-pure builds that access paths outside sandbox
let FilesystemAccess =
      { path : Text
      , mode : FilesystemAccessMode
      , contentHash : Optional Text   -- SHA256 if readable file
      , timestamp : Text              -- ISO 8601
      }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- AUTH TOKEN USAGE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Token value NOT recorded (security), just the provider
let AuthUsage =
      { provider : Text               -- e.g., "github", "docker"
      , scope : Optional Text         -- what scope was used
      , timestamp : Text              -- ISO 8601
      }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- OUTPUT HASH
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let OutputHash =
      { name : Text
      , sha256 : Text
      }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CRYPTOGRAPHIC SIGNATURE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Signs: sha256(derivationHash || outputHashes || evidence)
let Signature =
      { algorithm : Text              -- "ed25519", "ml-dsa-65", "slh-dsa-shake-128f"
      , publicKey : Text              -- Base64 encoded
      , signature : Text              -- Base64 encoded
      }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- DISCHARGE PROOF
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let DischargeProof =
      { -- What coeffects were required
        coeffects : Coeffect.Coeffects
        
        -- Evidence of network access (from witness proxy)
      , networkAccess : List NetworkAccess
        
        -- Evidence of filesystem access (from sandbox hooks)
      , filesystemAccess : List FilesystemAccess
        
        -- Evidence of auth token usage
      , authUsage : List AuthUsage
        
        -- Build metadata
      , buildId : Text                -- Unique build identifier
      , derivationHash : Text         -- Content hash of input derivation
      , outputHashes : List OutputHash
      , startTime : Text              -- ISO 8601
      , endTime : Text                -- ISO 8601
        
        -- Optional cryptographic signature(s)
        -- Can have multiple: ed25519 + post-quantum hybrid
      , signatures : List Signature
      }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- CONSTRUCTORS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Empty proof for pure builds (no external requirements)
let pureProof
    : { buildId : Text
      , derivationHash : Text
      , outputHashes : List OutputHash
      , startTime : Text
      , endTime : Text
      } -> DischargeProof
    = \(meta : { buildId : Text
               , derivationHash : Text
               , outputHashes : List OutputHash
               , startTime : Text
               , endTime : Text
               }) ->
        { coeffects = Coeffect.pure
        , networkAccess = [] : List NetworkAccess
        , filesystemAccess = [] : List FilesystemAccess
        , authUsage = [] : List AuthUsage
        , buildId = meta.buildId
        , derivationHash = meta.derivationHash
        , outputHashes = meta.outputHashes
        , startTime = meta.startTime
        , endTime = meta.endTime
        , signatures = [] : List Signature
        }

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PREDICATES (inline to avoid remote imports)
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Inline List.null to avoid remote import
let listNull
    : forall (a : Type) -> List a -> Bool
    = \(a : Type) ->
      \(xs : List a) ->
        merge { None = True, Some = \(_ : a) -> False }
              (List/head a xs)

-- Inline List.length
let listLength
    : forall (a : Type) -> List a -> Natural
    = \(a : Type) ->
      \(xs : List a) ->
        List/length a xs

-- Check if proof is for pure build
let isPure
    : DischargeProof -> Bool
    = \(p : DischargeProof) ->
        listNull Coeffect.Coeffect p.coeffects

-- Check if proof has network evidence
let hasNetworkEvidence
    : DischargeProof -> Bool
    = \(p : DischargeProof) ->
        listNull NetworkAccess p.networkAccess == False

-- Check if proof is signed
let isSigned
    : DischargeProof -> Bool
    = \(p : DischargeProof) ->
        listNull Signature p.signatures == False

-- Check if proof has hybrid signature (classical + post-quantum)
let hasHybridSignature
    : DischargeProof -> Bool
    = \(p : DischargeProof) ->
        Natural/isZero (Natural/subtract 2 (listLength Signature p.signatures)) == False

in  { -- Types
      NetworkAccess
    , FilesystemAccessMode
    , FilesystemAccess
    , AuthUsage
    , OutputHash
    , Signature
    , DischargeProof
    -- Constructors
    , pureProof
    -- Predicates
    , isPure
    , hasNetworkEvidence
    , isSigned
    , hasHybridSignature
    }
