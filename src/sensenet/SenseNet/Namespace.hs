{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

{- |
Module      : SenseNet.Namespace
Description : Linux namespace setup for Buck2 execution

Creates a mount namespace where the project appears to have
all generated files (BUCK, toolchains, prelude) in place,
without modifying the actual filesystem.
-}
module SenseNet.Namespace
  ( execInNamespace
  , execSimple
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Shelly hiding ((</>))
import System.FilePath ((</>), takeDirectory)

import SenseNet.Config
import SenseNet.Discover (DhallFile(..))

default (Text)

-- | Execute buck2 in a namespace with bind-mounted generated files
--
-- Strategy:
--   1. unshare --user --map-root-user --mount creates new namespace
--   2. Remove symlinks/create dirs for mount points
--   3. Bind mount generated files over project locations:
--      - toolchains/ (with generated BUCK and .bzl files)
--      - prelude/ (the buck2-prelude)
--      - .buckconfig (the generated config)
--      - Each BUCK file from tmpdir into its source location
--   4. Exec buck2
execInNamespace :: Config -> [DhallFile] -> FilePath -> [Text] -> Sh ()
execInNamespace cfg files buck2 args = do
  let toolchainsSrc = T.pack $ generatedToolchains cfg
      toolchainsDst = T.pack $ projectRoot cfg </> "toolchains"
      preludeSrc = T.pack $ generatedPrelude cfg
      preludeDst = T.pack $ projectRoot cfg </> "prelude"
      buckconfigSrc = T.pack $ generatedBuckconfig cfg
      buckconfigDst = T.pack $ projectRoot cfg </> ".buckconfig"
      root = T.pack $ projectRoot cfg
  
  -- Generate BUCK file mount commands
  let buckMounts = concatMap (buckMountCmd cfg) files
  
  -- Build mount script
  -- Note: We use tmpfs+bind to overlay directories without modifying the real filesystem.
  -- The rm/mkdir approach was DELETING the actual files because file operations 
  -- in a mount namespace still affect the underlying filesystem!
  let script = T.unlines $
        [ "set -e"
        -- Ensure mount points exist (create if missing, don't delete!)
        , "mkdir -p " <> toolchainsDst <> " 2>/dev/null || true"
        , "mkdir -p " <> preludeDst <> " 2>/dev/null || true"
        , "touch " <> buckconfigDst <> " 2>/dev/null || true"
        -- Bind mount generated directories over existing ones
        , "mount --bind " <> toolchainsSrc <> " " <> toolchainsDst <> " || echo 'MOUNT FAILED: toolchains'"
        , "mount --bind " <> preludeSrc <> " " <> preludeDst <> " || echo 'MOUNT FAILED: prelude'"
        , "mount --bind " <> buckconfigSrc <> " " <> buckconfigDst <> " || echo 'MOUNT FAILED: buckconfig'"
        ]
        -- Mount each generated BUCK file
        ++ buckMounts
        ++
        [ "cd " <> root
        -- Use --no-buckd to run buck2 in-process, avoiding daemon that runs outside namespace
        , "exec " <> T.pack buck2 <> " --no-buckd " <> T.unwords args
        ]
  
  -- Execute via unshare
  run_ "unshare" 
    [ "--user"
    , "--map-root-user"  
    , "--mount"
    , "sh", "-c", script
    ]

-- | Generate mount commands for a BUCK file
buckMountCmd :: Config -> DhallFile -> [Text]
buckMountCmd cfg file
  | "BUILD.dhall" `T.isSuffixOf` T.pack (dhallPath file) =
      let srcDir = takeDirectory (dhallRelPath file)
          buckSrc = T.pack $ tmpDir cfg </> srcDir </> "BUCK"
          buckDst = T.pack $ projectRoot cfg </> srcDir </> "BUCK"
      in [ "touch " <> buckDst <> " 2>/dev/null || true"
         , "mount --bind " <> buckSrc <> " " <> buckDst
         ]
  | otherwise = []

-- | Simple fallback without namespaces — uses --config-file flag
execSimple :: Config -> FilePath -> [Text] -> Sh ()
execSimple cfg buck2 args = do
  cd (fromText $ T.pack $ projectRoot cfg)
  run_ (fromText $ T.pack buck2) ("--config-file" : T.pack (generatedBuckconfig cfg) : args)
