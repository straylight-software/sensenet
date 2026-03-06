{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

-- | DICE (Dynamic Incremental Computation Engine) for Haskell
--
-- This module provides a clean, type-safe interface to DICE, enabling
-- incremental builds without Buck2 or Starlark.
--
-- = Quick Start
--
-- @
-- import SenseNet.DICE
--
-- main :: IO ()
-- main = do
--   result <- runDICE $ do
--     -- Inject source files
--     inject "src/main.cpp" "abc123" 1024
--     inject "src/lib.cpp" "def456" 2048
--
--     -- Compute an action
--     compute "compile-main"
--
--   case result of
--     Left err -> putStrLn $ "Error: " <> show err
--     Right outputs -> putStrLn $ "Built: " <> show outputs
-- @
--
-- = Architecture
--
-- DICE uses a transactional model:
--
-- 1. Create an engine (holds the computation graph)
-- 2. Start a transaction (inject source file metadata)
-- 3. Commit the transaction
-- 4. Request computations (DICE handles caching/invalidation)
--
-- The 'DICE' monad handles all of this automatically.
module SenseNet.DICE
  ( -- * The DICE Monad
    DICE,
    runDICE,
    runDICE',

    -- * Errors
    DICEError (..),

    -- * Core Operations
    inject,
    compute,

    -- * Target Registration (dependency-aware)
    registerTarget,
    clearTargets,

    -- * Callbacks (legacy)
    onCompute,

    -- * Utilities
    sha256,
    diceVersion,

    -- * Low-level Access (rarely needed)
    withEngine,
    withTransaction,

    -- * DICE Monad Utilities
    throwDICE,
    tryIO,
  )
where

import Control.Exception (Exception, SomeException, bracket, try)
import Control.Monad.IO.Class (MonadIO (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BSU
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64, Word8)
import Foreign.C.String (peekCString)
import Foreign.Marshal.Alloc (alloca, mallocBytes)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (castPtr, nullPtr, plusPtr)
import Foreign.Storable (peek, poke)
import SenseNet.DICE.FFI qualified as FFI

-- ════════════════════════════════════════════════════════════════════════════
-- Error Types
-- ════════════════════════════════════════════════════════════════════════════

-- | Errors that can occur during DICE operations
data DICEError
  = RuntimeCreateFailed
  | EngineCreateFailed
  | UpdaterCreateFailed
  | CommitFailed
  | ComputeFailed Text
  | InjectFailed Text
  | CallbackRegistrationFailed Text
  | HashFailed
  deriving stock (Show, Eq)

instance Exception DICEError

-- ════════════════════════════════════════════════════════════════════════════
-- DICE Monad
-- ════════════════════════════════════════════════════════════════════════════

-- | The DICE monad for incremental computation.
--
-- This monad manages:
--
-- * DICE engine lifecycle
-- * Transaction state (injected sources)
-- * Error handling
--
-- Use 'runDICE' to execute DICE computations.
newtype DICE a = DICE {unDICE :: DICEEnv -> IO (Either DICEError a)}

instance Functor DICE where
  fmap f (DICE g) = DICE $ \env -> fmap (fmap f) (g env)

instance Applicative DICE where
  pure a = DICE $ \_ -> pure (Right a)
  DICE f <*> DICE a = DICE $ \env -> do
    ef <- f env
    case ef of
      Left err -> pure (Left err)
      Right fn -> fmap (fmap fn) (a env)

instance Monad DICE where
  DICE m >>= f = DICE $ \env -> do
    ea <- m env
    case ea of
      Left err -> pure (Left err)
      Right a -> unDICE (f a) env

instance MonadIO DICE where
  liftIO io = DICE $ \_ -> Right <$> io

-- | Internal environment for DICE operations
data DICEEnv = DICEEnv
  { envRuntime :: FFI.RuntimePtr,
    envEngine :: FFI.EnginePtr,
    envSources :: IORef [(Text, Text, Word64)] -- (path, hash, size)
  }

-- | Throw a DICE error
throwDICE :: DICEError -> DICE a
throwDICE err = DICE $ \_ -> pure (Left err)

-- | Catch IO exceptions and convert to DICE errors
tryIO :: IO a -> (SomeException -> DICEError) -> DICE a
tryIO io mkErr = DICE $ \_ -> do
  result <- try io
  case result of
    Left exc -> pure (Left (mkErr exc))
    Right a -> pure (Right a)

-- ════════════════════════════════════════════════════════════════════════════
-- Running DICE
-- ════════════════════════════════════════════════════════════════════════════

-- | Run a DICE computation.
--
-- Creates the runtime, engine, and transaction automatically.
-- All resources are properly cleaned up on exit.
--
-- @
-- result <- runDICE $ do
--   inject "src/main.cpp" hash size
--   compute "build-main"
-- @
runDICE :: DICE a -> IO (Either DICEError a)
runDICE dice =
  bracket createRuntime FFI.c_runtime_free $ \rtPtr -> do
    if rtPtr == nullPtr
      then pure (Left RuntimeCreateFailed)
      else bracket createEngine FFI.c_engine_free $ \engPtr -> do
        if engPtr == nullPtr
          then pure (Left EngineCreateFailed)
          else do
            sourcesRef <- newIORef []
            let env = DICEEnv rtPtr engPtr sourcesRef
            unDICE dice env
  where
    createRuntime = FFI.c_runtime_new
    createEngine = FFI.c_engine_new

-- | Run DICE and throw on error (for simple scripts)
runDICE' :: DICE a -> IO a
runDICE' dice = do
  result <- runDICE dice
  case result of
    Left err -> fail $ "DICE error: " <> show err
    Right a -> pure a

-- ════════════════════════════════════════════════════════════════════════════
-- Core Operations
-- ════════════════════════════════════════════════════════════════════════════

-- | Inject a source file into the current transaction.
--
-- This tells DICE about a source file's identity (path, content hash, size).
-- DICE uses this to track dependencies and invalidation.
--
-- @
-- inject "src/main.cpp" "a1b2c3..." 1024
-- @
inject :: Text -> Text -> Word64 -> DICE ()
inject path hash size = DICE $ \env -> do
  modifyIORef' (envSources env) ((path, hash, size) :)
  pure (Right ())

-- | Request computation of an action.
--
-- Commits any pending source injections, then computes the action.
-- Returns the list of output paths on success.
--
-- @
-- outputs <- compute "compile-main"
-- @
compute :: Text -> DICE [Text]
compute key = DICE $ \env -> do
  -- Get pending sources
  sources <- readIORef (envSources env)

  -- Create updater
  updPtr <- FFI.c_updater_new (envEngine env)
  if updPtr == nullPtr
    then pure (Left UpdaterCreateFailed)
    else do
      -- Inject all sources
      injectResult <- injectAll updPtr (reverse sources)
      case injectResult of
        Left err -> do
          FFI.c_updater_free updPtr
          pure (Left err)
        Right () -> do
          -- Commit transaction
          txnPtr <- FFI.c_commit (envRuntime env) updPtr
          if txnPtr == nullPtr
            then pure (Left CommitFailed)
            else do
              -- Compute
              result <- computeAction (envRuntime env) txnPtr key
              FFI.c_transaction_free txnPtr
              pure result
  where
    injectAll _ [] = pure (Right ())
    injectAll updPtr ((p, h, s) : rest) = do
      let pathBS = TE.encodeUtf8 p
          hashBS = TE.encodeUtf8 h
      rc <- BS.useAsCStringLen pathBS $ \(pathPtr, pathLen) ->
        BS.useAsCStringLen hashBS $ \(hashPtr, hashLen) ->
          FFI.c_inject_source
            updPtr
            pathPtr
            (fromIntegral pathLen)
            hashPtr
            (fromIntegral hashLen)
            s
      if rc /= 0
        then pure (Left (InjectFailed p))
        else injectAll updPtr rest

    computeAction rtPtr txnPtr k = do
      let keyBS = TE.encodeUtf8 k
      resultPtr <- BS.useAsCStringLen keyBS $ \(keyPtr, keyLen) ->
        FFI.c_compute_action rtPtr txnPtr keyPtr (fromIntegral keyLen)
      if resultPtr == nullPtr
        then pure (Left (ComputeFailed k))
        else do
          ok <- FFI.c_result_ok resultPtr
          if ok == 1
            then do
              count <- FFI.c_result_output_count resultPtr
              outputs <- mapM (getOutput resultPtr) [0 .. count - 1]
              FFI.c_result_free resultPtr
              pure (Right outputs)
            else do
              errText <- getError resultPtr
              FFI.c_result_free resultPtr
              pure (Left (ComputeFailed errText))

    getOutput ptr idx = alloca $ \lenPtr -> do
      outPtr <- FFI.c_result_output_at ptr idx lenPtr
      if outPtr == nullPtr
        then pure T.empty
        else do
          len <- peek lenPtr
          bs <- BS.packCStringLen (outPtr, fromIntegral len)
          pure (TE.decodeUtf8 bs)

    getError ptr = alloca $ \lenPtr -> do
      errPtr <- FFI.c_result_error ptr lenPtr
      if errPtr == nullPtr
        then pure (T.pack "Unknown error")
        else do
          len <- peek lenPtr
          bs <- BS.packCStringLen (errPtr, fromIntegral len)
          pure (TE.decodeUtf8 bs)

-- ════════════════════════════════════════════════════════════════════════════
-- Target Registration (Dependency-Aware)
-- ════════════════════════════════════════════════════════════════════════════

-- | Register a target with its dependencies.
--
-- This is the primary API for dependency-aware builds. When the target is computed:
-- 1. DICE computes all dependencies first
-- 2. Dep outputs are serialized to JSON
-- 3. Your callback receives resolved dep outputs
--
-- @
-- registerTarget "mybin" [":mylib"] $ \key depsJson -> do
--   -- depsJson contains: [{\"name\": \"mylib\", \"outputs\": [\"libmylib.a\"]}]
--   -- Use dep outputs to link
--   pure "{\"outputs\": [\"mybin\"], \"exit_code\": 0}"
-- @
--
-- Note: Targets are global and persist for the program lifetime.
registerTarget :: Text -> [Text] -> (Text -> Text -> IO Text) -> DICE ()
registerTarget targetName deps callback = DICE $ \_ -> do
  let wrapped keyPtr keyLen depsPtr depsLen _userData = do
        keyBS <- BS.packCStringLen (keyPtr, fromIntegral keyLen)
        depsBS <- BS.packCStringLen (depsPtr, fromIntegral depsLen)
        result <- callback (TE.decodeUtf8 keyBS) (TE.decodeUtf8 depsBS)
        -- Allocate result string for Rust to free
        let resultBS = TE.encodeUtf8 result
        BS.useAsCStringLen resultBS $ \(srcPtr, len) -> do
          dest <- mallocBytes (len + 1)
          copyBytes dest srcPtr len
          poke (dest `plusPtr` len) (0 :: Word8)
          pure (castPtr dest)

  fnPtr <- FFI.mkComputeCallback wrapped

  -- Serialize deps to JSON array: ["dep1", "dep2", ...]
  let depsJson = "[" <> T.intercalate "," (map (\d -> "\"" <> escapeJson d <> "\"") deps) <> "]"
      nameBS = TE.encodeUtf8 targetName
      depsBS = TE.encodeUtf8 depsJson

  rc <- BS.useAsCStringLen nameBS $ \(namePtr, nameLen) ->
    BS.useAsCStringLen depsBS $ \(depsPtr, depsLen) ->
      FFI.c_register_target
        namePtr
        (fromIntegral nameLen)
        depsPtr
        (fromIntegral depsLen)
        fnPtr
        nullPtr

  if rc /= 0
    then pure (Left (CallbackRegistrationFailed targetName))
    else pure (Right ())

-- | Clear all registered targets (useful for tests/resets)
clearTargets :: DICE ()
clearTargets = DICE $ \_ -> do
  FFI.c_clear_targets
  pure (Right ())

-- | Escape special characters for JSON strings
escapeJson :: Text -> Text
escapeJson = T.concatMap escapeChar
  where
    escapeChar :: Char -> Text
    escapeChar '\\' = T.pack "\\\\"
    escapeChar '"' = T.pack "\\\""
    escapeChar '\n' = T.pack "\\n"
    escapeChar '\r' = T.pack "\\r"
    escapeChar '\t' = T.pack "\\t"
    escapeChar c = T.singleton c

-- ════════════════════════════════════════════════════════════════════════════
-- Callbacks (Legacy)
-- ════════════════════════════════════════════════════════════════════════════

-- | Register a compute callback for a key type (legacy API).
--
-- When DICE needs to compute a key of this type, it will call your function.
--
-- @
-- onCompute "action" $ \\key deps -> do
--   -- Run build command
--   pure "{\"outputs\": [\"out.o\"], \"exit_code\": 0}"
-- @
--
-- Note: Callbacks are global and persist for the program lifetime.
-- Prefer 'registerTarget' for dependency-aware builds.
onCompute :: Text -> (Text -> Text -> IO Text) -> DICE ()
onCompute keyType callback = DICE $ \_ -> do
  let wrapped keyPtr keyLen depsPtr depsLen _userData = do
        keyBS <- BS.packCStringLen (keyPtr, fromIntegral keyLen)
        depsBS <- BS.packCStringLen (depsPtr, fromIntegral depsLen)
        result <- callback (TE.decodeUtf8 keyBS) (TE.decodeUtf8 depsBS)
        -- Allocate result string for Rust to free
        let resultBS = TE.encodeUtf8 result
        BS.useAsCStringLen resultBS $ \(srcPtr, len) -> do
          dest <- mallocBytes (len + 1)
          copyBytes dest srcPtr len
          poke (dest `plusPtr` len) (0 :: Word8)
          pure (castPtr dest)

  fnPtr <- FFI.mkComputeCallback wrapped
  let keyTypeBS = TE.encodeUtf8 keyType
  rc <- BS.useAsCStringLen keyTypeBS $ \(ptr, len) ->
    FFI.c_register_compute ptr (fromIntegral len) fnPtr nullPtr
  if rc /= 0
    then pure (Left (CallbackRegistrationFailed keyType))
    else pure (Right ())

-- ════════════════════════════════════════════════════════════════════════════
-- Utilities
-- ════════════════════════════════════════════════════════════════════════════

-- | Compute SHA256 hash of data.
--
-- Uses the DICE library's hash implementation for consistency.
--
-- @
-- hash <- sha256 fileContents
-- @
sha256 :: ByteString -> DICE Text
sha256 bs = DICE $ \_ ->
  BSU.unsafeUseAsCStringLen bs $ \(ptr, len) -> do
    hashPtr <- FFI.c_hash_sha256 (castPtr ptr) (fromIntegral len)
    if hashPtr == nullPtr
      then pure (Left HashFailed)
      else do
        hash <- peekCString hashPtr
        FFI.c_free_string hashPtr
        pure (Right (T.pack hash))

-- | Get DICE library version.
diceVersion :: IO Text
diceVersion = do
  vPtr <- FFI.c_version
  v <- peekCString vPtr
  pure (T.pack v)

-- ════════════════════════════════════════════════════════════════════════════
-- Low-level Access
-- ════════════════════════════════════════════════════════════════════════════

-- | Run an action with direct engine access.
--
-- For advanced use cases that need the raw engine handle.
withEngine :: (FFI.EnginePtr -> IO a) -> DICE a
withEngine f = DICE $ \env -> Right <$> f (envEngine env)

-- | Run an action with direct transaction access.
--
-- Creates a transaction from pending sources, runs the action,
-- then cleans up.
withTransaction :: (FFI.TransactionPtr -> IO a) -> DICE a
withTransaction f = DICE $ \env -> do
  sources <- readIORef (envSources env)
  updPtr <- FFI.c_updater_new (envEngine env)
  if updPtr == nullPtr
    then pure (Left UpdaterCreateFailed)
    else do
      -- Inject sources
      mapM_ (injectOne updPtr) (reverse sources)
      -- Commit
      txnPtr <- FFI.c_commit (envRuntime env) updPtr
      if txnPtr == nullPtr
        then pure (Left CommitFailed)
        else do
          result <- f txnPtr
          FFI.c_transaction_free txnPtr
          pure (Right result)
  where
    injectOne updPtr (p, h, s) = do
      let pathBS = TE.encodeUtf8 p
          hashBS = TE.encodeUtf8 h
      BS.useAsCStringLen pathBS $ \(pathPtr, pathLen) ->
        BS.useAsCStringLen hashBS $ \(hashPtr, hashLen) ->
          FFI.c_inject_source
            updPtr
            pathPtr
            (fromIntegral pathLen)
            hashPtr
            (fromIntegral hashLen)
            s
