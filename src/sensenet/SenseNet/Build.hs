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
  IR.RRustBinary r -> buildRustBinary projectRoot pkgPath r
  IR.RRustLibrary r -> buildRustLibrary projectRoot pkgPath r
  IR.RHaskellBinary r -> buildHaskellBinary projectRoot pkgPath r
  IR.RHaskellLibrary r -> buildHaskellLibrary projectRoot pkgPath r
  IR.RLeanBinary r -> buildLeanBinary projectRoot pkgPath r
  IR.RLeanLibrary r -> buildLeanLibrary projectRoot pkgPath r
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
-- Rust Build
-- ════════════════════════════════════════════════════════════════════════════

buildRustBinary :: FilePath -> FilePath -> IR.RustBinary -> IO (Either BuildError BuildResult)
buildRustBinary projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name
  
  createDirectoryIfMissing True outDir
  
  -- For single-file Rust, compile directly
  -- For multi-file, we'd need proper crate handling
  case bin.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag bin.edition
          cmd = ["rustc", "--edition", edition, srcPath, "-o", outBin]
      
      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          TIO.putStrLn $ "  rustc: " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode "rustc" (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    
    srcs -> do
      -- Multi-file: use first as main, compile all
      let mainSrc = srcDir </> T.unpack (head srcs)
          edition = rustEditionFlag bin.edition
          cmd = ["rustc", "--edition", edition, mainSrc, "-o", outBin]
      
      TIO.putStrLn $ "  rustc: " <> T.pack (unwords cmd)
      (exitCode, _, stderr) <- readProcessWithExitCode "rustc" (tail cmd) ""
      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildRustLibrary :: FilePath -> FilePath -> IR.RustLibrary -> IO (Either BuildError BuildResult)
buildRustLibrary projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      crateName = maybe (T.unpack lib.name) T.unpack lib.crateName
      outLib = outDir </> ("lib" <> crateName <> ".rlib")
  
  createDirectoryIfMissing True outDir
  
  case lib.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag lib.edition
          cmd = ["rustc", "--edition", edition, "--crate-type", "rlib", 
                 "--crate-name", crateName, srcPath, "-o", outLib]
      
      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          TIO.putStrLn $ "  rustc: " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode "rustc" (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outLib]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    
    _ -> pure $ Left $ UnsupportedRule "Multi-file Rust library"

-- ════════════════════════════════════════════════════════════════════════════
-- Haskell Build
-- ════════════════════════════════════════════════════════════════════════════

buildHaskellBinary :: FilePath -> FilePath -> IR.HaskellBinary -> IO (Either BuildError BuildResult)
buildHaskellBinary projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name
  
  createDirectoryIfMissing True outDir
  
  -- Use srcs list, not main (main is the module name, not file)
  let srcFiles = map (\s -> srcDir </> T.unpack s) bin.srcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) bin.packages
      extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions
      ghcOpts = map T.unpack bin.ghcOptions
      mainFlag = ["-main-is", T.unpack bin.main]
      cmd = ["ghc"] ++ extFlags ++ pkgFlags ++ ghcOpts ++ mainFlag ++ srcFiles ++ ["-o", outBin]
  
  -- Check first source exists
  case srcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (mainSrc : _) -> do
      exists <- doesFileExist mainSrc
      if not exists
        then pure $ Left $ SourceNotFound mainSrc
        else do
          TIO.putStrLn $ "  ghc: " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode "ghc" (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildHaskellLibrary :: FilePath -> FilePath -> IR.HaskellLibrary -> IO (Either BuildError BuildResult)
buildHaskellLibrary projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
  
  createDirectoryIfMissing True outDir
  
  -- Compile each source to .o and .hi
  results <- forM lib.srcs $ \src -> do
    let srcPath = srcDir </> T.unpack src
        objPath = outDir </> T.unpack src <> ".o"
        pkgFlags = concatMap (\p -> ["-package", T.unpack p]) lib.packages
        extFlags = map (\e -> "-X" <> T.unpack e) lib.languageExtensions
        ghcOpts = map T.unpack lib.ghcOptions
        cmd = ["ghc", "-c"] ++ extFlags ++ pkgFlags ++ ghcOpts ++ 
              [srcPath, "-o", objPath, "-odir", outDir, "-hidir", outDir]
    
    exists <- doesFileExist srcPath
    if not exists
      then pure $ Left $ SourceNotFound srcPath
      else do
        TIO.putStrLn $ "  ghc: " <> T.pack (unwords cmd)
        (exitCode, _, stderr) <- readProcessWithExitCode "ghc" (tail cmd) ""
        case exitCode of
          ExitSuccess -> pure $ Right objPath
          ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
  
  case sequence results of
    Left err -> pure $ Left err
    Right objs -> pure $ Right $ BuildSuccess objs

-- ════════════════════════════════════════════════════════════════════════════
-- Lean Build
-- ════════════════════════════════════════════════════════════════════════════

buildLeanBinary :: FilePath -> FilePath -> IR.LeanBinary -> IO (Either BuildError BuildResult)
buildLeanBinary projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name
  
  createDirectoryIfMissing True outDir
  
  -- Single file Lean compilation
  case bin.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          cmd = ["lean", "--run", srcPath]
          -- For actual binary, we need: lean -o outBin srcPath
          buildCmd = ["lean", "-o", outBin, srcPath]
      
      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          TIO.putStrLn $ "  lean: " <> T.pack (unwords buildCmd)
          (exitCode, _, stderr) <- readProcessWithExitCode "lean" (tail buildCmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords buildCmd) n (T.pack stderr)
    
    _ -> pure $ Left $ UnsupportedRule "Multi-file Lean binary"

buildLeanLibrary :: FilePath -> FilePath -> IR.LeanLibrary -> IO (Either BuildError BuildResult)
buildLeanLibrary projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
  
  createDirectoryIfMissing True outDir
  
  -- Compile each .lean to .olean
  results <- forM lib.srcs $ \src -> do
    let srcPath = srcDir </> T.unpack src
        oleanPath = outDir </> T.unpack src <> ".olean"
        cmd = ["lean", "-c", oleanPath, srcPath]
    
    exists <- doesFileExist srcPath
    if not exists
      then pure $ Left $ SourceNotFound srcPath
      else do
        TIO.putStrLn $ "  lean: " <> T.pack (unwords cmd)
        (exitCode, _, stderr) <- readProcessWithExitCode "lean" (tail cmd) ""
        case exitCode of
          ExitSuccess -> pure $ Right oleanPath
          ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
  
  case sequence results of
    Left err -> pure $ Left err
    Right oleans -> pure $ Right $ BuildSuccess oleans

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

rustEditionFlag :: IR.RustEdition -> String
rustEditionFlag = \case
  IR.E2015 -> "2015"
  IR.E2018 -> "2018"
  IR.E2021 -> "2021"
  IR.E2024 -> "2024"
