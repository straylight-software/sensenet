{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Clean TUI for sensenet builds using Brick
--
-- Modeled on Buck2's superconsole:
-- - Vertical list of running actions with elapsed time
-- - Clean unicode symbols, no emoji
-- - Stats header, running actions, overflow indicator
module SenseNet.TUI
  ( runBuildWithTUI,
    BuildEvent (..),
    ActionInfo (..),
    initialState,
  )
where

import Brick
import Brick.BChan (BChan, newBChan, writeBChan)
import Brick.Widgets.Border
import Brick.Widgets.List qualified as L
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, catch, finally)
import Control.Monad (forever, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vec
import Data.Word (Word64)
import Graphics.Vty qualified as V
import Graphics.Vty.CrossPlatform qualified as V
import Lens.Micro ((^.))
import Lens.Micro.Mtl (use, (%=), (.=))
import Lens.Micro.TH (makeLenses)
import Text.Printf (printf)

-- ════════════════════════════════════════════════════════════════════════════
-- Animation Constants
-- ════════════════════════════════════════════════════════════════════════════

-- | Simple braille spinner
spinnerFrames :: [Text]
spinnerFrames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

-- ════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════

data BuildEvent
  = EventBuildStarted !Int
  | EventActionStarted !Word64 !Text
  | EventActionCompleted !Word64 !Text ![FilePath]
  | EventActionFailed !Word64 !Text !Text
  | EventActionCached !Word64 !Text ![FilePath]
  | EventBuildFinished !(Either Text [FilePath])
  | EventTick
  deriving (Show)

data ActionInfo = ActionInfo
  { _actionId :: !Word64,
    _actionName :: !Text,
    _actionStartTime :: !UTCTime
  }
  deriving (Show)

makeLenses ''ActionInfo

data LogEntry = LogEntry
  { _logTime :: !UTCTime,
    _logText :: !Text,
    _logSuccess :: !Bool,
    _logDuration :: !NominalDiffTime
  }
  deriving (Show)

makeLenses ''LogEntry

data ResourceName = LogList
  deriving (Show, Eq, Ord)

data TUIState = TUIState
  { _tuiTotal :: !Int,
    _tuiCompleted :: !Int,
    _tuiCached :: !Int,
    _tuiFailed :: !Int,
    _tuiRunning :: !(Map Word64 ActionInfo),
    _tuiLogs :: !(L.List ResourceName LogEntry),
    _tuiStartTime :: !UTCTime,
    _tuiCurrentTime :: !UTCTime,
    _tuiFinished :: !Bool,
    _tuiResult :: !(Maybe (Either Text [FilePath])),
    _tuiTick :: !Int
  }
  deriving (Show)

makeLenses ''TUIState

-- ════════════════════════════════════════════════════════════════════════════
-- Initial State
-- ════════════════════════════════════════════════════════════════════════════

initialState :: UTCTime -> TUIState
initialState now =
  TUIState
    { _tuiTotal = 0,
      _tuiCompleted = 0,
      _tuiCached = 0,
      _tuiFailed = 0,
      _tuiRunning = Map.empty,
      _tuiLogs = L.list LogList Vec.empty 1,
      _tuiStartTime = now,
      _tuiCurrentTime = now,
      _tuiFinished = False,
      _tuiResult = Nothing,
      _tuiTick = 0
    }

-- ════════════════════════════════════════════════════════════════════════════
-- Brick App
-- ════════════════════════════════════════════════════════════════════════════

app :: App TUIState BuildEvent ResourceName
app =
  App
    { appDraw = drawUI,
      appChooseCursor = neverShowCursor,
      appHandleEvent = handleEvent,
      appStartEvent = pure (),
      appAttrMap = const theAttrMap
    }

theAttrMap :: AttrMap
theAttrMap =
  attrMap
    V.defAttr
    [ (attrName "header", V.withStyle (fg V.cyan) V.bold),
      (attrName "success", fg V.green),
      (attrName "failure", fg V.red),
      (attrName "cached", fg V.cyan),
      (attrName "running", fg V.yellow),
      (attrName "dim", fg V.brightBlack),
      (attrName "accent", fg V.blue),
      (attrName "time", fg V.blue),
      (attrName "progress", fg V.cyan),
      (attrName "target", fg V.cyan),
      (attrName "action", fg V.white)
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Drawing
-- ════════════════════════════════════════════════════════════════════════════

drawUI :: TUIState -> [Widget ResourceName]
drawUI s = [ui]
  where
    ui =
      vBox
        [ drawHeader s,
          str " ",
          drawProgress s,
          drawStats s,
          str " ",
          hBorderWithLabel (withAttr (attrName "dim") $ str " Running "),
          drawRunning s,
          hBorderWithLabel (withAttr (attrName "dim") $ str " Log "),
          drawLog s,
          drawFooter s
        ]

drawHeader :: TUIState -> Widget ResourceName
drawHeader s =
  padLeftRight 1 $
    hBox
      [ withAttr (attrName "header") $ str "SENSE // NET",
        padLeft Max $
          hBox
            [ withAttr (attrName "accent") $ str $ show done,
              withAttr (attrName "dim") $ str "/",
              str $ show (s ^. tuiTotal),
              withAttr (attrName "dim") $ str " targets"
            ]
      ]
  where
    -- Include failed in done count for progress tracking
    done = s ^. tuiCompleted + s ^. tuiCached + s ^. tuiFailed

drawProgress :: TUIState -> Widget ResourceName
drawProgress s =
  padLeftRight 1 $
    hBox
      [ bar,
        str " ",
        pctWidget,
        padLeft Max $ timeWidget
      ]
  where
    total = max 1 (s ^. tuiTotal)
    -- Include failed in done count for progress tracking
    done = s ^. tuiCompleted + s ^. tuiCached + s ^. tuiFailed
    pct = fromIntegral done / fromIntegral total :: Double
    barWidth = 50 :: Int
    filledW = floor (pct * fromIntegral barWidth)

    filled = withAttr (attrName "progress") $ str $ replicate filledW '█'
    empty = withAttr (attrName "dim") $ str $ replicate (barWidth - filledW) '░'
    bar = hBox [filled, empty]

    pctInt = round (pct * 100) :: Int
    pctWidget
      | pctInt >= 100 = withAttr (attrName "success") $ str "100%"
      | otherwise = str $ show pctInt ++ "%"

    elapsed = diffUTCTime (s ^. tuiCurrentTime) (s ^. tuiStartTime)
    timeWidget = withAttr (attrName "time") $ str $ "Time: " ++ formatDuration elapsed

drawStats :: TUIState -> Widget ResourceName
drawStats s =
  padLeftRight 1 $
    hBox
      [ withAttr (attrName "success") $ str $ "✓ " ++ show (s ^. tuiCompleted),
        str "   ",
        withAttr (attrName "cached") $ str $ "⊙ " ++ show (s ^. tuiCached),
        str "   ",
        withAttr (attrName "failure") $ str $ "✗ " ++ show (s ^. tuiFailed),
        str "   ",
        withAttr (attrName "running") $ txt $ spinner <> " " <> T.pack (show numRunning)
      ]
  where
    numRunning = Map.size (s ^. tuiRunning)
    tick = s ^. tuiTick
    spinnerIdx = tick `mod` length spinnerFrames
    spinner = spinnerFrames !! spinnerIdx

-- | Running actions - Buck2 style vertical list
drawRunning :: TUIState -> Widget ResourceName
drawRunning s = padLeftRight 1 $ vLimit maxVisible $ vBox content
  where
    maxVisible = 12
    actions = sortOn (^. actionStartTime) $ Map.elems (s ^. tuiRunning)
    numActions = length actions
    visible = take maxVisible actions

    content
      | null actions = [withAttr (attrName "dim") $ str "(idle)"]
      | otherwise = map (drawAction s) visible ++ overflow

    overflow
      | numActions > maxVisible =
          [withAttr (attrName "dim") $ str $ "... and " ++ show (numActions - maxVisible) ++ " more currently executing"]
      | otherwise = []

-- | Single action line: //target:name -- action (type) [mode] TIME
drawAction :: TUIState -> ActionInfo -> Widget ResourceName
drawAction s action =
  hBox
    [ withAttr (attrName "running") $ txt spinner,
      str " ",
      withAttr (attrName "target") $ txt target,
      withAttr (attrName "dim") $ str " -- ",
      withAttr (attrName "action") $ txt actionType,
      padLeft Max $ withAttr (attrName "time") $ str timeStr
    ]
  where
    tick = s ^. tuiTick
    offset = fromIntegral (action ^. actionId) `mod` length spinnerFrames
    spinnerIdx = (tick + offset) `mod` length spinnerFrames
    spinner = spinnerFrames !! spinnerIdx

    name = action ^. actionName
    -- Extract target and action type from name
    -- Format: //path:target or just target
    (target, actionType) = parseActionName name

    elapsed = diffUTCTime (s ^. tuiCurrentTime) (action ^. actionStartTime)
    timeStr = formatDuration elapsed

-- | Parse "//pkg:target" into (target, action_type)
parseActionName :: Text -> (Text, Text)
parseActionName name
  | "//" `T.isPrefixOf` name = (name, "build")
  | otherwise = (name, "action")

-- | Log section
drawLog :: TUIState -> Widget ResourceName
drawLog s =
  padLeftRight 1 $
    vLimit 6 $
      L.renderList renderLogEntry True (s ^. tuiLogs)

renderLogEntry :: Bool -> LogEntry -> Widget ResourceName
renderLogEntry _ entry =
  hBox
    [ symbol,
      str " ",
      txt shortText,
      padLeft Max $ withAttr (attrName "time") $ str durStr
    ]
  where
    symbol
      | entry ^. logSuccess = withAttr (attrName "success") $ str "✓"
      | otherwise = withAttr (attrName "failure") $ str "✗"

    text = entry ^. logText
    shortText
      | T.length text > 70 = T.take 67 text <> "..."
      | otherwise = text
    durStr = formatDuration (entry ^. logDuration)

drawFooter :: TUIState -> Widget ResourceName
drawFooter s =
  padLeftRight 1 $
    hBox
      [ withAttr (attrName "dim") $ str "q:quit  ↑↓:scroll",
        padLeft Max statusWidget
      ]
  where
    statusWidget
      | s ^. tuiFinished = case s ^. tuiResult of
          Just (Right _) -> withAttr (attrName "success") $ str "BUILD COMPLETE"
          Just (Left err) -> withAttr (attrName "failure") $ str $ "FAILED: " ++ T.unpack (T.take 30 err)
          Nothing -> str ""
      | otherwise = str ""

-- ════════════════════════════════════════════════════════════════════════════
-- Utilities
-- ════════════════════════════════════════════════════════════════════════════

formatDuration :: NominalDiffTime -> String
formatDuration dt
  | secs < 10 = printf "%.1fs" secs
  | secs < 60 = printf "%.0fs" secs
  | secs < 3600 = printf "%dm%02ds" mins (round secs `mod` 60 :: Int)
  | otherwise = printf "%dh%02dm" hours (mins `mod` 60)
  where
    secs = realToFrac dt :: Double
    mins = floor secs `div` 60 :: Int
    hours = mins `div` 60

-- ════════════════════════════════════════════════════════════════════════════
-- Event Handling
-- ════════════════════════════════════════════════════════════════════════════

handleEvent :: BrickEvent ResourceName BuildEvent -> EventM ResourceName TUIState ()
handleEvent = \case
  VtyEvent (V.EvKey (V.KChar 'q') []) -> halt
  VtyEvent (V.EvKey V.KEsc []) -> halt
  VtyEvent (V.EvKey V.KUp []) -> tuiLogs %= L.listMoveUp
  VtyEvent (V.EvKey V.KDown []) -> tuiLogs %= L.listMoveDown
  VtyEvent (V.EvKey V.KPageUp []) -> tuiLogs %= L.listMoveBy (-10)
  VtyEvent (V.EvKey V.KPageDown []) -> tuiLogs %= L.listMoveBy 10
  AppEvent evt -> handleBuildEvent evt
  _ -> pure ()

handleBuildEvent :: BuildEvent -> EventM ResourceName TUIState ()
handleBuildEvent = \case
  EventBuildStarted total ->
    tuiTotal .= total
  EventActionStarted aid name -> do
    now <- liftIO getCurrentTime
    tuiRunning %= Map.insert aid (ActionInfo aid name now)
  EventActionCompleted aid name _outputs -> do
    now <- liftIO getCurrentTime
    running <- use tuiRunning
    let duration = case Map.lookup aid running of
          Just info -> diffUTCTime now (info ^. actionStartTime)
          Nothing -> 0
    tuiRunning %= Map.delete aid
    tuiCompleted %= (+ 1)
    addLogEntry True name duration
  EventActionFailed aid name err -> do
    now <- liftIO getCurrentTime
    running <- use tuiRunning
    let duration = case Map.lookup aid running of
          Just info -> diffUTCTime now (info ^. actionStartTime)
          Nothing -> 0
    tuiRunning %= Map.delete aid
    tuiFailed %= (+ 1)
    addLogEntry False (name <> ": " <> err) duration
  EventActionCached aid name _outputs -> do
    tuiRunning %= Map.delete aid
    tuiCached %= (+ 1)
    addLogEntry True (name <> " [cached]") 0
  EventBuildFinished result -> do
    tuiFinished .= True
    tuiResult .= Just result
    -- Brief pause to show final state, then exit
    liftIO $ threadDelay 500000 -- 500ms to see final result
    halt
  EventTick -> do
    now <- liftIO getCurrentTime
    tuiCurrentTime .= now
    tuiTick %= (+ 1)

addLogEntry :: Bool -> Text -> NominalDiffTime -> EventM ResourceName TUIState ()
addLogEntry success msg duration = do
  now <- liftIO getCurrentTime
  let entry = LogEntry now msg success duration
  tuiLogs %= \l ->
    let vec = L.listElements l
        newVec = Vec.snoc vec entry
        newList = L.list LogList newVec 1
     in L.listMoveTo (Vec.length newVec - 1) newList

-- ════════════════════════════════════════════════════════════════════════════
-- Main Entry Point
-- ════════════════════════════════════════════════════════════════════════════

runBuildWithTUI ::
  (BChan BuildEvent -> IO (Either Text [FilePath])) ->
  IO (Either Text [FilePath])
runBuildWithTUI buildAction = do
  chan <- newBChan 100
  now <- getCurrentTime
  let state0 = initialState now

  resultVar <- newEmptyMVar
  cancelledVar <- newEmptyMVar

  -- Ticker at 10Hz
  tickerThread <- forkIO $ forever $ do
    threadDelay 100000
    writeBChan chan EventTick

  -- Build thread
  _buildThread <- forkIO $ do
    result <-
      buildAction chan `catch` \(e :: SomeException) -> do
        cancelled <- tryTakeMVar cancelledVar
        case cancelled of
          Just () -> pure $ Left "Build cancelled"
          Nothing -> pure $ Left $ T.pack $ "Build error: " ++ show e
    writeBChan chan (EventBuildFinished result)
    void $ tryPutMVar resultVar result

  let buildVty = V.mkVty V.defaultConfig
  let runTUI = do
        initialVty <- buildVty
        customMain initialVty buildVty (Just chan) app state0

  _finalState <-
    runTUI `finally` do
      killThread tickerThread
      void $ tryPutMVar cancelledVar ()

  threadDelay 100000
  tryTakeMVar resultVar >>= \case
    Just r -> pure r
    Nothing -> pure $ Left "Build interrupted"
