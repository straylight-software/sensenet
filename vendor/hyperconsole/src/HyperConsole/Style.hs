{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE StrictData #-}

-- | Terminal styling (colors and attributes)
module HyperConsole.Style
  ( -- * Colors
    Color (..),

    -- * Attributes
    Attr (..),

    -- * Styles
    Style (..),
    defaultStyle,

    -- * Builders
    bold,
    dim,
    italic,
    underline,
    fg,
    bg,
    rgb,
  )
where

import Data.Word (Word8)

-- | 8-bit or 24-bit color
data Color
  = Default
  | Black
  | Red
  | Green
  | Yellow
  | Blue
  | Magenta
  | Cyan
  | White
  | BrightBlack
  | BrightRed
  | BrightGreen
  | BrightYellow
  | BrightBlue
  | BrightMagenta
  | BrightCyan
  | BrightWhite
  | Color256 !Word8
  | RGB !Word8 !Word8 !Word8
  deriving stock (Eq, Show, Ord)

-- | Text attributes
data Attr
  = Bold
  | Dim
  | Italic
  | Underline
  | Blink
  | Reverse
  | Strikethrough
  deriving stock (Eq, Show, Ord)

-- | Style combining foreground, background, and attributes
data Style = Style
  { styleFg :: !Color,
    styleBg :: !Color,
    styleAttrs :: ![Attr]
  }
  deriving stock (Eq, Show)

-- | Semigroup: later styles override earlier
instance Semigroup Style where
  s1 <> s2 =
    Style
      { styleFg = if styleFg s2 == Default then styleFg s1 else styleFg s2,
        styleBg = if styleBg s2 == Default then styleBg s1 else styleBg s2,
        styleAttrs = styleAttrs s1 ++ styleAttrs s2
      }

instance Monoid Style where
  mempty = defaultStyle

-- | Default style (no colors, no attributes)
defaultStyle :: Style
defaultStyle = Style Default Default []

-- | Add bold attribute
bold :: Style -> Style
bold s = s {styleAttrs = Bold : styleAttrs s}

-- | Add dim attribute
dim :: Style -> Style
dim s = s {styleAttrs = Dim : styleAttrs s}

-- | Add italic attribute
italic :: Style -> Style
italic s = s {styleAttrs = Italic : styleAttrs s}

-- | Add underline attribute
underline :: Style -> Style
underline s = s {styleAttrs = Underline : styleAttrs s}

-- | Set foreground color
fg :: Color -> Style
fg c = defaultStyle {styleFg = c}

-- | Set background color
bg :: Color -> Style
bg c = defaultStyle {styleBg = c}

-- | Create RGB foreground color
rgb :: Word8 -> Word8 -> Word8 -> Style
rgb r g b = fg (RGB r g b)
