{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : SenseNet.TUI
-- Description : Razorgirl dashboard TUI for sensenet builds
--
-- "The sky above the port was the color of television,
--  tuned to a dead channel."
--
--                                      — Neuromancer
--
-- Full ono-sendai razorgirl aesthetic build monitor with:
--
--   * __Preamble phase__ — Streaming log of discovery, dhall eval, graph build
--   * __Build phase__ — Target groups with progress bars
--   * __Complete phase__ — Summary with timing
--
-- Uses HyperConsole for flicker-free rendering in tmux.
module SenseNet.TUI
  ( -- * TUI Build
    buildWithTUI,

    -- * Dashboard State (for testing)
    DashboardState (..),
    initDashboardState,
    handleProgressEvent,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, waitCatch)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, tryTakeMVar)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (void)
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq, (|>))
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import HyperConsole
import HyperConsole.Theme
import SenseNet.Build (BuildError, BuildResult, ProgressCallback, ProgressEvent (..))

-- ════════════════════════════════════════════════════════════════════════════
-- Dashboard State
-- ════════════════════════════════════════════════════════════════════════════

-- | Target status in the dashboard
data TargetStatus
  = -- | Waiting to start
    TQueued
  | -- | Currently building, started at time
    TBuilding UTCTime
  | -- | Finished successfully, start time + duration ms
    TCompleted UTCTime Int
  | -- | Failed with error
    TFailed UTCTime Int Text
  | -- | Cache hit
    TCached
  deriving stock (Eq, Show)

-- | A build target for display
data Target = Target
  { -- | e.g. "//sigil-trtllm:test-rope"
    targetId :: Text,
    -- | Current build status
    targetStatus :: TargetStatus
  }
  deriving stock (Eq, Show)

-- | Build phase
data Phase
  = -- | Scanning for BUILD.dhall files
    PhaseDiscovery
  | -- | Parsing dhall files
    PhaseParsing
  | -- | Building dependency graph
    PhaseGraph
  | -- | Checking cache
    PhaseCacheCheck
  | -- | Executing builds
    PhaseBuilding
  | -- | All done
    PhaseComplete
  deriving stock (Eq, Show)

-- | Log line with styling
data LogLine = LogLine
  { logText :: Text,
    logStyle :: Style
  }
  deriving stock (Eq, Show)

-- | Complete dashboard state
data DashboardState = DashboardState
  { -- | All known targets
    dsTargets :: Map Text Target,
    -- | Current phase
    dsPhase :: Phase,
    -- | Log history (newest last), uses Seq for O(1) append
    dsLogs :: Seq LogLine,
    -- | When build started
    dsStartTime :: Maybe UTCTime,
    -- | Total actions (from graph)
    dsTotal :: Int,
    -- | Completed actions
    dsCompleted :: Int,
    -- | Cache hits
    dsCached :: Int,
    -- | Failed actions
    dsFailed :: Int
  }
  deriving stock (Show)

-- | Initial empty state
initDashboardState :: DashboardState
initDashboardState =
  DashboardState
    { dsTargets = Map.empty,
      dsPhase = PhaseDiscovery,
      dsLogs = Seq.empty,
      dsStartTime = Nothing,
      dsTotal = 0,
      dsCompleted = 0,
      dsCached = 0,
      dsFailed = 0
    }

-- ════════════════════════════════════════════════════════════════════════════
-- Event Handling
-- ════════════════════════════════════════════════════════════════════════════

-- | Process a ProgressEvent and update dashboard state
handleProgressEvent :: UTCTime -> ProgressEvent -> DashboardState -> DashboardState
handleProgressEvent now event state = case event of
  -- ══════════════════════════════════════════════════════════════════════════
  -- Discovery phase
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressDiscovering path ->
    addLog razorAccent ("◌ scanning " <> path) $
      state {dsPhase = PhaseDiscovery}
  ProgressFoundPackage pkg ->
    addLog razorMuted ("◉ found " <> pkg) state
  -- ══════════════════════════════════════════════════════════════════════════
  -- Dhall parsing phase
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressDhallParsing path ->
    addLog razorAccent ("◌ parsing " <> path) $
      state {dsPhase = PhaseParsing}
  ProgressDhallParsed path ->
    addLog razorMuted ("◉ parsed " <> path) state
  ProgressDhallImport imp ->
    addLog razorDim ("  ↳ import " <> imp) state
  ProgressDhallNormalizing target ->
    addLog razorAccent ("◌ eval " <> target) state
  ProgressDhallEvaluated target nRules ->
    addLog razorInfo ("◉ eval " <> target <> " (" <> T.pack (show nRules) <> " rules)") state
  -- ══════════════════════════════════════════════════════════════════════════
  -- Toolchains
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressToolchainLoading path ->
    addLog razorAccent ("◌ toolchains " <> path) state
  ProgressToolchainCached path ->
    addLog razorMuted ("○ toolchains (cached) " <> path) state
  ProgressToolchainLoaded path n ->
    addLog razorInfo ("◉ toolchains " <> path <> " (" <> T.pack (show n) <> ")") state
  -- ══════════════════════════════════════════════════════════════════════════
  -- Dependency resolution
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressResolvingDeps target ->
    addLog razorAccent ("◌ deps " <> target) state
  ProgressCrossPackageDep pkg ->
    addLog razorDim ("  ↳ cross-pkg " <> pkg) state
  ProgressDepsResolved target n ->
    addLog razorInfo ("◉ deps " <> target <> " (" <> T.pack (show n) <> ")") state
  -- ══════════════════════════════════════════════════════════════════════════
  -- Nix resolution
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressNixResolving ref ->
    addLog razorAccent ("◌ nix " <> ref) state
  ProgressNixResolved ref _storePath ->
    addLog razorInfo ("◉ nix " <> ref) state
  -- ══════════════════════════════════════════════════════════════════════════
  -- Graph construction
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressBuildingGraph target ->
    addLog razorAccent ("◌ graph " <> target) $
      state {dsPhase = PhaseGraph}
  ProgressGraphAction action ->
    -- Register target as queued
    let tid = action
        target = Target tid TQueued
     in state {dsTargets = Map.insert tid target (dsTargets state)}
  ProgressGraphBuilt n ->
    addLog razorInfo ("◉ graph (" <> T.pack (show n) <> " actions)") $
      state {dsTotal = n}
  -- ══════════════════════════════════════════════════════════════════════════
  -- Cache checks
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressCacheCheck action ->
    addLog razorDim ("? " <> action) $
      state {dsPhase = PhaseCacheCheck}
  ProgressCacheHit action ->
    addLog razorAccent ("✓ hit " <> action) state
  ProgressCacheMiss action ->
    addLog razorMiss ("✗ miss " <> action) state
  -- ══════════════════════════════════════════════════════════════════════════
  -- Execution
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressStarting name _cur total ->
    let target = Target name (TBuilding now)
        newState =
          state
            { dsPhase = PhaseBuilding,
              dsTotal = max total (dsTotal state),
              dsTargets = Map.insert name target (dsTargets state),
              dsStartTime = case dsStartTime state of
                Nothing -> Just now
                x -> x
            }
     in addLog razorAccent ("→ " <> name) newState
  ProgressCached name _cur total ->
    let target = Target name TCached
     in addLog razorMuted ("○ " <> name <> " (cached)") $
          state
            { dsPhase = PhaseBuilding, -- Switch to building phase on first execution event
              dsTotal = max total (dsTotal state),
              dsCompleted = dsCompleted state + 1,
              dsCached = dsCached state + 1,
              dsTargets = Map.insert name target (dsTargets state),
              dsStartTime = case dsStartTime state of
                Nothing -> Just now
                x -> x
            }
  ProgressCompleted name _cur total _memKB ->
    let durationMs = case Map.lookup name (dsTargets state) of
          Just (Target _ (TBuilding startT)) -> round (diffUTCTime now startT * 1000)
          _ -> 0
        target = Target name (TCompleted now durationMs)
     in addLog razorAccent ("✓ " <> name) $
          state
            { dsTotal = max total (dsTotal state),
              dsCompleted = dsCompleted state + 1,
              dsTargets = Map.insert name target (dsTargets state)
            }
  ProgressFailed name _cur _total err ->
    let durationMs = case Map.lookup name (dsTargets state) of
          Just (Target _ (TBuilding startT)) -> round (diffUTCTime now startT * 1000)
          _ -> 0
        target = Target name (TFailed now durationMs err)
     in addLog razorMiss ("✗ " <> name <> ": " <> err) $
          state
            { dsFailed = dsFailed state + 1,
              dsTargets = Map.insert name target (dsTargets state)
            }
  -- ══════════════════════════════════════════════════════════════════════════
  -- Finalization
  -- ══════════════════════════════════════════════════════════════════════════
  ProgressWritingOutput path ->
    addLog razorDim ("◌ write " <> path) state
  ProgressCacheStore action ->
    addLog razorDim ("◌ cache " <> action) state
  ProgressPhaseComplete phase duration ->
    addLog razorInfo ("◉ " <> phase <> " (" <> T.pack (show (round (duration * 1000) :: Int)) <> "ms)") state

-- | Add a log line to state (O(1) append using Seq)
addLog :: Style -> Text -> DashboardState -> DashboardState
addLog style txt state =
  state {dsLogs = dsLogs state |> LogLine txt style}

-- ════════════════════════════════════════════════════════════════════════════
-- TUI Build Entry Point
-- ════════════════════════════════════════════════════════════════════════════

-- | Run a build action with the razorgirl dashboard
--
-- Falls back to simple output if not running in a TTY.
-- Properly handles exceptions, terminal cleanup, and render thread lifecycle.
buildWithTUI ::
  Text ->
  (ProgressCallback -> IO (Either BuildError BuildResult)) ->
  IO (Either BuildError BuildResult)
buildWithTUI _target buildAction =
  withConsoleFallback fallback $ \console -> do
    -- Initialize state with start time set immediately
    now <- getCurrentTime
    stateRef <- newIORef initDashboardState {dsStartTime = Just now}

    -- Mutable dimensions ref for resize handling
    dimsRef <- newIORef =<< getTerminalSize

    -- Signal to stop the render loop
    stopSignal <- newEmptyMVar :: IO (MVar ())

    -- Start render loop (~40fps for smooth progress bars)
    -- The render loop now checks for stop signal and updates dimensions
    renderThread <- async $ renderLoopWithStop console dimsRef stateRef stopSignal

    -- Run the build with proper exception handling
    result <-
      bracket
        (pure ()) -- acquire: nothing needed
        ( \_ -> do
            -- release: always stop render thread and cleanup
            -- Signal render loop to stop
            putMVar stopSignal ()
            -- Wait for render thread to finish (with timeout via cancel as backup)
            void $ waitCatch renderThread
        )
        ( \_ -> do
            -- use: run the actual build
            -- Create progress callback that updates state
            let callback = dashboardCallback stateRef

            -- Run the build, catching any exceptions
            buildResult <- try $ buildAction callback

            case buildResult of
              Left (e :: SomeException) -> do
                -- Mark as failed on exception
                atomicModifyIORef' stateRef $ \s ->
                  (s {dsPhase = PhaseComplete, dsFailed = dsFailed s + 1}, ())
                -- Re-throw after cleanup in bracket
                pure $ Left $ error $ "Build exception: " ++ show e
              Right r -> do
                -- Mark complete
                atomicModifyIORef' stateRef $ \s -> (s {dsPhase = PhaseComplete}, ())
                pure r
        )

    -- Final render after build completes
    endTime <- getCurrentTime
    finalState <- readIORef stateRef
    dims <- readIORef dimsRef
    render console (dashboardWidget dims endTime finalState)

    -- Print newline after dashboard
    TIO.putStrLn ""

    pure result
  where
    -- Fallback for non-TTY: use verbose text callback
    fallback = buildAction verboseCallback

    verboseCallback = \case
      ProgressDiscovering p -> TIO.putStrLn $ "◌ scanning " <> p
      ProgressFoundPackage p -> TIO.putStrLn $ "◉ found " <> p
      ProgressDhallParsing p -> TIO.putStrLn $ "◌ parsing " <> p
      ProgressDhallParsed p -> TIO.putStrLn $ "◉ parsed " <> p
      ProgressDhallImport i -> TIO.putStrLn $ "  ↳ import " <> i
      ProgressDhallNormalizing t -> TIO.putStrLn $ "◌ eval " <> t
      ProgressDhallEvaluated t n -> TIO.putStrLn $ "◉ eval " <> t <> " (" <> T.pack (show n) <> " rules)"
      ProgressToolchainLoading p -> TIO.putStrLn $ "◌ toolchains " <> p
      ProgressToolchainCached p -> TIO.putStrLn $ "○ toolchains (cached) " <> p
      ProgressToolchainLoaded p n -> TIO.putStrLn $ "◉ toolchains " <> p <> " (" <> T.pack (show n) <> ")"
      ProgressResolvingDeps t -> TIO.putStrLn $ "◌ deps " <> t
      ProgressCrossPackageDep p -> TIO.putStrLn $ "  ↳ cross-pkg " <> p
      ProgressDepsResolved t n -> TIO.putStrLn $ "◉ deps " <> t <> " (" <> T.pack (show n) <> ")"
      ProgressNixResolving r -> TIO.putStrLn $ "◌ nix " <> r
      ProgressNixResolved r _ -> TIO.putStrLn $ "◉ nix " <> r
      ProgressBuildingGraph t -> TIO.putStrLn $ "◌ graph " <> t
      ProgressGraphAction a -> TIO.putStrLn $ "  + " <> a
      ProgressGraphBuilt n -> TIO.putStrLn $ "◉ graph (" <> T.pack (show n) <> " actions)"
      ProgressCacheCheck a -> TIO.putStrLn $ "? cache " <> a
      ProgressCacheHit a -> TIO.putStrLn $ "✓ hit " <> a
      ProgressCacheMiss a -> TIO.putStrLn $ "✗ miss " <> a
      ProgressStarting nm _ _ -> TIO.putStrLn $ "→ " <> nm
      ProgressCached nm _ _ -> TIO.putStrLn $ "○ " <> nm <> " (cached)"
      ProgressCompleted nm _ _ _ -> TIO.putStrLn $ "✓ " <> nm
      ProgressFailed nm _ _ e -> TIO.putStrLn $ "✗ " <> nm <> ": " <> e
      ProgressWritingOutput p -> TIO.putStrLn $ "◌ write " <> p
      ProgressCacheStore a -> TIO.putStrLn $ "◌ cache " <> a
      ProgressPhaseComplete ph d -> TIO.putStrLn $ "◉ " <> ph <> " (" <> T.pack (show (round (d * 1000) :: Int)) <> "ms)"

-- ════════════════════════════════════════════════════════════════════════════
-- Render Loop
-- ════════════════════════════════════════════════════════════════════════════

-- | Render loop with stop signal and dynamic dimensions
-- Updates display at ~40fps, checking for stop signal and terminal resize
renderLoopWithStop :: Console -> IORef Dimensions -> IORef DashboardState -> MVar () -> IO ()
renderLoopWithStop console dimsRef stateRef stopSignal = go
  where
    go = do
      -- Check for stop signal (non-blocking)
      stopped <- tryTakeMVar stopSignal
      case stopped of
        Just () -> pure () -- Stop requested, exit loop
        Nothing -> do
          -- Update dimensions in case terminal was resized
          newDims <- getTerminalSize
          writeIORef dimsRef newDims

          -- Render current state
          now <- getCurrentTime
          state <- readIORef stateRef
          render console (dashboardWidget newDims now state)

          -- Sleep then continue
          threadDelay 25000 -- ~40fps
          go

-- | Progress callback that updates dashboard state
dashboardCallback :: IORef DashboardState -> ProgressCallback
dashboardCallback stateRef event = do
  now <- getCurrentTime
  atomicModifyIORef' stateRef $ \s -> (handleProgressEvent now event s, ())

-- ════════════════════════════════════════════════════════════════════════════
-- Dashboard Widget
-- ════════════════════════════════════════════════════════════════════════════

-- | Main dashboard widget
dashboardWidget :: Dimensions -> UTCTime -> DashboardState -> Widget
dashboardWidget dims now state = case dsPhase state of
  PhaseComplete -> completeWidget dims now state
  PhaseBuilding -> buildingWidget dims now state
  _ -> preambleWidget dims state

-- ════════════════════════════════════════════════════════════════════════════
-- Preamble Widget (discovery, parsing, graph building)
-- ════════════════════════════════════════════════════════════════════════════

preambleWidget :: Dimensions -> DashboardState -> Widget
preambleWidget dims state =
  vboxWith
    [Exact 3, Exact 1, Fill 1, Exact 1, Exact 1, Exact 1]
    [ headerWidget,
      space 0 1,
      logStreamWidget dims (dsLogs state),
      space 0 1,
      preambleStatusWidget (dsPhase state) (dsLogs state),
      footerWidget
    ]

logStreamWidget :: Dimensions -> Seq LogLine -> Widget
logStreamWidget dims logs =
  let visibleCount = max 12 (height dims - 10)
      logsList = toList logs
      -- Take most recent logs and display oldest-first (natural reading order)
      visible = take visibleCount (reverse logsList) -- newest first
      orderedForDisplay = reverse visible -- oldest first for display
      totalVisible = length orderedForDisplay
      -- Apply fade effect: oldest lines (at top) are dimmer
      -- Lines near the bottom (newest) are brightest
      renderLine :: Int -> LogLine -> Widget
      renderLine i (LogLine txt style) =
        let distanceFromBottom = totalVisible - 1 - i
            -- Fade the oldest 3 lines (at top of log stream)
            opacity = if distanceFromBottom >= totalVisible - 3 then dim style else style
         in textStyled opacity txt
   in vbox (zipWith renderLine [0 ..] orderedForDisplay)

preambleStatusWidget :: Phase -> Seq LogLine -> Widget
preambleStatusWidget phase logs =
  let countLogs pat = length . filter (T.isInfixOf pat . logText) . toList
      hits = countLogs "hit" logs
      misses = countLogs "miss" logs
      statusText = case phase of
        PhaseDiscovery -> "scanning..."
        PhaseParsing -> T.pack (show (countLogs "parsed" logs)) <> " files parsed"
        PhaseGraph -> "building graph..."
        PhaseCacheCheck ->
          let total = hits + misses
           in if total > 0
                then T.pack (show hits) <> " hits, " <> T.pack (show misses) <> " misses"
                else "checking cache..."
        PhaseBuilding -> "building..."
        PhaseComplete -> "complete"
   in hbox
        [ fill razorRule '─',
          textStyled razorDim (" " <> statusText <> " ")
        ]

-- ════════════════════════════════════════════════════════════════════════════
-- Building Widget
-- ════════════════════════════════════════════════════════════════════════════

buildingWidget :: Dimensions -> UTCTime -> DashboardState -> Widget
buildingWidget _dims now state =
  vboxWith
    [Exact 3, Exact 1, Exact 4, Exact 1, Fill 1, Exact 1]
    [ headerWidget,
      space 0 1,
      statsRowWidget now state,
      space 0 1,
      activeTargetsWidget now state,
      footerWidget
    ]

statsRowWidget :: UTCTime -> DashboardState -> Widget
statsRowWidget now state =
  let total = dsTotal state
      done = dsCompleted state
      cached = dsCached state
      failed = dsFailed state
      elapsed :: Int
      elapsed = maybe 0 (\t -> round (diffUTCTime now t * 1000)) (dsStartTime state)
      cacheRate = if done > 0 then (cached * 100) `div` done else 0
      cacheStyle = if cacheRate > 50 then razorAccent else if cached > 0 then razorInfo else razorMuted
      -- Show failed count if any
      targetSuffix =
        if failed > 0
          then " (" <> T.pack (show failed) <> " failed)"
          else "/ " <> T.pack (show total)
      targetStyle = if failed > 0 then razorMiss else razorBright
   in hboxWith
        [Fill 1, Fill 1, Fill 1]
        [ statCard "TARGETS" (T.pack (show done)) (Just targetSuffix) targetStyle,
          statCard "ELAPSED" (formatElapsed elapsed) (Just "s") razorBright,
          statCard "CACHE" (T.pack (show cached)) (Just ("/" <> T.pack (show done) <> " " <> T.pack (show cacheRate) <> "%")) cacheStyle
        ]

statCard :: Text -> Text -> Maybe Text -> Style -> Widget
statCard label value mUnit valueStyle =
  borderedStyled razorRule $
    padded 0 1 0 1 $
      vbox
        [ textStyled razorMuted label,
          hbox $
            [textStyled (bold valueStyle) value]
              ++ maybe [] (\u -> [textStyled razorMuted u]) mUnit
        ]

activeTargetsWidget :: UTCTime -> DashboardState -> Widget
activeTargetsWidget now state =
  let -- Show building targets first, then recently completed/cached
      building = [(tid, t) | (tid, t@(Target _ (TBuilding _))) <- Map.toList (dsTargets state)]
      cached = [(tid, t) | (tid, t@(Target _ TCached)) <- Map.toList (dsTargets state)]
      completed = [(tid, t) | (tid, t@(Target _ (TCompleted _ _))) <- Map.toList (dsTargets state)]
      failed = [(tid, t) | (tid, t@(Target _ (TFailed _ _ _))) <- Map.toList (dsTargets state)]
      -- Show failed first, then building, then recent cached/completed
      allTargets = failed ++ building ++ take 4 cached ++ take 4 completed
      visibleTargets = take 12 allTargets
      rows = map (targetRowWidget now) visibleTargets
      -- Pad with empty rows to fill space and prevent rendering artifacts
      emptyRows = replicate (12 - length visibleTargets) (space 0 1)
   in vboxWith (replicate 12 (Exact 1)) (rows ++ emptyRows)

targetRowWidget :: UTCTime -> (Text, Target) -> Widget
targetRowWidget now (tid, Target _ status) =
  let (glyph, glyphStyle, nameStyle, timeStr) = case status of
        TQueued -> ("○", razorDim, razorDim, "")
        TBuilding startT ->
          let elapsed = round (diffUTCTime now startT * 1000) :: Int
           in ("→", razorAccent, razorBright, formatMs elapsed)
        TCompleted _ durationMs -> ("✓", razorAccent, razorMuted, formatMs durationMs)
        TFailed _ durationMs _ -> ("✗", razorMiss, razorMiss, formatMs durationMs)
        TCached -> ("◆", razorAccent, razorMuted, "cached")

      paddedName = padTextRight 50 tid
   in hboxWith
        [Exact 2, Exact 50, Fill 1, Exact 7]
        [ textStyled glyphStyle (glyph <> " "),
          textStyled nameStyle paddedName,
          fill razorDim ' ', -- Use space instead of ─ to avoid visual noise
          textStyled razorMuted (" " <> padTextLeft 6 timeStr)
        ]

-- ════════════════════════════════════════════════════════════════════════════
-- Complete Widget
-- ════════════════════════════════════════════════════════════════════════════

completeWidget :: Dimensions -> UTCTime -> DashboardState -> Widget
completeWidget _dims now state =
  let elapsed :: Int
      elapsed = maybe 0 (\t -> round (diffUTCTime now t * 1000)) (dsStartTime state)
      failed = dsFailed state
      resultStyle = if failed > 0 then razorMiss else razorAccent
      resultText =
        if failed > 0
          then "BUILD FAILED · " <> T.pack (show failed) <> " ERRORS"
          else "BUILD COMPLETE"
   in vboxWith
        [Exact 3, Exact 1, Exact 4, Exact 1, Fill 1, Exact 1, Exact 1, Exact 1]
        [ headerWidget,
          space 0 1,
          statsRowWidget now state,
          space 0 1,
          activeTargetsWidget now state,
          space 0 1,
          centered $
            hboxWith
              [Exact 2, Exact 30, Exact 3, Exact 15, Exact 4, Exact 15]
              [ textStyled resultStyle (if failed > 0 then "✗ " else "✓ "),
                textStyled razorBright resultText,
                textStyled razorMuted " · ",
                textStyled razorBright (T.pack (show (dsCompleted state)) <> " TARGETS"),
                textStyled razorMuted " IN ",
                textStyled razorBright (formatMs elapsed)
              ],
          footerWidget
        ]

-- ════════════════════════════════════════════════════════════════════════════
-- Header / Footer
-- ════════════════════════════════════════════════════════════════════════════

headerWidget :: Widget
headerWidget =
  vbox
    [ textStyled razorMuted "STRAYLIGHT SOFTWARE · BUILD MONITOR",
      hboxWith
        [Exact 2, Exact 15, Exact 6, Exact 2]
        [ textStyled razorMuted "> ",
          textStyled (bold razorBright) "sensenet build ",
          textStyled razorBright "// ...",
          textStyled razorAccent " █"
        ],
      textStyled razorDim "dhall → nix → exec"
    ]

footerWidget :: Widget
footerWidget =
  hboxWith
    [Exact 29, Fill 1, Exact 42]
    [ textStyled razorMuted "SENSENET · DHALL + NIX + CAS ",
      fill defaultStyle ' ',
      textStyled razorDim "the one rectilinear chamber in the complex"
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Helpers
-- ════════════════════════════════════════════════════════════════════════════

padTextRight :: Int -> Text -> Text
padTextRight w t =
  let len = T.length t
   in if len >= w then T.take w t else t <> T.replicate (w - len) " "

padTextLeft :: Int -> Text -> Text
padTextLeft w t =
  let len = T.length t
   in if len >= w then t else T.replicate (w - len) " " <> t

formatMs :: Int -> Text
formatMs ms =
  let s = fromIntegral ms / 1000.0 :: Double
      whole = floor s :: Int
      frac = round ((s - fromIntegral whole) * 10) :: Int
   in T.pack (show whole) <> "." <> T.pack (show (frac `mod` 10)) <> "s"

formatElapsed :: Int -> Text
formatElapsed ms =
  let s = fromIntegral ms / 1000.0 :: Double
      whole = floor s :: Int
      frac = round ((s - fromIntegral whole) * 10) :: Int
   in T.pack (show whole) <> "." <> T.pack (show (frac `mod` 10))
