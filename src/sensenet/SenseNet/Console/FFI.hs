{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

-- | Low-level FFI bindings to superconsole. Internal module - do not use directly.
--
-- Use "SenseNet.Console" for the public API.
module SenseNet.Console.FFI
  ( -- * Raw handle pointers
    SuperConsolePtr,
    LinesPtr,
    ComponentPtr,

    -- * SuperConsole lifecycle
    c_superconsole_compatible,
    c_superconsole_new,
    c_superconsole_forced_new,
    c_superconsole_free,

    -- * Rendering
    c_superconsole_render,
    c_superconsole_finalize,
    c_superconsole_clear,

    -- * Emitting output
    c_superconsole_emit,
    c_superconsole_emit_str,

    -- * Lines construction
    c_lines_new,
    c_lines_free,
    c_lines_push_str,
    c_lines_push_styled,
    c_lines_len,

    -- * Components
    c_component_echo,
    c_component_spinner,
    c_component_blank,
    c_component_free,
    c_component_vertical,
    c_component_horizontal,
    c_component_padded,
    c_component_bordered,

    -- * Build Progress Component
    c_component_build_progress,
    c_build_progress_update,
    c_build_progress_add_action,
    c_build_progress_remove_action,
    c_build_progress_clear_actions,
  )
where

import Data.Word (Word32, Word64)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr)

-- | Opaque pointer types for type safety at FFI boundary
type SuperConsolePtr = Ptr ()

type LinesPtr = Ptr ()

type ComponentPtr = Ptr ()

-- ═══════════════════════════════════════════════════════════════════════════
-- SuperConsole Lifecycle
-- ═══════════════════════════════════════════════════════════════════════════

foreign import ccall unsafe "superconsole_compatible"
  c_superconsole_compatible :: IO CInt

foreign import ccall unsafe "superconsole_new"
  c_superconsole_new :: IO SuperConsolePtr

foreign import ccall unsafe "superconsole_forced_new"
  c_superconsole_forced_new :: Word32 -> Word32 -> IO SuperConsolePtr

foreign import ccall unsafe "superconsole_free"
  c_superconsole_free :: SuperConsolePtr -> IO ()

-- ═══════════════════════════════════════════════════════════════════════════
-- Rendering
-- ═══════════════════════════════════════════════════════════════════════════

foreign import ccall unsafe "superconsole_render"
  c_superconsole_render :: SuperConsolePtr -> ComponentPtr -> IO CInt

-- Note: finalize consumes the superconsole, so this is 'safe' to prevent
-- any further use after return
foreign import ccall safe "superconsole_finalize"
  c_superconsole_finalize :: SuperConsolePtr -> ComponentPtr -> IO CInt

foreign import ccall unsafe "superconsole_clear"
  c_superconsole_clear :: SuperConsolePtr -> IO CInt

-- ═══════════════════════════════════════════════════════════════════════════
-- Emitting Output
-- ═══════════════════════════════════════════════════════════════════════════

-- | Emit lines above the canvas (transfers ownership)
foreign import ccall unsafe "superconsole_emit"
  c_superconsole_emit :: SuperConsolePtr -> LinesPtr -> IO ()

foreign import ccall unsafe "superconsole_emit_str"
  c_superconsole_emit_str :: SuperConsolePtr -> CString -> CSize -> IO ()

-- ═══════════════════════════════════════════════════════════════════════════
-- Lines Construction
-- ═══════════════════════════════════════════════════════════════════════════

foreign import ccall unsafe "lines_new"
  c_lines_new :: IO LinesPtr

foreign import ccall unsafe "lines_free"
  c_lines_free :: LinesPtr -> IO ()

foreign import ccall unsafe "lines_push_str"
  c_lines_push_str :: LinesPtr -> CString -> CSize -> IO CInt

-- | Push styled text line
-- fg_color, bg_color: ANSI 256-color code, -1 for default
-- bold: 1 for bold, 0 for normal
foreign import ccall unsafe "lines_push_styled"
  c_lines_push_styled :: LinesPtr -> CString -> CSize -> CInt -> CInt -> CInt -> IO CInt

foreign import ccall unsafe "lines_len"
  c_lines_len :: LinesPtr -> IO CSize

-- ═══════════════════════════════════════════════════════════════════════════
-- Components
-- ═══════════════════════════════════════════════════════════════════════════

-- | Create echo component from lines (transfers ownership)
foreign import ccall unsafe "component_echo"
  c_component_echo :: LinesPtr -> IO ComponentPtr

foreign import ccall unsafe "component_spinner"
  c_component_spinner :: CString -> CSize -> Word64 -> IO ComponentPtr

foreign import ccall unsafe "component_blank"
  c_component_blank :: IO ComponentPtr

foreign import ccall unsafe "component_free"
  c_component_free :: ComponentPtr -> IO ()

-- | Stack components vertically (transfers ownership of all components)
foreign import ccall unsafe "component_vertical"
  c_component_vertical :: Ptr ComponentPtr -> CSize -> IO ComponentPtr

-- | Stack components horizontally (transfers ownership)
foreign import ccall unsafe "component_horizontal"
  c_component_horizontal :: Ptr ComponentPtr -> CSize -> IO ComponentPtr

foreign import ccall unsafe "component_padded"
  c_component_padded :: ComponentPtr -> Word32 -> Word32 -> Word32 -> Word32 -> IO ComponentPtr

foreign import ccall unsafe "component_bordered"
  c_component_bordered :: ComponentPtr -> IO ComponentPtr

-- ═══════════════════════════════════════════════════════════════════════════
-- Build Progress Component
-- ═══════════════════════════════════════════════════════════════════════════

foreign import ccall unsafe "component_build_progress"
  c_component_build_progress :: IO ComponentPtr

foreign import ccall unsafe "build_progress_update"
  c_build_progress_update :: ComponentPtr -> Word32 -> Word32 -> Word32 -> Word32 -> IO ()

foreign import ccall unsafe "build_progress_add_action"
  c_build_progress_add_action :: ComponentPtr -> Word64 -> CString -> CSize -> Word64 -> IO ()

foreign import ccall unsafe "build_progress_remove_action"
  c_build_progress_remove_action :: ComponentPtr -> Word64 -> IO ()

foreign import ccall unsafe "build_progress_clear_actions"
  c_build_progress_clear_actions :: ComponentPtr -> IO ()
