{-# LANGUAGE OverloadedStrings #-}

-- | Build result and error types
module SenseNet.Build.Types
  ( BuildResult (..),
    BuildError (..),
    BuildContext (..),
    PackageCache,
  )
where

import Data.IORef (IORef)
import Data.Map.Strict (Map)
import Data.Set (Set)
import Data.Text (Text)
import SenseNet.DICE (DICEError)
import SenseNet.IR qualified as IR
import SenseNet.Toolchains qualified as TC

-- | Result of a successful build
data BuildResult
  = BuildSuccess [FilePath] -- Output files
  | BuildCached [FilePath] -- Already up to date
  deriving (Show, Eq)

-- | Build errors
data BuildError
  = SourceNotFound FilePath
  | CompileFailed Text Int Text -- cmd, exit code, stderr
  | LinkFailed Text Int Text
  | DICEFailed DICEError
  | TargetNotFound Text
  | UnsupportedRule Text
  | PackageNotFound Text
  | ToolchainError Text -- Toolchain not configured or missing
  deriving (Show, Eq)

-- | Cache for loaded packages to avoid re-parsing BUILD.dhall
type PackageCache = IORef (Map FilePath IR.Package)

-- | State for cross-package dependency resolution
data BuildContext = BuildContext
  { bcProjectRoot :: !FilePath,
    bcToolchains :: !TC.Toolchains,
    bcPkgCache :: !PackageCache,
    bcProcessed :: !(IORef (Set Text)), -- Fully qualified target names already registered
    bcRuleMap :: !(IORef (Map Text (IR.Rule, FilePath))) -- target -> (rule, pkgPath)
  }
