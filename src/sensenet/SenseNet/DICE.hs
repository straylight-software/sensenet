{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE LambdaCase #-}

-- | FFI bindings to DICE (Dynamic Incremental Computation Engine)
--
-- This module provides Haskell bindings to the Rust DICE library,
-- enabling incremental computation for builds without Buck2/Starlark.
--
-- Usage:
--
-- @
-- import qualified SenseNet.DICE as DICE
--
-- main = DICE.withEngine $ \engine -> do
--   -- Register compute callback
--   DICE.registerCompute engine "action" $ \key deps -> do
--     -- Execute build action
--     return $ DICE.ActionResult ["output.o"] "hash123" 0 ""
--
--   -- Inject source files
--   DICE.withTransaction engine $ \txn -> do
--     DICE.injectSource txn "src/main.cpp" "abc123" 1024
--     DICE.injectSource txn "src/lib.cpp" "def456" 2048
--
--   -- Request computation
--   result <- DICE.compute engine "action-key-hash"
--   case result of
--     Right outputs -> putStrLn $ "Built: " ++ show outputs
--     Left err -> putStrLn $ "Error: " ++ err
-- @
module SenseNet.DICE
  ( -- * Handles
    Runtime
  , Engine
  , Updater
  , Transaction
  , Result

    -- * Lifecycle
  , withRuntime
  , withEngine
  , withTransaction

    -- * Callbacks
  , ComputeFn
  , registerCompute

    -- * Injection
  , injectSource

    -- * Computation
  , compute
  , ActionResult(..)

    -- * Utilities
  , hashSHA256
  , version
  ) where

import Control.Exception (bracket)
import Control.Monad (when)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Unsafe as BSU
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word64)
import Foreign.C.String
import Foreign.C.Types
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr
import Foreign.Storable (peek, pokeByteOff)

-- ═══════════════════════════════════════════════════════════════════════════
-- Opaque Handle Types
-- ═══════════════════════════════════════════════════════════════════════════

-- | Tokio runtime handle
newtype Runtime = Runtime (Ptr ())

-- | DICE engine handle
newtype Engine = Engine (Ptr ())

-- | Transaction updater handle
newtype Updater = Updater (Ptr ())

-- | Transaction handle
newtype Transaction = Transaction (Ptr ())

-- | Computation result handle
newtype Result = Result (Ptr ())

-- ═══════════════════════════════════════════════════════════════════════════
-- FFI Imports
-- ═══════════════════════════════════════════════════════════════════════════

-- Runtime
foreign import ccall unsafe "dice_runtime_new"
  c_dice_runtime_new :: IO (Ptr ())

foreign import ccall unsafe "dice_runtime_free"
  c_dice_runtime_free :: Ptr () -> IO ()

-- Engine
foreign import ccall unsafe "dice_engine_new"
  c_dice_engine_new :: IO (Ptr ())

foreign import ccall unsafe "dice_engine_free"
  c_dice_engine_free :: Ptr () -> IO ()

-- Callbacks
foreign import ccall unsafe "dice_register_compute"
  c_dice_register_compute
    :: CString -> CSize -> FunPtr ComputeFnC -> Ptr () -> IO CInt

-- Transaction
foreign import ccall unsafe "dice_updater_new"
  c_dice_updater_new :: Ptr () -> IO (Ptr ())

foreign import ccall unsafe "dice_inject_source"
  c_dice_inject_source
    :: Ptr () -> CString -> CSize -> CString -> CSize -> Word64 -> IO CInt

foreign import ccall unsafe "dice_commit"
  c_dice_commit :: Ptr () -> Ptr () -> IO (Ptr ())

foreign import ccall unsafe "dice_updater_free"
  c_dice_updater_free :: Ptr () -> IO ()

foreign import ccall unsafe "dice_transaction_free"
  c_dice_transaction_free :: Ptr () -> IO ()

-- Computation
foreign import ccall unsafe "dice_compute_action"
  c_dice_compute_action
    :: Ptr () -> Ptr () -> CString -> CSize -> IO (Ptr ())

foreign import ccall unsafe "dice_result_ok"
  c_dice_result_ok :: Ptr () -> IO CInt

foreign import ccall unsafe "dice_result_exit_code"
  c_dice_result_exit_code :: Ptr () -> IO CInt

foreign import ccall unsafe "dice_result_output_count"
  c_dice_result_output_count :: Ptr () -> IO CSize

foreign import ccall unsafe "dice_result_output_at"
  c_dice_result_output_at :: Ptr () -> CSize -> Ptr CSize -> IO CString

foreign import ccall unsafe "dice_result_error"
  c_dice_result_error :: Ptr () -> Ptr CSize -> IO CString

foreign import ccall unsafe "dice_result_free"
  c_dice_result_free :: Ptr () -> IO ()

-- Utilities
foreign import ccall unsafe "dice_hash_sha256"
  c_dice_hash_sha256 :: Ptr Word8 -> CSize -> IO CString

foreign import ccall unsafe "dice_free_string"
  c_dice_free_string :: CString -> IO ()

foreign import ccall unsafe "dice_version"
  c_dice_version :: IO CString

-- ═══════════════════════════════════════════════════════════════════════════
-- Callback Types
-- ═══════════════════════════════════════════════════════════════════════════

-- | C callback function type
type ComputeFnC =
  CString -> CSize -> CString -> CSize -> Ptr () -> IO CString

-- | Haskell compute function type
-- Takes: key, dependencies JSON
-- Returns: JSON result string (will be freed by Rust)
type ComputeFn = Text -> Text -> IO Text

-- Foreign wrapper for callbacks
foreign import ccall "wrapper"
  mkComputeFn :: ComputeFnC -> IO (FunPtr ComputeFnC)

-- ═══════════════════════════════════════════════════════════════════════════
-- Data Types
-- ═══════════════════════════════════════════════════════════════════════════

-- | Result of an action computation
data ActionResult = ActionResult
  { arOutputs :: [Text]
  , arOutputHash :: Text
  , arExitCode :: Int
  , arLog :: Text
  } deriving (Show, Eq)

-- ═══════════════════════════════════════════════════════════════════════════
-- Lifecycle Functions
-- ═══════════════════════════════════════════════════════════════════════════

-- | Run action with a DICE runtime
withRuntime :: (Runtime -> IO a) -> IO a
withRuntime f = bracket
  (Runtime <$> c_dice_runtime_new)
  (\(Runtime p) -> c_dice_runtime_free p)
  f

-- | Run action with a DICE engine
-- Note: Currently doesn't use the runtime, but will when we add proper async
withEngine :: (Engine -> IO a) -> IO a
withEngine f = bracket
  (Engine <$> c_dice_engine_new)
  (\(Engine p) -> c_dice_engine_free p)
  f

-- | Run action with a transaction
-- Creates an updater, runs the action to inject values, then commits
withTransaction :: Runtime -> Engine -> (Updater -> IO ()) -> IO Transaction
withTransaction (Runtime rtPtr) (Engine engPtr) inject = do
  updaterPtr <- c_dice_updater_new engPtr
  when (updaterPtr == nullPtr) $
    error "Failed to create DICE updater"
  
  -- Run injection
  inject (Updater updaterPtr)
  
  -- Commit
  txnPtr <- c_dice_commit rtPtr updaterPtr
  when (txnPtr == nullPtr) $
    error "Failed to commit DICE transaction"
  
  return (Transaction txnPtr)

-- ═══════════════════════════════════════════════════════════════════════════
-- Callback Registration
-- ═══════════════════════════════════════════════════════════════════════════

-- | Register a compute callback for a key type
registerCompute :: Text -> ComputeFn -> IO ()
registerCompute keyType callback = do
  -- Wrap the Haskell callback
  let wrappedCallback :: ComputeFnC
      wrappedCallback keyPtr keyLen depsPtr depsLen _userData = do
        -- Convert key from C string
        keyBS <- BS.packCStringLen (keyPtr, fromIntegral keyLen)
        let key = TE.decodeUtf8 keyBS
        
        -- Convert deps from C string
        depsBS <- BS.packCStringLen (depsPtr, fromIntegral depsLen)
        let deps = TE.decodeUtf8 depsBS
        
        -- Call Haskell callback
        result <- callback key deps
        
        -- Return result as C string (caller will free)
        -- Note: We use malloc to match what Rust expects
        let resultBS = TE.encodeUtf8 result
        BS.useAsCStringLen resultBS $ \(ptr, len) -> do
          -- Allocate and copy
          dest <- mallocBytes (len + 1)
          copyBytes dest ptr len
          pokeByteOff dest len (0 :: Word8)
          return $ castPtr dest
  
  -- Create function pointer
  fnPtr <- mkComputeFn wrappedCallback
  
  -- Register with DICE
  let keyTypeBS = TE.encodeUtf8 keyType
  BS.useAsCStringLen keyTypeBS $ \(ptr, len) -> do
    rc <- c_dice_register_compute ptr (fromIntegral len) fnPtr nullPtr
    when (rc /= 0) $
      error $ "Failed to register compute callback for: " ++ T.unpack keyType

-- Need these for the callback implementation
foreign import ccall unsafe "malloc"
  mallocBytes :: Int -> IO (Ptr a)

foreign import ccall unsafe "memcpy"
  copyBytes :: Ptr a -> Ptr b -> Int -> IO ()

-- ═══════════════════════════════════════════════════════════════════════════
-- Injection Functions
-- ═══════════════════════════════════════════════════════════════════════════

-- | Inject a source file into the transaction
injectSource :: Updater -> Text -> Text -> Word64 -> IO ()
injectSource (Updater updPtr) path hash size = do
  let pathBS = TE.encodeUtf8 path
      hashBS = TE.encodeUtf8 hash
  
  BS.useAsCStringLen pathBS $ \(pathPtr, pathLen) ->
    BS.useAsCStringLen hashBS $ \(hashPtr, hashLen) -> do
      rc <- c_dice_inject_source
        updPtr
        pathPtr (fromIntegral pathLen)
        hashPtr (fromIntegral hashLen)
        size
      when (rc /= 0) $
        error $ "Failed to inject source: " ++ T.unpack path

-- ═══════════════════════════════════════════════════════════════════════════
-- Computation Functions
-- ═══════════════════════════════════════════════════════════════════════════

-- | Compute an action by key
compute :: Runtime -> Transaction -> Text -> IO (Either Text [Text])
compute (Runtime rtPtr) (Transaction txnPtr) key = do
  let keyBS = TE.encodeUtf8 key
  
  resultPtr <- BS.useAsCStringLen keyBS $ \(keyPtr, keyLen) ->
    c_dice_compute_action rtPtr txnPtr keyPtr (fromIntegral keyLen)
  
  when (resultPtr == nullPtr) $
    error "Failed to compute action"
  
  -- Check result
  ok <- c_dice_result_ok resultPtr
  if ok == 1
    then do
      -- Get outputs
      count <- c_dice_result_output_count resultPtr
      outputs <- mapM (getOutput resultPtr) [0 .. count - 1]
      c_dice_result_free resultPtr
      return $ Right outputs
    else do
      -- Get error
      alloca $ \lenPtr -> do
        errPtr <- c_dice_result_error resultPtr lenPtr
        if errPtr == nullPtr
          then do
            c_dice_result_free resultPtr
            return $ Left (T.pack "Unknown error")
          else do
            len <- peek lenPtr
            errBS <- BS.packCStringLen (errPtr, fromIntegral len)
            c_dice_result_free resultPtr
            return $ Left $ TE.decodeUtf8 errBS
  where
    getOutput :: Ptr () -> CSize -> IO Text
    getOutput ptr idx = alloca $ \lenPtr -> do
      outPtr <- c_dice_result_output_at ptr idx lenPtr
      if outPtr == nullPtr
        then return T.empty
        else do
          len <- peek lenPtr
          bs <- BS.packCStringLen (outPtr, fromIntegral len)
          return $ TE.decodeUtf8 bs

-- ═══════════════════════════════════════════════════════════════════════════
-- Utility Functions
-- ═══════════════════════════════════════════════════════════════════════════

-- | Compute SHA256 hash of data
hashSHA256 :: ByteString -> IO Text
hashSHA256 bs = BSU.unsafeUseAsCStringLen bs $ \(ptr, len) -> do
  hashPtr <- c_dice_hash_sha256 (castPtr ptr) (fromIntegral len)
  when (hashPtr == nullPtr) $
    error "Failed to compute SHA256 hash"
  
  hash <- peekCString hashPtr
  c_dice_free_string hashPtr
  return $ T.pack hash

-- | Get DICE library version
version :: IO Text
version = do
  vPtr <- c_dice_version
  v <- peekCString vPtr
  return $ T.pack v

-- ═══════════════════════════════════════════════════════════════════════════
-- Word8 type for FFI
-- ═══════════════════════════════════════════════════════════════════════════

type Word8 = Foreign.C.Types.CUChar
