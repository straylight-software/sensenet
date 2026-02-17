{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- | Low-level FFI bindings to DICE. Internal module - do not use directly.
--
-- Use "SenseNet.DICE" for the public API.
module SenseNet.DICE.FFI
  ( -- * Raw handle pointers
    RuntimePtr,
    EnginePtr,
    UpdaterPtr,
    TransactionPtr,
    ResultPtr,

    -- * FFI functions
    c_runtime_new,
    c_runtime_free,
    c_engine_new,
    c_engine_free,
    c_register_compute,
    c_register_target,
    c_clear_targets,
    c_updater_new,
    c_inject_source,
    c_commit,
    c_updater_free,
    c_transaction_free,
    c_compute_action,
    c_result_ok,
    c_result_exit_code,
    c_result_output_count,
    c_result_output_at,
    c_result_error,
    c_result_free,
    c_hash_sha256,
    c_free_string,
    c_version,

    -- * Callback types
    ComputeCallback,
    mkComputeCallback,
  )
where

import Data.Word (Word64, Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (FunPtr, Ptr)

-- | Opaque pointer types for type safety at FFI boundary
type RuntimePtr = Ptr ()

type EnginePtr = Ptr ()

type UpdaterPtr = Ptr ()

type TransactionPtr = Ptr ()

type ResultPtr = Ptr ()

-- | C callback type for compute functions
type ComputeCallback =
  CString -> CSize -> CString -> CSize -> Ptr () -> IO CString

-- Runtime lifecycle
foreign import ccall unsafe "dice_runtime_new"
  c_runtime_new :: IO RuntimePtr

foreign import ccall unsafe "dice_runtime_free"
  c_runtime_free :: RuntimePtr -> IO ()

-- Engine lifecycle
foreign import ccall unsafe "dice_engine_new"
  c_engine_new :: IO EnginePtr

foreign import ccall unsafe "dice_engine_free"
  c_engine_free :: EnginePtr -> IO ()

-- Callback registration (legacy - simple actions without deps)
foreign import ccall unsafe "dice_register_compute"
  c_register_compute :: CString -> CSize -> FunPtr ComputeCallback -> Ptr () -> IO CInt

-- Target registration with dependencies
-- dice_register_target(name, name_len, deps_json, deps_json_len, callback, user_data)
foreign import ccall unsafe "dice_register_target"
  c_register_target :: CString -> CSize -> CString -> CSize -> FunPtr ComputeCallback -> Ptr () -> IO CInt

-- Clear all registered targets
foreign import ccall unsafe "dice_clear_targets"
  c_clear_targets :: IO ()

-- Transaction management
foreign import ccall unsafe "dice_updater_new"
  c_updater_new :: EnginePtr -> IO UpdaterPtr

foreign import ccall unsafe "dice_inject_source"
  c_inject_source :: UpdaterPtr -> CString -> CSize -> CString -> CSize -> Word64 -> IO CInt

-- Note: c_commit is 'safe' because it may block waiting for async operations
foreign import ccall safe "dice_commit"
  c_commit :: RuntimePtr -> UpdaterPtr -> IO TransactionPtr

foreign import ccall unsafe "dice_updater_free"
  c_updater_free :: UpdaterPtr -> IO ()

foreign import ccall unsafe "dice_transaction_free"
  c_transaction_free :: TransactionPtr -> IO ()

-- Computation
-- Note: c_compute_action is 'safe' because it calls back into Haskell via registered callbacks
foreign import ccall safe "dice_compute_action"
  c_compute_action :: RuntimePtr -> TransactionPtr -> CString -> CSize -> IO ResultPtr

foreign import ccall unsafe "dice_result_ok"
  c_result_ok :: ResultPtr -> IO CInt

foreign import ccall unsafe "dice_result_exit_code"
  c_result_exit_code :: ResultPtr -> IO CInt

foreign import ccall unsafe "dice_result_output_count"
  c_result_output_count :: ResultPtr -> IO CSize

foreign import ccall unsafe "dice_result_output_at"
  c_result_output_at :: ResultPtr -> CSize -> Ptr CSize -> IO CString

foreign import ccall unsafe "dice_result_error"
  c_result_error :: ResultPtr -> Ptr CSize -> IO CString

foreign import ccall unsafe "dice_result_free"
  c_result_free :: ResultPtr -> IO ()

-- Utilities
foreign import ccall unsafe "dice_hash_sha256"
  c_hash_sha256 :: Ptr Word8 -> CSize -> IO CString

foreign import ccall unsafe "dice_free_string"
  c_free_string :: CString -> IO ()

foreign import ccall unsafe "dice_version"
  c_version :: IO CString

-- Callback wrapper
foreign import ccall "wrapper"
  mkComputeCallback :: ComputeCallback -> IO (FunPtr ComputeCallback)
