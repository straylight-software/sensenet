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
import HyperConsole.Style (Style)
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
    -- Fallback for non-TTY: just run with a simple callback
    fallback = buildAction simpleCallback

    simpleCallback = \case
      ProgressStarting name _ _ -> TIO.putStrLn $ "Building " <> name
      ProgressCached name _ _ -> TIO.putStrLn $ "Cached " <> name
      ProgressCompleted name _ _ _ -> TIO.putStrLn $ "Built " <> name
      ProgressFailed name _ _ err -> TIO.putStrLn $ "Failed " <> name <> ": " <> err

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
tuiCallback :: Console -> IORef TUIState -> ProgressCallback
tuiCallback console stateRef = \case
  ProgressStarting name _cur total -> do
    now <- getCurrentTime
    atomicModifyIORef' stateRef $ \s ->
      ( s
          { tuiTotal = max total (tuiTotal s),
            tuiActive = Map.insert name now (tuiActive s)
          },
        ()
      )
  ProgressCached name _cur total -> do
    -- Emit completed line (scrolls up)
    emit console (completedLine Theme.themeStatusCached "○" name "(cached)")
    -- Increment both completed and cached - don't use cur as callbacks may arrive out of order
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
    -- Emit completed line (scrolls up)
    emit console (completedLine Theme.themeSuccess "✓" name "")
    -- Increment completed - don't use cur as callbacks may arrive out of order
    atomicModifyIORef' stateRef $ \s ->
      ( s
          { tuiTotal = max total (tuiTotal s),
            tuiCompleted = tuiCompleted s + 1,
            tuiActive = Map.delete name (tuiActive s)
          },
        ()
      )
  ProgressFailed name _cur _total err -> do
    -- Emit failure line
    emit console (failedLine name err)
    atomicModifyIORef' stateRef $ \s ->
      ( s {tuiActive = Map.delete name (tuiActive s)},
        ()
      )

-- | Create a completed line for emit (scrolls up above canvas)
completedLine :: Style -> Text -> Text -> Text -> Line
completedLine style glyph name suffix =
  Seq.fromList $
    [ Span style (glyph <> " "),
      Span Theme.themePrimary name
    ]
      ++ [Span Theme.themeSecondary (" " <> suffix) | not (T.null suffix)]

-- | Create a failed line for emit
failedLine :: Text -> Text -> Line
failedLine name err =
  Seq.fromList
    [ Span Theme.themeError "✗ ",
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
