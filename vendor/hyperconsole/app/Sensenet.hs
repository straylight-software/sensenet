{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

-- | Sensenet Build Dashboard
--
-- "He'd operated on an almost permanent adrenaline high, a byproduct
--  of youth and proficiency, jacked into a custom cyberspace deck
--  that projected his disembodied consciousness into the consensual
--  hallucination that was the matrix."
--
--                                                    — Neuromancer
--
-- Production-grade build monitor with pluggable event sources.
-- The dashboard receives BuildEvents and renders current state.
module Main where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_, when)
import Data.IORef
import Data.List (sortBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..), comparing)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.Vector qualified as V
import HyperConsole
import HyperConsole.Theme


-- ════════════════════════════════════════════════════════════════════════════
-- Public API: Types
-- ════════════════════════════════════════════════════════════════════════════

-- | Unique identifier for a build target
type TargetId = Text

-- | Build target status
data TargetStatus
  = Queued                        -- ^ Waiting to start
  | Building UTCTime              -- ^ Currently building, started at time
  | Completed UTCTime Int         -- ^ Finished successfully, start time + duration ms
  | Failed UTCTime Int Text       -- ^ Failed with error, start time + duration + message
  | Cached                        -- ^ Cache hit, no build needed
  deriving stock (Eq, Show)

-- | A build target
data Target = Target
  { targetId       :: TargetId        -- ^ e.g. "sigil-trtllm:test-rope"
  , targetPath     :: Text            -- ^ e.g. "sigil-trtllm"
  , targetLang     :: Text            -- ^ e.g. "cuda", "haskell", "rust"
  , targetStatus   :: TargetStatus    -- ^ Current build status
  , targetEstimate :: Maybe Int       -- ^ Estimated build time in ms (if known)
  }
  deriving stock (Eq, Show)

-- | Build events from external sources
data BuildEvent
  = TargetQueued TargetId Text Text (Maybe Int)  -- ^ id, path, lang, estimate
  | TargetStarted TargetId UTCTime               -- ^ Build started
  | TargetProgress TargetId Double               -- ^ Progress update (0-1)
  | TargetCompleted TargetId UTCTime Int         -- ^ Completed, start time, duration ms
  | TargetFailed TargetId UTCTime Int Text       -- ^ Failed, start time, duration, error
  | TargetCached TargetId                        -- ^ Cache hit
  | LogMessage Text Style                        -- ^ Log line with style
  | PhaseChanged Phase                           -- ^ Build phase changed
  deriving stock (Eq, Show)

-- | Build phases
data Phase
  = Scanning
  | Parsing
  | Graphing
  | CacheCheck
  | Building_
  | Complete
  deriving stock (Eq, Show)

-- | Target group for display
data TargetGroup = TargetGroup
  { groupLabel  :: Text
  , groupFilter :: Target -> Bool
  }

-- | Complete build state
data BuildState = BuildState
  { stateTargets   :: Map TargetId Target   -- ^ All targets
  , statePhase     :: Phase                 -- ^ Current phase
  , stateLogs      :: [LogLine]             -- ^ Log history (newest last)
  , stateStartTime :: Maybe UTCTime         -- ^ When build started
  , stateGroups    :: [TargetGroup]         -- ^ Display groups
  }

-- | Log line with styling
data LogLine = LogLine
  { logText  :: Text
  , logStyle :: Style
  }


-- ════════════════════════════════════════════════════════════════════════════
-- Public API: State Management
-- ════════════════════════════════════════════════════════════════════════════

-- | Create initial empty state with groups
initBuildState :: [TargetGroup] -> BuildState
initBuildState groups = BuildState
  { stateTargets   = Map.empty
  , statePhase     = Scanning
  , stateLogs      = []
  , stateStartTime = Nothing
  , stateGroups    = groups
  }

-- | Process a build event and update state
handleEvent :: BuildEvent -> BuildState -> BuildState
handleEvent event state = case event of
  TargetQueued tid path lang estimate ->
    let target = Target tid path lang Queued estimate
    in state { stateTargets = Map.insert tid target (stateTargets state) }

  TargetStarted tid startTime ->
    updateTarget tid (\t -> t { targetStatus = Building startTime }) state

  TargetProgress _ _ ->
    -- Progress is computed from current time, no state change needed
    state

  TargetCompleted tid startTime durationMs ->
    updateTarget tid (\t -> t { targetStatus = Completed startTime durationMs }) state

  TargetFailed tid startTime durationMs errMsg ->
    updateTarget tid (\t -> t { targetStatus = Failed startTime durationMs errMsg }) state

  TargetCached tid ->
    updateTarget tid (\t -> t { targetStatus = Cached }) state

  LogMessage txt style ->
    state { stateLogs = stateLogs state ++ [LogLine txt style] }

  PhaseChanged phase ->
    state { statePhase = phase }

-- | Update a target in the state
updateTarget :: TargetId -> (Target -> Target) -> BuildState -> BuildState
updateTarget tid f state =
  state { stateTargets = Map.adjust f tid (stateTargets state) }


-- ════════════════════════════════════════════════════════════════════════════
-- Public API: Rendering
-- ════════════════════════════════════════════════════════════════════════════

-- | Render the build dashboard for current state
buildDashboard :: Dimensions -> UTCTime -> BuildState -> Widget
buildDashboard dims now state = case statePhase state of
  Complete -> completeWidget dims now state
  Building_ -> buildingWidget dims now state
  _ -> preambleWidget dims state

-- | Render preamble phase (scanning, parsing, etc.)
preambleWidget :: Dimensions -> BuildState -> Widget
preambleWidget dims state =
  vboxWith [Exact 3, Exact 1, Fill 1, Exact 1, Exact 1, Exact 1]
    [ headerWidget
    , space 0 1
    , logStreamWidget dims (stateLogs state)
    , space 0 1
    , preambleStatus (statePhase state) (stateLogs state) (stateTargets state)
    , footerWidget
    ]

-- | Render active building phase
buildingWidget :: Dimensions -> UTCTime -> BuildState -> Widget
buildingWidget _dims now state =
  vboxWith [Exact 3, Exact 1, Exact 4, Exact 1, Fill 1, Exact 1]
    [ headerWidget
    , space 0 1
    , statsRowWidget now state
    , space 0 1
    , groupsWidget now state
    , footerWidget
    ]

-- | Render complete phase
completeWidget :: Dimensions -> UTCTime -> BuildState -> Widget
completeWidget _dims now state =
  let targets = Map.elems (stateTargets state)
      totalMs = totalBuildTime targets
  in vboxWith [Exact 3, Exact 1, Exact 4, Exact 1, Fill 1, Exact 1, Exact 1, Exact 1]
    [ headerWidget
    , space 0 1
    , statsRowWidget now state
    , space 0 1
    , groupsWidget now state
    , space 0 1
    , centered $
        hbox
          [ textStyled razorAccent "✓ "
          , textStyled razorBright "BUILD COMPLETE"
          , textStyled razorMuted " · "
          , textStyled razorBright (T.pack (show (length targets)) <> " TARGETS")
          , textStyled razorMuted " · "
          , textStyled razorBright (formatMs totalMs)
          ]
    , footerWidget
    ]


-- ════════════════════════════════════════════════════════════════════════════
-- Internal: Header / Footer
-- ════════════════════════════════════════════════════════════════════════════

headerWidget :: Widget
headerWidget =
  vbox
    [ textStyled razorMuted "STRAYLIGHT SOFTWARE · BUILD MONITOR"
    , hbox
        [ textStyled razorMuted "> "
        , textStyled (bold razorBright) "sensenet build "
        , textStyled razorBright "// ..."
        , textStyled razorAccent " █"
        ]
    , textStyled razorDim "railgun · shell-autocomplete · dhall → nix → exec"
    ]

footerWidget :: Widget
footerWidget =
  hbox
    [ textStyled razorMuted "SENSENET · DHALL + NIX + CAS"
    , fill defaultStyle ' '
    , textStyled razorDim "the one rectilinear chamber in the complex"
    ]


-- ════════════════════════════════════════════════════════════════════════════
-- Internal: Log Stream
-- ════════════════════════════════════════════════════════════════════════════

logStreamWidget :: Dimensions -> [LogLine] -> Widget
logStreamWidget dims logs =
  let visibleCount = max 12 (height dims - 12)
      visible = take visibleCount (reverse logs)
      renderLine :: Int -> LogLine -> Widget
      renderLine i (LogLine txt style) =
        let opacity = if i < 3 then dim style else style
        in textStyled opacity txt
  in vbox (zipWith renderLine [0..] (reverse visible))

preambleStatus :: Phase -> [LogLine] -> Map TargetId Target -> Widget
preambleStatus phase logs targets =
  let total = Map.size targets
      statusText = case phase of
        Scanning  -> countLogs "found" <> "/" <> T.pack (show total) <> " packages"
        Parsing   -> countLogs "eval" <> "/" <> T.pack (show total) <> " parsed"
        Graphing  -> "computing dependency graph..."
        CacheCheck -> countLogs "miss" <> "/" <> T.pack (show total) <> " cache checks"
        Building_ -> "building..."
        Complete  -> "complete"
      countLogs pat = T.pack . show . length $ filter (T.isInfixOf pat . logText) logs
  in hbox
       [ fill razorRule '─'
       , textStyled razorDim (" " <> statusText <> " ")
       ]


-- ════════════════════════════════════════════════════════════════════════════
-- Internal: Stats Row
-- ════════════════════════════════════════════════════════════════════════════

statsRowWidget :: UTCTime -> BuildState -> Widget
statsRowWidget now state =
  let targets = Map.elems (stateTargets state)
      total = length targets
      done = length [t | t <- targets, isCompleted (targetStatus t)]
      cached = length [t | t <- targets, isCached (targetStatus t)]
      elapsed :: Int
      elapsed = maybe 0 (\t -> round (diffUTCTime now t * 1000)) (stateStartTime state)
      cacheRate = if total > 0 then (cached * 100) `div` total else 0
      cacheStyle = if cacheRate > 50 then razorAccent else razorMiss
  in hboxWith [Fill 1, Fill 1, Fill 1]
    [ statCard "TARGETS" (T.pack (show done)) (Just ("/ " <> T.pack (show total))) razorBright
    , statCard "ELAPSED" (formatElapsed elapsed) (Just "s") razorBright
    , statCard "CACHE HITS" (T.pack (show cacheRate)) (Just "%") cacheStyle
    ]

statCard :: Text -> Text -> Maybe Text -> Style -> Widget
statCard label value mUnit valueStyle =
  borderedStyled razorRule $
    padded 0 1 0 1 $
      vbox
        [ textStyled razorMuted label
        , hbox $
            [ textStyled (bold valueStyle) value ] ++
            maybe [] (\u -> [textStyled razorMuted u]) mUnit
        ]

isCompleted :: TargetStatus -> Bool
isCompleted (Completed _ _) = True
isCompleted _ = False

isCached :: TargetStatus -> Bool
isCached Cached = True
isCached _ = False

isFailed :: TargetStatus -> Bool
isFailed (Failed _ _ _) = True
isFailed _ = False


-- ════════════════════════════════════════════════════════════════════════════
-- Internal: Groups
-- ════════════════════════════════════════════════════════════════════════════

groupsWidget :: UTCTime -> BuildState -> Widget
groupsWidget now state =
  let targets = Map.elems (stateTargets state)
      groupWidgets = map (groupWidget now targets) (stateGroups state)
      groupSizes = map (groupLineCount targets) (stateGroups state)
      constraints = map Exact groupSizes
  in vboxWith constraints groupWidgets
  where
    groupLineCount ts g =
      let items = filter (groupFilter g) ts
      in if null items then 0 else 1 + length items

groupWidget :: UTCTime -> [Target] -> TargetGroup -> Widget
groupWidget now targets TargetGroup{..} =
  let items = filter groupFilter targets
      done = length [t | t <- items, isCompleted (targetStatus t) || isCached (targetStatus t)]
      failed = length [t | t <- items, isFailed (targetStatus t)]
      total = length items
      countStyle
        | failed > 0 = razorMiss
        | done == total = razorAccent
        | otherwise = razorMuted
      constraints = replicate (1 + length items) (Exact 1)
  in if null items then empty else
     vboxWith constraints $
       [ groupHeaderWidget groupLabel done total countStyle
       ] ++ map (targetRow now) items

groupHeaderWidget :: Text -> Int -> Int -> Style -> Widget
groupHeaderWidget label done total countStyle =
  let countText = T.pack (show done) <> "/" <> T.pack (show total)
      paddedCount = padTextLeft 6 countText
      labelText = " " <> label <> " "
      labelLen = T.length labelText
  in hboxWith [Exact 2, Exact labelLen, Fill 1, Exact 7]
       [ textStyled razorAccent "//"
       , textStyled razorMuted labelText
       , fill razorRule '─'
       , textStyled countStyle (" " <> paddedCount)
       ]

targetRow :: UTCTime -> Target -> Widget
targetRow now Target{..} =
  let (glyph, glyphStyle, nameStyle, pct, timeStr) = case targetStatus of
        Queued ->
          ("○", razorDim, razorDim, 0, "")
        Building startTime ->
          let elapsed = round (diffUTCTime now startTime * 1000) :: Int
              estPct = case targetEstimate of
                Just est -> min 0.99 (fromIntegral elapsed / fromIntegral est)
                Nothing -> 0.5  -- Unknown, show 50%
          in ("→", razorAccent, razorBright, perceptual estPct, formatMs elapsed)
        Completed _ durationMs ->
          ("✓", razorAccent, razorMuted, 1.0, formatMs durationMs)
        Failed _ durationMs _ ->
          ("✗", razorMiss, razorMiss, 1.0, formatMs durationMs)
        Cached ->
          ("◆", razorAccent, razorMuted, 1.0, "cached")

      waiting = case targetStatus of { Queued -> True; _ -> False }
      failed = case targetStatus of { Failed{} -> True; _ -> False }

      barStyle = if failed then razorMiss else razorAccent
      barEmptyStyle = razorDim

      nameText = "//" <> targetId
      paddedName = padTextRight 40 nameText

  in if waiting
       then hboxWith [Exact 2, Exact 40, Exact 1, Fill 1]
              [ textStyled glyphStyle (glyph <> " ")
              , textStyled nameStyle paddedName
              , textStyled razorDim " "
              , fill razorDim '─'
              ]
       else hboxWith [Exact 2, Exact 40, Exact 1, Fill 1, Exact 1, Exact 6]
              [ textStyled glyphStyle (glyph <> " ")
              , textStyled nameStyle paddedName
              , textStyled razorDim " "
              , progressThin barStyle barEmptyStyle pct
              , textStyled razorDim " "
              , textStyled razorMuted (padTextLeft 6 timeStr)
              ]


-- ════════════════════════════════════════════════════════════════════════════
-- Internal: Progress Bar
-- ════════════════════════════════════════════════════════════════════════════

progressThin :: Style -> Style -> Double -> Widget
progressThin filledStyle emptyStyle pct = Widget $ \dims ->
  let w = width dims
      filled = max 0 (min w (round (pct * fromIntegral w)))
      unfilled = w - filled
      bar = Seq.fromList
              [ Span filledStyle (T.replicate filled "━")
              , Span emptyStyle (T.replicate unfilled "─")
              ]
  in Canvas (V.singleton bar) (Dimensions w 1)


-- ════════════════════════════════════════════════════════════════════════════
-- Internal: Helpers
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

perceptual :: Double -> Double
perceptual x
  | x <= 0    = 0
  | x >= 1    = 1
  | x < 0.4   = (x / 0.4) * 0.75
  | otherwise = 0.75 + ((x - 0.4) / 0.6) * 0.25

clamp01 :: Double -> Double
clamp01 x = max 0 (min 1 x)

totalBuildTime :: [Target] -> Int
totalBuildTime targets = maximum (0 : [d | t <- targets, Completed _ d <- [targetStatus t]])


-- ════════════════════════════════════════════════════════════════════════════
-- Demo: Simulated Build
-- ════════════════════════════════════════════════════════════════════════════

main :: IO ()
main = withConsole $ \console -> do
  dims <- getTerminalSize
  stateRef <- newIORef (initBuildState defaultGroups)

  -- Phase 1: Preamble
  runDemoPreamble console dims stateRef

  -- Phase 2: Building
  runDemoBuilding console dims stateRef

  -- Hold final state
  threadDelay 3000000
  clear console


-- ════════════════════════════════════════════════════════════════════════════
-- Demo: Groups
-- ════════════════════════════════════════════════════════════════════════════

defaultGroups :: [TargetGroup]
defaultGroups =
  [ TargetGroup "SIGIL · TENSORRT-LLM" (\t -> targetPath t == "sigil-trtllm")
  , TargetGroup "NVIDIA · CUDA" (\t -> targetPath t == "examples/nv")
  , TargetGroup "SENSENET · CORE" (\t -> targetPath t `elem` ["sensenet", "nix-analyze"])
  , TargetGroup "HASKELL" (\t -> targetPath t `elem` ["examples/haskell", "examples/haskell-cxx", "examples/hasktorch"])
  , TargetGroup "LEAN4 · FORMAL VERIFICATION" (\t -> targetLang t == "lean")
  , TargetGroup "RUST" (\t -> targetLang t == "rust")
  , TargetGroup "C++ · NATIVE" (\t -> targetLang t == "cxx" && not ("haskell" `T.isInfixOf` targetPath t) && targetPath t /= "examples/nv")
  , TargetGroup "FRONTEND" (\t -> targetLang t == "purescript")
  ]


-- ════════════════════════════════════════════════════════════════════════════
-- Demo: Package Data
-- ════════════════════════════════════════════════════════════════════════════

data DemoPackage = DemoPackage
  { dpName :: Text
  , dpPath :: Text
  , dpLang :: Text
  , dpTime :: Int  -- Simulated build time in ms
  }

demoPackages :: [DemoPackage]
demoPackages =
  [ DemoPackage "nv:hello" "examples/nv" "cuda" 2100
  , DemoPackage "nv:mdspan_device_test" "examples/nv" "cuda" 3200
  , DemoPackage "nv:tensor_core" "examples/nv" "cuda" 4100
  , DemoPackage "sigil-trtllm:test-rope" "sigil-trtllm" "cuda" 6200
  , DemoPackage "sigil-trtllm:test-fp4-quant" "sigil-trtllm" "cuda" 3400
  , DemoPackage "sigil-trtllm:sigil-eval-perplexity" "sigil-trtllm" "cuda" 4800
  , DemoPackage "sigil-trtllm:sigil-inspect-checkpoint" "sigil-trtllm" "cuda" 7200
  , DemoPackage "sigil-trtllm:sigil-build-engine" "sigil-trtllm" "cuda" 8800
  , DemoPackage "sigil-trtllm:sigil-run-inference" "sigil-trtllm" "cuda" 5100
  , DemoPackage "cxx:hello-cxx" "examples/cxx" "cxx" 900
  , DemoPackage "cxx:foo" "examples/cxx" "cxx" 1100
  , DemoPackage "cxx:bar" "examples/cxx" "cxx" 1300
  , DemoPackage "cxx:baz" "examples/cxx" "cxx" 800
  , DemoPackage "simdjson:twitter" "examples/simdjson" "cxx" 3600
  , DemoPackage "haskell:hello-hs" "examples/haskell" "haskell" 2200
  , DemoPackage "haskell:json_demo" "examples/haskell" "haskell" 2800
  , DemoPackage "haskell:greetlib" "examples/haskell" "haskell" 1600
  , DemoPackage "haskell-cxx:test_ffi" "examples/haskell-cxx" "haskell" 3100
  , DemoPackage "hasktorch:hasktorch_demo" "examples/hasktorch" "haskell" 3500
  , DemoPackage "hasktorch:linear_regression" "examples/hasktorch" "haskell" 3800
  , DemoPackage "rust:hello-rs" "examples/rust" "rust" 1800
  , DemoPackage "rust:mathlib" "examples/rust" "rust" 1200
  , DemoPackage "rust-crate-test:cfg-if" "examples/rust-crate-test" "rust" 1400
  , DemoPackage "rust-crate-test:once_cell" "examples/rust-crate-test" "rust" 1500
  , DemoPackage "lean:hello-lean" "examples/lean" "lean" 2400
  , DemoPackage "lean:hashmap" "examples/lean" "lean" 2900
  , DemoPackage "lean-multifile:straylight" "examples/lean-multifile" "lean" 3900
  , DemoPackage "lean-continuity:continuity" "examples/lean-continuity" "lean" 700
  , DemoPackage "blake:blake" "examples/blake" "rust" 2600
  , DemoPackage "sqlite-test:sqlite-test" "examples/sqlite-test" "cxx" 1100
  , DemoPackage "zlib-test:zlib-test" "examples/zlib-test" "cxx" 1700
  , DemoPackage "multi-dep:multi-dep" "examples/multi-dep" "cxx" 1900
  , DemoPackage "cross-pkg-test/lib:greeter" "examples/cross-pkg-test" "cxx" 1000
  , DemoPackage "purescript:halogen-todo" "examples/purescript" "purescript" 2700
  , DemoPackage "straylight-web:straylight-web" "examples/straylight-web" "purescript" 3000
  , DemoPackage "sensenet:sensenet-core" "sensenet" "haskell" 5600
  , DemoPackage "sensenet:sensenet-dice" "sensenet" "haskell" 4200
  , DemoPackage "sensenet:dhallfast" "sensenet" "haskell" 4500
  , DemoPackage "nix-analyze:nix-analyze" "nix-analyze" "haskell" 4800
  ]

demoBuildFiles :: [Text]
demoBuildFiles =
  [ "examples/blake", "examples/cxx", "examples/haskell-cxx", "examples/haskell"
  , "examples/hasktorch", "examples/lean-continuity", "examples/lean-multifile"
  , "examples/lean", "examples/multi-dep", "examples/nv", "examples/rust-crate-test"
  , "examples/rust", "examples/simdjson", "examples/sqlite-test", "examples/zlib-test"
  , "examples/purescript", "examples/straylight-web", "examples/cross-pkg-test/app"
  , "examples/cross-pkg-test/lib", "nix-analyze", "sensenet", "sigil-trtllm"
  ]


-- ════════════════════════════════════════════════════════════════════════════
-- Demo: Preamble Phase
-- ════════════════════════════════════════════════════════════════════════════

runDemoPreamble :: Console -> Dimensions -> IORef BuildState -> IO ()
runDemoPreamble console dims stateRef = do
  now <- getCurrentTime

  -- Queue all targets
  forM_ demoPackages $ \DemoPackage{..} -> do
    modifyIORef' stateRef $ handleEvent (TargetQueued dpName dpPath dpLang (Just dpTime))

  -- Scan phase
  modifyIORef' stateRef $ handleEvent (LogMessage "◌ scanning //..." razorAccent)
  forM_ demoBuildFiles $ \path -> do
    modifyIORef' stateRef $ handleEvent (LogMessage ("◉ found //src/" <> path <> "/BUILD.dhall") razorMuted)
    state <- readIORef stateRef
    render console (buildDashboard dims now state)
    threadDelay 28000

  -- Parse phase
  modifyIORef' stateRef $ handleEvent (PhaseChanged Parsing)
  modifyIORef' stateRef $ handleEvent (LogMessage "◌ parsing //..." razorAccent)
  forM_ demoBuildFiles $ \path -> do
    modifyIORef' stateRef $ handleEvent (LogMessage ("◉ eval //src/" <> path <> "/BUILD.dhall") razorInfo)
    state <- readIORef stateRef
    render console (buildDashboard dims now state)
    threadDelay 22000

  -- Graph
  modifyIORef' stateRef $ handleEvent (PhaseChanged Graphing)
  modifyIORef' stateRef $ handleEvent (LogMessage "◌ graph //..." razorAccent)
  state <- readIORef stateRef
  render console (buildDashboard dims now state)
  threadDelay 100000

  -- Cache check
  modifyIORef' stateRef $ handleEvent (PhaseChanged CacheCheck)
  forM_ demoPackages $ \DemoPackage{..} -> do
    modifyIORef' stateRef $ handleEvent (LogMessage ("✗ miss //" <> dpName) razorMiss)
    st <- readIORef stateRef
    render console (buildDashboard dims now st)
    threadDelay 10000


-- ════════════════════════════════════════════════════════════════════════════
-- Demo: Building Phase
-- ════════════════════════════════════════════════════════════════════════════

runDemoBuilding :: Console -> Dimensions -> IORef BuildState -> IO ()
runDemoBuilding console dims stateRef = do
  startTime <- getCurrentTime

  -- Transition to building phase
  modifyIORef' stateRef $ \s -> s { statePhase = Building_, stateStartTime = Just startTime }

  -- Compute schedule
  let scheduled = computeSchedule 12 demoPackages

  -- Run simulation
  let go elapsed
        | all (isTargetDone elapsed) scheduled = do
            -- Complete
            now <- getCurrentTime
            modifyIORef' stateRef $ \s -> s { statePhase = Complete }
            state <- readIORef stateRef
            render console (buildDashboard dims now state)
        | otherwise = do
            now <- getCurrentTime

            -- Process starts
            forM_ scheduled $ \(pkg, schedStart) -> do
              when (elapsed >= schedStart && elapsed < schedStart + 75) $ do
                let startT = addMs startTime schedStart
                modifyIORef' stateRef $ handleEvent (TargetStarted (dpName pkg) startT)

            -- Process completions
            forM_ scheduled $ \(pkg, schedStart) -> do
              let endTime = schedStart + dpTime pkg
              when (elapsed >= endTime && elapsed < endTime + 75) $ do
                let startT = addMs startTime schedStart
                modifyIORef' stateRef $ handleEvent (TargetCompleted (dpName pkg) startT (dpTime pkg))

            -- Render
            state <- readIORef stateRef
            render console (buildDashboard dims now state)

            threadDelay 25000
            go (elapsed + 75)

  go 0
  where
    isTargetDone elapsed (pkg, schedStart) = elapsed >= schedStart + dpTime pkg

    addMs :: UTCTime -> Int -> UTCTime
    addMs t ms = posixSecondsToUTCTime (realToFrac (diffUTCTime t epoch) + fromIntegral ms / 1000)
      where epoch = posixSecondsToUTCTime 0


-- ════════════════════════════════════════════════════════════════════════════
-- Demo: Scheduling
-- ════════════════════════════════════════════════════════════════════════════

computeSchedule :: Int -> [DemoPackage] -> [(DemoPackage, Int)]
computeSchedule maxPar pkgs =
  let indexed = zip [0..] pkgs
      sorted = sortBy (comparing (Down . dpTime . snd)) indexed
      initialLanes = replicate maxPar 0 :: [Int]
      initialStarts = replicate (length pkgs) 0 :: [Int]
      (finalStarts, _) = foldl assignPkg (initialStarts, initialLanes) sorted
  in zip pkgs finalStarts
  where
    assignPkg (starts, lanes) (origIdx, pkg) =
      let (bestLane, bestTime) = minimumByComparing snd (zip [0..] lanes)
          newLaneEnd = bestTime + dpTime pkg
          newLanes = updateAt bestLane newLaneEnd lanes
          newStarts = updateAt origIdx bestTime starts
      in (newStarts, newLanes)
    minimumByComparing f = foldr1 (\a b -> if f a <= f b then a else b)
    updateAt i v xs = take i xs ++ [v] ++ drop (i + 1) xs
