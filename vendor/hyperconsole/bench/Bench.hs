{-# LANGUAGE OverloadedStrings #-}

-- | HyperConsole Benchmarks
--
-- "She knew that the cores of the colony's four big
--  Hosaka mainframes burned most brightly in the small
--  hours of the night, when most of the habitat's
--  human population was asleep."
--
--                                      — Neuromancer
--
-- = Benchmarks
--
-- This module benchmarks:
--
--   * Widget rendering (text, layout, tables)
--   * Layout solving (flexbox constraint resolution)
--   * Canvas operations (diff computation)
--   * IoUring frame building
--   * Unicode width calculations
module Main where

import Control.DeepSeq (NFData (..), deepseq, force)
import Criterion.Main
import Data.ByteString (ByteString)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import HyperConsole
import HyperConsole.Terminal.IoUring qualified as IoUring

-- ════════════════════════════════════════════════════════════════════════════
-- NFData instances for benchmarking
-- ════════════════════════════════════════════════════════════════════════════

instance NFData Span where
  rnf (Span style txt) = rnf style `seq` rnf txt

instance NFData Style where
  rnf (Style fg' bg' attrs) = rnf fg' `seq` rnf bg' `seq` rnf attrs

instance NFData Color where
  rnf Default = ()
  rnf Black = ()
  rnf Red = ()
  rnf Green = ()
  rnf Yellow = ()
  rnf Blue = ()
  rnf Magenta = ()
  rnf Cyan = ()
  rnf White = ()
  rnf BrightBlack = ()
  rnf BrightRed = ()
  rnf BrightGreen = ()
  rnf BrightYellow = ()
  rnf BrightBlue = ()
  rnf BrightMagenta = ()
  rnf BrightCyan = ()
  rnf BrightWhite = ()
  rnf (Color256 n) = rnf n
  rnf (RGB r g b) = rnf r `seq` rnf g `seq` rnf b

instance NFData Attr where
  rnf Bold = ()
  rnf Dim = ()
  rnf Italic = ()
  rnf Underline = ()
  rnf Blink = ()
  rnf Reverse = ()
  rnf Strikethrough = ()

instance NFData Canvas where
  rnf (Canvas lns dims) = rnf lns `seq` rnf dims

instance NFData Dimensions where
  rnf (Dimensions w h) = rnf w `seq` rnf h

-- ════════════════════════════════════════════════════════════════════════════
-- Benchmark Data
-- ════════════════════════════════════════════════════════════════════════════

-- | Standard terminal dimensions
termDims :: Dimensions
termDims = Dimensions 120 40

-- | Large terminal dimensions
largeDims :: Dimensions
largeDims = Dimensions 200 60

-- | Generate test text
genText :: Int -> Text
genText n = T.replicate n "Hello World "

-- | Generate Unicode text with wide chars
genUnicodeText :: Int -> Text
genUnicodeText n = T.replicate n "Hello 中文 🚀 "

-- | Generate table data
genTableData :: Int -> Int -> [[Text]]
genTableData rows cols = [[T.pack ("Cell " <> show r <> "," <> show c) | c <- [0 .. cols - 1]] | r <- [0 .. rows - 1]]

-- ════════════════════════════════════════════════════════════════════════════
-- Widget Benchmarks
-- ════════════════════════════════════════════════════════════════════════════

widgetBenchmarks :: Benchmark
widgetBenchmarks =
  bgroup
    "Widget"
    [ bgroup
        "text"
        [ bench "short" $ nf (`runWidget` termDims) (text "Hello, World!"),
          bench "medium" $ nf (`runWidget` termDims) (text (genText 10)),
          bench "long" $ nf (`runWidget` termDims) (text (genText 100)),
          bench "unicode" $ nf (`runWidget` termDims) (text (genUnicodeText 10))
        ],
      bgroup
        "vbox"
        [ bench "5 items" $ nf (`runWidget` termDims) (vbox [text "line" | _ <- [1 .. 5 :: Int]]),
          bench "20 items" $ nf (`runWidget` termDims) (vbox [text "line" | _ <- [1 .. 20 :: Int]]),
          bench "100 items" $ nf (`runWidget` termDims) (vbox [text "line" | _ <- [1 .. 100 :: Int]])
        ],
      bgroup
        "hbox"
        [ bench "5 items" $ nf (`runWidget` termDims) (hbox [text "col" | _ <- [1 .. 5 :: Int]]),
          bench "20 items" $ nf (`runWidget` termDims) (hbox [text "col" | _ <- [1 .. 20 :: Int]])
        ],
      bgroup
        "nested"
        [ bench "3x3 grid" $
            nf
              (`runWidget` termDims)
              ( vbox
                  [ hbox [text "cell" | _ <- [1 .. 3 :: Int]]
                  | _ <- [1 .. 3 :: Int]
                  ]
              ),
          bench "10x10 grid" $
            nf
              (`runWidget` termDims)
              ( vbox
                  [ hbox [text "cell" | _ <- [1 .. 10 :: Int]]
                  | _ <- [1 .. 10 :: Int]
                  ]
              )
        ],
      bgroup
        "table"
        [ bench "5x5" $ nf (`runWidget` termDims) (table defaultStyle (genTableData 5 5)),
          bench "10x10" $ nf (`runWidget` termDims) (table defaultStyle (genTableData 10 10)),
          bench "50x10" $ nf (`runWidget` termDims) (table defaultStyle (genTableData 50 10))
        ],
      bgroup
        "progress"
        [ bench "single" $ nf (`runWidget` termDims) (progress (fg Green) (fg BrightBlack) 0.5),
          bench "bar with label" $ nf (`runWidget` termDims) (progressBar (fg Green) (fg BrightBlack) defaultStyle 0.75)
        ],
      bgroup
        "decorators"
        [ bench "bordered" $ nf (`runWidget` termDims) (bordered (text "content")),
          bench "padded" $ nf (`runWidget` termDims) (padded 1 1 1 1 (text "content")),
          bench "bordered+padded" $ nf (`runWidget` termDims) (bordered (padded 1 1 1 1 (text "content")))
        ]
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Layout Benchmarks
-- ════════════════════════════════════════════════════════════════════════════

layoutBenchmarks :: Benchmark
layoutBenchmarks =
  bgroup
    "Layout"
    [ bgroup
        "solve"
        [ bench "5 Fill" $ nf (solve defaultLayout termDims) (replicate 5 (Fill 1)),
          bench "20 Fill" $ nf (solve defaultLayout termDims) (replicate 20 (Fill 1)),
          bench "100 Fill" $ nf (solve defaultLayout termDims) (replicate 100 (Fill 1)),
          bench "mixed" $ nf (solve defaultLayout termDims) [Exact 20, Fill 1, Percent 25, Fill 2, Exact 10],
          bench "all Exact" $ nf (solve defaultLayout termDims) (replicate 20 (Exact 10)),
          bench "all Percent" $ nf (solve defaultLayout termDims) (replicate 10 (Percent 10))
        ]
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Unicode Benchmarks
-- ════════════════════════════════════════════════════════════════════════════

unicodeBenchmarks :: Benchmark
unicodeBenchmarks =
  bgroup
    "Unicode"
    [ bgroup
        "displayWidth"
        [ bench "ASCII 100" $ nf displayWidth (T.replicate 100 "a"),
          bench "ASCII 1000" $ nf displayWidth (T.replicate 1000 "a"),
          bench "CJK 100" $ nf displayWidth (T.replicate 100 "中"),
          bench "mixed 100" $ nf displayWidth (genUnicodeText 10)
        ],
      bgroup
        "truncateText"
        [ bench "no truncation" $ nf (truncateText 1000) (T.replicate 100 "a"),
          bench "truncate ASCII" $ nf (truncateText 50) (T.replicate 100 "a"),
          bench "truncate CJK" $ nf (truncateText 50) (T.replicate 100 "中"),
          bench "truncate mixed" $ nf (truncateText 50) (genUnicodeText 20)
        ],
      bgroup
        "padRight"
        [ bench "pad ASCII" $ nf (padRight 100) (T.replicate 50 "a"),
          bench "pad CJK" $ nf (padRight 100) (T.replicate 25 "中")
        ]
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- IoUring Frame Benchmarks
-- ════════════════════════════════════════════════════════════════════════════

ioUringBenchmarks :: Benchmark
ioUringBenchmarks =
  bgroup
    "IoUring"
    [ bgroup
        "frame"
        [ bench "build 10 segments" $ nfIO $ do
            frame <- IoUring.newFrame
            mapM_ (IoUring.addSegment frame) (replicate 10 "segment data"),
          bench "build 100 segments" $ nfIO $ do
            frame <- IoUring.newFrame
            mapM_ (IoUring.addSegment frame) (replicate 100 "segment data"),
          bench "build 1000 segments" $ nfIO $ do
            frame <- IoUring.newFrame
            mapM_ (IoUring.addSegment frame) (replicate 1000 "segment data"),
          bench "build + read" $ nfIO $ do
            frame <- IoUring.newFrame
            mapM_ (IoUring.addSegment frame) (replicate 100 "segment data")
            IoUring.buildFrame frame
        ]
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Canvas Diff Benchmarks
-- ════════════════════════════════════════════════════════════════════════════

-- | Generate a canvas for diff testing
genCanvas :: Int -> Int -> Canvas
genCanvas w h =
  let line = Seq.singleton (Span defaultStyle (T.replicate w "x"))
   in Canvas (V.replicate h line) (Dimensions w h)

-- | Modify some lines in a canvas
modifyCanvas :: Int -> Canvas -> Canvas
modifyCanvas n canvas =
  let lns = canvasLines canvas
      modified = V.imap (\i l -> if i `mod` n == 0 then Seq.singleton (Span (fg Red) "modified") else l) lns
   in canvas {canvasLines = modified}

canvasBenchmarks :: Benchmark
canvasBenchmarks =
  bgroup
    "Canvas"
    [ bgroup
        "generate"
        [ bench "80x24" $ nf (genCanvas 80) 24,
          bench "120x40" $ nf (genCanvas 120) 40,
          bench "200x60" $ nf (genCanvas 200) 60
        ],
      bgroup
        "compare"
        [ bench "identical 80x24" $
            let c = genCanvas 80 24 in nf (== c) c,
          bench "10% different" $
            let c1 = genCanvas 80 24
                c2 = modifyCanvas 10 c1
             in nf (== c1) c2
        ]
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Main
-- ════════════════════════════════════════════════════════════════════════════

main :: IO ()
main =
  defaultMain
    [ widgetBenchmarks,
      layoutBenchmarks,
      unicodeBenchmarks,
      ioUringBenchmarks,
      canvasBenchmarks
    ]
