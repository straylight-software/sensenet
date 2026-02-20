{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Genrule build functions
module SenseNet.Build.Genrule
  ( buildGenrule,
  )
where

import Data.Text qualified as T
import SenseNet.Build.Types (BuildError (..), BuildResult (..))
import SenseNet.IR qualified as IR
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

buildGenrule :: TC.Toolchains -> FilePath -> FilePath -> IR.Genrule -> IO (Either BuildError BuildResult)
buildGenrule _tc projectRoot pkgPath gen = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outPath = outDir </> T.unpack gen.out

  createDirectoryIfMissing True outDir

  -- Substitute $SRCS and $OUT in command
  let srcs = T.intercalate " " $ map (\s -> T.pack $ srcDir </> T.unpack s) gen.srcs
      cmd = T.replace "$SRCS" srcs $ T.replace "$OUT" (T.pack outPath) gen.cmd

  (exitCode, _, stderr) <- readProcessWithExitCode "sh" ["-c", T.unpack cmd] ""

  case exitCode of
    ExitSuccess -> pure $ Right $ BuildSuccess [outPath]
    ExitFailure n -> pure $ Left $ CompileFailed cmd n (T.pack stderr)
