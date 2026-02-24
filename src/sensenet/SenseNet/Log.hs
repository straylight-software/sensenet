{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : SenseNet.Log
-- Description : Structured logging via Katip
--
-- Provides structured logging for sensenet builds using Katip.
-- Logs include build targets, phases, timing, and coeffects.
--
-- Usage:
--
-- @
-- main = do
--   logEnv <- initLogging
--   withBuildTarget logEnv "//src/examples/cxx:hello" $ do
--     withPhase logEnv "compile" $ do
--       ... build actions ...
--   closeLogging logEnv
-- @
module SenseNet.Log
  ( -- * Log Environment
    LogEnv,
    initLogging,
    closeLogging,

    -- * Scoped Logging
    withBuildTarget,
    withPhase,

    -- * Direct Logging
    logBuildStart,
    logBuildComplete,
    logBuildCached,
    logBuildFailed,
    logActionStart,
    logActionComplete,

    -- * Severity Levels
    logDebug,
    logInfo,
    logWarn,
    logError,
  )
where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (NominalDiffTime)
import GHC.Generics (Generic)
import Katip qualified as K
import Network.HostName (getHostName)
import System.IO (stdout)

-- ════════════════════════════════════════════════════════════════════════════
-- Log Environment
-- ════════════════════════════════════════════════════════════════════════════

-- | Katip logging environment
data LogEnv = LogEnv
  { leLogEnv :: !K.LogEnv,
    leContext :: !K.LogContexts,
    leNamespace :: !K.Namespace
  }
  deriving stock (Generic)

-- | Initialize logging to stdout with JSON format
initLogging :: IO LogEnv
initLogging = do
  hostname <- T.pack <$> getHostName
  handleScribe <- K.mkHandleScribe K.ColorIfTerminal stdout (K.permitItem K.InfoS) K.V2
  let makeLogEnv =
        K.registerScribe "stdout" handleScribe K.defaultScribeSettings
          =<< K.initLogEnv "sensenet" (K.Environment hostname)
  logEnv <- makeLogEnv
  pure
    LogEnv
      { leLogEnv = logEnv,
        leContext = mempty,
        leNamespace = "build"
      }

-- | Close logging and flush all pending writes
closeLogging :: LogEnv -> IO ()
closeLogging env = () <$ K.closeScribes (leLogEnv env)

-- ════════════════════════════════════════════════════════════════════════════
-- Scoped Logging
-- ════════════════════════════════════════════════════════════════════════════

-- | Run an action with a build target in the log context
withBuildTarget :: LogEnv -> Text -> IO a -> IO a
withBuildTarget env target action =
  let ctx = K.liftPayload (TargetContext target)
      env' = env {leContext = leContext env <> ctx}
   in runLog env' action

-- | Run an action with a phase in the log namespace
withPhase :: LogEnv -> Text -> IO a -> IO a
withPhase env phase action =
  let ns = K.Namespace [phase]
      env' = env {leNamespace = leNamespace env <> ns}
   in runLog env' action

-- Internal: run Katip action with LogEnv
runLog :: LogEnv -> IO a -> IO a
runLog env action =
  K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $
    liftIO action

-- ════════════════════════════════════════════════════════════════════════════
-- Log Context Types
-- ════════════════════════════════════════════════════════════════════════════

-- | Context for build target
newtype TargetContext = TargetContext Text
  deriving stock (Generic)

instance ToJSON TargetContext where
  toJSON (TargetContext t) = object ["target" .= t]

instance K.ToObject TargetContext

instance K.LogItem TargetContext where
  payloadKeys _ _ = K.AllKeys

-- | Context for action execution
data ActionContext = ActionContext
  { acName :: !Text,
    acCached :: !Bool
  }
  deriving stock (Generic)

instance ToJSON ActionContext where
  toJSON ac = object ["action" .= acName ac, "cached" .= acCached ac]

instance K.ToObject ActionContext

instance K.LogItem ActionContext where
  payloadKeys _ _ = K.AllKeys

-- ════════════════════════════════════════════════════════════════════════════
-- Build Logging
-- ════════════════════════════════════════════════════════════════════════════

-- | Log build start
logBuildStart :: LogEnv -> Text -> Int -> IO ()
logBuildStart env target count =
  runLog env $
    K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $
      K.logLocM K.InfoS $
        K.ls ("Building " <> target <> " (" <> T.pack (show count) <> " targets)")

-- | Log build completion with timing
logBuildComplete :: LogEnv -> Text -> NominalDiffTime -> IO ()
logBuildComplete env target duration =
  runLog env $
    K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $
      K.logLocM K.InfoS $
        K.ls ("Built " <> target <> " in " <> T.pack (show duration))

-- | Log cache hit
logBuildCached :: LogEnv -> Text -> IO ()
logBuildCached env target =
  runLog env $
    K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $
      K.logLocM K.DebugS $
        K.ls ("Cached: " <> target)

-- | Log build failure
logBuildFailed :: LogEnv -> Text -> Text -> IO ()
logBuildFailed env target err =
  runLog env $
    K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $
      K.logLocM K.ErrorS $
        K.ls ("Failed: " <> target <> " - " <> err)

-- | Log action start
logActionStart :: LogEnv -> Text -> IO ()
logActionStart env name =
  runLog env $
    K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $
      K.logLocM K.DebugS $
        K.ls ("Starting: " <> name)

-- | Log action completion
logActionComplete :: LogEnv -> Text -> Bool -> NominalDiffTime -> IO ()
logActionComplete env name cached duration =
  runLog env $
    K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $ do
      let status = if cached then "cached" else "built"
      K.logLocM K.InfoS $
        K.ls (name <> " " <> status <> " (" <> T.pack (show duration) <> ")")

-- ════════════════════════════════════════════════════════════════════════════
-- Generic Logging
-- ════════════════════════════════════════════════════════════════════════════

-- | Log at debug level
logDebug :: LogEnv -> Text -> IO ()
logDebug env msg =
  runLog env $
    K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $
      K.logLocM K.DebugS (K.ls msg)

-- | Log at info level
logInfo :: LogEnv -> Text -> IO ()
logInfo env msg =
  runLog env $
    K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $
      K.logLocM K.InfoS (K.ls msg)

-- | Log at warning level
logWarn :: LogEnv -> Text -> IO ()
logWarn env msg =
  runLog env $
    K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $
      K.logLocM K.WarningS (K.ls msg)

-- | Log at error level
logError :: LogEnv -> Text -> IO ()
logError env msg =
  runLog env $
    K.runKatipContextT (leLogEnv env) (leContext env) (leNamespace env) $
      K.logLocM K.ErrorS (K.ls msg)
