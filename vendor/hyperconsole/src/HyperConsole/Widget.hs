{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE StrictData #-}

-- | Composable widget system
--
-- "The Finn's holographic face hung between a pink satin
--  bedroom and a display of antique orbital gear."
--
--                                          — Neuromancer
--
-- Widgets are pure functions from dimensions to canvases.
-- They compose cleanly via:
--
--   * Layout containers (hbox, vbox with flexbox constraints)
--   * Decorators (borders, padding, sizing)
--   * Common UI elements (progress, spinner, table, tree)
--
-- = Design
--
-- The widget system follows a simple principle:
--
-- @
-- newtype Widget = Widget { runWidget :: Dimensions -> Canvas }
-- @
--
-- No state, no effects, just pure rendering. IO happens at the edges
-- in the Terminal module.
module HyperConsole.Widget
  ( -- * Core types
    Widget (..),
    Canvas (..),
    Span (..),
    Line,

    -- * Basic widgets
    text,
    textStyled,
    textMultiline,
    char,
    empty,
    space,
    fill,
    rule,

    -- * Layout containers
    hbox,
    vbox,
    hboxWith,
    vboxWith,
    labeled,
    (<+>),
    layers,
    conditional,

    -- * Decorators
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

    -- * Common widgets
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

    -- * Low-level
    fromLines,
    toLines,
    measure,
    mapCanvas,
  )
where

import Data.Foldable (toList)
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector (Vector)
import Data.Vector qualified as V
import HyperConsole.Layout (Constraint (..), Dimensions (..), Direction (..), Layout (..), defaultLayout, solve)
import HyperConsole.Style (Style, defaultStyle)
import HyperConsole.Unicode (displayWidth, truncateText)

-- | A span of styled text
data Span = Span
  { spanStyle :: !Style,
    spanText :: !Text
  }
  deriving stock (Eq, Show)

-- | A line is a sequence of spans
type Line = Seq Span

-- | A canvas is the rendered output of a widget
data Canvas = Canvas
  { canvasLines :: !(Vector Line),
    canvasDims :: !Dimensions
  }
  deriving stock (Eq, Show)

-- | Empty canvas
emptyCanvas :: Dimensions -> Canvas
emptyCanvas dims = Canvas (V.replicate (height dims) Seq.empty) dims

-- | A widget is a function from available dimensions to a canvas
newtype Widget = Widget {runWidget :: Dimensions -> Canvas}

-- ════════════════════════════════════════════════════════════════════════════
-- Basic Widgets
-- ════════════════════════════════════════════════════════════════════════════

-- | Plain text widget (single line)
text :: Text -> Widget
text t = textStyled defaultStyle t

-- | Styled text widget (single line)
textStyled :: Style -> Text -> Widget
textStyled style t = Widget $ \dims ->
  let truncated = truncateText (width dims) t
      line = Seq.singleton (Span style truncated)
   in Canvas (V.singleton line) (Dimensions (displayWidth truncated) 1)

-- | Single character widget
char :: Style -> Char -> Widget
char style c = textStyled style (T.singleton c)

-- | Empty widget (takes no space)
empty :: Widget
empty = Widget $ \_ -> Canvas V.empty (Dimensions 0 0)

-- | Space (takes space but draws nothing)
space :: Int -> Int -> Widget
space w h = Widget $ \_ ->
  Canvas (V.replicate h Seq.empty) (Dimensions w h)

-- | Fill area with a character
fill :: Style -> Char -> Widget
fill style c = Widget $ \dims ->
  let line = Seq.singleton (Span style (T.replicate (width dims) (T.singleton c)))
   in Canvas (V.replicate (height dims) line) dims

-- ════════════════════════════════════════════════════════════════════════════
-- Layout Containers
-- ════════════════════════════════════════════════════════════════════════════

-- | Horizontal box (equal distribution)
hbox :: [Widget] -> Widget
hbox = hboxWith (replicate 100 (Fill 1))

-- | Horizontal box with constraints
hboxWith :: [Constraint] -> [Widget] -> Widget
hboxWith constraints widgets = Widget $ \dims ->
  let childDims = solve defaultLayout dims (take (length widgets) constraints)
      canvases = zipWith runWidget widgets childDims
   in horizontalConcat dims canvases

-- | Vertical box (equal distribution)
vbox :: [Widget] -> Widget
vbox = vboxWith (replicate 100 (Fill 1))

-- | Vertical box with constraints
vboxWith :: [Constraint] -> [Widget] -> Widget
vboxWith constraints widgets = Widget $ \dims ->
  let layout = defaultLayout {layoutDirection = Vertical}
      childDims = solve layout dims (take (length widgets) constraints)
      canvases = zipWith runWidget widgets childDims
   in verticalConcat dims canvases

-- | Labeled row: fixed-width label + filling content
--
-- This is the common pattern for "Label:  [content that fills]"
-- The label width is measured and the content takes remaining space.
labeled :: Widget -> Widget -> Widget
labeled label content = Widget $ \dims ->
  let labelCanvas = runWidget label dims
      labelWidth = measureLineWidth labelCanvas
      contentWidth = max 0 (width dims - labelWidth)
      contentDims = Dimensions contentWidth (height dims)
      contentCanvas = runWidget content contentDims
   in horizontalConcat dims [labelCanvas, contentCanvas]
  where
    -- Measure actual rendered width of first line
    measureLineWidth canvas =
      case V.toList (canvasLines canvas) of
        [] -> 0
        (line : _) -> sum [T.length (spanText s) | s <- toList line]

-- | Infix operator for labeled rows
--
-- @label \<+\> content@ is equivalent to @labeled label content@
(<+>) :: Widget -> Widget -> Widget
(<+>) = labeled

infixl 6 <+>

-- | Concatenate canvases horizontally
horizontalConcat :: Dimensions -> [Canvas] -> Canvas
horizontalConcat dims [] = emptyCanvas dims
horizontalConcat dims canvases =
  let maxH = maximum (1 : map (V.length . canvasLines) canvases)
      padCanvas c =
        let h = V.length (canvasLines c)
            padding = V.replicate (max 0 (maxH - h)) Seq.empty
         in canvasLines c V.++ padding
      paddedVecs = map padCanvas canvases
      combined = zipWithN maxH paddedVecs
   in Canvas (V.take (height dims) combined) dims
  where
    -- Zip N vectors together by concatenating lines
    -- Safely accesses each vector, using empty for out of bounds
    zipWithN _ [] = V.empty
    zipWithN len vecs = V.generate len $ \i ->
      foldl (<>) Seq.empty [safeIndex v i | v <- vecs]
    safeIndex v i
      | i < V.length v = v V.! i
      | otherwise = Seq.empty

-- | Concatenate canvases vertically
verticalConcat :: Dimensions -> [Canvas] -> Canvas
verticalConcat dims canvases =
  let allLines = V.concat (map canvasLines canvases)
      -- Use actual line count, not requested height (avoids padding)
      actualHeight = V.length allLines
   in Canvas (V.take (height dims) allLines) (Dimensions (width dims) (min actualHeight (height dims)))

-- ════════════════════════════════════════════════════════════════════════════
-- Decorators
-- ════════════════════════════════════════════════════════════════════════════

-- | Add padding around a widget (top, right, bottom, left)
padded :: Int -> Int -> Int -> Int -> Widget -> Widget
padded top right bottom left inner = Widget $ \dims ->
  let innerDims =
        Dimensions
          (max 0 (width dims - left - right))
          (max 0 (height dims - top - bottom))
      innerCanvas = runWidget inner innerDims
      topPad = V.replicate top Seq.empty
      bottomPad = V.replicate bottom Seq.empty
      leftPadSpan = Span defaultStyle (T.replicate left " ")
      paddedLines = V.map (leftPadSpan Seq.<|) (canvasLines innerCanvas)
   in Canvas (topPad V.++ paddedLines V.++ bottomPad) dims

-- | Draw a border around a widget (simple box drawing)
bordered :: Widget -> Widget
bordered = borderedWith '┌' '─' '┐' '│' '│' '└' '─' '┘'

-- | Draw a border with custom characters
borderedWith :: Char -> Char -> Char -> Char -> Char -> Char -> Char -> Char -> Widget -> Widget
borderedWith tl top tr left right bl bot br inner = Widget $ \dims ->
  let innerW = max 0 (width dims - 2)
      innerDims = Dimensions innerW (max 0 (height dims - 2))
      innerCanvas = runWidget inner innerDims
      w = width dims
      topBorder = Seq.singleton (Span defaultStyle (T.singleton tl <> T.replicate (w - 2) (T.singleton top) <> T.singleton tr))
      bottomBorder = Seq.singleton (Span defaultStyle (T.singleton bl <> T.replicate (w - 2) (T.singleton bot) <> T.singleton br))
      -- Pad line to inner width, then wrap with borders
      wrapLine line =
        let lineW = sum [T.length (spanText s) | s <- toList line]
            padding = max 0 (innerW - lineW)
            paddedLine =
              if padding > 0
                then line Seq.|> Span defaultStyle (T.replicate padding " ")
                else line
         in Span defaultStyle (T.singleton left) Seq.<| (paddedLine Seq.|> Span defaultStyle (T.singleton right))
      wrappedLines = V.map wrapLine (canvasLines innerCanvas)
   in Canvas (V.singleton topBorder V.++ wrappedLines V.++ V.singleton bottomBorder) dims

-- | Fixed size widget
fixed :: Int -> Int -> Widget -> Widget
fixed w h inner = Widget $ \_ ->
  let canvas = runWidget inner (Dimensions w h)
   in canvas {canvasDims = Dimensions w h}

-- | Minimum size widget
minSize :: Int -> Int -> Widget -> Widget
minSize minW minH inner = Widget $ \dims ->
  runWidget inner (Dimensions (max minW (width dims)) (max minH (height dims)))

-- | Maximum size widget
maxSize :: Int -> Int -> Widget -> Widget
maxSize maxW maxH inner = Widget $ \dims ->
  runWidget inner (Dimensions (min maxW (width dims)) (min maxH (height dims)))

-- ════════════════════════════════════════════════════════════════════════════
-- Common Widgets
-- ════════════════════════════════════════════════════════════════════════════

-- | Animated spinner (pass tick count for animation)
spinner :: Style -> Int -> Widget
spinner style tick = Widget $ \_ ->
  let frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" :: Text
      frame = T.index frames (tick `mod` T.length frames)
   in Canvas (V.singleton (Seq.singleton (Span style (T.singleton frame)))) (Dimensions 1 1)

-- | Progress bar (0.0 to 1.0)
progress :: Style -> Style -> Double -> Widget
progress filledStyle emptyStyle pct = Widget $ \dims ->
  let w = width dims
      filled = max 0 (min w (round (pct * fromIntegral w)))
      unfilled = w - filled
      bar =
        if filled > 0
          then Span filledStyle (T.replicate filled "█") Seq.<| rest
          else rest
        where
          rest =
            if unfilled > 0
              then Seq.singleton (Span emptyStyle (T.replicate unfilled "░"))
              else Seq.empty
   in Canvas (V.singleton bar) (Dimensions w 1)

-- | Progress bar with percentage label
progressBar :: Style -> Style -> Style -> Double -> Widget
progressBar filledStyle emptyStyle labelStyle pct = Widget $ \dims ->
  let label = T.pack (show (round (pct * 100) :: Int) ++ "%")
      labelW = displayWidth label
      barW = max 0 (width dims - labelW - 1)
      barCanvas = runWidget (progress filledStyle emptyStyle pct) (Dimensions barW 1)
      labelCanvas = runWidget (textStyled labelStyle label) (Dimensions labelW 1)
      spaceCanvas = runWidget (space 1 1) (Dimensions 1 1)
   in horizontalConcat dims [barCanvas, spaceCanvas, labelCanvas]

-- | Simple table widget
table :: Style -> [[Text]] -> Widget
table style rows = Widget $ \dims ->
  let numCols = if null rows then 0 else maximum (map length rows)
      -- Calculate column widths
      colWidths = [maximum (0 : [displayWidth (safeIndex r c "") | r <- rows]) | c <- [0 .. numCols - 1]]
      -- Render each row
      renderRow r =
        Seq.fromList
          [ Span style (padCell (colWidths !! c) (safeIndex r c ""))
          | c <- [0 .. numCols - 1]
          ]
      renderedRows = V.fromList (map renderRow rows)
   in Canvas (V.take (height dims) renderedRows) dims
  where
    safeIndex xs i def = if i < length xs then xs !! i else def
    padCell w t =
      let tw = displayWidth t
       in if tw >= w
            then truncateText w t
            else t <> T.replicate (w - tw) " "

-- | Vertical list widget
list :: Style -> Style -> Int -> [Text] -> Widget
list normalStyle selectedStyle selected items = Widget $ \dims ->
  let visibleItems = take (height dims) items
      renderItem i t =
        let style = if i == selected then selectedStyle else normalStyle
         in Seq.singleton (Span style (truncateText (width dims) t))
      renderedLines = V.fromList [renderItem i t | (i, t) <- zip [0 ..] visibleItems]
   in Canvas renderedLines dims

-- ════════════════════════════════════════════════════════════════════════════
-- Low-level
-- ════════════════════════════════════════════════════════════════════════════

-- | Create a widget from raw lines
fromLines :: [Line] -> Widget
fromLines lns = Widget $ \dims ->
  Canvas (V.take (height dims) (V.fromList lns)) dims

-- | Extract lines from a canvas
toLines :: Canvas -> [Line]
toLines = V.toList . canvasLines

-- | Measure the natural size of a widget (renders with large dimensions)
measure :: Widget -> Dimensions
measure w = canvasDims (runWidget w (Dimensions maxBound maxBound))

-- | Map a function over all spans in a canvas
mapCanvas :: (Span -> Span) -> Canvas -> Canvas
mapCanvas f canvas = canvas {canvasLines = V.map (fmap f) (canvasLines canvas)}

-- ════════════════════════════════════════════════════════════════════════════
-- Extended Basic Widgets
-- ════════════════════════════════════════════════════════════════════════════

-- | Multi-line text widget (wraps or truncates)
textMultiline :: Style -> Text -> Widget
textMultiline style t = Widget $ \dims ->
  let lns = T.lines t
      truncatedLines = take (height dims) lns
      renderLine l = Seq.singleton (Span style (truncateText (width dims) l))
   in Canvas (V.fromList (map renderLine truncatedLines)) dims

-- | Horizontal rule (full width line)
rule :: Style -> Char -> Widget
rule style c = Widget $ \dims ->
  let line = Seq.singleton (Span style (T.replicate (width dims) (T.singleton c)))
   in Canvas (V.singleton line) (Dimensions (width dims) 1)

-- ════════════════════════════════════════════════════════════════════════════
-- Extended Layout
-- ════════════════════════════════════════════════════════════════════════════

-- | Layer widgets on top of each other (last is on top)
layers :: [Widget] -> Widget
layers widgets = Widget $ \dims ->
  let canvases = map (`runWidget` dims) widgets
   in case canvases of
        [] -> emptyCanvas dims
        (c : cs) -> foldl overlayCanvas c cs
  where
    overlayCanvas :: Canvas -> Canvas -> Canvas
    overlayCanvas bottom top =
      let bottomLines = canvasLines bottom
          topLines = canvasLines top
          h = max (V.length bottomLines) (V.length topLines)
          merged = V.generate h $ \i ->
            let botLine = if i < V.length bottomLines then bottomLines V.! i else Seq.empty
                topLine = if i < V.length topLines then topLines V.! i else Seq.empty
             in if Seq.null topLine then botLine else topLine
       in Canvas merged (canvasDims bottom)

-- | Conditional widget (renders first if condition true, otherwise second)
conditional :: Bool -> Widget -> Widget -> Widget
conditional cond ifTrue ifFalse = Widget $ \dims ->
  runWidget (if cond then ifTrue else ifFalse) dims

-- ════════════════════════════════════════════════════════════════════════════
-- Extended Decorators
-- ════════════════════════════════════════════════════════════════════════════

-- | Uniform padding on all sides
paddedUniform :: Int -> Widget -> Widget
paddedUniform n = padded n n n n

-- | Bordered widget with custom style
borderedStyled :: Style -> Widget -> Widget
borderedStyled style inner = Widget $ \dims ->
  let innerW = max 0 (width dims - 2)
      innerDims = Dimensions innerW (max 0 (height dims - 2))
      innerCanvas = runWidget inner innerDims
      w = width dims
      topBorder = Seq.singleton (Span style ("┌" <> T.replicate (w - 2) "─" <> "┐"))
      bottomBorder = Seq.singleton (Span style ("└" <> T.replicate (w - 2) "─" <> "┘"))
      wrapLine line =
        let lineW = sum [T.length (spanText s) | s <- toList line]
            padding = max 0 (innerW - lineW)
            paddedLine =
              if padding > 0
                then line Seq.|> Span defaultStyle (T.replicate padding " ")
                else line
         in Span style "│" Seq.<| (paddedLine Seq.|> Span style "│")
      wrappedLines = V.map wrapLine (canvasLines innerCanvas)
   in Canvas (V.singleton topBorder V.++ wrappedLines V.++ V.singleton bottomBorder) dims

-- | Bordered widget with title
titled :: Style -> Text -> Widget -> Widget
titled style title inner = Widget $ \dims ->
  let innerW = max 0 (width dims - 2)
      innerDims = Dimensions innerW (max 0 (height dims - 2))
      innerCanvas = runWidget inner innerDims
      w = width dims
      titleTrunc = truncateText (w - 4) title
      titleLen = displayWidth titleTrunc
      leftPad = 2
      rightPad = max 0 (w - 3 - leftPad - titleLen)
      topBorder = Seq.singleton (Span style ("┌─" <> titleTrunc <> T.replicate rightPad "─" <> "┐"))
      bottomBorder = Seq.singleton (Span style ("└" <> T.replicate (w - 2) "─" <> "┘"))
      wrapLine line =
        let lineW = sum [T.length (spanText s) | s <- toList line]
            padding = max 0 (innerW - lineW)
            paddedLine =
              if padding > 0
                then line Seq.|> Span defaultStyle (T.replicate padding " ")
                else line
         in Span style "│" Seq.<| (paddedLine Seq.|> Span style "│")
      wrappedLines = V.map wrapLine (canvasLines innerCanvas)
   in Canvas (V.singleton topBorder V.++ wrappedLines V.++ V.singleton bottomBorder) dims

-- | Center a widget horizontally and vertically
centered :: Widget -> Widget
centered inner = Widget $ \dims ->
  let innerCanvas = runWidget inner dims
      innerW = width (canvasDims innerCanvas)
      innerH = V.length (canvasLines innerCanvas)
      leftPad = max 0 ((width dims - innerW) `div` 2)
      topPad = max 0 ((height dims - innerH) `div` 2)
      leftPadSpan = Span defaultStyle (T.replicate leftPad " ")
      topLines = V.replicate topPad Seq.empty
      paddedLines = V.map (leftPadSpan Seq.<|) (canvasLines innerCanvas)
   in Canvas (topLines V.++ paddedLines) dims

-- | Align widget to the right
alignRight :: Widget -> Widget
alignRight inner = Widget $ \dims ->
  let innerCanvas = runWidget inner dims
      innerW = width (canvasDims innerCanvas)
      leftPad = max 0 (width dims - innerW)
      leftPadSpan = Span defaultStyle (T.replicate leftPad " ")
      paddedLines = V.map (leftPadSpan Seq.<|) (canvasLines innerCanvas)
   in Canvas paddedLines dims

-- | Align widget to the bottom
alignBottom :: Widget -> Widget
alignBottom inner = Widget $ \dims ->
  let innerCanvas = runWidget inner dims
      innerH = V.length (canvasLines innerCanvas)
      topPad = max 0 (height dims - innerH)
      topLines = V.replicate topPad Seq.empty
   in Canvas (topLines V.++ canvasLines innerCanvas) dims

-- ════════════════════════════════════════════════════════════════════════════
-- Extended Common Widgets
-- ════════════════════════════════════════════════════════════════════════════

-- | Spinner with customizable frames
spinnerStyle :: Style -> Text -> Int -> Widget
spinnerStyle style frames tick = Widget $ \_ ->
  let frame = if T.null frames then ' ' else T.index frames (tick `mod` T.length frames)
   in Canvas (V.singleton (Seq.singleton (Span style (T.singleton frame)))) (Dimensions 1 1)

-- | Progress bar with custom label format
progressBarLabeled :: Style -> Style -> Style -> (Double -> Text) -> Double -> Widget
progressBarLabeled filledStyle emptyStyle labelStyle labelFn pct = Widget $ \dims ->
  let label = labelFn pct
      labelW = displayWidth label
      barW = max 0 (width dims - labelW - 1)
      barCanvas = runWidget (progress filledStyle emptyStyle pct) (Dimensions barW 1)
      labelCanvas = runWidget (textStyled labelStyle label) (Dimensions labelW 1)
      spaceCanvas = runWidget (space 1 1) (Dimensions 1 1)
   in horizontalConcat dims [barCanvas, spaceCanvas, labelCanvas]

-- | Styled table with header
tableStyled :: Style -> Style -> [Text] -> [[Text]] -> Widget
tableStyled headerStyle rowStyle headers rows = Widget $ \dims ->
  let allRows = headers : rows
      numCols = if null allRows then 0 else maximum (map length allRows)
      colWidths = [maximum (0 : [displayWidth (safeIndex r c "") | r <- allRows]) | c <- [0 .. numCols - 1]]
      renderRow style r =
        Seq.fromList
          [ Span style (padCell (colWidths !! c) (safeIndex r c ""))
          | c <- [0 .. numCols - 1]
          ]
      headerLine = renderRow headerStyle headers
      dataLines = V.fromList (map (renderRow rowStyle) rows)
      allLines = V.cons headerLine dataLines
   in Canvas (V.take (height dims) allLines) dims
  where
    safeIndex xs i def = if i < length xs then xs !! i else def
    padCell w t =
      let tw = displayWidth t
       in if tw >= w
            then truncateText w t
            else t <> T.replicate (w - tw) " "

-- | Tree widget with indentation
tree :: Style -> Style -> [(Int, Text)] -> Widget
tree normalStyle bulletStyle items = Widget $ \dims ->
  let renderItem (depth, txt) =
        let indent = T.replicate (depth * 2) " "
            bullet = "• "
            content = truncateText (width dims - depth * 2 - 2) txt
         in Seq.fromList
              [ Span normalStyle indent,
                Span bulletStyle bullet,
                Span normalStyle content
              ]
      renderedLines = V.fromList (map renderItem (take (height dims) items))
   in Canvas renderedLines dims

-- | Sparkline chart (inline graph)
sparkline :: Style -> [Double] -> Widget
sparkline style values = Widget $ \dims ->
  let blocks = "▁▂▃▄▅▆▇█" :: Text
      maxVal = maximum (1 : values)
      minVal = minimum (0 : values)
      range = maxVal - minVal
      normalize v = if range == 0 then 0 else (v - minVal) / range
      toBlock v =
        let idx = min 7 (floor (normalize v * 8) :: Int)
         in T.index blocks idx
      visibleValues = take (width dims) values
      chars = T.pack (map toBlock visibleValues)
   in Canvas (V.singleton (Seq.singleton (Span style chars))) (Dimensions (T.length chars) 1)

-- | Gauge widget (circular-style indicator)
gauge :: Style -> Style -> Style -> Double -> Widget
gauge lowStyle midStyle highStyle pct = Widget $ \_dims ->
  let segments = "○◔◑◕●" :: Text
      idx = min 4 (floor (pct * 5) :: Int)
      c = T.index segments idx
      style
        | pct < 0.33 = lowStyle
        | pct < 0.66 = midStyle
        | otherwise = highStyle
   in Canvas (V.singleton (Seq.singleton (Span style (T.singleton c)))) (Dimensions 1 1)

-- | Status line (key: value pairs)
statusLine :: Style -> Style -> [(Text, Text)] -> Widget
statusLine keyStyle valueStyle pairs = Widget $ \dims ->
  let renderPair (k, v) = [Span keyStyle (k <> ": "), Span valueStyle v, Span defaultStyle "  "]
      allSpans = concatMap renderPair pairs
      line = Seq.fromList allSpans
   in Canvas (V.singleton line) (Dimensions (width dims) 1)
