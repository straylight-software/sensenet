{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : SenseNet.Output
-- Description : Typed output protocol - structured output for all contexts
--
-- "The sky above the port was the color of television,
--  tuned to a dead channel."
--
--                                      — Neuromancer
--
-- = The End of stdout/stderr Split
--
-- Unix gave us stdout and stderr in an era when stdout went to a printer
-- and stderr went to the operator's console. Two physical destinations.
-- That hardware reality hasn't existed in decades.
--
-- Now stderr is where programs dump unstructured diagnostics that sometimes
-- matter and sometimes don't, and every consumer has to decide whether to
-- merge them. @2>&1@ is the most common shell idiom because the separation
-- is almost never what anyone wants.
--
-- This module provides typed output that adapts to context:
--
-- @
-- data Output
--   = Result !Value          -- The actual data/answer
--   | Progress !Progress     -- Build progress, spinners
--   | Diagnostic !Diagnostic -- Warnings, info, debug
--   | Error !Error           -- Failures
-- @
--
-- = Context-Aware Presentation
--
-- The producer emits typed facts. The presenter decides rendering:
--
--   * __Terminal__ (TTY) → Colors, Unicode glyphs, progress bars
--   * __Pipe__ (non-TTY) → Plain text, works with grep/jq/wc
--   * __Agent__ (SENSENET_AGENT=1) → JSON lines protocol for programmatic consumers
--
-- Shell pipelines get raw text that works naturally:
--
-- @
-- sensenet targets | grep rust        # works
-- sensenet query ... --json | jq      # works
-- @
--
-- Agents (weapon, sigil, etc.) opt into the typed protocol explicitly.
--
-- = Usage
--
-- @
-- withAutoPresenter $ \\presenter -> do
--   emitProgressIO presenter $ Building "//core:lib"
--   result <- buildTarget target
--   emitResultIO presenter $ BuildSuccess result
-- @
module SenseNet.Output
  ( -- * Output Types
    Output (..),
    Progress (..),
    Diagnostic (..),
    DiagnosticLevel (..),
    Error (..),
    Result (..),

    -- * Output Monad
    OutputT,
    runOutputT,
    emit,
    emitResult,
    emitProgress,
    emitDiagnostic,
    emitError,

    -- * Presentation
    Presenter (..),
    terminalPresenter,
    pipePresenter,
    agentPresenter,
    nullPresenter,

    -- * Context Detection
    OutputContext (..),
    detectContext,
    presenterForContext,

    -- * Direct IO Helpers

    -- | For gradual migration - emit directly in IO
    emitIO,
    emitResultIO,
    emitProgressIO,
    emitErrorIO,
    withAutoPresenter,
  )
where

import Control.Monad (unless)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import Data.Aeson (ToJSON (..), Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Colour.SRGB (sRGB24)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (NominalDiffTime)
import GHC.Generics (Generic)
import HyperConsole.Style (Attr (..), Color (..), Style (..))
import HyperConsole.Theme qualified as Theme
import System.Console.ANSI qualified as ANSI
import System.Environment (lookupEnv)
import System.IO (Handle, hIsTerminalDevice, stderr, stdout)

-- ════════════════════════════════════════════════════════════════════════════
-- Output Types
-- ════════════════════════════════════════════════════════════════════════════

-- | The typed output ADT - replaces stdout/stderr entirely
data Output
  = -- | Final results (what would go to stdout in a pipeline)
    OutputResult !Result
  | -- | Progress updates (build status, spinners)
    OutputProgress !Progress
  | -- | Diagnostics (warnings, info, debug)
    OutputDiagnostic !Diagnostic
  | -- | Errors (failures that stop execution)
    OutputError !Error
  deriving stock (Eq, Show, Generic)

instance ToJSON Output where
  toJSON = \case
    OutputResult r -> object ["type" .= ("result" :: Text), "data" .= r]
    OutputProgress p -> object ["type" .= ("progress" :: Text), "data" .= p]
    OutputDiagnostic d -> object ["type" .= ("diagnostic" :: Text), "data" .= d]
    OutputError e -> object ["type" .= ("error" :: Text), "data" .= e]

-- | Build/computation results
data Result
  = -- | Successful build with outputs
    BuildSuccess
      { rsTarget :: !Text,
        rsOutputs :: ![Text],
        rsDuration :: !NominalDiffTime
      }
  | -- | Query result (dhall eval, nix eval, etc)
    QueryResult !Value
  | -- | Raw text result (for pipelines)
    TextResult !Text
  | -- | JSON result (for structured queries)
    JsonResult !Value
  deriving stock (Eq, Show, Generic)

instance ToJSON Result where
  toJSON = \case
    BuildSuccess t o d ->
      object
        [ "kind" .= ("build_success" :: Text),
          "target" .= t,
          "outputs" .= o,
          "duration_secs" .= (realToFrac d :: Double)
        ]
    QueryResult v ->
      object ["kind" .= ("query" :: Text), "value" .= v]
    TextResult t ->
      object ["kind" .= ("text" :: Text), "text" .= t]
    JsonResult v ->
      object ["kind" .= ("json" :: Text), "value" .= v]

-- | Progress updates during execution
data Progress
  = -- | Starting to build a target
    Building !Text
  | -- | Target retrieved from cache
    Cached !Text
  | -- | Build step completed
    Built !Text !NominalDiffTime
  | -- | Overall progress (current, total)
    ProgressCount !Int !Int
  | -- | Action within a build (compiling, linking, etc)
    Action !Text !Text -- target, action name
  | -- | Spinner tick (for animations)
    Tick !Int
  | -- | Generic progress message
    ProgressMsg !Text
  deriving stock (Eq, Show, Generic)

instance ToJSON Progress where
  toJSON = \case
    Building t -> object ["kind" .= ("building" :: Text), "target" .= t]
    Cached t -> object ["kind" .= ("cached" :: Text), "target" .= t]
    Built t d ->
      object
        [ "kind" .= ("built" :: Text),
          "target" .= t,
          "duration_secs" .= (realToFrac d :: Double)
        ]
    ProgressCount c tot ->
      object ["kind" .= ("count" :: Text), "current" .= c, "total" .= tot]
    Action t a ->
      object ["kind" .= ("action" :: Text), "target" .= t, "action" .= a]
    Tick n -> object ["kind" .= ("tick" :: Text), "tick" .= n]
    ProgressMsg msg -> object ["kind" .= ("message" :: Text), "message" .= msg]

-- | Diagnostic severity levels
data DiagnosticLevel
  = Debug
  | Info
  | Warning
  deriving stock (Eq, Show, Ord, Generic)

instance ToJSON DiagnosticLevel where
  toJSON = \case
    Debug -> "debug"
    Info -> "info"
    Warning -> "warning"

-- | Diagnostic messages (non-fatal)
data Diagnostic = Diagnostic
  { diagLevel :: !DiagnosticLevel,
    diagMessage :: !Text,
    diagContext :: !(Maybe Text) -- optional target/file context
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Diagnostic where
  toJSON (Diagnostic lvl msg ctx) =
    object
      [ "level" .= lvl,
        "message" .= msg,
        "context" .= ctx
      ]

-- | Errors (fatal failures)
data Error
  = -- | Build failed
    BuildFailed
      { errTarget :: !Text,
        errMessage :: !Text,
        errDetails :: !(Maybe Text)
      }
  | -- | Configuration/parse error
    ConfigError !Text
  | -- | Internal error (bug)
    InternalError !Text
  deriving stock (Eq, Show, Generic)

instance ToJSON Error where
  toJSON = \case
    BuildFailed t m d ->
      object
        [ "kind" .= ("build_failed" :: Text),
          "target" .= t,
          "message" .= m,
          "details" .= d
        ]
    ConfigError m ->
      object ["kind" .= ("config_error" :: Text), "message" .= m]
    InternalError m ->
      object ["kind" .= ("internal_error" :: Text), "message" .= m]

-- ════════════════════════════════════════════════════════════════════════════
-- Presenter - How output is rendered
-- ════════════════════════════════════════════════════════════════════════════

-- | A presenter renders typed output to some destination
newtype Presenter = Presenter {present :: Output -> IO ()}

-- | Terminal presenter - colors, progress bars, human-readable
terminalPresenter :: Presenter
terminalPresenter = Presenter $ \output -> case output of
  OutputResult r -> renderResultTerminal r
  OutputProgress p -> renderProgressTerminal p
  OutputDiagnostic d -> renderDiagnosticTerminal d
  OutputError e -> renderErrorTerminal e

-- | Agent presenter - JSON lines, results and errors only
agentPresenter :: Presenter
agentPresenter = Presenter $ \output -> case output of
  OutputResult _ -> BL.putStr (encode output) >> putStrLn ""
  OutputError _ -> BL.putStr (encode output) >> putStrLn ""
  OutputProgress _ -> pure () -- agents don't need progress spam
  OutputDiagnostic d ->
    -- agents only see warnings, not info/debug
    case diagLevel d of
      Warning -> BL.putStr (encode output) >> putStrLn ""
      _ -> pure ()

-- | Pipe presenter - raw text output for shell pipelines
-- Like terminal but without ANSI colors (works with grep, jq, wc, etc.)
pipePresenter :: Presenter
pipePresenter = Presenter $ \output -> case output of
  OutputResult r -> renderResultPipe r
  OutputProgress p -> renderProgressPipe p
  OutputDiagnostic d -> renderDiagnosticPipe d
  OutputError e -> renderErrorPipe e

-- | Null presenter - discard everything
nullPresenter :: Presenter
nullPresenter = Presenter $ \_ -> pure ()

-- ════════════════════════════════════════════════════════════════════════════
-- HyperConsole Style Rendering
-- ════════════════════════════════════════════════════════════════════════════

-- | Apply a HyperConsole style to stdout
withStyle :: Style -> IO () -> IO ()
withStyle style action = do
  applyStyle stdout style
  action
  ANSI.setSGR [ANSI.Reset]

-- | Apply a HyperConsole style to stderr
withStyleErr :: Style -> IO () -> IO ()
withStyleErr style action = do
  applyStyle stderr style
  action
  ANSI.hSetSGR stderr [ANSI.Reset]

-- | Apply HyperConsole style SGR codes to a handle
applyStyle :: Handle -> Style -> IO ()
applyStyle h Style {..} = do
  let codes =
        [colorToSGR True styleFg | styleFg /= Default]
          ++ [colorToSGR False styleBg | styleBg /= Default]
          ++ map attrToSGR styleAttrs
  unless (null codes) $ ANSI.hSetSGR h codes

-- | Convert HyperConsole Color to ANSI SGR
colorToSGR :: Bool -> Color -> ANSI.SGR
colorToSGR isFg c =
  let layer = if isFg then ANSI.Foreground else ANSI.Background
   in case c of
        Default -> ANSI.SetDefaultColor layer
        Black -> ANSI.SetColor layer ANSI.Dull ANSI.Black
        Red -> ANSI.SetColor layer ANSI.Dull ANSI.Red
        Green -> ANSI.SetColor layer ANSI.Dull ANSI.Green
        Yellow -> ANSI.SetColor layer ANSI.Dull ANSI.Yellow
        Blue -> ANSI.SetColor layer ANSI.Dull ANSI.Blue
        Magenta -> ANSI.SetColor layer ANSI.Dull ANSI.Magenta
        Cyan -> ANSI.SetColor layer ANSI.Dull ANSI.Cyan
        White -> ANSI.SetColor layer ANSI.Dull ANSI.White
        BrightBlack -> ANSI.SetColor layer ANSI.Vivid ANSI.Black
        BrightRed -> ANSI.SetColor layer ANSI.Vivid ANSI.Red
        BrightGreen -> ANSI.SetColor layer ANSI.Vivid ANSI.Green
        BrightYellow -> ANSI.SetColor layer ANSI.Vivid ANSI.Yellow
        BrightBlue -> ANSI.SetColor layer ANSI.Vivid ANSI.Blue
        BrightMagenta -> ANSI.SetColor layer ANSI.Vivid ANSI.Magenta
        BrightCyan -> ANSI.SetColor layer ANSI.Vivid ANSI.Cyan
        BrightWhite -> ANSI.SetColor layer ANSI.Vivid ANSI.White
        Color256 n -> ANSI.SetPaletteColor layer n
        RGB r g b -> ANSI.SetRGBColor layer (sRGB24 r g b)

-- | Convert HyperConsole Attr to ANSI SGR
attrToSGR :: Attr -> ANSI.SGR
attrToSGR Bold = ANSI.SetConsoleIntensity ANSI.BoldIntensity
attrToSGR Dim = ANSI.SetConsoleIntensity ANSI.FaintIntensity
attrToSGR Italic = ANSI.SetItalicized True
attrToSGR Underline = ANSI.SetUnderlining ANSI.SingleUnderline
attrToSGR Blink = ANSI.SetBlinkSpeed ANSI.SlowBlink
attrToSGR Reverse = ANSI.SetSwapForegroundBackground True
attrToSGR Strikethrough = ANSI.SetConsoleIntensity ANSI.NormalIntensity

-- ════════════════════════════════════════════════════════════════════════════
-- Terminal Rendering
-- ════════════════════════════════════════════════════════════════════════════

renderResultTerminal :: Result -> IO ()
renderResultTerminal = \case
  BuildSuccess target outputs duration -> do
    withStyle Theme.themeSuccess $ TIO.putStr (Theme.glyphCheck <> " ")
    TIO.putStrLn $ target <> " built in " <> T.pack (show duration)
    mapM_ (\o -> TIO.putStrLn $ "  " <> Theme.glyphArrow <> " " <> o) outputs
  QueryResult v -> BL.putStr (encode v) >> putStrLn ""
  TextResult t -> TIO.putStrLn t
  JsonResult v -> BL.putStr (encode v) >> putStrLn ""

renderProgressTerminal :: Progress -> IO ()
renderProgressTerminal = \case
  Building target -> do
    withStyle Theme.themeAccent $ TIO.putStr (Theme.glyphBuilding <> " ")
    TIO.putStrLn $ "Building " <> target
  Cached target -> do
    withStyle Theme.themeStatusCached $ TIO.putStr (Theme.glyphCached <> " ")
    TIO.putStrLn $ "Cached " <> target
  Built target duration -> do
    withStyle Theme.themeSuccess $ TIO.putStr (Theme.glyphCheck <> " ")
    TIO.putStrLn $ target <> " (" <> T.pack (show duration) <> ")"
  ProgressCount current total -> do
    withStyle Theme.themeProgressText $
      TIO.putStrLn $
        "[" <> T.pack (show current) <> "/" <> T.pack (show total) <> "]"
  Action target action -> do
    withStyle Theme.themeAccent $
      TIO.putStrLn $
        "  " <> action <> ": " <> target
  Tick _ -> pure () -- ticks handled by HyperConsole in TUI mode
  ProgressMsg msg -> TIO.putStrLn msg

renderDiagnosticTerminal :: Diagnostic -> IO ()
renderDiagnosticTerminal (Diagnostic lvl msg ctx) = do
  let (style, prefix) = case lvl of
        Debug -> (Theme.themeSecondary, "debug: ")
        Info -> (Theme.themeSecondary, "")
        Warning -> (Theme.themeWarning, Theme.glyphWarning <> " warning: ")
  withStyleErr style $ case ctx of
    Just c -> TIO.hPutStrLn stderr $ c <> ": " <> prefix <> msg
    Nothing -> TIO.hPutStrLn stderr $ prefix <> msg

renderErrorTerminal :: Error -> IO ()
renderErrorTerminal err = do
  withStyleErr Theme.themeError $ TIO.hPutStr stderr (Theme.glyphError <> " error: ")
  case err of
    BuildFailed target msg details -> do
      TIO.hPutStrLn stderr $ target <> ": " <> msg
      case details of
        Just d -> TIO.hPutStrLn stderr d
        Nothing -> pure ()
    ConfigError msg -> TIO.hPutStrLn stderr msg
    InternalError msg -> TIO.hPutStrLn stderr $ "internal: " <> msg

-- ════════════════════════════════════════════════════════════════════════════
-- Pipe Rendering (no ANSI colors)
-- ════════════════════════════════════════════════════════════════════════════

renderResultPipe :: Result -> IO ()
renderResultPipe = \case
  BuildSuccess target outputs duration -> do
    TIO.putStrLn $ target <> " built in " <> T.pack (show duration)
    mapM_ (\o -> TIO.putStrLn $ "  -> " <> o) outputs
  QueryResult v -> BL.putStr (encode v) >> putStrLn ""
  TextResult t -> TIO.putStrLn t
  JsonResult v -> BL.putStr (encode v) >> putStrLn ""

renderProgressPipe :: Progress -> IO ()
renderProgressPipe = \case
  Building target -> TIO.putStrLn $ "* Building " <> target
  Cached target -> TIO.putStrLn $ "= Cached " <> target
  Built target duration -> TIO.putStrLn $ "+ " <> target <> " (" <> T.pack (show duration) <> ")"
  ProgressCount current total -> TIO.putStrLn $ "[" <> T.pack (show current) <> "/" <> T.pack (show total) <> "]"
  Action target action -> TIO.putStrLn $ "  " <> action <> ": " <> target
  Tick _ -> pure ()
  ProgressMsg msg -> TIO.putStrLn msg

renderDiagnosticPipe :: Diagnostic -> IO ()
renderDiagnosticPipe (Diagnostic lvl msg ctx) = do
  let prefix = case lvl of
        Debug -> "debug: "
        Info -> ""
        Warning -> "warning: "
  case ctx of
    Just c -> TIO.hPutStrLn stderr $ c <> ": " <> prefix <> msg
    Nothing -> TIO.hPutStrLn stderr $ prefix <> msg

renderErrorPipe :: Error -> IO ()
renderErrorPipe = \case
  BuildFailed target msg details -> do
    TIO.hPutStrLn stderr $ "error: " <> target <> ": " <> msg
    case details of
      Just d -> TIO.hPutStrLn stderr d
      Nothing -> pure ()
  ConfigError msg -> TIO.hPutStrLn stderr $ "error: " <> msg
  InternalError msg -> TIO.hPutStrLn stderr $ "error: internal: " <> msg

-- ════════════════════════════════════════════════════════════════════════════
-- Output Monad
-- ════════════════════════════════════════════════════════════════════════════

-- | Output monad - carries the presenter for rendering
newtype OutputT m a = OutputT {unOutputT :: ReaderT Presenter m a}
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadReader Presenter)

-- | Run an OutputT action with a presenter
runOutputT :: Presenter -> OutputT IO a -> IO a
runOutputT presenter action = runReaderT (unOutputT action) presenter

-- | Emit a typed output message
emit :: (MonadIO m, MonadReader Presenter m) => Output -> m ()
emit output = do
  presenter <- asks id
  liftIO $ present presenter output

-- | Convenience: emit a result
emitResult :: (MonadIO m, MonadReader Presenter m) => Result -> m ()
emitResult = emit . OutputResult

-- | Convenience: emit progress
emitProgress :: (MonadIO m, MonadReader Presenter m) => Progress -> m ()
emitProgress = emit . OutputProgress

-- | Convenience: emit a diagnostic
emitDiagnostic :: (MonadIO m, MonadReader Presenter m) => DiagnosticLevel -> Text -> m ()
emitDiagnostic lvl msg = emit $ OutputDiagnostic (Diagnostic lvl msg Nothing)

-- | Convenience: emit an error
emitError :: (MonadIO m, MonadReader Presenter m) => Error -> m ()
emitError = emit . OutputError

-- ════════════════════════════════════════════════════════════════════════════
-- Context Detection
-- ════════════════════════════════════════════════════════════════════════════

-- | Output context - how are we being invoked?
data OutputContext
  = -- | Interactive terminal (human)
    ContextTerminal
  | -- | Piped output (another program)
    ContextPipe
  | -- | AI agent (structured output)
    ContextAgent
  deriving stock (Eq, Show)

-- | Detect the output context from environment
--
-- Checks in order:
--   1. SENSENET_AGENT=1 → ContextAgent (set by weapon, sigil, etc)
--   2. stdout is TTY → ContextTerminal (human at terminal)
--   3. otherwise → ContextPipe (piped to another program)
detectContext :: IO OutputContext
detectContext = do
  -- Check for agent environment variable first
  mAgent <- lookupEnv "SENSENET_AGENT"
  case mAgent of
    Just "1" -> pure ContextAgent
    Just "true" -> pure ContextAgent
    _ -> do
      isTTY <- hIsTerminalDevice stdout
      pure $
        if isTTY
          then ContextTerminal
          else ContextPipe

-- | Get the appropriate presenter for a context
--
-- Terminal and Pipe both get raw text output (works with grep, jq, etc.)
-- Only explicit Agent mode gets the typed JSON protocol
presenterForContext :: OutputContext -> Presenter
presenterForContext = \case
  ContextTerminal -> terminalPresenter
  ContextPipe -> pipePresenter -- raw output for shell pipelines
  ContextAgent -> agentPresenter -- typed JSON protocol for agents

-- ════════════════════════════════════════════════════════════════════════════
-- Direct IO Helpers (for gradual migration)
-- ════════════════════════════════════════════════════════════════════════════

-- | Emit output directly in IO with a given presenter
emitIO :: Presenter -> Output -> IO ()
emitIO p = present p

-- | Emit a result directly in IO
emitResultIO :: Presenter -> Result -> IO ()
emitResultIO p = emitIO p . OutputResult

-- | Emit progress directly in IO
emitProgressIO :: Presenter -> Progress -> IO ()
emitProgressIO p = emitIO p . OutputProgress

-- | Emit an error directly in IO
emitErrorIO :: Presenter -> Error -> IO ()
emitErrorIO p = emitIO p . OutputError

-- | Run an IO action with auto-detected presenter
-- Detects context and passes the appropriate presenter to the action
withAutoPresenter :: (Presenter -> IO a) -> IO a
withAutoPresenter action = do
  ctx <- detectContext
  action (presenterForContext ctx)
