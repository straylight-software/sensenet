{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Playwright - TTY-free test harness for HyperConsole
--
-- "He'd operated on an almost permanent adrenaline high, a byproduct
--  of youth and proficiency, jacked into a custom cyberspace deck..."
--
--                                                    — Neuromancer
--
-- Renders widgets to text for debugging without requiring a terminal.
-- Dumps canvas structure, line counts, and rendered output.
module Main where

import Data.Foldable (toList)
import Data.List (sortBy)
import Data.Ord (Down (..), comparing)
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V
import HyperConsole
import HyperConsole.Theme
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--help"] -> printHelp
    ["-h"] -> printHelp
    ["progress"] -> runProgressPlaywright
    ["progress-bar"] -> runProgressBarPlaywright
    ["hbox-mixed"] -> runHboxMixedPlaywright
    ["sensenet"] -> runSensenetPlaywright
    ["sensenet-preamble"] -> runSensenetPreamblePlaywright
    ["sensenet-row"] -> runSensenetRowPlaywright
    ["all"] -> runAllPlaywright
    [] -> runAllPlaywright
    _ -> printHelp

printHelp :: IO ()
printHelp = do
  putStrLn "HyperConsole Playwright - TTY-free test harness"
  putStrLn ""
  putStrLn "Usage: hyperconsole-playwright [TEST]"
  putStrLn ""
  putStrLn "Available tests:"
  putStrLn "  progress          Full progress showcase widget"
  putStrLn "  progress-bar      Just the progressBar widget"
  putStrLn "  hbox-mixed        hbox with mixed-height children"
  putStrLn "  sensenet          Sensenet build dashboard"
  putStrLn "  sensenet-preamble Sensenet preamble phase"
  putStrLn "  all               Run all tests (default)"

runAllPlaywright :: IO ()
runAllPlaywright = do
  runProgressBarPlaywright
  putStrLn ""
  runHboxMixedPlaywright
  putStrLn ""
  runProgressPlaywright
  putStrLn ""
  runSensenetPlaywright

-- ════════════════════════════════════════════════════════════════════════════
-- Canvas Inspection
-- ════════════════════════════════════════════════════════════════════════════

-- | Render a canvas to plain text (no ANSI codes)
renderCanvasPlain :: Canvas -> Text
renderCanvasPlain canvas =
  T.unlines [renderLine line | line <- V.toList (canvasLines canvas)]
  where
    renderLine line = T.concat [spanText s | s <- toList line]

-- | Dump canvas structure for debugging
dumpCanvas :: String -> Canvas -> IO ()
dumpCanvas name canvas = do
  putStrLn $ "═══ " <> name <> " ═══"
  putStrLn $ "Dimensions: " <> show (canvasDims canvas)
  putStrLn $ "Line count: " <> show (V.length (canvasLines canvas))
  putStrLn "Lines:"
  V.iforM_ (canvasLines canvas) $ \i line -> do
    putStrLn $ "  [" <> show i <> "] spans=" <> show (Seq.length line) <> ": " <> show (take 3 $ toList line) <> "..."
  putStrLn "Rendered:"
  TIO.putStrLn $ renderCanvasPlain canvas

-- | Show actual character widths of each line
dumpLineWidths :: Canvas -> IO ()
dumpLineWidths canvas = do
  putStrLn "Line widths:"
  V.iforM_ (canvasLines canvas) $ \i line -> do
    let totalChars = sum [T.length (spanText s) | s <- toList line]
    putStrLn $ "  [" <> show i <> "] chars=" <> show totalChars

-- ════════════════════════════════════════════════════════════════════════════
-- Test Cases
-- ════════════════════════════════════════════════════════════════════════════

runProgressBarPlaywright :: IO ()
runProgressBarPlaywright = do
  putStrLn "Testing progressBar widget..."
  let dims = Dimensions 80 10

  -- Test at 0%
  putStrLn "\n--- progressBar at 0% ---"
  let w0 = progressBar (fg Cyan) (fg BrightBlack) (fg White) 0.0
      c0 = runWidget w0 dims
  dumpCanvas "progressBar 0%" c0

  -- Test at 50%
  putStrLn "\n--- progressBar at 50% ---"
  let w50 = progressBar (fg Cyan) (fg BrightBlack) (fg White) 0.5
      c50 = runWidget w50 dims
  dumpCanvas "progressBar 50%" c50

  -- Test at 100%
  putStrLn "\n--- progressBar at 100% ---"
  let w100 = progressBar (fg Cyan) (fg BrightBlack) (fg White) 1.0
      c100 = runWidget w100 dims
  dumpCanvas "progressBar 100%" c100

  -- Test the ACTUAL pattern from the demo: hbox [text, progress]
  putStrLn "\n--- hbox [label, progress] - THE BUG ---"
  let wBug =
        hbox
          [ textStyled (fg BrightBlack) "Standard:    ",
            progress (fg Green) (fg BrightBlack) 0.5
          ]
      cBug = runWidget wBug dims
  dumpCanvas "hbox label+progress" cBug
  dumpLineWidths cBug

  -- What SHOULD happen with proper constraints
  putStrLn "\n--- hboxWith [Exact 13, Fill 1] [label, progress] ---"
  let wFixed =
        hboxWith
          [Exact 13, Fill 1]
          [ textStyled (fg BrightBlack) "Standard:    ",
            progress (fg Green) (fg BrightBlack) 0.5
          ]
      cFixed = runWidget wFixed dims
  dumpCanvas "hboxWith fixed label" cFixed
  dumpLineWidths cFixed

  -- NEW: Using labeled combinator
  putStrLn "\n--- labeled (THE FIX) ---"
  let wLabeled =
        labeled
          (textStyled (fg BrightBlack) "Standard:    ")
          (progress (fg Green) (fg BrightBlack) 0.5)
      cLabeled = runWidget wLabeled dims
  dumpCanvas "labeled combinator" cLabeled
  dumpLineWidths cLabeled

  -- NEW: Using <+> operator
  putStrLn "\n--- Using <+> operator ---"
  let wOp = textStyled (fg BrightBlack) "Standard:    " <+> progress (fg Green) (fg BrightBlack) 0.5
      cOp = runWidget wOp dims
  dumpCanvas "<+> operator" cOp
  dumpLineWidths cOp

runHboxMixedPlaywright :: IO ()
runHboxMixedPlaywright = do
  putStrLn "Testing hbox with mixed-height children..."
  let dims = Dimensions 80 10

  -- Mixed heights
  putStrLn "\n--- hbox [vbox 3 lines, text 1 line, vbox 2 lines] ---"
  let w =
        hbox
          [ vbox [text "a", text "b", text "c"],
            text "x",
            vbox [text "1", text "2"]
          ]
      c = runWidget w dims
  dumpCanvas "hbox mixed" c

  -- With empty
  putStrLn "\n--- hbox [empty, text, empty] ---"
  let w2 = hbox [empty, text "middle", empty]
      c2 = runWidget w2 dims
  dumpCanvas "hbox with empty" c2

runProgressPlaywright :: IO ()
runProgressPlaywright = do
  putStrLn "Testing full progressShowcase..."
  let dims = Dimensions 120 20
      pct = 0.0
      tick = 0

  let w = progressShowcase pct tick
      c = runWidget w dims
  dumpCanvas "progressShowcase" c
  dumpLineWidths c

-- ════════════════════════════════════════════════════════════════════════════
-- Widgets (copied from Demo.hs for isolation)
-- ════════════════════════════════════════════════════════════════════════════

progressShowcase :: Double -> Int -> Widget
progressShowcase pct tick =
  bordered $
    padded 1 2 1 2 $
      vbox
        [ textStyled (bold (fg BrightWhite)) "Progress Bar Showcase",
          rule (fg BrightBlack) '─',
          space 0 1,
          -- Standard (FIXED: using <+>)
          textStyled (fg BrightBlack) "Standard:    " <+> progress (fg Green) (fg BrightBlack) pct,
          -- Gradient
          textStyled (fg BrightBlack) "Gradient:    " <+> progress (gradientColor pct) (fg BrightBlack) pct,
          -- With label
          textStyled (fg BrightBlack) "With Label:  " <+> progressBar (fg Cyan) (fg BrightBlack) (fg White) pct,
          space 0 1,
          rule (fg BrightBlack) '─',
          -- Gauges
          textStyled (fg BrightBlack) "Gauges:      "
            <+> hbox
              [ gauge (fg Green) (fg Yellow) (fg Red) pct,
                textStyled (fg BrightBlack) "  ",
                gauge (fg Green) (fg Yellow) (fg Red) (min 1.0 (pct * 1.2)),
                textStyled (fg BrightBlack) "  ",
                gauge (fg Green) (fg Yellow) (fg Red) (min 1.0 (pct * 1.5)),
                textStyled (fg BrightBlack) "  ",
                gauge (fg Green) (fg Yellow) (fg Red) (min 1.0 (pct * 2.0))
              ],
          -- Spinners
          space 0 1,
          textStyled (fg BrightBlack) "Spinners:    "
            <+> hbox
              [ spinner (fg Cyan) tick,
                textStyled (fg BrightBlack) "  ",
                spinnerStyle (fg Magenta) "◐◓◑◒" tick,
                textStyled (fg BrightBlack) "  ",
                spinnerStyle (fg Yellow) "⣾⣽⣻⢿⡿⣟⣯⣷" tick,
                textStyled (fg BrightBlack) "  ",
                spinnerStyle (fg Green) "←↖↑↗→↘↓↙" tick,
                textStyled (fg BrightBlack) "  ",
                spinnerStyle (fg Red) "▁▂▃▄▅▆▇█▇▆▅▄▃▂" tick
              ]
        ]
  where
    gradientColor p
      | p < 0.33 = fg Red
      | p < 0.66 = fg Yellow
      | otherwise = fg Green

-- ════════════════════════════════════════════════════════════════════════════
-- Sensenet Dashboard Tests
-- ════════════════════════════════════════════════════════════════════════════

runSensenetPlaywright :: IO ()
runSensenetPlaywright = do
  putStrLn "Testing Sensenet build dashboard..."

  -- Debug: check C++ packages
  putStrLn "\n--- Debug: C++ packages ---"
  let cppPkgs = filter isCppNativeDebug sensenetPackages
  putStrLn $ "C++ package count: " <> show (length cppPkgs)
  mapM_ (\p -> putStrLn $ "  " <> T.unpack (snPkgName p) <> " | " <> T.unpack (snPkgPath p) <> " | " <> T.unpack (snPkgLang p)) cppPkgs

  -- Debug: check each group
  putStrLn "\n--- Debug: Group sizes ---"
  forM_ sensenetGroups $ \g -> do
    let items = filter (snGroupFilter g) sensenetPackages
    putStrLn $ T.unpack (snGroupLabel g) <> ": " <> show (length items) <> " packages"

  -- Now show the full dashboard
  runSensenetPlaywrightFull
  where
    isCppNativeDebug p = snPkgLang p == "cxx"
                      && snPkgPath p /= "examples/nv"
                      && not ("haskell" `T.isInfixOf` snPkgPath p)

forM_ :: [a] -> (a -> IO ()) -> IO ()
forM_ xs f = mapM_ f xs

runSensenetPlaywrightFull :: IO ()
runSensenetPlaywrightFull = do
  let dims = Dimensions 120 80

  -- Debug: test just one group
  putStrLn "\n--- Debug: Single group widget ---"
  let sigil = case sensenetGroups of { (x:_) -> x; _ -> error "no groups" }
      gw = sensenetGroupWidget sensenetPackages 3000 sigil
      gc = runWidget gw (Dimensions 100 20)
  dumpCanvas "single group" gc
  TIO.putStrLn $ renderCanvasPlain gc

  -- Debug: test groups widget
  putStrLn "\n--- Debug: All groups widget ---"
  let gwAll = sensenetGroupsWidget sensenetPackages 3000
      gcAll = runWidget gwAll (Dimensions 100 100)  -- More height to avoid truncation
  putStrLn $ "Groups canvas lines: " <> show (V.length (canvasLines gcAll))
  TIO.putStrLn $ renderCanvasPlain gcAll

  -- Test at different elapsed times
  putStrLn "\n--- Sensenet at 3000ms (early) ---"
  let w3 = sensenetBuildWidget dims sensenetPackages 3000
      c3 = runWidget w3 dims
  dumpLineWidths c3
  TIO.putStrLn $ renderCanvasPlain c3

  putStrLn "\n--- Sensenet at 6000ms (mid) ---"
  let w6 = sensenetBuildWidget dims sensenetPackages 6000
      c6 = runWidget w6 dims
  TIO.putStrLn $ renderCanvasPlain c6

runSensenetPreamblePlaywright :: IO ()
runSensenetPreamblePlaywright = do
  putStrLn "Testing Sensenet preamble..."
  let dims = Dimensions 120 40
      logs = [ SensenetLog "◉ found //src/examples/blake/BUILD.dhall" razorMuted
             , SensenetLog "◉ found //src/examples/cxx/BUILD.dhall" razorMuted
             , SensenetLog "◉ eval //src/examples/blake/BUILD.dhall (1 rules)" razorInfo
             , SensenetLog "◌ graph //..." razorAccent
             , SensenetLog "✗ miss //nv:hello" razorMiss
             ]
      w = sensenetPreambleWidget dims logs "cache" 1 39
      c = runWidget w dims
  TIO.putStrLn $ renderCanvasPlain c

runSensenetRowPlaywright :: IO ()
runSensenetRowPlaywright = do
  putStrLn "Testing Sensenet single row (debug)..."
  let dims = Dimensions 100 1

  -- Test waiting row (elapsed=0, start=1000 so waiting)
  putStrLn "\n--- Waiting row (should be 100 chars) ---"
  let waitingPkg = SensenetPackage "test:waiting-pkg" "test" "hs" 2000 1000
      waitingRow = sensenetPkgRow 0 waitingPkg
      waitingCanvas = runWidget waitingRow dims
  dumpCanvas "waiting row" waitingCanvas
  dumpLineWidths waitingCanvas

  -- Test active row (elapsed=1500, start=1000 so active)
  putStrLn "\n--- Active row (should be 100 chars) ---"
  let activePkg = SensenetPackage "test:active-pkg" "test" "hs" 2000 1000
      activeRow = sensenetPkgRow 1500 activePkg
      activeCanvas = runWidget activeRow dims
  dumpCanvas "active row" activeCanvas
  dumpLineWidths activeCanvas

  -- Test completed row
  putStrLn "\n--- Completed row (should be 100 chars) ---"
  let completedPkg = SensenetPackage "test:done-pkg" "test" "hs" 500 100
      completedRow = sensenetPkgRow 1000 completedPkg
      completedCanvas = runWidget completedRow dims
  dumpCanvas "completed row" completedCanvas
  dumpLineWidths completedCanvas

-- ════════════════════════════════════════════════════════════════════════════
-- Sensenet Types & Data (extracted from Sensenet.hs for playwright)
-- ════════════════════════════════════════════════════════════════════════════

data SensenetPackage = SensenetPackage
  { snPkgName  :: !Text
  , snPkgPath  :: !Text
  , snPkgLang  :: !Text
  , snPkgTime  :: !Int
  , snPkgStart :: !Int
  }

data SensenetGroup = SensenetGroup
  { snGroupLabel  :: !Text
  , snGroupFilter :: SensenetPackage -> Bool
  }

data SensenetLog = SensenetLog
  { snLogText  :: !Text
  , snLogStyle :: !Style
  }

sensenetPackages :: [SensenetPackage]
sensenetPackages = computeSensenetStartTimes
  [ SensenetPackage "nv:hello" "examples/nv" "cuda" 2100 0
  , SensenetPackage "nv:mdspan_device_test" "examples/nv" "cuda" 3200 0
  , SensenetPackage "nv:tensor_core" "examples/nv" "cuda" 4100 0
  , SensenetPackage "sigil-trtllm:test-rope" "sigil-trtllm" "cuda" 6200 0
  , SensenetPackage "sigil-trtllm:test-fp4-quant" "sigil-trtllm" "cuda" 3400 0
  , SensenetPackage "sigil-trtllm:sigil-eval-perplexity" "sigil-trtllm" "cuda" 4800 0
  , SensenetPackage "sigil-trtllm:sigil-inspect-checkpoint" "sigil-trtllm" "cuda" 7200 0
  , SensenetPackage "sigil-trtllm:sigil-build-engine" "sigil-trtllm" "cuda" 8800 0
  , SensenetPackage "sigil-trtllm:sigil-run-inference" "sigil-trtllm" "cuda" 5100 0
  , SensenetPackage "cxx:hello-cxx" "examples/cxx" "cxx" 900 0
  , SensenetPackage "cxx:foo" "examples/cxx" "cxx" 1100 0
  , SensenetPackage "cxx:bar" "examples/cxx" "cxx" 1300 0
  , SensenetPackage "cxx:baz" "examples/cxx" "cxx" 800 0
  , SensenetPackage "simdjson:twitter" "examples/simdjson" "cxx" 3600 0
  , SensenetPackage "haskell:hello-hs" "examples/haskell" "haskell" 2200 0
  , SensenetPackage "haskell:json_demo" "examples/haskell" "haskell" 2800 0
  , SensenetPackage "haskell:greetlib" "examples/haskell" "haskell" 1600 0
  , SensenetPackage "haskell-cxx:test_ffi" "examples/haskell-cxx" "haskell" 3100 0
  , SensenetPackage "hasktorch:hasktorch_demo" "examples/hasktorch" "haskell" 3500 0
  , SensenetPackage "hasktorch:linear_regression" "examples/hasktorch" "haskell" 3800 0
  , SensenetPackage "rust:hello-rs" "examples/rust" "rust" 1800 0
  , SensenetPackage "rust:mathlib" "examples/rust" "rust" 1200 0
  , SensenetPackage "rust-crate-test:cfg-if" "examples/rust-crate-test" "rust" 1400 0
  , SensenetPackage "rust-crate-test:once_cell" "examples/rust-crate-test" "rust" 1500 0
  , SensenetPackage "lean:hello-lean" "examples/lean" "lean" 2400 0
  , SensenetPackage "lean:hashmap" "examples/lean" "lean" 2900 0
  , SensenetPackage "lean-multifile:straylight" "examples/lean-multifile" "lean" 3900 0
  , SensenetPackage "lean-continuity:continuity" "examples/lean-continuity" "lean" 700 0
  , SensenetPackage "blake:blake" "examples/blake" "rust" 2600 0
  , SensenetPackage "sqlite-test:sqlite-test" "examples/sqlite-test" "cxx" 1100 0
  , SensenetPackage "zlib-test:zlib-test" "examples/zlib-test" "cxx" 1700 0
  , SensenetPackage "multi-dep:multi-dep" "examples/multi-dep" "cxx" 1900 0
  , SensenetPackage "cross-pkg-test/lib:greeter" "examples/cross-pkg-test" "cxx" 1000 0
  , SensenetPackage "purescript:halogen-todo" "examples/purescript" "purescript" 2700 0
  , SensenetPackage "straylight-web:straylight-web" "examples/straylight-web" "purescript" 3000 0
  , SensenetPackage "sensenet:sensenet-core" "sensenet" "haskell" 5600 0
  , SensenetPackage "sensenet:sensenet-dice" "sensenet" "haskell" 4200 0
  , SensenetPackage "sensenet:dhallfast" "sensenet" "haskell" 4500 0
  , SensenetPackage "nix-analyze:nix-analyze" "nix-analyze" "haskell" 4800 0
  ]

sensenetGroups :: [SensenetGroup]
sensenetGroups =
  [ SensenetGroup "SIGIL · TENSORRT-LLM" (\p -> snPkgPath p == "sigil-trtllm")
  , SensenetGroup "NVIDIA · CUDA" (\p -> snPkgPath p == "examples/nv")
  , SensenetGroup "SENSENET · CORE" (\p -> snPkgPath p `elem` ["sensenet", "nix-analyze"])
  , SensenetGroup "HASKELL" (\p -> snPkgPath p `elem` ["examples/haskell", "examples/haskell-cxx", "examples/hasktorch"])
  , SensenetGroup "LEAN4 · FORMAL VERIFICATION" (\p -> snPkgLang p == "lean")
  , SensenetGroup "RUST" (\p -> snPkgLang p == "rust")
  , SensenetGroup "C++ · NATIVE" (isCppNative)
  , SensenetGroup "FRONTEND" (\p -> snPkgLang p == "purescript")
  ]
  where
    isCppNative p = snPkgLang p == "cxx" 
                 && snPkgPath p /= "examples/nv" 
                 && not ("haskell" `T.isInfixOf` snPkgPath p)

computeSensenetStartTimes :: [SensenetPackage] -> [SensenetPackage]
computeSensenetStartTimes pkgs =
  let maxPar = 12
      indexed = zip [0..] pkgs
      sorted = sortBy (comparing (Down . snPkgTime . snd)) indexed
      initialLanes = replicate maxPar 0 :: [Int]
      initialStarts = replicate (length pkgs) 0 :: [Int]
      (finalStarts, _) = foldl assignPkg (initialStarts, initialLanes) sorted
  in zipWith (\p s -> p { snPkgStart = s }) pkgs finalStarts
  where
    assignPkg (starts, lanes) (origIdx, pkg) =
      let (bestLane, bestTime) = minimumByComparing snd (zip [0..] lanes)
          newLaneEnd = bestTime + snPkgTime pkg
          newLanes = updateAt bestLane newLaneEnd lanes
          newStarts = updateAt origIdx bestTime starts
      in (newStarts, newLanes)
    minimumByComparing f = foldr1 (\a b -> if f a <= f b then a else b)
    updateAt i v xs = take i xs ++ [v] ++ drop (i + 1) xs

-- ════════════════════════════════════════════════════════════════════════════
-- Sensenet Widgets (for playwright testing)
-- ════════════════════════════════════════════════════════════════════════════

sensenetBuildWidget :: Dimensions -> [SensenetPackage] -> Int -> Widget
sensenetBuildWidget _dims pkgs elapsed =
  vboxWith [Exact 3, Exact 1, Exact 4, Exact 1, Fill 1, Exact 1]
    [ sensenetHeaderWidget
    , space 0 1
    , sensenetStatsWidget pkgs elapsed
    , space 0 1
    , sensenetGroupsWidget pkgs elapsed
    , sensenetFooterWidget
    ]

sensenetPreambleWidget :: Dimensions -> [SensenetLog] -> Text -> Int -> Int -> Widget
sensenetPreambleWidget dims logs phase current total =
  vbox
    [ sensenetHeaderWidget
    , space 0 1
    , sensenetLogStreamWidget dims logs
    , space 0 1
    , sensenetPreambleStatus phase current total
    , sensenetFooterWidget
    ]

sensenetHeaderWidget :: Widget
sensenetHeaderWidget =
  vbox
    [ textStyled razorMuted "STRAYLIGHT SOFTWARE · BUILD MONITOR"
    , hbox
        [ textStyled razorMuted "> "
        , textStyled (bold razorBright) "sensenet build "
        , textStyled razorBright "// ..."
        , textStyled razorAccent " █"
        ]
    , textStyled razorDim "railgun · shell-autocomplete · 39 targets · dhall → nix → exec"
    ]

sensenetStatsWidget :: [SensenetPackage] -> Int -> Widget
sensenetStatsWidget pkgs elapsed =
  hboxWith [Fill 1, Fill 1, Fill 1]
    [ sensenetStatCard "TARGETS" (T.pack (show done)) (Just ("/ " <> T.pack (show total))) razorBright
    , sensenetStatCard "ELAPSED" (sensenetFormatElapsed elapsed) (Just "s") razorBright
    , sensenetStatCard "CACHE HITS" "0" (Just "%") razorMiss
    ]
  where
    total = length pkgs
    done = length [p | p <- pkgs, elapsed >= snPkgStart p + snPkgTime p]

sensenetStatCard :: Text -> Text -> Maybe Text -> Style -> Widget
sensenetStatCard label value mUnit valueStyle =
  borderedStyled razorRule $
    padded 0 1 0 1 $
      vbox
        [ textStyled razorMuted label
        , hbox $
            [ textStyled (bold valueStyle) value ] ++
            maybe [] (\u -> [textStyled razorMuted u]) mUnit
        ]

sensenetFormatElapsed :: Int -> Text
sensenetFormatElapsed ms =
  let s = fromIntegral ms / 1000.0 :: Double
      whole = floor s :: Int
      frac = round ((s - fromIntegral whole) * 10) :: Int
  in T.pack (show whole) <> "." <> T.pack (show (frac `mod` 10))

sensenetGroupsWidget :: [SensenetPackage] -> Int -> Widget
sensenetGroupsWidget pkgs elapsed =
  let groupWidgets = map (sensenetGroupWidget pkgs elapsed) sensenetGroups
      -- Use Exact 1 per line - each group is (1 header + n packages) lines
      groupSizes = map (groupLineCount pkgs) sensenetGroups
      constraints = map Exact groupSizes
  in vboxWith constraints groupWidgets
  where
    groupLineCount ps g = 
      let items = filter (snGroupFilter g) ps
      in if null items then 0 else 1 + length items

sensenetGroupWidget :: [SensenetPackage] -> Int -> SensenetGroup -> Widget
sensenetGroupWidget pkgs elapsed SensenetGroup{..} =
  let items = filter snGroupFilter pkgs
      done = length [p | p <- items, elapsed >= snPkgStart p + snPkgTime p]
      total = length items
      countStyle = if done == total then razorAccent else razorMuted
      -- Use Exact 1 for each line
      constraints = replicate (1 + length items) (Exact 1)
  in if null items then empty else
     vboxWith constraints $
       [ sensenetGroupHeaderWidget snGroupLabel done total countStyle
       ] ++ map (sensenetPkgRow elapsed) items

sensenetGroupHeaderWidget :: Text -> Int -> Int -> Style -> Widget
sensenetGroupHeaderWidget label done total countStyle =
  -- Count column: " X/YY" - max width is " 39/39" = 6 chars, pad to 7 for spacing
  let countText = T.pack (show done) <> "/" <> T.pack (show total)
      paddedCount = snPadLeft 6 countText  -- right-align the count
      labelText = " " <> label <> " "
      labelLen = T.length labelText
  in hboxWith [Exact 2, Exact labelLen, Fill 1, Exact 7]
       [ textStyled razorAccent "//"
       , textStyled razorMuted labelText
       , fill razorRule '─'
       , textStyled countStyle (" " <> paddedCount)
       ]

sensenetPkgRow :: Int -> SensenetPackage -> Widget
sensenetPkgRow elapsed pkg =
  let rawPct = sensenetClamp01 (fromIntegral (elapsed - snPkgStart pkg) / fromIntegral (snPkgTime pkg))
      pct = sensenetPerceptual rawPct
      done = rawPct >= 1
      active = elapsed >= snPkgStart pkg && not done
      waiting = elapsed < snPkgStart pkg

      glyph | done      = "✓"
            | active    = "→"
            | otherwise = "○"

      glyphStyle | done      = razorAccent
                 | active    = razorAccent
                 | otherwise = razorDim

      nameStyle | done      = razorMuted
                | active    = razorBright
                | otherwise = razorDim

      timeStr | done      = sensenetFormatSecs (snPkgTime pkg)
              | active    = sensenetFormatSecs (elapsed - snPkgStart pkg)
              | otherwise = ""

      timeStyle = razorMuted
      barStyle = razorAccent
      barEmptyStyle = razorDim
      
      -- Pad name to fixed width so progress bars align
      nameText = "//" <> snPkgName pkg
      paddedName = snPadRight 40 nameText  -- longest name is 38 chars + //
  in if waiting
       -- Waiting rows: extend the fill to cover time column (no trailing spaces)
       then hboxWith [Exact 2, Exact 40, Exact 1, Fill 1]
              [ textStyled glyphStyle (glyph <> " ")
              , textStyled nameStyle paddedName
              , textStyled razorDim " "
              , fill razorDim '─'
              ]
       -- Active/completed rows: show progress bar and time
       else hboxWith [Exact 2, Exact 40, Exact 1, Fill 1, Exact 1, Exact 5]
              [ textStyled glyphStyle (glyph <> " ")
              , textStyled nameStyle paddedName
              , textStyled razorDim " "
              , sensenetProgressThin barStyle barEmptyStyle pct
              , textStyled razorDim " "
              , textStyled timeStyle (snPadLeft 5 timeStr)
              ]

-- | Pad text to width on the right (left-align)
snPadRight :: Int -> Text -> Text
snPadRight w t = 
  let len = T.length t
  in if len >= w then T.take w t else t <> T.replicate (w - len) " "

-- | Pad text to width on the left (right-align)
snPadLeft :: Int -> Text -> Text
snPadLeft w t =
  let len = T.length t
  in if len >= w then t else T.replicate (w - len) " " <> t

sensenetProgressThin :: Style -> Style -> Double -> Widget
sensenetProgressThin filledStyle emptyStyle pct = Widget $ \dims ->
  let w = width dims
      filled = max 0 (min w (round (pct * fromIntegral w)))
      unfilled = w - filled
      bar = Seq.fromList
              [ Span filledStyle (T.replicate filled "━")
              , Span emptyStyle (T.replicate unfilled "─")
              ]
  in Canvas (V.singleton bar) (Dimensions w 1)

sensenetLogStreamWidget :: Dimensions -> [SensenetLog] -> Widget
sensenetLogStreamWidget dims logs =
  let visibleCount = max 12 (height dims - 12)
      visible = take visibleCount (reverse logs)
      renderLine i (SensenetLog txt style) =
        let opacity = if i < 3 then dim style else style
        in textStyled opacity txt
  in vbox (zipWith renderLine [0..] (reverse visible))

sensenetPreambleStatus :: Text -> Int -> Int -> Widget
sensenetPreambleStatus phase current total =
  let statusText = case phase of
        "scan"  -> T.pack (show current) <> "/" <> T.pack (show total) <> " packages"
        "parse" -> T.pack (show current) <> "/" <> T.pack (show total) <> " parsed"
        "graph" -> "computing dependency graph..."
        "cache" -> T.pack (show current) <> "/" <> T.pack (show total) <> " cache checks"
        _       -> ""
  in hbox
       [ fill razorRule '─'
       , textStyled razorDim (" " <> statusText <> " ")
       ]

sensenetFooterWidget :: Widget
sensenetFooterWidget =
  hbox
    [ textStyled razorMuted "SENSENET · DHALL + NIX + CAS"
    , fill defaultStyle ' '
    , textStyled razorDim "the one rectilinear chamber in the complex"
    ]

sensenetPerceptual :: Double -> Double
sensenetPerceptual x
  | x <= 0    = 0
  | x >= 1    = 1
  | x < 0.4   = (x / 0.4) * 0.75
  | otherwise = 0.75 + ((x - 0.4) / 0.6) * 0.25

sensenetClamp01 :: Double -> Double
sensenetClamp01 x = max 0 (min 1 x)

sensenetFormatSecs :: Int -> Text
sensenetFormatSecs ms =
  let s = fromIntegral ms / 1000.0 :: Double
      whole = floor s :: Int
      frac = round ((s - fromIntegral whole) * 10) :: Int
  in T.pack (show whole) <> "." <> T.pack (show (frac `mod` 10)) <> "s"
