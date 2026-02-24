--| Core Types
--|
--| Re-exports base types from libevring, with compatibility aliases
--| for sensenet's Haskell parser.

let Evring = ../evring/package.dhall

-- Re-export CxxStandard as CxxStd for backward compat
let CxxStd = Evring.CxxStandard

-- Simplified Dep for sensenet parser compatibility
-- (sensenet's Haskell expects < Flake : Text | Local : Text >)
let Dep = < Local : Text | Flake : Text >

-- Simplified Vis for sensenet parser compatibility
let Vis = < Public | Private >

in  { Dep
    , CxxStd
    , Vis
    , local = Dep.Local
    , flake = Dep.Flake
    , nix = \(p : Text) -> Dep.Flake "nixpkgs#${p}"
    -- Re-exports from libevring
    , Triple = Evring.Triple
    , Arch = Evring.Arch
    , OS = Evring.OS
    , Cpu = Evring.Cpu
    , Gpu = Evring.Gpu
    , Coeffect = Evring.Coeffect
    , Coeffects = Evring.Coeffects
    }
