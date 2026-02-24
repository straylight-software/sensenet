--| Coeffect.dhall - The Coeffect Algebra
--|
--| EFFECTS vs COEFFECTS:
--|   Effects:    what a computation DOES to the world
--|   Coeffects:  what a computation NEEDS from the world
--|
--| A pure build needs nothing external (coeffects = ∅).
--| An impure build needs things like network, filesystem, time, random, auth.
--|
--| The TENSOR PRODUCT (++) combines coeffects.
--| Purity is verified before caching.
--|
--| Direct port from Continuity.Coeffect.lean
--|
--| straylight.software · 2026

let Toolchain = ./Toolchain.dhall

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COEFFECT TYPE
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let Coeffect =
      < Pure                            -- Needs nothing
      | Filesystem : Text               -- Needs file (path, non-CA)
      | FilesystemCA : Toolchain.Hash   -- Needs CA content (hash)
      | Network : { host : Text, port : Natural }  -- Needs network endpoint
      | NetworkCA : Toolchain.Hash      -- Needs CA content via network
      | Environment : Text              -- Needs env var
      | Time                            -- Needs wall clock (non-reproducible!)
      | Random                          -- Needs entropy (non-reproducible!)
      | Identity                        -- Needs uid/gid
      | Auth : Text                     -- Needs credential (provider name)
      | Gpu : Text                      -- Needs GPU (device name)
      | Sandbox : Text                  -- Needs sandbox (name)
      >

-- A set of coeffects (List = tensor product)
let Coeffects = List Coeffect

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- PURITY LEVELS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Purity level: higher = purer
let purityLevel
    : Coeffect -> Natural
    = \(c : Coeffect) ->
        merge
          { Pure = 3
          , FilesystemCA = \(_ : Toolchain.Hash) -> 2
          , NetworkCA = \(_ : Toolchain.Hash) -> 2
          , Auth = \(_ : Text) -> 2
          , Gpu = \(_ : Text) -> 2
          , Sandbox = \(_ : Text) -> 2
          , Filesystem = \(_ : Text) -> 1
          , Network = \(_ : { host : Text, port : Natural }) -> 1
          , Environment = \(_ : Text) -> 1
          , Identity = 1
          , Time = 0
          , Random = 0
          }
          c

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- REPRODUCIBILITY
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Is a single coeffect reproducible?
let isReproducibleCoeffect
    : Coeffect -> Bool
    = \(c : Coeffect) ->
        merge
          { Pure = True
          , FilesystemCA = \(_ : Toolchain.Hash) -> True   -- CA = reproducible
          , NetworkCA = \(_ : Toolchain.Hash) -> True      -- CA = reproducible
          , Auth = \(_ : Text) -> True                     -- OK if handled
          , Gpu = \(_ : Text) -> True                      -- Deterministic if seeded
          , Sandbox = \(_ : Text) -> True                  -- OK
          , Filesystem = \(_ : Text) -> False              -- Non-CA = bad
          , Network = \(_ : { host : Text, port : Natural }) -> False
          , Environment = \(_ : Text) -> False             -- Ambient
          , Identity = False                               -- Ambient
          , Time = False                                   -- Non-reproducible!
          , Random = False                                 -- Non-reproducible!
          }
          c

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COEFFECT CONSTRUCTORS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

let pure : Coeffects = [] : Coeffects

let filesystem
    : Text -> Coeffect
    = \(path : Text) -> Coeffect.Filesystem path

let filesystemCA
    : Text -> Coeffect
    = \(sha256 : Text) -> Coeffect.FilesystemCA { sha256 }

let network
    : Text -> Natural -> Coeffect
    = \(host : Text) ->
      \(port : Natural) ->
        Coeffect.Network { host, port }

let networkCA
    : Text -> Coeffect
    = \(sha256 : Text) -> Coeffect.NetworkCA { sha256 }

let env
    : Text -> Coeffect
    = \(varname : Text) -> Coeffect.Environment varname

let auth
    : Text -> Coeffect
    = \(provider : Text) -> Coeffect.Auth provider

let gpu
    : Text -> Coeffect
    = \(device : Text) -> Coeffect.Gpu device

let sandbox
    : Text -> Coeffect
    = \(name : Text) -> Coeffect.Sandbox name

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
-- COMMON COEFFECT SETS
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

-- Needs crates.io
let cratesIo : Coeffects = [ network "crates.io" 443 ]

-- Needs PyPI
let pypi : Coeffects = [ network "pypi.org" 443 ]

-- Needs npmjs.com
let npm : Coeffects = [ network "registry.npmjs.org" 443 ]

-- Needs Nix cache
let nixCache : Coeffects = [ network "cache.nixos.org" 443 ]

-- Needs GitHub
let github : Coeffects = [ network "github.com" 443 ]

in  { -- Types
      Coeffect
    , Coeffects
    -- Analysis
    , purityLevel
    , isReproducibleCoeffect
    -- Constructors
    , pure
    , filesystem
    , filesystemCA
    , network
    , networkCA
    , env
    , auth
    , gpu
    , sandbox
    -- Common sets
    , cratesIo
    , pypi
    , npm
    , nixCache
    , github
    }
