{-# LANGUAGE OverloadedStrings #-}

-- | Unicode text handling utilities
module HyperConsole.Unicode
  ( -- * Display width
    displayWidth,
    charWidth,
    isWide,

    -- * Text manipulation
    truncateText,
    wrapText,
    padRight,
    padLeft,
    center,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- | Calculate display width of text (handling wide characters)
displayWidth :: Text -> Int
displayWidth = T.foldl' (\acc c -> acc + charWidth c) 0

-- | Width of a single character in terminal cells
charWidth :: Char -> Int
charWidth c
  | c < ' ' = 0 -- Control characters
  | c == '\t' = 8 -- Tab (simplified)
  | isWide c = 2 -- CJK, etc.
  | otherwise = 1

-- | Check if character is wide (CJK, etc.)
isWide :: Char -> Bool
isWide c =
  let cp = fromEnum c
   in -- CJK ranges (comprehensive)
      (cp >= 0x1100 && cp <= 0x115F) -- Hangul Jamo
        || (cp >= 0x231A && cp <= 0x231B) -- Watch, hourglass
        || (cp >= 0x2329 && cp <= 0x232A) -- Brackets
        || (cp >= 0x23E9 && cp <= 0x23F3) -- Symbols
        || (cp >= 0x23F8 && cp <= 0x23FA) -- Symbols
        || (cp >= 0x25FD && cp <= 0x25FE) -- Squares
        || (cp >= 0x2614 && cp <= 0x2615) -- Umbrella, coffee
        || (cp >= 0x2648 && cp <= 0x2653) -- Zodiac
        || (cp >= 0x267F && cp <= 0x267F) -- Wheelchair
        || (cp >= 0x2693 && cp <= 0x2693) -- Anchor
        || (cp >= 0x26A1 && cp <= 0x26A1) -- Lightning
        || (cp >= 0x26AA && cp <= 0x26AB) -- Circles
        || (cp >= 0x26BD && cp <= 0x26BE) -- Sports
        || (cp >= 0x26C4 && cp <= 0x26C5) -- Weather
        || (cp >= 0x26CE && cp <= 0x26CE) -- Ophiuchus
        || (cp >= 0x26D4 && cp <= 0x26D4) -- No entry
        || (cp >= 0x26EA && cp <= 0x26EA) -- Church
        || (cp >= 0x26F2 && cp <= 0x26F3) -- Fountain, golf
        || (cp >= 0x26F5 && cp <= 0x26F5) -- Sailboat
        || (cp >= 0x26FA && cp <= 0x26FA) -- Tent
        || (cp >= 0x26FD && cp <= 0x26FD) -- Fuel pump
        || (cp >= 0x2702 && cp <= 0x2702) -- Scissors
        || (cp >= 0x2705 && cp <= 0x2705) -- Check
        || (cp >= 0x2708 && cp <= 0x270D) -- Airplane, etc
        || (cp >= 0x270F && cp <= 0x270F) -- Pencil
        || (cp >= 0x2712 && cp <= 0x2712) -- Nib
        || (cp >= 0x2714 && cp <= 0x2714) -- Check
        || (cp >= 0x2716 && cp <= 0x2716) -- X
        || (cp >= 0x271D && cp <= 0x271D) -- Cross
        || (cp >= 0x2721 && cp <= 0x2721) -- Star
        || (cp >= 0x2728 && cp <= 0x2728) -- Sparkles
        || (cp >= 0x2733 && cp <= 0x2734) -- Stars
        || (cp >= 0x2744 && cp <= 0x2744) -- Snowflake
        || (cp >= 0x2747 && cp <= 0x2747) -- Sparkle
        || (cp >= 0x274C && cp <= 0x274C) -- X
        || (cp >= 0x274E && cp <= 0x274E) -- X
        || (cp >= 0x2753 && cp <= 0x2755) -- Questions
        || (cp >= 0x2757 && cp <= 0x2757) -- Exclamation
        || (cp >= 0x2763 && cp <= 0x2764) -- Heart
        || (cp >= 0x2795 && cp <= 0x2797) -- Math
        || (cp >= 0x27A1 && cp <= 0x27A1) -- Arrow
        || (cp >= 0x27B0 && cp <= 0x27B0) -- Loop
        || (cp >= 0x27BF && cp <= 0x27BF) -- Loop
        || (cp >= 0x2934 && cp <= 0x2935) -- Arrows
        || (cp >= 0x2B05 && cp <= 0x2B07) -- Arrows
        || (cp >= 0x2B1B && cp <= 0x2B1C) -- Squares
        || (cp >= 0x2B50 && cp <= 0x2B50) -- Star
        || (cp >= 0x2B55 && cp <= 0x2B55) -- Circle
        || (cp >= 0x2E80 && cp <= 0x2EFF) -- CJK Radicals
        || (cp >= 0x2F00 && cp <= 0x2FDF) -- Kangxi Radicals
        || (cp >= 0x2FF0 && cp <= 0x2FFF) -- Ideographic Description
        || (cp >= 0x3000 && cp <= 0x303E) -- CJK Symbols
        || (cp >= 0x3041 && cp <= 0x3096) -- Hiragana
        || (cp >= 0x30A0 && cp <= 0x30FF) -- Katakana
        || (cp >= 0x3105 && cp <= 0x312F) -- Bopomofo
        || (cp >= 0x3131 && cp <= 0x318E) -- Hangul Compatibility
        || (cp >= 0x3190 && cp <= 0x31FF) -- Kanbun, etc
        || (cp >= 0x3200 && cp <= 0x321E) -- Enclosed CJK
        || (cp >= 0x3220 && cp <= 0x3247) -- Enclosed CJK
        || (cp >= 0x3250 && cp <= 0x4DBF) -- CJK Extension A
        || (cp >= 0x4E00 && cp <= 0x9FFF) -- CJK Unified Ideographs
        || (cp >= 0xA000 && cp <= 0xA4CF) -- Yi
        || (cp >= 0xAC00 && cp <= 0xD7A3) -- Hangul
        || (cp >= 0xF900 && cp <= 0xFAFF) -- CJK Compatibility
        || (cp >= 0xFE10 && cp <= 0xFE1F) -- Vertical forms
        || (cp >= 0xFE30 && cp <= 0xFE6F) -- CJK Compatibility Forms
        || (cp >= 0xFF00 && cp <= 0xFF60) -- Fullwidth
        || (cp >= 0xFFE0 && cp <= 0xFFE6) -- Fullwidth
        || (cp >= 0x1F004 && cp <= 0x1F004) -- Mahjong
        || (cp >= 0x1F0CF && cp <= 0x1F0CF) -- Playing card
        || (cp >= 0x1F170 && cp <= 0x1F171) -- Letters
        || (cp >= 0x1F17E && cp <= 0x1F17F) -- Letters
        || (cp >= 0x1F18E && cp <= 0x1F18E) -- Letter
        || (cp >= 0x1F191 && cp <= 0x1F19A) -- Squared words
        || (cp >= 0x1F1E6 && cp <= 0x1F1FF) -- Regional indicators
        || (cp >= 0x1F200 && cp <= 0x1F202) -- Ideographic
        || (cp >= 0x1F210 && cp <= 0x1F23B) -- Squared CJK
        || (cp >= 0x1F240 && cp <= 0x1F248) -- Circled ideographs
        || (cp >= 0x1F250 && cp <= 0x1F251) -- Circled ideographs
        || (cp >= 0x1F260 && cp <= 0x1F265) -- Symbols
        || (cp >= 0x1F300 && cp <= 0x1F5FF) -- Misc Symbols and Pictographs
        || (cp >= 0x1F600 && cp <= 0x1F64F) -- Emoticons
        || (cp >= 0x1F680 && cp <= 0x1F6FF) -- Transport
        || (cp >= 0x1F700 && cp <= 0x1F77F) -- Alchemical
        || (cp >= 0x1F780 && cp <= 0x1F7FF) -- Geometric Shapes Extended
        || (cp >= 0x1F800 && cp <= 0x1F8FF) -- Supplemental Arrows-C
        || (cp >= 0x1F900 && cp <= 0x1F9FF) -- Supplemental Symbols
        || (cp >= 0x1FA00 && cp <= 0x1FA6F) -- Chess
        || (cp >= 0x1FA70 && cp <= 0x1FAFF) -- Symbols Extended-A
        || (cp >= 0x1FB00 && cp <= 0x1FBFF) -- Legacy Computing
        || (cp >= 0x20000 && cp <= 0x2FFFF) -- CJK Extension B+
        || (cp >= 0x30000 && cp <= 0x3FFFF) -- CJK Extension G+

-- | Truncate text to fit width (respects wide chars)
truncateText :: Int -> Text -> Text
truncateText maxWidth t = go 0 t
  where
    go _ "" = ""
    go w txt
      | w >= maxWidth = ""
      | otherwise =
          let c = T.head txt
              cw = charWidth c
           in if w + cw > maxWidth
                then ""
                else T.cons c (go (w + cw) (T.tail txt))

-- | Wrap text to fit width
wrapText :: Int -> Text -> [Text]
wrapText maxWidth = concatMap wrapLine . T.lines
  where
    wrapLine line
      | displayWidth line <= maxWidth = [line]
      | otherwise =
          let (first, rest) = splitAtWidth maxWidth line
           in first : wrapLine rest

    splitAtWidth w t = go 0 "" t
      where
        go _ acc "" = (acc, "")
        go currW acc txt
          | currW >= w = (acc, txt)
          | otherwise =
              let c = T.head txt
                  cw = charWidth c
               in if currW + cw > w
                    then (acc, txt)
                    else go (currW + cw) (T.snoc acc c) (T.tail txt)

-- | Pad text to width on the right
padRight :: Int -> Text -> Text
padRight w t =
  let tw = displayWidth t
   in if tw >= w
        then truncateText w t
        else t <> T.replicate (w - tw) " "

-- | Pad text to width on the left
padLeft :: Int -> Text -> Text
padLeft w t =
  let tw = displayWidth t
   in if tw >= w
        then truncateText w t
        else T.replicate (w - tw) " " <> t

-- | Center text within width
center :: Int -> Text -> Text
center w t =
  let tw = displayWidth t
   in if tw >= w
        then truncateText w t
        else
          let leftPad = (w - tw) `div` 2
              rightPad = w - tw - leftPad
           in T.replicate leftPad " " <> t <> T.replicate rightPad " "
