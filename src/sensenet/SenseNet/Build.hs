{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Direct build execution using DICE
--
-- No Buck2, no Starlark, no BUCK files. Just:
--   BUILD.dhall → IR → DICE → execute
module SenseNet.Build
  ( build,
    buildWithDeps,
    buildWithConsole,
    BuildResult (..),
    BuildError (..),
  )
where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally)
import Control.Monad (forM, forM_, forever, when)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (intercalate, isPrefixOf, nub, stripPrefix)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Word (Word64)
import GHC.IO.Handle (hGetContents)
import SenseNet.Console qualified as Console
import SenseNet.DICE (DICE, DICEError, clearTargets, compute, inject, registerTarget, runDICE, sha256)
import SenseNet.IR qualified as IR
import SenseNet.Toolchains qualified as TC
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.Process (StdStream (..), createProcess, cwd, env, proc, readProcessWithExitCode, std_err, std_out, waitForProcess)

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

data BuildResult
  = BuildSuccess [FilePath] -- Output files
  | BuildCached [FilePath] -- Already up to date
  deriving (Show, Eq)

data BuildError
  = SourceNotFound FilePath
  | CompileFailed Text Int Text -- cmd, exit code, stderr
  | LinkFailed Text Int Text
  | DICEFailed DICEError
  | TargetNotFound Text
  | UnsupportedRule Text
  deriving (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════
-- Build Entry Point
-- ════════════════════════════════════════════════════════════════════════════

-- | Build a target from a package (legacy - no dependency resolution)
build :: TC.Toolchains -> FilePath -> IR.Package -> Text -> IO (Either BuildError BuildResult)
build tc projectRoot pkg targetName = do
  -- Find the target
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ TargetNotFound targetName
    Just rule -> buildRule tc projectRoot pkg.path rule

-- | Build a target with full dependency resolution via DICE
--
-- This is the primary entry point for dependency-aware builds:
-- 1. Registers all rules in the package with DICE (with their deps)
-- 2. Requests computation of the target
-- 3. DICE auto-resolves deps in the correct order
--
-- @
-- buildWithDeps toolchains "." pkg "mybin"
-- @
buildWithDeps :: TC.Toolchains -> FilePath -> IR.Package -> Text -> IO (Either BuildError BuildResult)
buildWithDeps tc projectRoot pkg targetName = do
  -- Find the target first
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ TargetNotFound targetName
    Just _rule -> do
      -- Build rule map for quick lookup
      let ruleMap = Map.fromList [(IR.ruleName r, r) | r <- pkg.rules]

      -- Run DICE to register all targets and compute
      result <- runDICE $ do
        -- Clear any previous registrations
        clearTargets

        -- Register all rules with their dependencies
        liftIO $ TIO.putStrLn $ "Registering " <> T.pack (show $ length pkg.rules) <> " targets..."
        forM_ pkg.rules $ \rule -> do
          let name = IR.ruleName rule
              deps = extractLocalDepNames (IR.ruleDeps rule)
          liftIO $ TIO.putStrLn $ "  " <> name <> " -> " <> T.pack (show deps)
          registerTarget name deps (makeCallback tc projectRoot pkg.path ruleMap)

        -- Request computation of the target
        liftIO $ TIO.putStrLn $ "\nComputing target: " <> targetName
        compute targetName

      case result of
        Left err -> pure $ Left $ DICEFailed err
        Right outputs -> pure $ Right $ BuildSuccess (map T.unpack outputs)

-- | Build state for console progress tracking
data BuildState = BuildState
  { bsTotal :: !Int,
    bsCompleted :: !Int,
    bsRunning :: !Int,
    bsCached :: !Int,
    bsActions :: ![(Word64, Text)], -- (action ID, name)
    bsNextId :: !Word64,
    bsLogs :: ![Text] -- Collected log messages to emit
  }

initialBuildState :: Int -> BuildState
initialBuildState total =
  BuildState
    { bsTotal = total,
      bsCompleted = 0,
      bsRunning = 0,
      bsCached = 0,
      bsActions = [],
      bsNextId = 1,
      bsLogs = []
    }

-- | Build a target with dependency resolution and superconsole TUI
buildWithConsole :: TC.Toolchains -> FilePath -> IR.Package -> Text -> IO (Either BuildError BuildResult)
buildWithConsole tc projectRoot pkg targetName = do
  -- Check if console is available
  isCompatible <- Console.compatible
  if not isCompatible
    then do
      -- Fall back to non-console build
      TIO.putStrLn "(Console not available, using text output)"
      buildWithDeps tc projectRoot pkg targetName
    else do
      -- Run with console
      mResult <- Console.withBuildConsole $ \console progress -> do
        buildWithConsoleInner tc projectRoot pkg targetName console progress
      case mResult of
        Nothing -> do
          TIO.putStrLn "(Console initialization failed, using text output)"
          buildWithDeps tc projectRoot pkg targetName
        Just result -> pure result

-- | Inner function that runs with an initialized console
buildWithConsoleInner ::
  TC.Toolchains ->
  FilePath ->
  IR.Package ->
  Text ->
  Console.Console ->
  Console.BuildProgress ->
  IO (Either BuildError BuildResult)
buildWithConsoleInner tc projectRoot pkg targetName console progress = do
  -- Find the target first
  case findRule targetName pkg.rules of
    Nothing -> pure $ Left $ TargetNotFound targetName
    Just _rule -> do
      -- Build rule map for quick lookup
      let ruleMap = Map.fromList [(IR.ruleName r, r) | r <- pkg.rules]
          totalTargets = length pkg.rules

      -- Initialize build state
      stateRef <- newIORef (initialBuildState totalTargets)

      -- Initialize progress display
      Console.updateProgress
        progress
        (fromIntegral totalTargets)
        0
        0
        0

      -- Start render thread (updates display at ~10 Hz)
      renderDone <- newEmptyMVar
      renderThread <- forkIO $ renderLoop console progress stateRef renderDone

      -- Run the build
      result <- runDICE $ do
        clearTargets

        -- Register all rules with their dependencies
        forM_ pkg.rules $ \rule -> do
          let name = IR.ruleName rule
              deps = extractLocalDepNames (IR.ruleDeps rule)
          registerTarget name deps (makeConsoleCallback tc projectRoot pkg.path ruleMap console progress stateRef)

        -- Request computation of the target
        compute targetName

      -- Stop render thread
      putMVar renderDone ()
      killThread renderThread

      -- Final render to show completion
      state <- readIORef stateRef
      Console.updateProgress
        progress
        (fromIntegral $ bsTotal state)
        (fromIntegral $ bsCompleted state)
        0
        (fromIntegral $ bsCached state)
      _ <- Console.renderProgress console progress

      case result of
        Left err -> pure $ Left $ DICEFailed err
        Right outputs -> pure $ Right $ BuildSuccess (map T.unpack outputs)

-- | Render loop that updates the console display
renderLoop :: Console.Console -> Console.BuildProgress -> IORef BuildState -> MVar () -> IO ()
renderLoop console progress stateRef done = go
  where
    go = do
      -- Check if we should stop
      -- Use a short delay for ~10 Hz refresh
      threadDelay 100000 -- 100ms

      -- Read current state
      state <- readIORef stateRef

      -- Emit any pending log messages
      forM_ (bsLogs state) $ \msg ->
        Console.emitLine console msg

      -- Clear emitted logs
      when (not $ null $ bsLogs state) $
        modifyIORef' stateRef $
          \s -> s {bsLogs = []}

      -- Update progress
      Console.updateProgress
        progress
        (fromIntegral $ bsTotal state)
        (fromIntegral $ bsCompleted state)
        (fromIntegral $ bsRunning state)
        (fromIntegral $ bsCached state)

      -- Render
      _ <- Console.renderProgress console progress

      -- Continue loop
      go

-- | Console-aware callback for DICE
makeConsoleCallback ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  Map Text IR.Rule ->
  Console.Console ->
  Console.BuildProgress ->
  IORef BuildState ->
  Text -> -- Target name
  Text -> -- Deps JSON
  IO Text -- Result JSON
makeConsoleCallback tc projectRoot pkgPath ruleMap console progress stateRef targetName depsJson = do
  -- Record action start
  actionId <- modifyIORefRet stateRef $ \s ->
    let newId = bsNextId s
        newActions = (newId, targetName) : bsActions s
     in (s {bsNextId = newId + 1, bsActions = newActions, bsRunning = bsRunning s + 1}, newId)

  -- Add action to progress display
  Console.addAction progress actionId targetName 0

  -- Build the target
  resultJson <- case Map.lookup targetName ruleMap of
    Nothing -> pure $ mkResultJson [] 1 ("Target not found: " <> targetName)
    Just rule -> do
      let depOutputs = parseDepOutputs depsJson
      result <- buildRuleWithDeps tc projectRoot pkgPath rule depOutputs
      case result of
        Left err -> pure $ mkResultJson [] 1 (T.pack $ show err)
        Right (BuildSuccess outputs) -> pure $ mkResultJson outputs 0 ""
        Right (BuildCached outputs) -> pure $ mkResultJson outputs 0 "cached"

  -- Record action completion
  Console.removeAction progress actionId

  -- Parse result to determine success/cached
  let isCached = "cached" `T.isInfixOf` resultJson
      isSuccess = "\"exit_code\":0" `T.isInfixOf` resultJson

  modifyIORef' stateRef $ \s ->
    let newActions = filter ((/= actionId) . fst) (bsActions s)
        logMsg =
          if isSuccess
            then "  ✓ " <> targetName
            else "  ✗ " <> targetName
     in s
          { bsCompleted = bsCompleted s + 1,
            bsRunning = bsRunning s - 1,
            bsCached = if isCached then bsCached s + 1 else bsCached s,
            bsActions = newActions,
            bsLogs = bsLogs s ++ [logMsg]
          }

  pure resultJson

-- | Modify an IORef and return a value
modifyIORefRet :: IORef a -> (a -> (a, b)) -> IO b
modifyIORefRet ref f = do
  old <- readIORef ref
  let (new, ret) = f old
  writeIORef ref new
  pure ret

-- | Extract local dependency names from Dep list
-- Strips the leading ":" from ":foo" style deps
extractLocalDepNames :: [IR.Dep] -> [Text]
extractLocalDepNames = concatMap extract
  where
    extract (IR.DepLocal name) =
      -- Strip leading ":" if present
      [fromMaybe name (T.stripPrefix ":" name)]
    extract (IR.DepFlake _) = [] -- Flake deps are external, not DICE targets

-- | Create a callback for a rule that builds it when invoked
-- The callback receives the target name and resolved dep outputs as JSON
makeCallback ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  Map Text IR.Rule ->
  Text -> -- Target name
  Text -> -- Deps JSON: [{"name": "dep1", "outputs": [...]}, ...]
  IO Text -- Result JSON: {"outputs": [...], "exit_code": N, "log": "..."}
makeCallback tc projectRoot pkgPath ruleMap targetName depsJson = do
  TIO.putStrLn $ "  Building: " <> targetName
  TIO.putStrLn $ "    Deps: " <> depsJson

  case Map.lookup targetName ruleMap of
    Nothing -> pure $ mkResultJson [] 1 ("Target not found: " <> targetName)
    Just rule -> do
      -- Parse dep outputs for use in linking
      let depOutputs = parseDepOutputs depsJson

      -- Build the rule (passing dep outputs for linking)
      result <- buildRuleWithDeps tc projectRoot pkgPath rule depOutputs
      case result of
        Left err -> pure $ mkResultJson [] 1 (T.pack $ show err)
        Right (BuildSuccess outputs) -> pure $ mkResultJson outputs 0 ""
        Right (BuildCached outputs) -> pure $ mkResultJson outputs 0 "cached"

-- | Build a rule with resolved dependency outputs
buildRuleWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.Rule ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildRuleWithDeps tc projectRoot pkgPath rule depOutputs = case rule of
  IR.RCxxBinary r -> buildCxxBinaryWithDeps tc projectRoot pkgPath r depOutputs
  IR.RCxxLibrary r -> buildCxxLibrary tc projectRoot pkgPath r
  IR.RRustBinary r -> buildRustBinaryWithDeps tc projectRoot pkgPath r depOutputs
  IR.RRustLibrary r -> buildRustLibrary tc projectRoot pkgPath r
  IR.RHaskellBinary r -> buildHaskellBinaryWithDeps tc projectRoot pkgPath r depOutputs
  IR.RHaskellLibrary r -> buildHaskellLibrary tc projectRoot pkgPath r
  IR.RLeanBinary r -> buildLeanBinary tc projectRoot pkgPath r
  IR.RLeanLibrary r -> buildLeanLibrary tc projectRoot pkgPath r
  IR.RNvBinary r -> buildNvBinary tc projectRoot pkgPath r
  IR.RNvLibrary r -> buildNvLibrary tc projectRoot pkgPath r
  IR.RPureScriptApp r -> buildPureScriptApp tc projectRoot pkgPath r
  IR.RPureScriptBinary r -> buildPureScriptBinary tc projectRoot pkgPath r
  IR.RGenrule r -> buildGenrule tc projectRoot pkgPath r
  IR.RNixCxxBinary r -> buildNixCxxBinary tc projectRoot pkgPath r
  other -> pure $ Left $ UnsupportedRule $ T.pack $ show other

-- | Parse dep outputs JSON: [{"name": "dep1", "outputs": ["path1", ...]}, ...]
parseDepOutputs :: Text -> [(Text, [FilePath])]
parseDepOutputs json = case parseDepArray (T.unpack json) of
  Just deps -> deps
  Nothing -> []

-- | Simple JSON parser for dep array (avoids aeson dependency in hot path)
parseDepArray :: String -> Maybe [(Text, [FilePath])]
parseDepArray s = do
  -- Very simple parser - find each {"name": "...", "outputs": [...]}
  let entries = findDepEntries s
  pure entries

-- | Find all dep entries in the JSON string
findDepEntries :: String -> [(Text, [FilePath])]
findDepEntries s = go s []
  where
    go [] acc = reverse acc
    go str acc = case findNextEntry str of
      Nothing -> reverse acc
      Just (entry, rest) -> go rest (entry : acc)

    findNextEntry str =
      case dropWhile (/= '{') str of
        [] -> Nothing
        (_ : after) ->
          let (inside, rest) = span (/= '}') after
              mName = extractFieldString "name" inside
              mOutputs = extractFieldArray "outputs" inside
           in case (mName, mOutputs) of
                (Just name, Just outputs) -> Just ((T.pack name, outputs), drop 1 rest)
                _ -> Nothing

    extractFieldString field str =
      let pattern = "\"" ++ field ++ "\":\""
       in case findSubstring pattern str of
            Nothing -> Nothing
            Just after ->
              let (value, _) = span (/= '"') after
               in Just value

    extractFieldArray field str =
      let pattern = "\"" ++ field ++ "\":["
       in case findSubstring pattern str of
            Nothing -> Nothing
            Just after ->
              let (arrayContent, _) = span (/= ']') after
               in Just $ extractStrings arrayContent

    extractStrings s' = go' s' []
      where
        go' [] acc = reverse acc
        go' ('"' : rest) acc =
          let (val, rest') = span (/= '"') rest
           in go' (drop 1 rest') (val : acc)
        go' (_ : rest) acc = go' rest acc

    findSubstring needle haystack =
      case dropWhile (\h -> not $ needle `isPrefixOf` h) (tails haystack) of
        [] -> Nothing
        (match : _) -> Just $ drop (length needle) match

    tails [] = [[]]
    tails xs@(_ : xs') = xs : tails xs'

-- | Create result JSON
mkResultJson :: [FilePath] -> Int -> Text -> Text
mkResultJson outputs exitCode logMsg =
  "{\"outputs\":["
    <> outputsJson
    <> "],\"exit_code\":"
    <> T.pack (show exitCode)
    <> ",\"output_hash\":\"\",\"log\":\""
    <> escapeJsonText logMsg
    <> "\"}"
  where
    outputsJson = T.intercalate "," $ map (\p -> "\"" <> escapeJsonText (T.pack p) <> "\"") outputs

-- | Escape text for JSON string
escapeJsonText :: Text -> Text
escapeJsonText = T.concatMap escapeChar
  where
    escapeChar '\\' = "\\\\"
    escapeChar '"' = "\\\""
    escapeChar '\n' = "\\n"
    escapeChar '\r' = "\\r"
    escapeChar '\t' = "\\t"
    escapeChar c = T.singleton c

findRule :: Text -> [IR.Rule] -> Maybe IR.Rule
findRule name = foldr (\r acc -> if IR.ruleName r == name then Just r else acc) Nothing

-- ════════════════════════════════════════════════════════════════════════════
-- Rule Dispatch
-- ════════════════════════════════════════════════════════════════════════════

buildRule :: TC.Toolchains -> FilePath -> FilePath -> IR.Rule -> IO (Either BuildError BuildResult)
buildRule tc projectRoot pkgPath = \case
  IR.RCxxBinary r -> buildCxxBinary tc projectRoot pkgPath r
  IR.RCxxLibrary r -> buildCxxLibrary tc projectRoot pkgPath r
  IR.RRustBinary r -> buildRustBinary tc projectRoot pkgPath r
  IR.RRustLibrary r -> buildRustLibrary tc projectRoot pkgPath r
  IR.RHaskellBinary r -> buildHaskellBinary tc projectRoot pkgPath r
  IR.RHaskellLibrary r -> buildHaskellLibrary tc projectRoot pkgPath r
  IR.RLeanBinary r -> buildLeanBinary tc projectRoot pkgPath r
  IR.RLeanLibrary r -> buildLeanLibrary tc projectRoot pkgPath r
  IR.RNvBinary r -> buildNvBinary tc projectRoot pkgPath r
  IR.RNvLibrary r -> buildNvLibrary tc projectRoot pkgPath r
  IR.RPureScriptApp r -> buildPureScriptApp tc projectRoot pkgPath r
  IR.RPureScriptBinary r -> buildPureScriptBinary tc projectRoot pkgPath r
  IR.RGenrule r -> buildGenrule tc projectRoot pkgPath r
  IR.RNixCxxBinary r -> buildNixCxxBinary tc projectRoot pkgPath r
  rule -> pure $ Left $ UnsupportedRule $ T.pack $ show rule

-- ════════════════════════════════════════════════════════════════════════════
-- C++ Build
-- ════════════════════════════════════════════════════════════════════════════

buildCxxBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.CxxBinary -> IO (Either BuildError BuildResult)
buildCxxBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      ld = T.unpack tc.cxx.ld.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      cxxLibs = map T.unpack tc.cxx.paths.libs
      sysroot = T.unpack tc.cxx.sysroot

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
        else pure () -- Will fail later
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
              includeFlags = concatMap (\i -> ["-isystem", i]) cxxIncludes
              -- -B tells linker where to find crt*.o files, -L/-rpath for libraries
              libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) cxxLibs
              sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
              linkFlag = ["-fuse-ld=" <> ld]
              cmd = [cxx, stdFlag] ++ sysrootFlag ++ includeFlags ++ cflags ++ srcs ++ ["-o", outBin] ++ linkFlag ++ libFlags ++ ldflags

          TIO.putStrLn $ "  compile: " <> T.pack (unwords cmd)
          (exitCode, _stdout, stderr) <- readProcessWithExitCode cxx (tail cmd) ""

          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildCxxLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.CxxLibrary -> IO (Either BuildError BuildResult)
buildCxxLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      sysroot = T.unpack tc.cxx.sysroot

  createDirectoryIfMissing True outDir

  -- Compile each source to .o
  results <- forM lib.srcs $ \src -> do
    let srcPath = srcDir </> T.unpack src
        objPath = outDir </> T.unpack src <> ".o"
        stdFlag = cxxStdFlag lib.std
        cflags = map T.unpack lib.cflags
        includeFlags = concatMap (\i -> ["-isystem", i]) cxxIncludes
        sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
        cmd = [cxx, "-c", stdFlag] ++ sysrootFlag ++ includeFlags ++ cflags ++ [srcPath, "-o", objPath]

    exists <- doesFileExist srcPath
    if not exists
      then pure $ Left $ SourceNotFound srcPath
      else do
        TIO.putStrLn $ "  compile: " <> T.pack (unwords cmd)
        (exitCode, _, stderr) <- readProcessWithExitCode cxx (tail cmd) ""
        case exitCode of
          ExitSuccess -> pure $ Right objPath
          ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

  case sequence results of
    Left err -> pure $ Left err
    Right objs -> pure $ Right $ BuildSuccess objs

-- | Build C++ binary with resolved dependency outputs
-- Dep outputs (e.g., .o files from libraries) are linked in
buildCxxBinaryWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.CxxBinary ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildCxxBinaryWithDeps tc projectRoot pkgPath bin depOutputs = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      ld = T.unpack tc.cxx.ld.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      cxxLibs = map T.unpack tc.cxx.paths.libs
      sysroot = T.unpack tc.cxx.sysroot

  createDirectoryIfMissing True outDir

  -- Check all sources exist
  missingCheck <- checkSources srcDir bin.srcs
  case missingCheck of
    Just missing -> pure $ Left $ SourceNotFound missing
    Nothing -> do
      -- Compile and link
      let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs
          cflags = map T.unpack bin.cflags
          ldflags = map T.unpack bin.ldflags
          stdFlag = cxxStdFlag bin.std
          includeFlags = concatMap (\i -> ["-isystem", i]) cxxIncludes
          libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) cxxLibs
          sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
          linkFlag = ["-fuse-ld=" <> ld]
          -- Add dep outputs (.o files) to link line
          depObjs = concatMap snd depOutputs
          cmd =
            [cxx, stdFlag]
              ++ sysrootFlag
              ++ includeFlags
              ++ cflags
              ++ srcs
              ++ depObjs
              ++ ["-o", outBin]
              ++ linkFlag
              ++ libFlags
              ++ ldflags

      TIO.putStrLn $ "  compile (with deps): " <> T.pack (unwords cmd)
      (exitCode, _stdout, stderr) <- readProcessWithExitCode cxx (tail cmd) ""

      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- ════════════════════════════════════════════════════════════════════════════
-- Nix C++ Build
-- ════════════════════════════════════════════════════════════════════════════

buildNixCxxBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.NixCxxBinary -> IO (Either BuildError BuildResult)
buildNixCxxBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let cxx = T.unpack tc.cxx.cxx.path
      ld = T.unpack tc.cxx.ld.path
      cxxIncludes = map T.unpack tc.cxx.paths.includes
      cxxLibs = map T.unpack tc.cxx.paths.libs
      sysroot = T.unpack tc.cxx.sysroot

  createDirectoryIfMissing True outDir

  -- Resolve nix dependencies to get include/lib paths
  nixPaths <- resolveNixDeps bin.nixDeps
  case nixPaths of
    Left err -> pure $ Left $ CompileFailed "nix eval" 1 err
    Right (nixIncludes, nixLibPaths, nixLinkFlags) -> do
      -- Check all sources exist
      missingCheck <- checkSources srcDir bin.srcs
      case missingCheck of
        Just missing -> pure $ Left $ SourceNotFound missing
        Nothing -> do
          -- Compile
          let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs
              cflags = map T.unpack bin.compilerFlags
              ldflags = map T.unpack bin.linkerFlags
              includeFlags = concatMap (\i -> ["-isystem", i]) (cxxIncludes ++ nixIncludes)
              libFlags = concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) (cxxLibs ++ nixLibPaths)
              sysrootFlag = if null sysroot then [] else ["--sysroot=" <> sysroot]
              linkFlag = ["-fuse-ld=" <> ld]
              cmd = [cxx, "-std=c++17"] ++ sysrootFlag ++ includeFlags ++ cflags ++ srcs ++ ["-o", outBin] ++ linkFlag ++ libFlags ++ nixLinkFlags ++ ldflags

          TIO.putStrLn $ "  compile: " <> T.pack (unwords cmd)
          (exitCode, _stdout, stderr) <- readProcessWithExitCode cxx (tail cmd) ""

          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- | Resolve nix flake refs to include/lib paths
-- Returns (includes, libPaths, linkFlags)
resolveNixDeps :: [Text] -> IO (Either Text ([FilePath], [FilePath], [String]))
resolveNixDeps deps = do
  results <- forM deps $ \dep -> do
    -- Get dev output for headers (fallback to out, then default)
    let flakeRef = T.unpack dep
        -- Extract package name for -l flag (e.g., "nixpkgs#zlib" -> "z")
        pkgName = extractPkgName dep

    -- Try dev output first for headers
    (devExit, devOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".dev.outPath"] ""
    devPath <-
      if devExit == ExitSuccess
        then pure devOut
        else do
          -- Fall back to out output
          (outExit, outOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".out.outPath"] ""
          if outExit == ExitSuccess
            then pure outOut
            else do
              -- Fall back to default output
              (mainExit, mainOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".outPath"] ""
              pure $ if mainExit == ExitSuccess then mainOut else ""

    -- Get out output for libs (not default, which may be bin)
    (outExit, outOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".out.outPath"] ""
    libPath <-
      if outExit == ExitSuccess
        then pure outOut
        else do
          -- Fall back to default output
          (mainExit, mainOut, _) <- readProcessWithExitCode "nix" ["eval", "--raw", flakeRef <> ".outPath"] ""
          pure $ if mainExit == ExitSuccess then mainOut else ""

    if null devPath && null libPath
      then pure $ Left $ "Failed to resolve nix dep: " <> dep
      else pure $ Right (devPath, libPath, pkgName)

  case sequence results of
    Left err -> pure $ Left err
    Right paths -> do
      let includes = [p </> "include" | (p, _, _) <- paths, not (null p)]
          libPaths = [p </> "lib" | (_, p, _) <- paths, not (null p)]
          linkFlags = ["-l" <> n | (_, _, n) <- paths, not (null n)]
      pure $ Right (includes, libPaths, linkFlags)

-- | Extract library name from flake ref for -l flag
-- "nixpkgs#zlib" -> "z", "nixpkgs#openssl" -> "ssl"
extractPkgName :: Text -> String
extractPkgName ref = case T.splitOn "#" ref of
  [_, pkg] -> libNameFor (T.unpack pkg)
  _ -> ""
  where
    -- Common mappings
    libNameFor "zlib" = "z"
    libNameFor "openssl" = "ssl"
    libNameFor "sqlite" = "sqlite3"
    libNameFor "curl" = "curl"
    libNameFor "libpng" = "png"
    libNameFor "libjpeg" = "jpeg"
    libNameFor name = name

-- ════════════════════════════════════════════════════════════════════════════
-- Genrule Build
-- ════════════════════════════════════════════════════════════════════════════

buildGenrule :: TC.Toolchains -> FilePath -> FilePath -> IR.Genrule -> IO (Either BuildError BuildResult)
buildGenrule _tc projectRoot pkgPath gen = do
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

buildRustBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.RustBinary -> IO (Either BuildError BuildResult)
buildRustBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let rustc = T.unpack tc.rust.rustc.path
      target = T.unpack tc.rust.target

  createDirectoryIfMissing True outDir

  -- For single-file Rust, compile directly
  -- For multi-file, we'd need proper crate handling
  case bin.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag bin.edition
          cmd = [rustc, "--edition", edition, "--target", target, srcPath, "-o", outBin]

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          TIO.putStrLn $ "  rustc: " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    srcs -> do
      -- Multi-file: use first as main, compile all
      let mainSrc = srcDir </> T.unpack (head srcs)
          edition = rustEditionFlag bin.edition
          cmd = [rustc, "--edition", edition, "--target", target, mainSrc, "-o", outBin]

      TIO.putStrLn $ "  rustc: " <> T.pack (unwords cmd)
      (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildRustLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.RustLibrary -> IO (Either BuildError BuildResult)
buildRustLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      crateName = maybe (T.unpack lib.name) T.unpack lib.crateName
      outLib = outDir </> ("lib" <> crateName <> ".rlib")

  -- Toolchain
  let rustc = T.unpack tc.rust.rustc.path
      target = T.unpack tc.rust.target

  createDirectoryIfMissing True outDir

  case lib.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag lib.edition
          cmd =
            [ rustc,
              "--edition",
              edition,
              "--target",
              target,
              "--crate-type",
              "rlib",
              "--crate-name",
              crateName,
              srcPath,
              "-o",
              outLib
            ]

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          TIO.putStrLn $ "  rustc: " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outLib]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    _ -> pure $ Left $ UnsupportedRule "Multi-file Rust library"

-- | Build a Rust binary with resolved dependency outputs
buildRustBinaryWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.RustBinary ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildRustBinaryWithDeps tc projectRoot pkgPath bin depOutputs = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let rustc = T.unpack tc.rust.rustc.path
      target = T.unpack tc.rust.target

  createDirectoryIfMissing True outDir

  -- Extract .rlib files from deps and generate --extern flags
  let rlibFiles = concatMap snd depOutputs
      -- Get unique directories for -L flags
      libDirs = nub $ map takeDirectory rlibFiles
      libDirFlags = concatMap (\d -> ["-L", d]) libDirs
      -- Generate --extern cratename=path.rlib for each dep
      externFlags = concatMap mkExternFlag depOutputs

  case bin.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          edition = rustEditionFlag bin.edition
          cmd =
            [rustc, "--edition", edition, "--target", target]
              ++ externFlags
              ++ libDirFlags
              ++ [srcPath, "-o", outBin]

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          TIO.putStrLn $ "  rustc (with deps): " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
    srcs -> do
      -- Multi-file: use first as main
      let mainSrc = srcDir </> T.unpack (head srcs)
          edition = rustEditionFlag bin.edition
          cmd =
            [rustc, "--edition", edition, "--target", target]
              ++ externFlags
              ++ libDirFlags
              ++ [mainSrc, "-o", outBin]

      TIO.putStrLn $ "  rustc (with deps): " <> T.pack (unwords cmd)
      (exitCode, _, stderr) <- readProcessWithExitCode rustc (tail cmd) ""
      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
  where
    -- Convert dep name + rlib path to --extern flag
    -- e.g., ("mathlib", [".../libmathlib.rlib"]) -> ["--extern", "mathlib=.../libmathlib.rlib"]
    mkExternFlag :: (Text, [FilePath]) -> [String]
    mkExternFlag (depName, paths) = case paths of
      [rlib] -> ["--extern", T.unpack depName <> "=" <> rlib]
      _ -> [] -- Skip if not exactly one .rlib

-- ════════════════════════════════════════════════════════════════════════════
-- Haskell Build
-- ════════════════════════════════════════════════════════════════════════════

buildHaskellBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.HaskellBinary -> IO (Either BuildError BuildResult)
buildHaskellBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let ghc = T.unpack tc.haskell.ghc.path
      pkgDb = tc.haskell.paths.includes -- Package DB paths
      libPaths = map T.unpack tc.haskell.paths.libs

  createDirectoryIfMissing True outDir

  -- Use srcs list, not main (main is the module name, not file)
  let srcFiles = map (\s -> srcDir </> T.unpack s) bin.srcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) bin.packages
      extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions
      ghcOpts = map T.unpack bin.ghcOptions
      mainFlag = ["-main-is", T.unpack bin.main]
      pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb
      libFlags = concatMap (\l -> ["-L" <> l]) libPaths
      includeFlags = ["-i" <> srcDir, "-i" <> outDir]
      cmd = [ghc] ++ pkgDbFlags ++ includeFlags ++ extFlags ++ pkgFlags ++ ghcOpts ++ mainFlag ++ srcFiles ++ ["-o", outBin] ++ libFlags

  -- Check first source exists
  case srcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (mainSrc : _) -> do
      exists <- doesFileExist mainSrc
      if not exists
        then pure $ Left $ SourceNotFound mainSrc
        else do
          TIO.putStrLn $ "  ghc: " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildHaskellLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.HaskellLibrary -> IO (Either BuildError BuildResult)
buildHaskellLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath

  -- Toolchain
  let ghc = T.unpack tc.haskell.ghc.path
      pkgDb = tc.haskell.paths.includes
      libPaths = map T.unpack tc.haskell.paths.libs

  createDirectoryIfMissing True outDir

  -- Create output subdirectories for nested modules
  forM_ lib.srcs $ \src -> do
    let objPath = outDir </> T.unpack src <> ".o"
    createDirectoryIfMissing True (takeDirectory objPath)

  -- Use --make mode to compile all sources at once (handles dependency order automatically)
  let srcFiles = map (\s -> srcDir </> T.unpack s) lib.srcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) lib.packages
      extFlags = map (\e -> "-X" <> T.unpack e) lib.languageExtensions
      ghcOpts = map T.unpack lib.ghcOptions
      pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb
      libFlags = concatMap (\l -> ["-L" <> l]) libPaths
      includeFlags = ["-i" <> srcDir, "-i" <> outDir]
      -- Use --make to handle dependency ordering, -no-link to avoid linking
      cmd =
        [ghc, "--make", "-no-link"]
          ++ pkgDbFlags
          ++ includeFlags
          ++ extFlags
          ++ pkgFlags
          ++ ghcOpts
          ++ ["-odir", outDir, "-hidir", outDir]
          ++ libFlags
          ++ srcFiles

  -- Check first source exists
  case srcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (firstSrc : _) -> do
      exists <- doesFileExist firstSrc
      if not exists
        then pure $ Left $ SourceNotFound firstSrc
        else do
          TIO.putStrLn $ "  ghc (lib): " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
          case exitCode of
            ExitSuccess -> do
              -- Return all .o files as outputs
              -- GHC --make puts .o at module path (e.g., SenseNet/IR.o not SenseNet/IR.hs.o)
              let srcToObj s = outDir </> dropHsExt (T.unpack s) <> ".o"
                  dropHsExt p = if ".hs" `isSuffixOf` p then take (length p - 3) p else p
                  isSuffixOf suf str = suf == drop (length str - length suf) str
                  objs = map srcToObj lib.srcs
              pure $ Right $ BuildSuccess objs
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- | Build Haskell binary with resolved dependency outputs
-- Dep outputs (.o and .hi files) are added to the compilation
buildHaskellBinaryWithDeps ::
  TC.Toolchains ->
  FilePath ->
  FilePath ->
  IR.HaskellBinary ->
  [(Text, [FilePath])] -> -- (dep name, output paths)
  IO (Either BuildError BuildResult)
buildHaskellBinaryWithDeps tc projectRoot pkgPath bin depOutputs = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let ghc = T.unpack tc.haskell.ghc.path
      pkgDb = tc.haskell.paths.includes
      libPaths = map T.unpack tc.haskell.paths.libs

  createDirectoryIfMissing True outDir

  -- Use srcs list
  let srcFiles = map (\s -> srcDir </> T.unpack s) bin.srcs
      pkgFlags = concatMap (\p -> ["-package", T.unpack p]) bin.packages
      extFlags = map (\e -> "-X" <> T.unpack e) bin.languageExtensions
      ghcOpts = map T.unpack bin.ghcOptions
      mainFlag = ["-main-is", T.unpack bin.main]
      pkgDbFlags = concatMap (\db -> ["-package-db", T.unpack db]) pkgDb
      libFlags = concatMap (\l -> ["-L" <> l]) libPaths
      -- Add dep output .o files to link line
      depObjs = concatMap snd depOutputs
      -- Add dep output directories to -i search path (for .hi files)
      depDirs = nub $ map takeDirectory $ concatMap snd depOutputs
      -- Include source dir and output dir plus dep dirs for module discovery
      searchFlags = ["-i" <> srcDir, "-i" <> outDir] ++ map (\d -> "-i" <> d) depDirs
      cmd =
        [ghc]
          ++ pkgDbFlags
          ++ extFlags
          ++ pkgFlags
          ++ ghcOpts
          ++ searchFlags
          ++ mainFlag
          ++ srcFiles
          ++ depObjs
          ++ ["-o", outBin]
          ++ libFlags

  -- Check first source exists
  case srcFiles of
    [] -> pure $ Left $ SourceNotFound "no sources"
    (mainSrc : _) -> do
      exists <- doesFileExist mainSrc
      if not exists
        then pure $ Left $ SourceNotFound mainSrc
        else do
          TIO.putStrLn $ "  ghc (with deps): " <> T.pack (unwords cmd)
          (exitCode, _, stderr) <- readProcessWithExitCode ghc (tail cmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)
  where
    nub = map head . groupBy (==) . sort
    sort = foldr insert []
    insert x [] = [x]
    insert x (y : ys) = if x <= y then x : y : ys else y : insert x ys
    groupBy _ [] = []
    groupBy eq (x : xs) = let (ys, zs) = span (eq x) xs in (x : ys) : groupBy eq zs

-- ════════════════════════════════════════════════════════════════════════════
-- Lean Build
-- ════════════════════════════════════════════════════════════════════════════

buildLeanBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.LeanBinary -> IO (Either BuildError BuildResult)
buildLeanBinary tc projectRoot pkgPath bin = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath
      outBin = outDir </> T.unpack bin.name

  -- Toolchain
  let lean = T.unpack tc.lean.lean.path

  createDirectoryIfMissing True outDir

  -- Single file Lean compilation
  case bin.srcs of
    [src] -> do
      let srcPath = srcDir </> T.unpack src
          buildCmd = [lean, "-o", outBin, srcPath]

      exists <- doesFileExist srcPath
      if not exists
        then pure $ Left $ SourceNotFound srcPath
        else do
          TIO.putStrLn $ "  lean: " <> T.pack (unwords buildCmd)
          (exitCode, _, stderr) <- readProcessWithExitCode lean (tail buildCmd) ""
          case exitCode of
            ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
            ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords buildCmd) n (T.pack stderr)
    _ -> pure $ Left $ UnsupportedRule "Multi-file Lean binary"

buildLeanLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.LeanLibrary -> IO (Either BuildError BuildResult)
buildLeanLibrary tc projectRoot pkgPath lib = do
  let srcDir = projectRoot </> pkgPath
      outDir = projectRoot </> "sensenet-out" </> pkgPath

  -- Toolchain
  let lean = T.unpack tc.lean.lean.path

  createDirectoryIfMissing True outDir

  -- Compile each .lean to .olean
  results <- forM lib.srcs $ \src -> do
    let srcPath = srcDir </> T.unpack src
        oleanPath = outDir </> T.unpack src <> ".olean"
        cmd = [lean, "-c", oleanPath, srcPath]

    exists <- doesFileExist srcPath
    if not exists
      then pure $ Left $ SourceNotFound srcPath
      else do
        TIO.putStrLn $ "  lean: " <> T.pack (unwords cmd)
        (exitCode, _, stderr) <- readProcessWithExitCode lean (tail cmd) ""
        case exitCode of
          ExitSuccess -> pure $ Right oleanPath
          ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

  case sequence results of
    Left err -> pure $ Left err
    Right oleans -> pure $ Right $ BuildSuccess oleans

-- ════════════════════════════════════════════════════════════════════════════
-- NVIDIA/CUDA Build
-- ════════════════════════════════════════════════════════════════════════════

buildNvBinary :: TC.Toolchains -> FilePath -> FilePath -> IR.NvBinary -> IO (Either BuildError BuildResult)
buildNvBinary tc projectRoot pkgPath bin = do
  case tc.nv of
    Nothing -> pure $ Left $ UnsupportedRule "NvBinary requires NVIDIA toolchain (not configured)"
    Just nv -> do
      let srcDir = projectRoot </> pkgPath
          outDir = projectRoot </> "sensenet-out" </> pkgPath
          outBin = outDir </> T.unpack bin.name

      createDirectoryIfMissing True outDir

      -- Use toolchain paths (nv contains its own cxx toolchain for stdlib)
      let clang = T.unpack nv.clang.path
          cudaPath = T.unpack nv.sdk_path
          cudaIncludes = map T.unpack nv.sdk.includes
          cudaLibs = map T.unpack nv.sdk.libs
          cxxIncludes = map T.unpack nv.cxx.paths.includes
          cxxLibs = map T.unpack nv.cxx.paths.libs
          ld = T.unpack nv.cxx.ld.path
          sysroot = T.unpack nv.cxx.sysroot

      -- Source files
      let srcs = map (\s -> srcDir </> T.unpack s) bin.srcs

      -- Architecture flags (from rule or toolchain defaults)
      let ruleArchs = bin.archs
          tcArchs = nv.archs
          archs = if null ruleArchs then tcArchs else ruleArchs
          archFlags = concatMap (\a -> ["--cuda-gpu-arch=" <> T.unpack a, "--cuda-include-ptx=" <> T.unpack a]) archs

      -- Compile flags
      let cudaFlags =
            [ "-x",
              "cuda",
              "--cuda-path=" <> cudaPath,
              "-std=c++23",
              "-Wno-unknown-cuda-version"
            ]
              ++ concatMap (\i -> ["-isystem", i]) cudaIncludes
              ++ concatMap (\i -> ["-isystem", i]) cxxIncludes
              ++ (if null sysroot then [] else ["--sysroot=" <> sysroot])

      -- Link flags (-B tells linker where to find crt*.o files)
      let linkFlags =
            [ "-fuse-ld=" <> ld,
              "-lcudart"
            ]
              ++ concatMap (\l -> ["-L" <> l, "-Wl,-rpath," <> l]) cudaLibs
              ++ concatMap (\l -> ["-B" <> l, "-L" <> l, "-Wl,-rpath," <> l]) cxxLibs

      let cmd = [clang] ++ cudaFlags ++ archFlags ++ srcs ++ ["-o", outBin] ++ linkFlags

      TIO.putStrLn $ "  clang++ (cuda): " <> T.pack (unwords cmd)
      (exitCode, _, stderr) <- readProcessWithExitCode clang (tail cmd) ""
      case exitCode of
        ExitSuccess -> pure $ Right $ BuildSuccess [outBin]
        ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

buildNvLibrary :: TC.Toolchains -> FilePath -> FilePath -> IR.NvLibrary -> IO (Either BuildError BuildResult)
buildNvLibrary tc projectRoot pkgPath lib = do
  case tc.nv of
    Nothing -> pure $ Left $ UnsupportedRule "NvLibrary requires NVIDIA toolchain (not configured)"
    Just nv -> do
      let srcDir = projectRoot </> pkgPath
          outDir = projectRoot </> "sensenet-out" </> pkgPath

      createDirectoryIfMissing True outDir

      -- Use toolchain paths (nv contains its own cxx toolchain for stdlib)
      let clang = T.unpack nv.clang.path
          cudaPath = T.unpack nv.sdk_path
          cudaIncludes = map T.unpack nv.sdk.includes
          cxxIncludes = map T.unpack nv.cxx.paths.includes
          sysroot = T.unpack nv.cxx.sysroot

      -- Architecture flags
      let ruleArchs = lib.archs
          tcArchs = nv.archs
          archs = if null ruleArchs then tcArchs else ruleArchs
          archFlags = concatMap (\a -> ["--cuda-gpu-arch=" <> T.unpack a, "--cuda-include-ptx=" <> T.unpack a]) archs

      -- Compile flags
      let cudaFlags =
            [ "-x",
              "cuda",
              "--cuda-path=" <> cudaPath,
              "-std=c++23",
              "-Wno-unknown-cuda-version",
              "-fPIC",
              "-c"
            ]
              ++ concatMap (\i -> ["-isystem", i]) cudaIncludes
              ++ concatMap (\i -> ["-isystem", i]) cxxIncludes
              ++ (if null sysroot then [] else ["--sysroot=" <> sysroot])

      -- Compile each source to .o
      results <- forM lib.srcs $ \src -> do
        let srcPath = srcDir </> T.unpack src
            objPath = outDir </> T.unpack src <> ".o"
            cmd = [clang] ++ cudaFlags ++ archFlags ++ [srcPath, "-o", objPath]

        exists <- doesFileExist srcPath
        if not exists
          then pure $ Left $ SourceNotFound srcPath
          else do
            TIO.putStrLn $ "  clang++ (cuda): " <> T.pack (unwords cmd)
            (exitCode, _, stderr) <- readProcessWithExitCode clang (tail cmd) ""
            case exitCode of
              ExitSuccess -> pure $ Right objPath
              ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

      case sequence results of
        Left err -> pure $ Left err
        Right objs -> pure $ Right $ BuildSuccess objs

-- ════════════════════════════════════════════════════════════════════════════
-- PureScript Build
-- ════════════════════════════════════════════════════════════════════════════

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

  TIO.putStrLn $ "  spago: " <> T.pack (unwords cmd)
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

  TIO.putStrLn $ "  spago: " <> T.pack (unwords cmd)
  (exitCode, stderr) <- runProcessWithPath srcDir extraPaths spago args
  case exitCode of
    ExitSuccess -> pure $ Right $ BuildSuccess [outBundle]
    ExitFailure n -> pure $ Left $ CompileFailed (T.pack $ unwords cmd) n (T.pack stderr)

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

-- | Copy a file
copyFile :: FilePath -> FilePath -> IO ()
copyFile src dst = BS.readFile src >>= BS.writeFile dst

-- | Run a process in a specific directory, returning exit code and stderr
runProcessInDir :: FilePath -> String -> [String] -> IO (ExitCode, String)
runProcessInDir dir prog args = do
  let p = (proc prog args) {cwd = Just dir, std_out = CreatePipe, std_err = CreatePipe}
  (_, _, Just herr, ph) <- createProcess p
  stderr <- hGetContents herr
  exitCode <- waitForProcess ph
  pure (exitCode, stderr)

-- | Run a process with modified PATH, returning exit code and stderr
runProcessWithPath :: FilePath -> [FilePath] -> String -> [String] -> IO (ExitCode, String)
runProcessWithPath dir extraPaths prog args = do
  currentEnv <- getEnvironment
  let currentPath = fromMaybe "" $ lookup "PATH" currentEnv
      newPath = intercalate ":" extraPaths <> ":" <> currentPath
      newEnv = ("PATH", newPath) : filter ((/= "PATH") . fst) currentEnv
      p = (proc prog args) {cwd = Just dir, std_out = CreatePipe, std_err = CreatePipe, env = Just newEnv}
  (_, _, Just herr, ph) <- createProcess p
  stderr <- hGetContents herr
  exitCode <- waitForProcess ph
  pure (exitCode, stderr)

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
