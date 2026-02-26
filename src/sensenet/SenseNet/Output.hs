{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : SenseNet.Output
-- Description : Typed output protocol - no stdout, no stderr
--
-- "The sky above the port was the color of television,
--  tuned to a dead channel."
--
--                                      — Neuromancer
--
-- = The End of stdio
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
-- This module replaces all of it with typed output:
--
-- @
-- data Output
--   = Result !Value          -- The actual data/answer
--   | Progress !Progress     -- Build progress, spinners
--   | Diagnostic !Diagnostic -- Warnings, info, debug
--   | Error !Error           -- Failures
-- @
--
-- The producer emits typed facts. The consumer decides presentation:
--
--   * Terminal → HyperConsole renders with colors, progress bars
--   * Agent → JSON stream of results and errors only
--   * Log → Everything, timestamped
--   * Pipeline → Results only, raw
--
-- No stdout. No stderr. No @2>&1@.
--
-- = Usage
--
-- @
-- runWithOutput TerminalPresenter $ do
--   emit $ Progress (Building "//core:lib")
--   result <- buildTarget target
--   emit $ Result (BuildSuccess result)
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

import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader (MonadReader, ReaderT, asks, runReaderT)
import Data.Aeson (ToJSON (..), Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (NominalDiffTime)
import GHC.Generics (Generic)
import System.Console.ANSI qualified as ANSI
import System.Environment (lookupEnv)
import System.IO (hIsTerminalDevice, stderr, stdout)

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

-- | Null presenter - discard everything
nullPresenter :: Presenter
nullPresenter = Presenter $ \_ -> pure ()

-- ════════════════════════════════════════════════════════════════════════════
-- Terminal Rendering
-- ════════════════════════════════════════════════════════════════════════════

renderResultTerminal :: Result -> IO ()
renderResultTerminal = \case
  BuildSuccess target outputs duration -> do
    ANSI.setSGR [ANSI.SetColor ANSI.Foreground ANSI.Vivid ANSI.Green]
    TIO.putStr "✓ "
    ANSI.setSGR [ANSI.Reset]
    TIO.putStrLn $ target <> " built in " <> T.pack (show duration)
    mapM_ (\o -> TIO.putStrLn $ "  → " <> o) outputs
  QueryResult v -> BL.putStr (encode v) >> putStrLn ""
  TextResult t -> TIO.putStrLn t
  JsonResult v -> BL.putStr (encode v) >> putStrLn ""

renderProgressTerminal :: Progress -> IO ()
renderProgressTerminal = \case
  Building target -> do
    ANSI.setSGR [ANSI.SetColor ANSI.Foreground ANSI.Dull ANSI.Cyan]
    TIO.putStr "⟳ "
    ANSI.setSGR [ANSI.Reset]
    TIO.putStrLn $ "Building " <> target
  Cached target -> do
    ANSI.setSGR [ANSI.SetColor ANSI.Foreground ANSI.Dull ANSI.Green]
    TIO.putStr "◉ "
    ANSI.setSGR [ANSI.Reset]
    TIO.putStrLn $ "Cached " <> target
  Built target duration -> do
    ANSI.setSGR [ANSI.SetColor ANSI.Foreground ANSI.Vivid ANSI.Green]
    TIO.putStr "✓ "
    ANSI.setSGR [ANSI.Reset]
    TIO.putStrLn $ target <> " (" <> T.pack (show duration) <> ")"
  ProgressCount current total -> do
    ANSI.setSGR [ANSI.SetColor ANSI.Foreground ANSI.Dull ANSI.White]
    TIO.putStrLn $ "[" <> T.pack (show current) <> "/" <> T.pack (show total) <> "]"
    ANSI.setSGR [ANSI.Reset]
  Action target action -> do
    ANSI.setSGR [ANSI.SetColor ANSI.Foreground ANSI.Dull ANSI.Cyan]
    TIO.putStrLn $ "  " <> action <> ": " <> target
    ANSI.setSGR [ANSI.Reset]
  Tick _ -> pure () -- ticks handled by HyperConsole in TUI mode
  ProgressMsg msg -> TIO.putStrLn msg

renderDiagnosticTerminal :: Diagnostic -> IO ()
renderDiagnosticTerminal (Diagnostic lvl msg ctx) = do
  let (color, prefix) = case lvl of
        Debug -> (ANSI.Dull, "debug: ")
        Info -> (ANSI.Dull, "")
        Warning -> (ANSI.Vivid, "warning: ")
  ANSI.hSetSGR stderr [ANSI.SetColor ANSI.Foreground color ANSI.Yellow]
  case ctx of
    Just c -> TIO.hPutStrLn stderr $ c <> ": " <> prefix <> msg
    Nothing -> TIO.hPutStrLn stderr $ prefix <> msg
  ANSI.hSetSGR stderr [ANSI.Reset]

renderErrorTerminal :: Error -> IO ()
renderErrorTerminal err = do
  ANSI.hSetSGR stderr [ANSI.SetColor ANSI.Foreground ANSI.Vivid ANSI.Red]
  TIO.hPutStr stderr "error: "
  ANSI.hSetSGR stderr [ANSI.Reset]
  case err of
    BuildFailed target msg details -> do
      TIO.hPutStrLn stderr $ target <> ": " <> msg
      case details of
        Just d -> TIO.hPutStrLn stderr d
        Nothing -> pure ()
    ConfigError msg -> TIO.hPutStrLn stderr msg
    InternalError msg -> TIO.hPutStrLn stderr $ "internal: " <> msg

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
presenterForContext :: OutputContext -> Presenter
presenterForContext = \case
  ContextTerminal -> terminalPresenter
  ContextPipe -> agentPresenter -- pipes get JSON
  ContextAgent -> agentPresenter

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
