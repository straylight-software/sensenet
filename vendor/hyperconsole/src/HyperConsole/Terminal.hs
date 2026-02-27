{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

-- | Terminal rendering with diff-based updates
--
-- Key features:
--   - Only redraws changed lines (reduces flicker)
--   - Supports emit area (logs scroll up) and canvas area (redrawn in place)
--   - Thread-safe rendering
module HyperConsole.Terminal
  ( -- * Console
    Console,
    withConsole,
    withConsoleFallback,

    -- * Rendering
    render,
    emit,
    emitLine,
    clear,

    -- * Utilities
    getTerminalSize,
    isTerminal,
  )
where

import Control.Concurrent (MVar, modifyMVar_, newMVar, withMVar)
import Control.Exception (bracket)
import Control.Monad (forM_, unless, when)
import Data.Colour.SRGB (sRGB24)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Data.Vector qualified as V
import HyperConsole.Layout (Dimensions (..))
import HyperConsole.Style (Attr (..), Color (..), Style (..))
import HyperConsole.Widget (Canvas (..), Line, Span (..), Widget (..), runWidget)
import System.Console.ANSI qualified as ANSI
import System.IO (Handle, hFlush, hIsTerminalDevice, hPutStr, stderr)

-- | Console state for rendering
data Console = Console
  { consoleHandle :: !Handle,
    consoleLastCanvas :: !(IORef Canvas),
    consoleEmitBuffer :: !(IORef (Seq Line)),
    consoleDimensions :: !(IORef Dimensions),
    consoleLock :: !(MVar ())
  }

-- | Run an action with a console, handling setup and teardown
withConsole :: (Console -> IO a) -> IO a
withConsole action = do
  isTty <- hIsTerminalDevice stderr
  if not isTty
    then error "HyperConsole requires a TTY (stderr must be a terminal)"
    else bracket setup teardown action
  where
    setup = do
      dims <- getTerminalSize
      lastCanvas <- newIORef (Canvas V.empty dims)
      emitBuffer <- newIORef Seq.empty
      dimsRef <- newIORef dims
      lock <- newMVar ()
      ANSI.hHideCursor stderr
      pure (Console stderr lastCanvas emitBuffer dimsRef lock)

    teardown Console {..} = do
      -- Show cursor and clear any remaining canvas
      ANSI.hShowCursor consoleHandle
      oldCanvas <- readIORef consoleLastCanvas
      let h = V.length (canvasLines oldCanvas)
      when (h > 0) $ do
        ANSI.hCursorUp consoleHandle h
        ANSI.hSetCursorColumn consoleHandle 0
        ANSI.hClearFromCursorToScreenEnd consoleHandle
      hFlush consoleHandle

-- | Run with console if TTY available, otherwise use fallback
withConsoleFallback :: IO a -> (Console -> IO a) -> IO a
withConsoleFallback fallback action = do
  isTty <- hIsTerminalDevice stderr
  if isTty
    then withConsole action
    else fallback

-- | Get terminal size
getTerminalSize :: IO Dimensions
getTerminalSize = do
  mSize <- ANSI.getTerminalSize
  case mSize of
    Just (h, w) -> pure (Dimensions w h)
    Nothing -> pure (Dimensions 80 24) -- fallback

-- | Check if stderr is a terminal
isTerminal :: IO Bool
isTerminal = hIsTerminalDevice stderr

-- | Render a widget to the console
--
-- This uses diff-based rendering to minimize terminal updates:
-- 1. Emits any buffered lines (they scroll up above the canvas)
-- 2. Compares new canvas to old canvas
-- 3. Only redraws changed lines
render :: Console -> Widget -> IO ()
render Console {..} widget = withMVar consoleLock $ \_ -> do
  -- Get current dimensions
  dims <- readIORef consoleDimensions

  -- Update dimensions from terminal (in case of resize)
  newDims <- getTerminalSize
  let dimsChanged = newDims /= dims
  when dimsChanged $ do
    writeIORef consoleDimensions newDims

  let actualDims = newDims

  -- Draw widget (subtract 1 from width to prevent terminal auto-wrap on full lines)
  let newCanvas = runWidget widget (Dimensions (width actualDims - 1) (height actualDims - 1))

  -- Get old canvas for diffing
  oldCanvas <- readIORef consoleLastCanvas

  -- Get and clear emit buffer
  emitLines <- readIORef consoleEmitBuffer
  writeIORef consoleEmitBuffer Seq.empty

  -- Clear old canvas area
  let oldHeight = V.length (canvasLines oldCanvas)
  -- If dimensions changed, we can't trust oldHeight because terminal reflowed
  when (oldHeight > 1 && not dimsChanged) $ do
    ANSI.hCursorUp consoleHandle (oldHeight - 1)
  when (oldHeight > 0 && not dimsChanged) $ do
    ANSI.hSetCursorColumn consoleHandle 0

  -- Emit buffered lines (if any, invalidates old canvas for diffing)
  forM_ emitLines $ \line -> do
    renderLine consoleHandle line
    hPutStr consoleHandle "\n"
    
  let oldCanvasDiff = if null emitLines && not dimsChanged then oldCanvas else oldCanvas { canvasLines = V.empty }

  -- Render new canvas with diff optimization
  renderCanvasDiff consoleHandle oldCanvasDiff newCanvas

  -- Save new canvas
  writeIORef consoleLastCanvas newCanvas
  hFlush consoleHandle

-- | Queue a line to be emitted (scrolls up above the canvas)
emit :: Console -> Line -> IO ()
emit Console {..} line = modifyMVar_ consoleLock $ \_ -> do
  modifyIORef' consoleEmitBuffer (Seq.|> line)
  pure ()

-- | Queue plain text to be emitted
emitLine :: Console -> T.Text -> IO ()
emitLine console t = emit console (Seq.singleton (Span mempty t))

-- | Clear the canvas area
clear :: Console -> IO ()
clear Console {..} = withMVar consoleLock $ \_ -> do
  oldCanvas <- readIORef consoleLastCanvas
  let oldHeight = V.length (canvasLines oldCanvas)
  when (oldHeight > 1) $ do
    ANSI.hCursorUp consoleHandle (oldHeight - 1)
  when (oldHeight > 0) $ do
    ANSI.hSetCursorColumn consoleHandle 0
    ANSI.hClearFromCursorToScreenEnd consoleHandle
  dims <- readIORef consoleDimensions
  writeIORef consoleLastCanvas (Canvas V.empty dims)
  hFlush consoleHandle

-- ════════════════════════════════════════════════════════════════════════════
-- Internal Rendering
-- ════════════════════════════════════════════════════════════════════════════

-- | Render a single line to the terminal
renderLine :: Handle -> Line -> IO ()
renderLine h line = do
  forM_ line $ \Span {..} -> do
    applyStyle h spanStyle
    hPutStr h (T.unpack spanText)
  ANSI.hSetSGR h [ANSI.Reset]

-- | Render canvas with diff optimization
--
-- Only redraws lines that have changed.
renderCanvasDiff :: Handle -> Canvas -> Canvas -> IO ()
renderCanvasDiff h oldCanvas newCanvas = do
  let oldLines = canvasLines oldCanvas
      newLines = canvasLines newCanvas
      maxLines = max (V.length oldLines) (V.length newLines)

  forM_ [0 .. maxLines - 1] $ \i -> do
    let oldLine = if i < V.length oldLines then Just (oldLines V.! i) else Nothing
        newLine = if i < V.length newLines then Just (newLines V.! i) else Nothing

    case (oldLine, newLine) of
      (Just old, Just new)
        | old == new -> do
            -- Line unchanged, skip (but need to move cursor)
            unless (i == maxLines - 1) $ hPutStr h "\n"
      (_, Just new) -> do
        -- Line changed or new
        ANSI.hClearLine h
        renderLine h new
        unless (i == maxLines - 1) $ hPutStr h "\n"
      (Just _, Nothing) -> do
        -- Line was removed
        ANSI.hClearLine h
        unless (i == maxLines - 1) $ hPutStr h "\n"
      (Nothing, Nothing) -> pure ()

-- | Apply style SGR codes
applyStyle :: Handle -> Style -> IO ()
applyStyle h Style {..} = do
  let codes =
        [colorToSGR True styleFg | styleFg /= Default]
          ++ [colorToSGR False styleBg | styleBg /= Default]
          ++ map attrToSGR styleAttrs
  unless (null codes) $ ANSI.hSetSGR h codes

-- | Convert Color to SGR
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

-- | Convert Attr to SGR
attrToSGR :: Attr -> ANSI.SGR
attrToSGR Bold = ANSI.SetConsoleIntensity ANSI.BoldIntensity
attrToSGR Dim = ANSI.SetConsoleIntensity ANSI.FaintIntensity
attrToSGR Italic = ANSI.SetItalicized True
attrToSGR Underline = ANSI.SetUnderlining ANSI.SingleUnderline
attrToSGR Blink = ANSI.SetBlinkSpeed ANSI.SlowBlink
attrToSGR Reverse = ANSI.SetSwapForegroundBackground True
attrToSGR Strikethrough = ANSI.SetConsoleIntensity ANSI.NormalIntensity -- approximation
