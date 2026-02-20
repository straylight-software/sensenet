{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | PureScript build functions
module SenseNet.Build.PureScript
  ( buildPureScriptApp,
    buildPureScriptBinary,
  )
where

import Data.Text qualified as T
import SenseNet.Build.Helpers (copyFile, runProcessWithPath)
import SenseNet.Build.Types (BuildError (..), BuildResult (..))
import SenseNet.IR qualified as IR
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))

buildPureScriptApp :: TC.Toolchains -> FilePath -> FilePath -> IR.PureScriptApp -> IO (Either BuildError BuildResult)
buildPureScriptApp tc projectRoot pkgPath app = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBundle = outDir </> "app.js"

  -- Toolchain - spago needs purs, node, esbuild in PATH
  let spago = T.unpack tc.purescript.spago.path
      purs = takeDirectory $ T.unpack tc.purescript.purs.path
      node = takeDirectory $ T.unpack tc.purescript.node.path
      esbuild = takeDirectory $ T.unpack tc.purescript.esbuild.path
      extraPaths = [purs, node, esbuild]

  createDirectoryIfMissing True outDir

  -- Use spago to build and bundle (must run from project directory)
  let args = ["bundle", "--outfile", outBundle]
      cmd = spago : args

  (exitCode, stderr) <- runProcessWithPath srcDir extraPaths spago args
  case exitCode of
    ExitSuccess -> do
      -- Copy index.html and style.css if present
      case app.indexHtml of
        Just html -> do
          let src = srcDir </> T.unpack html
              dst = outDir </> T.unpack html
          exists <- doesFileExist src
          if exists then copyFile src dst else pure ()
        Nothing -> pure ()
      case app.styleCss of
        Just css -> do
          let src = srcDir </> T.unpack css
              dst = outDir </> T.unpack css
          exists <- doesFileExist src
          if exists then copyFile src dst else pure ()
        Nothing -> pure ()
      pure $ Right $ BuildSuccess [outBundle]
    ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildPureScriptBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.PureScriptBinary -> IO (Either BuildError BuildResult)
buildPureScriptBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBundle = outDir </> T.unpack bin.name <> ".js"

  -- Toolchain - spago needs purs, node, esbuild in PATH
  let spago = T.unpack tc.purescript.spago.path
      purs = takeDirectory $ T.unpack tc.purescript.purs.path
      node = takeDirectory $ T.unpack tc.purescript.node.path
      esbuild = takeDirectory $ T.unpack tc.purescript.esbuild.path
      extraPaths = [purs, node, esbuild]

  createDirectoryIfMissing True outDir

  -- Use spago to build and bundle for Node (must run from project directory)
  let args = ["bundle", "--platform", "node", "--outfile", outBundle]
      cmd = spago : args

  (exitCode, stderr) <- runProcessWithPath srcDir extraPaths spago args
  case exitCode of
    ExitSuccess -> pure $ Right $ BuildSuccess [outBundle]
    ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
