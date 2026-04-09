{-# LANGUAGE OverloadedStrings #-}

-- | HyperConsole Demo Suite
--
-- "The sky above the port was the color of television,
--  tuned to a dead channel."
--
--                                      — Neuromancer
--
-- Beautiful demonstrations of HyperConsole's capabilities.
module Main where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as T
import HyperConsole
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["--help"] -> printHelp
    ["-h"] -> printHelp
    ["build"] -> runBuildDemo
    ["dashboard"] -> runDashboardDemo
    ["progress"] -> runProgressDemo
    ["table"] -> runTableDemo
    ["sparkline"] -> runSparklineDemo
    ["all"] -> runAllDemos
    [] -> runAllDemos
    _ -> printHelp

printHelp :: IO ()
printHelp = do
  putStrLn "HyperConsole Demo Suite"
  putStrLn ""
  putStrLn "Usage: hyperconsole-demo [DEMO]"
  putStrLn ""
  putStrLn "Available demos:"
  putStrLn "  build       Animated build progress simulation"
  putStrLn "  dashboard   System monitoring dashboard"
  putStrLn "  progress    Progress bar variants"
  putStrLn "  table       Styled tables"
  putStrLn "  sparkline   Real-time sparkline charts"
  putStrLn "  all         Run all demos (default)"
  putStrLn ""
  putStrLn "Examples:"
  putStrLn "  hyperconsole-demo build"
  putStrLn "  hyperconsole-demo dashboard"

runAllDemos :: IO ()
runAllDemos = do
  runProgressDemo
  threadDelay 500000
  runTableDemo
  threadDelay 500000
  runSparklineDemo
  threadDelay 500000
  runBuildDemo
  threadDelay 500000
  runDashboardDemo

-- ════════════════════════════════════════════════════════════════════════════
-- Build Demo - Simulated Build System
-- ════════════════════════════════════════════════════════════════════════════

runBuildDemo :: IO ()
runBuildDemo = withConsole $ \console -> do
  let targets =
        [ ("//core:foundation", 15),
          ("//core:runtime", 25),
          ("//lib:network", 20),
          ("//lib:crypto", 30),
          ("//lib:storage", 18),
          ("//app:server", 35),
          ("//app:client", 28),
          ("//test:unit", 12),
          ("//test:integration", 22)
        ]

  forM_ (zip [0 ..] targets) $ \(idx, (target, duration)) -> do
    -- Building phase
    forM_ [0 .. duration] $ \tick -> do
      let pct = fromIntegral tick / fromIntegral duration
          completed = take idx targets
          building = (target, pct)
          pending = drop (idx + 1) targets
      render console $ buildWidget completed building pending tick
      threadDelay 40000

  -- Final state
  render console $ buildCompleteWidget targets
  threadDelay 2000000
  clear console

buildWidget :: [(Text, Int)] -> (Text, Double) -> [(Text, Int)] -> Int -> Widget
buildWidget completed (current, pct) pending tick =
  bordered $
    padded 1 2 1 2 $
      vbox
        [ titleBar,
          rule defaultStyle '─',
          space 0 1,
          completedSection,
          currentSection,
          pendingSection,
          space 0 1,
          rule defaultStyle '─',
          statusBar tick
        ]
  where
    titleBar =
      hbox
        [ textStyled (bold (fg BrightWhite)) "⚡ SENSENET BUILD SYSTEM",
          fill defaultStyle ' ',
          textStyled (fg BrightBlack) "v2.0.1"
        ]

    completedSection =
      if null completed
        then empty
        else
          vbox $
            [textStyled (dim (fg Green)) "✓ Completed:"]
              ++ [ hbox
                     [ textStyled (fg Green) "  ✓ ",
                       textStyled (fg White) name,
                       fill defaultStyle ' ',
                       textStyled (dim (fg Green)) (T.pack $ show dur <> "ms")
                     ]
                 | (name, dur) <- take 5 (reverse completed)
                 ]

    currentSection =
      vbox
        [ space 0 1,
          hbox
            [ spinner (fg Cyan) tick,
              textStyled (bold (fg Cyan)) " Building: ",
              textStyled (fg White) current
            ],
          padded 0 4 0 4 $
            hbox
              [ progress (fg Cyan) (fg BrightBlack) pct,
                textStyled (fg Yellow) (T.pack $ " " <> show (round (pct * 100) :: Int) <> "%")
              ]
        ]

    pendingSection =
      if null pending
        then empty
        else
          vbox $
            [space 0 1, textStyled (dim (fg Yellow)) "⏳ Pending:"]
              ++ [ hbox
                     [ textStyled (fg BrightBlack) "  ○ ",
                       textStyled (dim (fg White)) name
                     ]
                 | (name, _) <- take 3 pending
                 ]

    statusBar t =
      hbox
        [ textStyled (fg BrightBlack) "Workers: ",
          textStyled (fg Green) "4",
          textStyled (fg BrightBlack) " │ Memory: ",
          textStyled (fg Yellow) "2.1 GB",
          textStyled (fg BrightBlack) " │ Cache: ",
          textStyled (fg Green) "89%",
          fill defaultStyle ' ',
          textStyled (dim (fg BrightBlack)) (spinnerText t)
        ]

    spinnerText t =
      let frames = ["◐", "◓", "◑", "◒"] :: [Text]
       in frames !! (t `mod` 4)

buildCompleteWidget :: [(Text, Int)] -> Widget
buildCompleteWidget targets =
  bordered $
    padded 1 2 1 2 $
      vbox
        [ hbox
            [ textStyled (bold (fg BrightGreen)) "✓ BUILD SUCCESSFUL",
              fill defaultStyle ' ',
              textStyled (fg BrightBlack) "sensenet v2.0.1"
            ],
          rule defaultStyle '─',
          space 0 1,
          hbox
            [ textStyled (fg White) "Targets: ",
              textStyled (bold (fg Green)) (T.pack $ show (length targets)),
              textStyled (fg BrightBlack) " │ ",
              textStyled (fg White) "Time: ",
              textStyled (bold (fg Cyan)) "3.2s",
              textStyled (fg BrightBlack) " │ ",
              textStyled (fg White) "Cache hits: ",
              textStyled (bold (fg Yellow)) "76%"
            ],
          space 0 1,
          rule defaultStyle '─',
          textStyled (dim (fg BrightBlack)) "Run 'sensenet test' to execute tests"
        ]

-- ════════════════════════════════════════════════════════════════════════════
-- Dashboard Demo - System Monitoring
-- ════════════════════════════════════════════════════════════════════════════

runDashboardDemo :: IO ()
runDashboardDemo = withConsole $ \console -> do
  forM_ [0 .. 150] $ \tick -> do
    render console $ dashboardWidget tick
    threadDelay 100000
  clear console

dashboardWidget :: Int -> Widget
dashboardWidget tick =
  vbox
    [ headerWidget,
      hboxWith
        [Fill 1, Fill 1]
        [ vbox [cpuWidget tick, memoryWidget tick],
          vbox [networkWidget tick, processWidget tick]
        ],
      footerWidget tick
    ]

headerWidget :: Widget
headerWidget =
  borderedStyled (fg BrightBlue) $
    padded 0 1 0 1 $
      hbox
        [ textStyled (bold (fg BrightCyan)) "◆ STRAYLIGHT SYSTEMS MONITOR",
          fill defaultStyle ' ',
          textStyled (fg BrightBlack) "[ ",
          textStyled (fg Green) "ONLINE",
          textStyled (fg BrightBlack) " ]"
        ]

cpuWidget :: Int -> Widget
cpuWidget tick =
  titled (fg Cyan) "CPU Usage" $
    padded 0 1 0 1 $
      vbox
        [ cpuCore "Core 0" (oscillate 0.3 0.8 tick 7),
          cpuCore "Core 1" (oscillate 0.2 0.6 tick 11),
          cpuCore "Core 2" (oscillate 0.4 0.9 tick 5),
          cpuCore "Core 3" (oscillate 0.1 0.5 tick 13),
          space 0 1,
          hbox
            [ textStyled (fg BrightBlack) "Load: ",
              textStyled (fg Yellow) (formatLoad $ oscillate 1.2 3.8 tick 9)
            ]
        ]
  where
    cpuCore name pct =
      hbox
        [ textStyled (fg BrightBlack) (name <> " "),
          progress (cpuColor pct) (fg BrightBlack) pct,
          textStyled (fg White) (T.pack $ " " <> show (round (pct * 100) :: Int) <> "%")
        ]
    cpuColor p
      | p > 0.8 = fg Red
      | p > 0.6 = fg Yellow
      | otherwise = fg Green
    formatLoad d =
      let n = round (d * 10) :: Int
       in T.pack $ show (n `div` 10) <> "." <> show (n `mod` 10)

memoryWidget :: Int -> Widget
memoryWidget tick =
  titled (fg Magenta) "Memory" $
    padded 0 1 0 1 $
      vbox
        [ hbox
            [ textStyled (fg BrightBlack) "Used:  ",
              gauge (fg Green) (fg Yellow) (fg Red) (oscillate 0.4 0.7 tick 17),
              textStyled (fg White) " 12.4 GB / 32 GB"
            ],
          hbox
            [ textStyled (fg BrightBlack) "Swap:  ",
              gauge (fg Green) (fg Yellow) (fg Red) (oscillate 0.1 0.3 tick 23),
              textStyled (fg White) " 0.8 GB / 8 GB"
            ],
          space 0 1,
          hbox
            [ textStyled (fg BrightBlack) "Buffers: ",
              textStyled (fg Cyan) "2.1 GB",
              textStyled (fg BrightBlack) " │ Cached: ",
              textStyled (fg Cyan) "8.3 GB"
            ]
        ]

networkWidget :: Int -> Widget
networkWidget tick =
  titled (fg Green) "Network I/O" $
    padded 0 1 0 1 $
      vbox
        [ hbox
            [ textStyled (fg BrightBlack) "↓ RX: ",
              textStyled (fg Green) (T.pack $ show (round (oscillate 10 150 tick 3) :: Int) <> " MB/s"),
              fill defaultStyle ' ',
              sparkline (fg Green) (take 20 $ networkData tick)
            ],
          hbox
            [ textStyled (fg BrightBlack) "↑ TX: ",
              textStyled (fg Cyan) (T.pack $ show (round (oscillate 5 80 tick 7) :: Int) <> " MB/s"),
              fill defaultStyle ' ',
              sparkline (fg Cyan) (take 20 $ networkData (tick + 50))
            ],
          space 0 1,
          hbox
            [ textStyled (fg BrightBlack) "Connections: ",
              textStyled (fg Yellow) "1,247",
              textStyled (fg BrightBlack) " │ Packets: ",
              textStyled (fg Yellow) "892K/s"
            ]
        ]
  where
    networkData t = [oscillate 0.1 1.0 (t + i * 3) (7 + i `mod` 5) | i <- [0 .. 30]]

processWidget :: Int -> Widget
processWidget tick =
  titled (fg Yellow) "Top Processes" $
    padded 0 1 0 1 $
      vbox
        [ procRow "ghc" (oscillate 15 35 tick 5) (fg Magenta),
          procRow "nix-daemon" (oscillate 8 20 tick 11) (fg Cyan),
          procRow "firefox" (oscillate 5 15 tick 7) (fg Yellow),
          procRow "postgres" (oscillate 3 10 tick 13) (fg Green),
          procRow "systemd" (oscillate 1 5 tick 17) (fg BrightBlack)
        ]
  where
    procRow name pct col =
      hbox
        [ textStyled col (T.justifyLeft 12 ' ' name),
          progress col (fg BrightBlack) (pct / 100),
          textStyled (fg White) (T.pack $ " " <> show (round pct :: Int) <> "%")
        ]

footerWidget :: Int -> Widget
footerWidget tick =
  hbox
    [ textStyled (fg BrightBlack) "Uptime: ",
      textStyled (fg White) "14d 7h 32m",
      textStyled (fg BrightBlack) " │ Updated: ",
      textStyled (fg White) "now",
      fill defaultStyle ' ',
      spinner (fg Cyan) tick,
      textStyled (fg BrightBlack) " Refreshing..."
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Progress Demo - Various Progress Styles
-- ════════════════════════════════════════════════════════════════════════════

runProgressDemo :: IO ()
runProgressDemo = withConsole $ \console -> do
  forM_ [0 .. 100] $ \i -> do
    let pct = fromIntegral i / 100.0
    render console $ progressShowcase pct i
    threadDelay 50000
  clear console

progressShowcase :: Double -> Int -> Widget
progressShowcase pct tick =
  bordered $
    padded 1 2 1 2 $
      vbox
        [ textStyled (bold (fg BrightWhite)) "Progress Bar Showcase",
          rule (fg BrightBlack) '─',
          space 0 1,
          -- Standard
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
-- Table Demo - Styled Tables
-- ════════════════════════════════════════════════════════════════════════════

runTableDemo :: IO ()
runTableDemo = withConsole $ \console -> do
  render console tableShowcase
  threadDelay 3000000
  clear console

tableShowcase :: Widget
tableShowcase =
  vbox
    [ titled (fg Cyan) "Build Targets" $
        padded 0 1 0 1 $
          tableStyled
            (bold (fg BrightWhite))
            (fg White)
            ["Target", "Status", "Duration", "Cache"]
            [ ["//core:lib", "✓ PASS", "1.2s", "HIT"],
              ["//core:runtime", "✓ PASS", "2.8s", "MISS"],
              ["//net:http", "✓ PASS", "0.9s", "HIT"],
              ["//net:grpc", "⟳ BUILD", "...", "-"],
              ["//app:server", "○ PEND", "-", "-"]
            ],
      space 0 1,
      titled (fg Yellow) "System Resources" $
        padded 0 1 0 1 $
          tableStyled
            (bold (fg BrightYellow))
            (fg White)
            ["Resource", "Used", "Available", "Usage"]
            [ ["CPU", "2.4 GHz", "4.0 GHz", "60%"],
              ["Memory", "12.1 GB", "32 GB", "38%"],
              ["Disk", "234 GB", "1 TB", "23%"],
              ["Network", "45 MB/s", "1 GB/s", "4%"]
            ],
      space 0 1,
      titled (fg Magenta) "Recent Events" $
        padded 0 1 0 1 $
          tree
            defaultStyle
            (fg Cyan)
            [ (0, "2024-02-25 14:32:01 - Build started"),
              (1, "Compiling core modules..."),
              (1, "Compiling network modules..."),
              (0, "2024-02-25 14:32:04 - Tests running"),
              (1, "Unit tests: 142 passed"),
              (1, "Integration tests: 28 passed"),
              (0, "2024-02-25 14:32:08 - Build complete")
            ]
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Sparkline Demo - Real-time Charts
-- ════════════════════════════════════════════════════════════════════════════

runSparklineDemo :: IO ()
runSparklineDemo = withConsole $ \console -> do
  forM_ [0 .. 100] $ \tick -> do
    render console $ sparklineShowcase tick
    threadDelay 100000
  clear console

sparklineShowcase :: Int -> Widget
sparklineShowcase tick =
  bordered $
    padded 1 2 1 2 $
      vbox
        [ textStyled (bold (fg BrightWhite)) "Real-time Metrics",
          rule (fg BrightBlack) '─',
          space 0 1,
          metricRow "CPU Load" (fg Green) (cpuData tick) "%",
          metricRow "Memory" (fg Cyan) (memData tick) "GB",
          metricRow "Network RX" (fg Yellow) (netRxData tick) "MB/s",
          metricRow "Network TX" (fg Magenta) (netTxData tick) "MB/s",
          metricRow "Disk I/O" (fg Red) (diskData tick) "MB/s",
          metricRow "Requests" (fg BrightGreen) (reqData tick) "K/s",
          space 0 1,
          rule (fg BrightBlack) '─',
          statusLine
            (fg BrightBlack)
            (fg White)
            [ ("Samples", T.pack $ show (tick + 1)),
              ("Interval", "100ms"),
              ("Buffer", "30s")
            ]
        ]
  where
    metricRow name color dataPoints unit =
      hbox
        [ textStyled (fg BrightBlack) (T.justifyLeft 12 ' ' (name <> ":")),
          sparkline color (take 40 dataPoints),
          textStyled color (T.pack $ " " <> show (round (safeLastOr 0 (take 40 dataPoints) * 100) :: Int) <> unit)
        ]

    safeLastOr d [] = d
    safeLastOr _ xs = last xs

    cpuData t = [oscillate 0.2 0.8 (t + i) 7 | i <- [0 .. 50]]
    memData t = [oscillate 0.3 0.6 (t + i) 13 | i <- [0 .. 50]]
    netRxData t = [oscillate 0.1 0.9 (t + i) 5 | i <- [0 .. 50]]
    netTxData t = [oscillate 0.1 0.5 (t + i) 11 | i <- [0 .. 50]]
    diskData t = [oscillate 0.0 0.7 (t + i) 17 | i <- [0 .. 50]]
    reqData t = [oscillate 0.2 1.0 (t + i) 3 | i <- [0 .. 50]]

-- ════════════════════════════════════════════════════════════════════════════
-- Utilities
-- ════════════════════════════════════════════════════════════════════════════

-- | Oscillate between min and max with period
oscillate :: Double -> Double -> Int -> Int -> Double
oscillate minVal maxVal tick period =
  let t = fromIntegral tick / fromIntegral period
      wave = (sin (t * 2 * pi) + 1) / 2
   in minVal + wave * (maxVal - minVal)
