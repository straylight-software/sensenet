{- |
Module      : SenseNet.Config
Description : Configuration types for sensenet

Project configuration and paths.
-}
module SenseNet.Config where

import System.FilePath ((</>))

-- | Project configuration
data Config = Config
  { projectRoot :: FilePath
  , preludePath :: FilePath        -- ^ Path to buck2-prelude (from Nix)
  , toolchainsPath :: FilePath     -- ^ Path to sensenet toolchains (from Nix)
  , tmpDir :: FilePath             -- ^ Temporary directory for generated files
  }

-- | Paths within the generated tmpdir
generatedPrelude :: Config -> FilePath
generatedPrelude cfg = tmpDir cfg </> "prelude"

generatedToolchains :: Config -> FilePath
generatedToolchains cfg = tmpDir cfg </> "toolchains"

generatedBuckconfig :: Config -> FilePath
generatedBuckconfig cfg = tmpDir cfg </> ".buckconfig"
