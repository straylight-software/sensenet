{-# LANGUAGE OverloadedStrings #-}

-- | HyperConsole - A strictly better superconsole
--
-- "The deck was empty. Nine Hermes rifle cases, plain and rectangular,
--  like coffins of burnished saddle hide."
--
--                                              — Mona Lisa Overdrive
--
-- = Overview
--
-- HyperConsole is a cleanroom terminal UI library that improves upon
-- Meta's superconsole with:
--
--   * __Incremental rendering__ - Only redraws changed lines (zero flicker)
--   * __Unicode support__ - Proper handling of wide characters and grapheme clusters
--   * __Flexbox layout__ - Constraint-based layout engine (no manual dimension threading)
--   * __Composable widgets__ - Clean widget composition with decorators
--   * __Pure core__ - Pure functional rendering with IO at the edges
--   * __io_uring backend__ - Single-syscall frame writes via writev
--
-- = Quick Start
--
-- @
-- import HyperConsole
--
-- main :: IO ()
-- main = withConsole $ \\console -> do
--   let widget = vbox
--         [ text "Building..."
--         , progress (fg Green) (fg BrightBlack) 0.75
--         , spinner (fg Cyan) tick
--         ]
--   render console widget
-- @
--
-- = Architecture
--
-- The library is organized into layers:
--
--   * "HyperConsole.Style" - Colors and text attributes
--   * "HyperConsole.Layout" - Flexbox-like constraint solver
--   * "HyperConsole.Widget" - Composable widget system
--   * "HyperConsole.Terminal" - Diff-based terminal rendering (ansi-terminal)
--   * "HyperConsole.Terminal.IoUring" - io_uring/writev backend (Linux)
--   * "HyperConsole.Terminal.Evring" - Full evring integration
--   * "HyperConsole.Unicode" - Wide character handling
--
-- = Performance
--
-- Traditional terminal rendering: N write() syscalls per frame
-- HyperConsole with IoUring: 1 writev() syscall per frame
--
-- For a typical 80x24 terminal with styled text:
--
--   * Traditional: ~100-500 syscalls/frame
--   * HyperConsole: 1 syscall/frame
--   * Speedup: 10-50x reduction in syscall overhead
--
-- = Comparison with superconsole
--
-- +----------------------+----------------+----------------+
-- | Feature              | superconsole   | HyperConsole   |
-- +----------------------+----------------+----------------+
-- | Incremental render   | No             | Yes (diff)     |
-- | Unicode width        | Basic          | Full (UAX #11) |
-- | Layout engine        | Manual         | Flexbox        |
-- | Widget composition   | Basic          | Decorators     |
-- | Syscalls/frame       | N              | 1 (writev)     |
-- | Language             | Rust           | Haskell        |
-- +----------------------+----------------+----------------+
module HyperConsole
  ( -- * Terminal Console
    Console,
    withConsole,
    withConsoleFallback,
    render,
    emit,
    emitLine,
    clear,

    -- * Widgets
    Widget (..),
    Canvas (..),
    Span (..),
    Line,

    -- ** Basic widgets
    text,
    textStyled,
    textMultiline,
    char,
    empty,
    space,
    fill,
    rule,

    -- ** Layout containers
    hbox,
    vbox,
    hboxWith,
    vboxWith,
    labeled,
    (<+>),
    layers,
    conditional,

    -- ** Decorators
    padded,
    paddedUniform,
    bordered,
    borderedWith,
    borderedStyled,
    titled,
    fixed,
    minSize,
    maxSize,
    centered,
    alignRight,
    alignBottom,

    -- ** Common widgets
    spinner,
    spinnerStyle,
    progress,
    progressBar,
    progressBarLabeled,
    table,
    tableStyled,
    list,
    tree,
    sparkline,
    gauge,
    statusLine,
    mapCanvas,

    -- * Layout
    Dimensions (..),
    Position (..),
    Direction (..),
    Alignment (..),
    Constraint (..),
    Layout (..),
    defaultLayout,
    vstack,
    hstack,
    solve,

    -- * Styling
    Style (..),
    Color (..),
    Attr (..),
    defaultStyle,
    bold,
    dim,
    italic,
    underline,
    fg,
    bg,
    rgb,

    -- * Straylight Theme

    -- | Tasteful defaults based on straylight typography.
    -- See "HyperConsole.Theme" for documentation.
    themePrimary,
    themeSecondary,
    themeAccent,
    themeSuccess,
    themeWarning,
    themeError,
    themeMuted,
    themeBorder,
    themeTitle,
    themeLabel,
    themeValue,
    themeSelected,
    themeHeader,
    themeProgressFilled,
    themeProgressEmpty,
    themeSpinner,
    themeStatusOk,
    themeStatusPending,
    themeStatusFailed,
    themeStatusCached,
    boxLight,
    boxHeavy,
    boxDouble,
    boxRounded,
    glyphCheck,
    glyphCross,
    glyphArrow,
    glyphBullet,
    glyphSpinner,
    glyphProgress,
    glyphProgressEmpty,
    glyphCached,
    glyphBuilding,

    -- * Unicode utilities
    displayWidth,
    charWidth,
    truncateText,
    wrapText,
    padRight,
    padLeft,
    center,

    -- * Terminal utilities
    getTerminalSize,
    isTerminal,
  )
where

import HyperConsole.Layout
import HyperConsole.Style
import HyperConsole.Terminal
import HyperConsole.Theme
import HyperConsole.Unicode
import HyperConsole.Widget
