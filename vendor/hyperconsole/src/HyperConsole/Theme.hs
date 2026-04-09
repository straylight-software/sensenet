{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Straylight Theme — tasteful defaults for terminal UI
--
-- "The sky above the port was the color of television,
--  tuned to a dead channel."
--
--                                      — Neuromancer
--
-- = Design Philosophy
--
-- The straylight aesthetic is defined by:
--
--   * __Restraint__ — Minimal color, maximum clarity
--   * __Cool tones__ — Cyan primary, warmth reserved for warnings
--   * __Hierarchy__ — Dim for secondary, bright for primary
--   * __Monospace harmony__ — Typography that breathes
--
-- = Color Palette
--
-- The palette derives from Nord, adapted for terminals:
--
-- @
-- ┌────────────┬────────────┬────────────────────────────────┐
-- │ Name       │ Hex        │ Usage                          │
-- ├────────────┼────────────┼────────────────────────────────┤
-- │ polar0     │ #2E3440    │ Background (dark)              │
-- │ polar1     │ #3B4252    │ Elevated surfaces              │
-- │ polar2     │ #434C5E    │ Borders, subtle                │
-- │ polar3     │ #4C566A    │ Comments, muted text           │
-- │ snow0      │ #D8DEE9    │ Primary text                   │
-- │ snow1      │ #E5E9F0    │ Subtle emphasis                │
-- │ snow2      │ #ECEFF4    │ High emphasis                  │
-- │ frost0     │ #8FBCBB    │ Accent, teal                   │
-- │ frost1     │ #88C0D0    │ Primary action, cyan           │
-- │ frost2     │ #81A1C1    │ Secondary action, blue         │
-- │ frost3     │ #5E81AC    │ Tertiary, deep blue            │
-- │ aurora0    │ #BF616A    │ Error, red                     │
-- │ aurora1    │ #D08770    │ Warning, orange                │
-- │ aurora2    │ #EBCB8B    │ Caution, yellow                │
-- │ aurora3    │ #A3BE8C    │ Success, green                 │
-- │ aurora4    │ #B48EAD    │ Special, purple                │
-- └────────────┴────────────┴────────────────────────────────┘
-- @
--
-- = Usage
--
-- @
-- import HyperConsole.Theme
--
-- -- Semantic styles adapt to meaning
-- textStyled themeSuccess "Build complete"
-- textStyled themeError "Build failed"
--
-- -- Direct palette access for custom needs
-- textStyled (fg frost1) "Custom cyan text"
-- @
module HyperConsole.Theme
  ( -- * Palette — Nord Colors
    -- $palette
    polar0,
    polar1,
    polar2,
    polar3,
    snow0,
    snow1,
    snow2,
    frost0,
    frost1,
    frost2,
    frost3,
    aurora0,
    aurora1,
    aurora2,
    aurora3,
    aurora4,

    -- * Palette — Razorgirl Colors
    razorBg,
    razorSurface,
    razorMuted,
    razorInfo,
    razorBright,
    razorAccent,
    razorDim,
    razorRule,
    razorMiss,
    razorHit,
    razorCached,
    razorExec,

    -- * Semantic Styles
    -- $semantic
    themePrimary,
    themeSecondary,
    themeTertiary,
    themeAccent,
    themeSuccess,
    themeWarning,
    themeError,
    themeMuted,
    themeSubtle,

    -- * UI Element Styles
    -- $elements
    themeBorder,
    themeBorderActive,
    themeTitle,
    themeLabel,
    themeValue,
    themeSelected,
    themeHeader,
    themePlaceholder,

    -- * Progress Styles
    themeProgressFilled,
    themeProgressEmpty,
    themeProgressText,
    themeSpinner,

    -- * Status Styles
    themeStatusOk,
    themeStatusPending,
    themeStatusFailed,
    themeStatusCached,
    themeStatusSkipped,

    -- * Box Drawing
    -- $boxdrawing
    boxLight,
    boxHeavy,
    boxDouble,
    boxRounded,
    boxAscii,

    -- * Glyphs
    -- $glyphs
    glyphCheck,
    glyphCross,
    glyphArrow,
    glyphArrowRight,
    glyphArrowDown,
    glyphBullet,
    glyphDot,
    glyphSpinner,
    glyphProgress,
    glyphProgressEmpty,
    glyphProgressPartial,
    glyphCached,
    glyphBuilding,
    glyphPending,
    glyphInfo,
    glyphWarning,
    glyphError,

    -- * Typography
    -- $typography
    em,
    nbsp,
    thinSpace,
    hairSpace,
    enDash,
    emDash,
    ellipsis,
  )
where

import Data.Text (Text)
import Data.Word (Word8)
import HyperConsole.Style

-- ════════════════════════════════════════════════════════════════════════════
-- Palette — Nord-derived colors
-- ════════════════════════════════════════════════════════════════════════════

-- $palette
-- The straylight palette is derived from Nord, a arctic, north-bluish
-- color palette. These are the raw colors — use semantic styles when possible.
--
-- True-color (24-bit) RGB values for modern terminals.

-- | Polar Night — dark backgrounds
--
-- The darkest colors, used for backgrounds and contrast.

-- | @#2E3440@ — Base background
polar0 :: Style
polar0 = rgb8 0x2E 0x34 0x40

-- | @#3B4252@ — Elevated surface (panels, cards)
polar1 :: Style
polar1 = rgb8 0x3B 0x42 0x52

-- | @#434C5E@ — Borders, separators
polar2 :: Style
polar2 = rgb8 0x43 0x4C 0x5E

-- | @#4C566A@ — Comments, disabled, muted
polar3 :: Style
polar3 = rgb8 0x4C 0x56 0x6A

-- | Snow Storm — light text
--
-- Light colors for text on dark backgrounds.

-- | @#D8DEE9@ — Primary text
snow0 :: Style
snow0 = rgb8 0xD8 0xDE 0xE9

-- | @#E5E9F0@ — Emphasized text
snow1 :: Style
snow1 = rgb8 0xE5 0xE9 0xF0

-- | @#ECEFF4@ — High emphasis, headings
snow2 :: Style
snow2 = rgb8 0xEC 0xEF 0xF4

-- | Frost — cool accent colors
--
-- The signature straylight colors — various shades of blue/cyan.

-- | @#8FBCBB@ — Teal accent
frost0 :: Style
frost0 = rgb8 0x8F 0xBC 0xBB

-- | @#88C0D0@ — Cyan primary — the straylight signature
frost1 :: Style
frost1 = rgb8 0x88 0xC0 0xD0

-- | @#81A1C1@ — Blue secondary
frost2 :: Style
frost2 = rgb8 0x81 0xA1 0xC1

-- | @#5E81AC@ — Deep blue tertiary
frost3 :: Style
frost3 = rgb8 0x5E 0x81 0xAC

-- | Aurora — warm accent colors
--
-- Used sparingly for status and attention.

-- | @#BF616A@ — Error red
aurora0 :: Style
aurora0 = rgb8 0xBF 0x61 0x6A

-- | @#D08770@ — Warning orange
aurora1 :: Style
aurora1 = rgb8 0xD0 0x87 0x70

-- | @#EBCB8B@ — Caution yellow
aurora2 :: Style
aurora2 = rgb8 0xEB 0xCB 0x8B

-- | @#A3BE8C@ — Success green
aurora3 :: Style
aurora3 = rgb8 0xA3 0xBE 0x8C

-- | @#B48EAD@ — Special purple
aurora4 :: Style
aurora4 = rgb8 0xB4 0x8E 0xAD

-- | Helper for RGB colors
rgb8 :: Word8 -> Word8 -> Word8 -> Style
rgb8 r g b = fg (RGB r g b)

-- ════════════════════════════════════════════════════════════════════════════
-- Ono-Sendai Razorgirl Palette
-- ════════════════════════════════════════════════════════════════════════════

-- | Razorgirl palette — darker, sharper aesthetic
--
-- Derived from the ono-sendai console aesthetic:
-- Darker backgrounds, sharper blues, minimal color.

-- | @#111417@ — Deep background
razorBg :: Style
razorBg = rgb8 0x11 0x14 0x17

-- | @#1a1e23@ — Surface (cards, panels)
razorSurface :: Style
razorSurface = rgb8 0x1a 0x1e 0x23

-- | @#596775@ — Muted text
razorMuted :: Style
razorMuted = rgb8 0x59 0x67 0x75

-- | @#80ccff@ — Info blue
razorInfo :: Style
razorInfo = rgb8 0x80 0xcc 0xff

-- | @#b6e3ff@ — Bright text
razorBright :: Style
razorBright = rgb8 0xb6 0xe3 0xff

-- | @#54aeff@ — Accent blue
razorAccent :: Style
razorAccent = rgb8 0x54 0xae 0xff

-- | @#2a3340@ — Dim elements
razorDim :: Style
razorDim = rgb8 0x2a 0x33 0x40

-- | @#242a32@ — Rules, borders
razorRule :: Style
razorRule = rgb8 0x24 0x2a 0x32

-- | @#ff6b6b@ — Miss/error red
razorMiss :: Style
razorMiss = rgb8 0xff 0x6b 0x6b

-- | @#3fb950@ — Hit/success green
razorHit :: Style
razorHit = rgb8 0x3f 0xb9 0x50

-- | @#8b949e@ — Cached/neutral gray
razorCached :: Style
razorCached = rgb8 0x8b 0x94 0x9e

-- | @#d29922@ — Executing/active amber
razorExec :: Style
razorExec = rgb8 0xd2 0x99 0x22

-- ════════════════════════════════════════════════════════════════════════════
-- Semantic Styles
-- ════════════════════════════════════════════════════════════════════════════

-- $semantic
-- Semantic styles convey meaning. Use these instead of raw colors
-- so the theme can be changed consistently.

-- | Primary content — main text, important values
--
-- Snow white on dark terminals. The default reading experience.
themePrimary :: Style
themePrimary = snow0

-- | Secondary content — supporting info, metadata
--
-- Muted but legible. Timestamps, paths, context.
themeSecondary :: Style
themeSecondary = polar3

-- | Tertiary content — even more subdued
--
-- Decorative elements, de-emphasized info.
themeTertiary :: Style
themeTertiary = dim polar3

-- | Accent — primary action color
--
-- Frost cyan. The straylight signature. Use for:
-- * In-progress operations
-- * Interactive elements
-- * Links and calls to action
themeAccent :: Style
themeAccent = frost1

-- | Success — completion, confirmation
--
-- Aurora green. Use sparingly:
-- * Build succeeded
-- * Tests passed
-- * Action completed
themeSuccess :: Style
themeSuccess = aurora3

-- | Warning — caution, non-blocking
--
-- Aurora orange. Draws attention without alarm:
-- * Deprecation notices
-- * Performance warnings
-- * Things that need attention
themeWarning :: Style
themeWarning = aurora1

-- | Error — failure, blocking
--
-- Aurora red. The only "loud" color:
-- * Build failed
-- * Test failed
-- * Fatal error
themeError :: Style
themeError = aurora0

-- | Muted — structural, decorative
--
-- Dim polar. For structure that shouldn't compete:
-- * Borders
-- * Separators
-- * Background elements
themeMuted :: Style
themeMuted = polar2

-- | Subtle — barely visible structural elements
--
-- Even more subdued than muted.
themeSubtle :: Style
themeSubtle = dim polar2

-- ════════════════════════════════════════════════════════════════════════════
-- UI Element Styles
-- ════════════════════════════════════════════════════════════════════════════

-- $elements
-- Styles for common UI elements.

-- | Border — box drawing characters
themeBorder :: Style
themeBorder = polar2

-- | Active border — focused element
themeBorderActive :: Style
themeBorderActive = frost2

-- | Title — section headings
themeTitle :: Style
themeTitle = bold snow2

-- | Label — keys in key-value pairs
themeLabel :: Style
themeLabel = polar3

-- | Value — values in key-value pairs
themeValue :: Style
themeValue = snow0

-- | Selected — highlighted list item
themeSelected :: Style
themeSelected = bold frost1 <> bg (RGB 0x3B 0x42 0x52)

-- | Header — table headers, column names
themeHeader :: Style
themeHeader = bold frost2

-- | Placeholder — empty state, hints
themePlaceholder :: Style
themePlaceholder = italic polar3

-- ════════════════════════════════════════════════════════════════════════════
-- Progress Styles
-- ════════════════════════════════════════════════════════════════════════════

-- | Filled portion of progress bar
themeProgressFilled :: Style
themeProgressFilled = frost1

-- | Empty portion of progress bar
themeProgressEmpty :: Style
themeProgressEmpty = polar2

-- | Progress text (percentage, counts)
themeProgressText :: Style
themeProgressText = polar3

-- | Spinner — animated indicator
themeSpinner :: Style
themeSpinner = frost1

-- ════════════════════════════════════════════════════════════════════════════
-- Status Styles
-- ════════════════════════════════════════════════════════════════════════════

-- | OK/success status
themeStatusOk :: Style
themeStatusOk = aurora3

-- | Pending/in-progress status
themeStatusPending :: Style
themeStatusPending = frost1

-- | Failed status
themeStatusFailed :: Style
themeStatusFailed = aurora0

-- | Cached/reused status
themeStatusCached :: Style
themeStatusCached = frost0

-- | Skipped/not applicable
themeStatusSkipped :: Style
themeStatusSkipped = polar3

-- ════════════════════════════════════════════════════════════════════════════
-- Box Drawing
-- ════════════════════════════════════════════════════════════════════════════

-- $boxdrawing
-- Unicode box drawing character sets.
-- Tuple order: (topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight)

-- | Light — single line, clean
--
-- @
-- ┌──────┐
-- │      │
-- └──────┘
-- @
boxLight :: (Char, Char, Char, Char, Char, Char, Char, Char)
boxLight = ('┌', '─', '┐', '│', '│', '└', '─', '┘')

-- | Heavy — thick lines, emphasis
--
-- @
-- ┏━━━━━━┓
-- ┃      ┃
-- ┗━━━━━━┛
-- @
boxHeavy :: (Char, Char, Char, Char, Char, Char, Char, Char)
boxHeavy = ('┏', '━', '┓', '┃', '┃', '┗', '━', '┛')

-- | Double — formal, documents
--
-- @
-- ╔══════╗
-- ║      ║
-- ╚══════╝
-- @
boxDouble :: (Char, Char, Char, Char, Char, Char, Char, Char)
boxDouble = ('╔', '═', '╗', '║', '║', '╚', '═', '╝')

-- | Rounded — soft, friendly
--
-- @
-- ╭──────╮
-- │      │
-- ╰──────╯
-- @
boxRounded :: (Char, Char, Char, Char, Char, Char, Char, Char)
boxRounded = ('╭', '─', '╮', '│', '│', '╰', '─', '╯')

-- | ASCII — fallback for limited fonts
--
-- @
-- +------+
-- |      |
-- +------+
-- @
boxAscii :: (Char, Char, Char, Char, Char, Char, Char, Char)
boxAscii = ('+', '-', '+', '|', '|', '+', '-', '+')

-- ════════════════════════════════════════════════════════════════════════════
-- Glyphs
-- ════════════════════════════════════════════════════════════════════════════

-- $glyphs
-- Unicode glyphs for UI elements. Chosen for:
--
-- * Wide font support (Nerd Fonts not required)
-- * Clear meaning at terminal sizes
-- * Visual harmony in monospace

-- | Success checkmark
glyphCheck :: Text
glyphCheck = "✓"

-- | Failure cross
glyphCross :: Text
glyphCross = "✗"

-- | Generic arrow
glyphArrow :: Text
glyphArrow = "→"

-- | Right-pointing arrow
glyphArrowRight :: Text
glyphArrowRight = "›"

-- | Down-pointing arrow
glyphArrowDown :: Text
glyphArrowDown = "↓"

-- | List bullet
glyphBullet :: Text
glyphBullet = "•"

-- | Small dot (for subtle markers)
glyphDot :: Text
glyphDot = "·"

-- | Spinner frames — Braille pattern
--
-- Smooth 10-frame rotation:
-- @⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏@
glyphSpinner :: Text
glyphSpinner = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

-- | Progress bar filled segment
glyphProgress :: Text
glyphProgress = "━"

-- | Progress bar empty segment
glyphProgressEmpty :: Text
glyphProgressEmpty = "─"

-- | Progress bar partial (half-filled)
glyphProgressPartial :: Text
glyphProgressPartial = "╸"

-- | Cached/reused indicator
glyphCached :: Text
glyphCached = "◆"

-- | Building/in-progress indicator
glyphBuilding :: Text
glyphBuilding = "◇"

-- | Pending/waiting indicator
glyphPending :: Text
glyphPending = "○"

-- | Info indicator
glyphInfo :: Text
glyphInfo = "ℹ"

-- | Warning indicator
glyphWarning :: Text
glyphWarning = "⚠"

-- | Error indicator
glyphError :: Text
glyphError = "✗"

-- ════════════════════════════════════════════════════════════════════════════
-- Typography
-- ════════════════════════════════════════════════════════════════════════════

-- $typography
-- Typography helpers for proper spacing and punctuation.
-- Monospace fonts benefit from careful spacing choices.

-- | Emphasis — use sparingly
em :: Text -> Text
em t = "*" <> t <> "*"

-- | Non-breaking space — keeps words together
nbsp :: Text
nbsp = "\x00A0"

-- | Thin space — subtle separation
thinSpace :: Text
thinSpace = "\x2009"

-- | Hair space — minimal separation
hairSpace :: Text
hairSpace = "\x200A"

-- | En dash — ranges (1–10)
enDash :: Text
enDash = "–"

-- | Em dash — breaks, asides
emDash :: Text
emDash = "—"

-- | Ellipsis — single character, not three dots
ellipsis :: Text
ellipsis = "…"
