{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : SenseNet.TUI
-- Description : Superconsole-style TUI for sensenet builds
--
-- "The sky above the port was the color of television,
--  tuned to a dead channel."
--
--                                      — Neuromancer
--
-- This module provides a superconsole-style TUI for build progress:
--
--   * __Emit area__ (top) — Completed builds scroll up
--   * __Canvas area__ (bottom) — In-place updating display:
--       - Progress bar with count
--       - Currently executing actions
--       - Summary statistics
--
-- The canvas redraws in-place while the emit area grows upward.
module SenseNet.TUI
  ( -- * TUI Build
    buildWithTUI,

    -- * TUI State
    TUIState (..),
    initialTUIState,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Monad (forever)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import HyperConsole.Layout (Constraint (Exact, Fill))
import HyperConsole.Terminal (Console, emit, render, withConsoleFallback)
import HyperConsole.Theme qualified as Theme
import HyperConsole.Widget (Line, Span (..), Widget, progress, textStyled, vbox, vboxWith, (<+>))
import SenseNet.Build (BuildError, BuildResult, ProgressCallback, ProgressEvent (..))

-- ════════════════════════════════════════════════════════════════════════════
-- TUI State
-- ════════════════════════════════════════════════════════════════════════════

-- | State for the TUI
data TUIState = TUIState
  { -- | The root target being built (e.g., "//..." or "//src/examples:all")
    tuiTarget :: !Text,
    -- | Total number of actions
    tuiTotal :: !Int,
    -- | Number of completed actions
    tuiCompleted :: !Int,
    -- | Number of cached actions
    tuiCached :: !Int,
    -- | Currently building targets (name -> start time)
    tuiActive :: !(Map Text UTCTime),
    -- | When the build started
    tuiStartTime :: !UTCTime,
    -- | Animation tick counter
    tuiTick :: !Int
  }
  deriving (Show)

-- | Initial TUI state
initialTUIState :: Text -> UTCTime -> TUIState
initialTUIState target startTime =
  TUIState
    { tuiTarget = target,
      tuiTotal = 0,
      tuiCompleted = 0,
      tuiCached = 0,
      tuiActive = Map.empty,
      tuiStartTime = startTime,
      tuiTick = 0
    }

-- ════════════════════════════════════════════════════════════════════════════
-- TUI Build
-- ════════════════════════════════════════════════════════════════════════════

-- | Run a build action with superconsole-style TUI progress display
--
-- Falls back to simple output if not running in a TTY.
buildWithTUI ::
  Text ->
  -- | Root target label
  (ProgressCallback -> IO (Either BuildError BuildResult)) ->
  -- | Build action that takes a progress callback
  IO (Either BuildError BuildResult)
buildWithTUI target buildAction =
  withConsoleFallback fallback $ \console -> do
    -- Initialize state
    startTime <- getCurrentTime
    stateRef <- newIORef (initialTUIState target startTime)
    tickRef <- newIORef (0 :: Int)

    -- Start render loop (~30fps for smooth animations)
    renderThread <- async $ renderLoop console stateRef tickRef

    -- Create progress callback that updates state
    let callback = tuiCallback console stateRef

    -- Run the build
    result <- buildAction callback

    -- Stop render loop
    cancel renderThread

    -- Final render to show completion
    finalState <- readIORef stateRef
    now <- getCurrentTime
    render console (buildWidget finalState now)

    -- Print final summary below the canvas
    TIO.putStrLn ""

    pure result
  where
    -- Fallback for non-TTY: use verbose text callback from DICE
    fallback = buildAction verboseCallback

    -- Simple text callback that shows all events
    verboseCallback = \case
      -- Discovery
      ProgressDiscovering p -> TIO.putStrLn $ "◌ scanning " <> p
      ProgressFoundPackage p -> TIO.putStrLn $ "◉ found " <> p
      -- Dhall
      ProgressDhallParsing p -> TIO.putStrLn $ "◌ parsing " <> p
      ProgressDhallParsed p -> TIO.putStrLn $ "◉ parsed " <> p
      ProgressDhallImport i -> TIO.putStrLn $ "  ↳ import " <> i
      ProgressDhallNormalizing t -> TIO.putStrLn $ "◌ eval " <> t
      ProgressDhallEvaluated t n -> TIO.putStrLn $ "◉ eval " <> t <> " (" <> T.pack (show n) <> " rules)"
      -- Toolchains
      ProgressToolchainLoading p -> TIO.putStrLn $ "◌ toolchains " <> p
      ProgressToolchainCached p -> TIO.putStrLn $ "○ toolchains (cached) " <> p
      ProgressToolchainLoaded p n -> TIO.putStrLn $ "◉ toolchains " <> p <> " (" <> T.pack (show n) <> ")"
      -- Dependencies
      ProgressResolvingDeps t -> TIO.putStrLn $ "◌ deps " <> t
      ProgressCrossPackageDep p -> TIO.putStrLn $ "  ↳ cross-pkg " <> p
      ProgressDepsResolved t n -> TIO.putStrLn $ "◉ deps " <> t <> " (" <> T.pack (show n) <> ")"
      -- Nix
      ProgressNixResolving r -> TIO.putStrLn $ "◌ nix " <> r
      ProgressNixResolved r _ -> TIO.putStrLn $ "◉ nix " <> r
      -- Graph
      ProgressBuildingGraph t -> TIO.putStrLn $ "◌ graph " <> t
      ProgressGraphAction a -> TIO.putStrLn $ "  + " <> a
      ProgressGraphBuilt n -> TIO.putStrLn $ "◉ graph (" <> T.pack (show n) <> " actions)"
      -- Cache
      ProgressCacheCheck a -> TIO.putStrLn $ "? cache " <> a
      ProgressCacheHit a -> TIO.putStrLn $ "✓ hit " <> a
      ProgressCacheMiss a -> TIO.putStrLn $ "✗ miss " <> a
      -- Execution
      ProgressStarting nm _ _ -> TIO.putStrLn $ "→ " <> nm
      ProgressCached nm _ _ -> TIO.putStrLn $ "○ " <> nm <> " (cached)"
      ProgressCompleted nm _ _ _ -> TIO.putStrLn $ "✓ " <> nm
      ProgressFailed nm _ _ e -> TIO.putStrLn $ "✗ " <> nm <> ": " <> e
      -- Finalization
      ProgressWritingOutput p -> TIO.putStrLn $ "◌ write " <> p
      ProgressCacheStore a -> TIO.putStrLn $ "◌ cache " <> a
      ProgressPhaseComplete ph d -> TIO.putStrLn $ "◉ " <> ph <> " (" <> T.pack (show (round (d * 1000) :: Int)) <> "ms)"

-- | Render loop - updates display at ~30fps
renderLoop :: Console -> IORef TUIState -> IORef Int -> IO ()
renderLoop console stateRef tickRef = forever $ do
  -- Increment tick
  tick <- atomicModifyIORef' tickRef (\t -> (t + 1, t + 1))

  -- Get current time for elapsed calculation
  now <- getCurrentTime

  -- Update state with new tick
  state <- readIORef stateRef
  let state' = state {tuiTick = tick}

  -- Render
  render console (buildWidget state' now)

  -- Sleep ~33ms (30fps)
  threadDelay 33333

-- | Progress callback that updates TUI state
--
-- Every event emits a line that scrolls up in the emit area, providing
-- maximum visibility into the build process.
tuiCallback :: Console -> IORef TUIState -> ProgressCallback
tuiCallback console stateRef = \case
  -- ══════════════════════════════════════════════════════════════════════════
  -- Discovery phase - show every file being scanned
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressDiscovering path ->
    emit console (infoLine "◌" "scanning" path)
  ProgressFoundPackage pkg ->
    emit console (successLine "◉" "found" pkg)
  -- ══════════════════════════════════════════════════════════════════════════
  -- Dhall phase - show parsing, imports, normalization
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressDhallParsing path ->
    emit console (infoLine "◌" "parsing" path)
  ProgressDhallParsed path ->
    emit console (successLine "◉" "parsed" path)
  ProgressDhallImport imp ->
    emit console (mutedLine "  ↳" "import" imp)
  ProgressDhallNormalizing target ->
    emit console (infoLine "◌" "eval" target)
  ProgressDhallEvaluated target nRules ->
    emit console (successLine "◉" "eval" (target <> " (" <> T.pack (show nRules) <> " rules)"))
  -- ══════════════════════════════════════════════════════════════════════════
  -- Toolchains
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressToolchainLoading path ->
    emit console (infoLine "◌" "toolchains" path)
  ProgressToolchainCached path ->
    emit console (cachedLine "○" "toolchains" path)
  ProgressToolchainLoaded path n ->
    emit console (successLine "◉" "toolchains" (path <> " (" <> T.pack (show n) <> ")"))
  -- ══════════════════════════════════════════════════════════════════════════
  -- Dependency resolution
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressResolvingDeps target ->
    emit console (infoLine "◌" "deps" target)
  ProgressCrossPackageDep pkg ->
    emit console (mutedLine "  ↳" "cross-pkg" pkg)
  ProgressDepsResolved target n ->
    emit console (successLine "◉" "deps" (target <> " (" <> T.pack (show n) <> ")"))
  -- ══════════════════════════════════════════════════════════════════════════
  -- Nix resolution
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressNixResolving ref ->
    emit console (infoLine "◌" "nix" ref)
  ProgressNixResolved ref _storePath ->
    emit console (successLine "◉" "nix" ref)
  -- ══════════════════════════════════════════════════════════════════════════
  -- Graph construction
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressBuildingGraph target ->
    emit console (infoLine "◌" "graph" target)
  ProgressGraphAction action ->
    emit console (mutedLine "  +" "" action)
  ProgressGraphBuilt n -> do
    emit console (successLine "◉" "graph" (T.pack (show n) <> " actions"))
    -- Update total when graph is built
    atomicModifyIORef' stateRef $ \s ->
      (s {tuiTotal = n}, ())

  -- ══════════════════════════════════════════════════════════════════════════
  -- Cache checks
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressCacheCheck action ->
    emit console (mutedLine "?" "cache" action)
  ProgressCacheHit action ->
    emit console (cachedLine "✓" "hit" action)
  ProgressCacheMiss action ->
    emit console (mutedLine "✗" "miss" action)
  -- ══════════════════════════════════════════════════════════════════════════
  -- Execution - these update the canvas state
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressStarting name _cur total -> do
    now <- getCurrentTime
    emit console (infoLine "→" "exec" name)
    atomicModifyIORef' stateRef $ \s ->
      ( s
          { tuiTotal = max total (tuiTotal s),
            tuiActive = Map.insert name now (tuiActive s)
          },
        ()
      )
  ProgressCached name _cur total -> do
    emit console (cachedLine "○" "" (name <> " (cached)"))
    atomicModifyIORef' stateRef $ \s ->
      ( s
          { tuiTotal = max total (tuiTotal s),
            tuiCompleted = tuiCompleted s + 1,
            tuiCached = tuiCached s + 1,
            tuiActive = Map.delete name (tuiActive s)
          },
        ()
      )
  ProgressCompleted name _cur total _memKB -> do
    emit console (successLine "✓" "" name)
    atomicModifyIORef' stateRef $ \s ->
      ( s
          { tuiTotal = max total (tuiTotal s),
            tuiCompleted = tuiCompleted s + 1,
            tuiActive = Map.delete name (tuiActive s)
          },
        ()
      )
  ProgressFailed name _cur _total err -> do
    emit console (errorLine "✗" name err)
    atomicModifyIORef' stateRef $ \s ->
      ( s {tuiActive = Map.delete name (tuiActive s)},
        ()
      )

  -- ══════════════════════════════════════════════════════════════════════════
  -- Finalization
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressWritingOutput path ->
    emit console (mutedLine "◌" "write" path)
  ProgressCacheStore action ->
    emit console (mutedLine "◌" "cache" action)
  ProgressPhaseComplete phase duration ->
    emit console (successLine "◉" phase (T.pack (show (round (duration * 1000) :: Int)) <> "ms"))

-- | Info line (in progress) - frost1 color
infoLine :: Text -> Text -> Text -> Line
infoLine glyph verb name =
  Seq.fromList $
    [Span Theme.themeAccent (glyph <> " ")]
      ++ [Span Theme.themeSecondary (verb <> " ") | not (T.null verb)]
      ++ [Span Theme.themePrimary name]

-- | Success line - green
successLine :: Text -> Text -> Text -> Line
successLine glyph verb name =
  Seq.fromList $
    [Span Theme.themeSuccess (glyph <> " ")]
      ++ [Span Theme.themeSecondary (verb <> " ") | not (T.null verb)]
      ++ [Span Theme.themePrimary name]

-- | Cached line - dim cyan
cachedLine :: Text -> Text -> Text -> Line
cachedLine glyph verb name =
  Seq.fromList $
    [Span Theme.themeStatusCached (glyph <> " ")]
      ++ [Span Theme.themeSecondary (verb <> " ") | not (T.null verb)]
      ++ [Span Theme.themePrimary name]

-- | Muted line (secondary info) - dim
mutedLine :: Text -> Text -> Text -> Line
mutedLine glyph verb name =
  Seq.fromList $
    [Span Theme.themeMuted (glyph <> " ")]
      ++ [Span Theme.themeMuted (verb <> " ") | not (T.null verb)]
      ++ [Span Theme.themeMuted name]

-- | Error line - red
errorLine :: Text -> Text -> Text -> Line
errorLine glyph name err =
  Seq.fromList
    [ Span Theme.themeError (glyph <> " "),
      Span Theme.themePrimary name,
      Span Theme.themeError (": " <> err)
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Widgets - Superconsole Style
-- ════════════════════════════════════════════════════════════════════════════

-- | Main build widget (superconsole style)
--
-- Layout:
--   Jobs completed: 45. Time elapsed: 2.3s. Cache hits: 100%
--   [████████████████████████████░░░░░░░░░░░░░░░] 28/45
--     ◉ //src/foo:bar (1.2s)
--     ◉ //src/baz:qux (0.8s)
buildWidget :: TUIState -> UTCTime -> Widget
buildWidget TUIState {..} now =
  vboxWith constraints [summaryWidget, progressWidget, activeListWidget]
  where
    -- Layout constraints: summary and progress are 1 line each, active list fills
    constraints = [Exact 1, Exact 1, Fill 1]

    -- Summary line: "Jobs completed: N. Time elapsed: Xs. Cache hits: N%"
    elapsed = realToFrac (diffUTCTime now tuiStartTime) :: Double
    cacheHitPct =
      if tuiCompleted > 0
        then (tuiCached * 100) `div` tuiCompleted
        else 0
    summaryWidget =
      textStyled Theme.themeSecondary $
        "Jobs completed: "
          <> T.pack (show tuiCompleted)
          <> ". Time elapsed: "
          <> formatDuration elapsed
          <> ". Cache hits: "
          <> T.pack (show cacheHitPct)
          <> "%"

    -- Progress bar: [████████░░░░░░░░] N/M
    pct =
      if tuiTotal > 0
        then fromIntegral tuiCompleted / fromIntegral tuiTotal
        else 0
    progressWidget =
      textStyled Theme.themeAccent "["
        <+> progress Theme.themeProgressFilled Theme.themeProgressEmpty pct
        <+> textStyled Theme.themeAccent "] "
        <+> textStyled Theme.themeProgressText (T.pack (show tuiCompleted) <> "/" <> T.pack (show tuiTotal))

    -- Active builds list (up to 8)
    activeItems = take 8 $ Map.toList tuiActive
    activeListWidget = vbox $ map (activeItemWidget now tuiTick) activeItems

-- | Widget for a single active build item
activeItemWidget :: UTCTime -> Int -> (Text, UTCTime) -> Widget
activeItemWidget now tick (name, startTime) =
  textStyled Theme.themeAccent ("  " <> spinnerFrame tick <> " ")
    <+> textStyled Theme.themeSecondary name
    <+> textStyled Theme.themeMuted (" (" <> formatDuration elapsed <> ")")
  where
    elapsed = realToFrac (diffUTCTime now startTime) :: Double

-- | Spinner animation (Braille pattern)
spinnerFrame :: Int -> Text
spinnerFrame tick =
  let frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" :: Text
   in T.singleton $ T.index frames (tick `mod` T.length frames)

-- | Format duration as "Xs" or "Xm Ys"
formatDuration :: Double -> Text
formatDuration secs
  | secs < 60 = T.pack (show (round secs :: Int)) <> "s"
  | otherwise =
      let mins = floor (secs / 60) :: Int
          remSecs = round (secs - fromIntegral mins * 60) :: Int
       in T.pack (show mins) <> "m " <> T.pack (show remSecs) <> "s"
