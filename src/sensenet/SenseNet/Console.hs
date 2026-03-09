{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | High-level interface to superconsole for Buck2-style build output.
--
-- This module provides a TUI for displaying build progress with:
-- - Progress bar showing completion percentage
-- - List of currently running actions with elapsed time
-- - Ability to emit completed actions above the progress display
--
-- Example usage:
--
-- @
-- import SenseNet.Console
--
-- main = do
--   withBuildConsole $ \console -> do
--     updateProgress console 10 0 0 0  -- 10 total actions
--     addAction console 1 "Building foo.o"
--     threadDelay 1000000
--     removeAction console 1
--     updateProgress console 10 1 0 0
-- @
module SenseNet.Console
  ( -- * Console Handle
    Console,
    BuildProgress,

    -- * Lifecycle
    compatible,
    new,
    newForced,
    withConsole,
    withBuildConsole,

    -- * Rendering
    render,
    finalize,
    clear,

    -- * Output
    emit,
    emitLine,

    -- * Build Progress
    newBuildProgress,
    updateProgress,
    addAction,
    removeAction,
    clearActions,
    renderProgress,

    -- * Color Constants
    Color (..),
    green,
    red,
    yellow,
    blue,
    cyan,
    magenta,
    white,
    defaultColor,
  )
where

import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe (unsafeUseAsCStringLen)
import Data.IORef
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Word (Word32, Word64)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (pokeArray)
import Foreign.Ptr (nullPtr)
import SenseNet.Console.FFI qualified as FFI

-- ═══════════════════════════════════════════════════════════════════════════
-- Types
-- ═══════════════════════════════════════════════════════════════════════════

-- | Handle to a SuperConsole instance
newtype Console = Console {consolePtr :: FFI.SuperConsolePtr}

-- | Handle to a build progress component
data BuildProgress = BuildProgress
  { progressPtr :: FFI.ComponentPtr,
    tickRef :: IORef Word64
  }

-- | ANSI 256-color code
newtype Color = Color CInt

-- ═══════════════════════════════════════════════════════════════════════════
-- Colors
-- ═══════════════════════════════════════════════════════════════════════════

green, red, yellow, blue, cyan, magenta, white, defaultColor :: Color
green = Color 2
red = Color 1
yellow = Color 3
blue = Color 4
cyan = Color 6
magenta = Color 5
white = Color 7
defaultColor = Color (-1)

-- ═══════════════════════════════════════════════════════════════════════════
-- Console Lifecycle
-- ═══════════════════════════════════════════════════════════════════════════

-- | Check if the terminal is compatible with superconsole
compatible :: IO Bool
compatible = do
  result <- FFI.c_superconsole_compatible
  pure (result == 1)

-- | Create a new console (returns Nothing if terminal incompatible)
new :: IO (Maybe Console)
new = do
  ptr <- FFI.c_superconsole_new
  if ptr == nullPtr
    then pure Nothing
    else pure (Just (Console ptr))

-- | Create a console with forced dimensions (for non-TTY environments)
newForced :: Word32 -> Word32 -> IO Console
newForced width height = do
  ptr <- FFI.c_superconsole_forced_new width height
  pure (Console ptr)

-- | Run action with a console, automatically finalizing on exit
withConsole :: (Console -> IO a) -> IO (Maybe a)
withConsole action = do
  mConsole <- new
  case mConsole of
    Nothing -> pure Nothing
    Just console -> do
      result <- action console
      -- Create a blank component for finalization
      blankPtr <- FFI.c_component_blank
      _ <- FFI.c_superconsole_finalize (consolePtr console) blankPtr
      pure (Just result)

-- | Run action with a build progress console
withBuildConsole :: (Console -> BuildProgress -> IO a) -> IO (Maybe a)
withBuildConsole action = do
  mConsole <- new
  case mConsole of
    Nothing -> pure Nothing
    Just console -> do
      progress <- newBuildProgress
      result <- action console progress
      -- Final render
      _ <- FFI.c_superconsole_finalize (consolePtr console) (progressPtr progress)
      pure (Just result)

-- ═══════════════════════════════════════════════════════════════════════════
-- Rendering
-- ═══════════════════════════════════════════════════════════════════════════

-- | Render a component to the console
render :: Console -> FFI.ComponentPtr -> IO Bool
render console component = do
  result <- FFI.c_superconsole_render (consolePtr console) component
  pure (result == 0)

-- | Finalize the console (final render, consumes the console)
finalize :: Console -> FFI.ComponentPtr -> IO Bool
finalize console component = do
  result <- FFI.c_superconsole_finalize (consolePtr console) component
  pure (result == 0)

-- | Clear the canvas area
clear :: Console -> IO Bool
clear console = do
  result <- FFI.c_superconsole_clear (consolePtr console)
  pure (result == 0)

-- ═══════════════════════════════════════════════════════════════════════════
-- Output
-- ═══════════════════════════════════════════════════════════════════════════

-- | Emit text above the canvas (for completed action logs)
emit :: Console -> Text -> IO ()
emit console text = emitBS console (TE.encodeUtf8 text)

-- | Emit a line above the canvas
emitLine :: Console -> Text -> IO ()
emitLine console text = emit console (text <> "\n")

-- | Emit raw bytes
emitBS :: Console -> ByteString -> IO ()
emitBS console bs =
  unsafeUseAsCStringLen bs $ \(cstr, len) ->
    FFI.c_superconsole_emit_str (consolePtr console) cstr (fromIntegral len)

-- ═══════════════════════════════════════════════════════════════════════════
-- Build Progress
-- ═══════════════════════════════════════════════════════════════════════════

-- | Create a new build progress component
newBuildProgress :: IO BuildProgress
newBuildProgress = do
  ptr <- FFI.c_component_build_progress
  tickRef <- newIORef 0
  pure BuildProgress {progressPtr = ptr, tickRef = tickRef}

-- | Update build progress statistics
updateProgress ::
  BuildProgress ->
  Word32 -> -- total actions
  Word32 -> -- completed
  Word32 -> -- running
  Word32 -> -- cached
  IO ()
updateProgress progress total completed running cached =
  FFI.c_build_progress_update (progressPtr progress) total completed running cached

-- | Add an action to the running list
addAction ::
  BuildProgress ->
  Word64 -> -- action ID
  Text -> -- action name
  Word64 -> -- elapsed milliseconds
  IO ()
addAction progress actionId name elapsedMs = do
  let bs = TE.encodeUtf8 name
  unsafeUseAsCStringLen bs $ \(cstr, len) ->
    FFI.c_build_progress_add_action
      (progressPtr progress)
      actionId
      cstr
      (fromIntegral len)
      elapsedMs

-- | Remove an action from the running list
removeAction :: BuildProgress -> Word64 -> IO ()
removeAction progress actionId =
  FFI.c_build_progress_remove_action (progressPtr progress) actionId

-- | Clear all running actions
clearActions :: BuildProgress -> IO ()
clearActions progress =
  FFI.c_build_progress_clear_actions (progressPtr progress)

-- | Render the build progress to the console
renderProgress :: Console -> BuildProgress -> IO Bool
renderProgress console progress = do
  -- Increment tick for animations
  modifyIORef' (tickRef progress) (+ 1)
  render console (progressPtr progress)
