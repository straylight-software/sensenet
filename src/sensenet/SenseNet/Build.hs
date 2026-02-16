{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE LambdaCase #-}

-- | Direct build execution using DICE
--
-- No Buck2, no Starlark, no BUCK files. Just:
--   BUILD.dhall → IR → DICE → execute
module SenseNet.Build
  ( build
  , BuildResult(..)
  , BuildError(..)
  ) where

import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Word (Word64)
import System.Directory (doesFileExist, getFileSize, createDirectoryIfMissing)
import System.Exit (ExitCode(..))
import System.FilePath ((</>), takeDirectory)
import System.Process (readProcessWithExitCode)

import SenseNet.DICE (DICE, DICEError, runDICE, inject, sha256)
import qualified SenseNet.IR as IR

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

data BuildResult
  = BuildSuccess [FilePath]  -- Output files
  | BuildCached [FilePath]   -- Already up to date
  deriving (Show, Eq)

data BuildError
  = SourceNotFound FilePath
  | CompileFailed Text Int Text  -- cmd, exit code, stderr
  | LinkFailed Text Int Text
  | DICEFailed DICEError
  | TargetNotFound Text
  | UnsupportedRule Text
  deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Build Entry Point
-- ════════════════════════════════════════════════════════════════════════════

-- | Build a target from a package
build :: FilePath -> IR.Package -> Text -> IO (Either BuildError BuildResult)
build projectRoot pkg targetName = do
  -- Find the target
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ TargetNotFound targetName
    Just rule -> buildRule projectRoot pkg.path rule

findRule :: Text -> [IR.Rule] -> Maybe IR.Rule
findRule name = foldr (\r acc -> if IR.ruleName r == name then Just r else acc) Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- Rule Dispatch
-- ════════════════════════════════════════════════════════════════════════════

buildRule :: FilePath -> FilePath -> IR.Rule -> IO (Either BuildError BuildResult)
buildRule projectRoot pkgPath = \case
  IR.RCxxBinary r -> buildCxxBinary projectRoot pkgPath r
  IR.RCxxLibrary r -> buildCxxLibrary projectRoot pkgPath r
  IR.RGenrule r -> buildGenrule projectRoot pkgPath r
  rule -> pure $ Left $ UnsupportedRule $ T.pack $ show rule

-- ════════════════════════════════════════════════════════════════════════════
-- C++ Build
-- ════════════════════════════════════════════════════════════════════════════

buildCxxBinary :: FilePath -> FilePath -> IR.CxxBinary -> IO (Either BuildError BuildResult)
buildCxxBinary projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name
  
  -- Ensure output directory exists
  createDirectoryIfMissing True outDir
  
  -- Hash sources and inject into DICE
  diceResult <- runDICE $ do
    forM_ bin.srcs $ \src -> do
      let srcPath = srcDir </> T.unpack src
      exists <- liftIO $ doesFileExist srcPath
      if exists
        then do
          contents <- liftIO $ BS.readFile srcPath
          hash <- sha256 contents
          size <- liftIO $ fromIntegral <$> getFileSize srcPath
          inject (T.pack srcPath) hash size
        else pure ()  -- Will fail later
    pure ()
  
  case diceResult of
    Left err -> pure $ Left $ DICEFailed err
    Right () -> do
      -- Check all sources exist
      missingCheck <- checkSources srcDir bin.srcs
      case missingCheck of
        Just missing -> pure $ Left $ SourceNotFound missing
        Nothing -> do
          -- Compile
          let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs
              cflags = map T.unpack bin.cflags
              ldflags = map T.unpack bin.ldflags
              stdFlag = cxxStdFlag bin.std
              cmd = ["c++", stdFlag] ++ cflags ++ srcs ++ ["-o", outBin] ++ ldflags
          
          TIO.putStrLn $ "  compile: " <> T.pack (unwords cmd)
          (exitCode, _stdout, stderr) <- readProcessWithExitCode "c++" (tail cmd) ""
          
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildCxxLibrary :: FilePath -> FilePath -> IR.CxxLibrary -> IO (Either BuildError BuildResult)
buildCxxLibrary projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
  
  createDirectoryIfMissing True outDir
  
  -- Compile each source to .o
  results <- forM lib.srcs $ \src -> do
    let srcPath = srcDir </> T.unpack src
        objPath = outDir </> T.unpack src <> ".o"
        stdFlag = cxxStdFlag lib.std
        cflags = map T.unpack lib.cflags
        cmd = ["c++", "-c", stdFlag] ++ cflags ++ [srcPath, "-o", objPath]
    
    exists <- doesFileExist srcPath
    if not exists
      then pure $ Left $ SourceNotFound srcPath
      else do
        TIO.putStrLn $ "  compile: " <> T.pack (unwords cmd)
        (exitCode, _, stderr) <- readProcessWithExitCode "c++" (tail cmd) ""
        case exitCode of
          ExitSuccess -> pure $ Right objPath
          ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
  
  case sequence results of
    Left err -> pure $ Left err
    Right objs -> pure $ Right $ BuildSuccess objs

-- ════════════════════════════════════════════════════════════════════════════
-- Genrule Build
-- ════════════════════════════════════════════════════════════════════════════

buildGenrule :: FilePath -> FilePath -> IR.Genrule -> IO (Either BuildError BuildResult)
buildGenrule projectRoot pkgPath gen = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outPath = outDir </> T.unpack gen.out
  
  createDirectoryIfMissing True outDir
  
  -- Substitute $SRCS and $OUT in command
  let srcs = T.intercalate " " $ map (\s -> T.pack $ srcDir </> T.unpack s) gen.srcs
      cmd = T.replace "$SRCS" srcs $ T.replace "$OUT" (T.pack outPath) gen.cmd
  
  TIO.putStrLn $ "  run: " <> cmd
  (exitCode, _, stderr) <- readProcessWithExitCode "sh" ["-c", T.unpack cmd] ""
  
  case exitCode of
    ExitSuccess -> pure $ Right $ BuildSuccess [outPath]
    ExitFailure n -> pure $ Left $ CompileFailed cmd n (T.pack stderr)

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

checkSources :: FilePath -> [Text] -> IO (Maybe FilePath)
checkSources srcDir = go
  where
    go [] = pure Nothing
    go (s : rest) = do
      let path = srcDir </> T.unpack s
      exists <- doesFileExist path
      if exists then go rest else pure $ Just path

cxxStdFlag :: IR.CxxStd -> String
cxxStdFlag = \case
  IR.Cxx11 -> "-std=c++11"
  IR.Cxx14 -> "-std=c++14"
  IR.Cxx17 -> "-std=c++17"
  IR.Cxx20 -> "-std=c++20"
  IR.Cxx23 -> "-std=c++23"
