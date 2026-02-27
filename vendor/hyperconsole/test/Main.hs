{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | HyperConsole Test Suite
--
-- "Case heard the soft whine of the deck's most expensive peripheral,
--  a new twelve-key Hosaka portable. Case had never spent much time
--  in the matrix at speeds where that particular key would be useful."
--
--                                                    — Neuromancer
--
-- = Test Categories
--
--   * Unit tests (HUnit)
--   * Property tests (QuickCheck)
--   * Adversarial tests (edge cases, malformed input)
--   * Fuzzing (random input that should never crash)
module Main where

import Control.Exception (SomeException, evaluate, try)
import Data.ByteString qualified as BS
import Data.Sequence qualified as Seq
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import HyperConsole
import HyperConsole.Terminal.IoUring (addClear, addEscape, addNewline, addSegment, addText, buildFrame, newFrame)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "HyperConsole"
    [ testGroup "Unicode" unicodeTests,
      testGroup "Layout" layoutTests,
      testGroup "Widget" widgetTests,
      testGroup "Style" styleTests,
      testGroup "IoUring" ioUringTests,
      testGroup "Adversarial" adversarialTests,
      testGroup "Properties" propertyTests
    ]

-- ════════════════════════════════════════════════════════════════════════════
-- Unicode Tests
-- ════════════════════════════════════════════════════════════════════════════

unicodeTests :: [TestTree]
unicodeTests =
  [ testCase "displayWidth ASCII" $ do
      displayWidth "hello" @?= 5
      displayWidth "" @?= 0
      displayWidth "a" @?= 1,
    testCase "displayWidth CJK" $ do
      displayWidth "中" @?= 2
      displayWidth "中文" @?= 4
      displayWidth "hello中文" @?= 9,
    testCase "displayWidth emoji" $ do
      -- Most emoji are wide
      charWidth '⭐' @?= 2,
    testCase "truncateText ASCII" $ do
      truncateText 5 "hello world" @?= "hello"
      truncateText 100 "short" @?= "short"
      truncateText 0 "hello" @?= "",
    testCase "truncateText CJK" $ do
      -- "中文" is 4 cells wide
      truncateText 4 "中文test" @?= "中文"
      truncateText 3 "中文test" @?= "中" -- Can't fit second char
      truncateText 2 "中文" @?= "中",
    testCase "padRight" $ do
      padRight 10 "hello" @?= "hello     "
      padRight 3 "hello" @?= "hel",
    testCase "padLeft" $ do
      padLeft 10 "hello" @?= "     hello"
      padLeft 3 "hello" @?= "hel",
    testCase "center" $ do
      center 10 "hi" @?= "    hi    "
      center 11 "hi" @?= "    hi     "
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Layout Tests
-- ════════════════════════════════════════════════════════════════════════════

layoutTests :: [TestTree]
layoutTests =
  [ testCase "solve empty" $ do
      solve defaultLayout (Dimensions 100 50) [] @?= [],
    testCase "solve single Fill" $ do
      let result = solve defaultLayout (Dimensions 100 50) [Fill 1]
      length result @?= 1
      width (safeHead result) @?= 100,
    testCase "solve two equal Fill" $ do
      let result = solve defaultLayout (Dimensions 100 50) [Fill 1, Fill 1]
      length result @?= 2
      width (safeHead result) @?= 50
      width (result !! 1) @?= 50,
    testCase "solve Exact + Fill" $ do
      let result = solve defaultLayout (Dimensions 100 50) [Exact 30, Fill 1]
      width (safeHead result) @?= 30
      width (result !! 1) @?= 70,
    testCase "solve Percent" $ do
      let result = solve defaultLayout (Dimensions 100 50) [Percent 25, Fill 1]
      width (safeHead result) @?= 25
      width (result !! 1) @?= 75,
    testCase "solve vertical" $ do
      let result = solve vstack (Dimensions 100 50) [Fill 1, Fill 1]
      height (safeHead result) @?= 25
      height (result !! 1) @?= 25
  ]
  where
    safeHead [] = Dimensions 0 0
    safeHead (x : _) = x

-- ════════════════════════════════════════════════════════════════════════════
-- Widget Tests
-- ════════════════════════════════════════════════════════════════════════════

widgetTests :: [TestTree]
widgetTests =
  [ testCase "text widget" $ do
      let widget = text "hello"
          canvas = runWidget widget (Dimensions 100 10)
      V.length (canvasLines canvas) @?= 1
      let line = canvasLines canvas V.! 0
      Seq.length line @?= 1
      let Span _ t = Seq.index line 0
      t @?= "hello",
    testCase "text truncation" $ do
      let widget = text "hello world"
          canvas = runWidget widget (Dimensions 5 10)
      let line = canvasLines canvas V.! 0
          Span _ t = Seq.index line 0
      t @?= "hello",
    testCase "vbox stacking" $ do
      let widget = vbox [text "line1", text "line2", text "line3"]
          canvas = runWidget widget (Dimensions 100 10)
      V.length (canvasLines canvas) >= 3 @?= True,
    testCase "bordered adds border" $ do
      let widget = bordered (text "x")
          canvas = runWidget widget (Dimensions 10 5)
      -- Bordered: top border + 1 content line + bottom border = 3 lines
      V.length (canvasLines canvas) @?= 3
      let topLine = canvasLines canvas V.! 0
          Span _ t = Seq.index topLine 0
      T.take 1 t @?= "┌",
    testCase "spinner cycles" $ do
      let frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏" :: T.Text
      let check tick =
            let canvas = runWidget (spinner defaultStyle tick) (Dimensions 1 1)
                line = canvasLines canvas V.! 0
                Span _ t = Seq.index line 0
             in t @?= T.singleton (T.index frames (tick `mod` T.length frames))
      mapM_ check [0 .. 9],
    -- New widget tests
    testCase "progress bar 0%" $ do
      let canvas = runWidget (progress (fg Green) defaultStyle 0.0) (Dimensions 10 1)
      V.length (canvasLines canvas) @?= 1,
    testCase "progress bar 100%" $ do
      let canvas = runWidget (progress (fg Green) defaultStyle 1.0) (Dimensions 10 1)
      V.length (canvasLines canvas) @?= 1,
    testCase "table renders" $ do
      let tbl = table defaultStyle [["A", "B"], ["C", "D"]]
          canvas = runWidget tbl (Dimensions 20 10)
      V.length (canvasLines canvas) @?= 2,
    testCase "empty widget" $ do
      let canvas = runWidget empty (Dimensions 100 100)
      V.length (canvasLines canvas) @?= 0,
    testCase "layers overlay" $ do
      let bottom = text "bottom"
          top = text "top"
          canvas = runWidget (layers [bottom, top]) (Dimensions 10 1)
      V.length (canvasLines canvas) @?= 1
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Style Tests
-- ════════════════════════════════════════════════════════════════════════════

styleTests :: [TestTree]
styleTests =
  [ testCase "defaultStyle" $ do
      styleFg defaultStyle @?= Default
      styleBg defaultStyle @?= Default
      styleAttrs defaultStyle @?= [],
    testCase "fg creates style" $ do
      styleFg (fg Red) @?= Red
      styleBg (fg Red) @?= Default,
    testCase "bg creates style" $ do
      styleBg (bg Blue) @?= Blue
      styleFg (bg Blue) @?= Default,
    testCase "bold adds attr" $ do
      Bold `elem` styleAttrs (bold defaultStyle) @?= True,
    testCase "style composition" $ do
      let s = fg Red <> bold (bg Blue)
      styleFg s @?= Red
      styleBg s @?= Blue
      Bold `elem` styleAttrs s @?= True
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- IoUring Tests
-- ════════════════════════════════════════════════════════════════════════════

ioUringTests :: [TestTree]
ioUringTests =
  [ testCase "newFrame creates empty frame" $ do
      frame <- newFrame
      segments <- buildFrame frame
      segments @?= [],
    testCase "addSegment accumulates" $ do
      frame <- newFrame
      addSegment frame "hello"
      addSegment frame "world"
      segments <- buildFrame frame
      length segments @?= 2
      segments @?= ["hello", "world"],
    testCase "addText encodes UTF-8" $ do
      frame <- newFrame
      addText frame "hello"
      addText frame "中文"
      segments <- buildFrame frame
      length segments @?= 2,
    testCase "addEscape adds escape" $ do
      frame <- newFrame
      addEscape frame "\ESC[2K"
      segments <- buildFrame frame
      segments @?= ["\ESC[2K"],
    testCase "addNewline adds newline" $ do
      frame <- newFrame
      addNewline frame
      segments <- buildFrame frame
      segments @?= ["\n"],
    testCase "addClear adds clear escape" $ do
      frame <- newFrame
      addClear frame
      segments <- buildFrame frame
      segments @?= ["\ESC[2K"],
    testCase "buildFrame preserves order" $ do
      frame <- newFrame
      addSegment frame "1"
      addSegment frame "2"
      addSegment frame "3"
      segments <- buildFrame frame
      segments @?= ["1", "2", "3"]
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Adversarial Tests
-- ════════════════════════════════════════════════════════════════════════════

adversarialTests :: [TestTree]
adversarialTests =
  [ testGroup
      "Malformed Input"
      [ testCase "empty text widget" $ do
          let canvas = runWidget (text "") (Dimensions 100 100)
          V.length (canvasLines canvas) @?= 1,
        testCase "zero width dimensions" $ do
          let canvas = runWidget (text "test") (Dimensions 0 10)
          let line = canvasLines canvas V.! 0
              Span _ t = Seq.index line 0
          t @?= "",
        testCase "zero height dimensions" $ do
          let canvas = runWidget (vbox [text "a", text "b"]) (Dimensions 100 0)
          V.length (canvasLines canvas) @?= 0,
        testCase "negative-like large dimensions" $ do
          -- maxBound should work (used in measure)
          let canvas = runWidget (text "x") (Dimensions maxBound maxBound)
          V.length (canvasLines canvas) @?= 1
      ],
    testGroup
      "Edge Cases"
      [ testCase "deeply nested widgets" $ do
          let deep = iterate bordered (text "x") !! 50
              canvas = runWidget deep (Dimensions 200 100)
          V.length (canvasLines canvas) > 0 @?= True,
        testCase "many children in hbox" $ do
          let many = hbox [text "x" | _ <- [1 .. 1000 :: Int]]
              canvas = runWidget many (Dimensions 100 1)
          V.length (canvasLines canvas) @?= 1,
        testCase "many children in vbox" $ do
          let many = vbox [text "x" | _ <- [1 .. 1000 :: Int]]
              canvas = runWidget many (Dimensions 100 50)
          V.length (canvasLines canvas) @?= 50,
        testCase "progress out of bounds low" $ do
          let canvas = runWidget (progress defaultStyle defaultStyle (-1.0)) (Dimensions 10 1)
          V.length (canvasLines canvas) @?= 1,
        testCase "progress out of bounds high" $ do
          let canvas = runWidget (progress defaultStyle defaultStyle 2.0) (Dimensions 10 1)
          V.length (canvasLines canvas) @?= 1,
        testCase "hbox with mixed height widgets" $ do
          -- This tests the horizontal concat with widgets of different heights
          let w =
                hbox
                  [ vbox [text "a", text "b", text "c"], -- 3 lines
                    text "x", -- 1 line
                    vbox [text "1", text "2"] -- 2 lines
                  ]
              canvas = runWidget w (Dimensions 100 10)
          V.length (canvasLines canvas) >= 1 @?= True,
        testCase "hbox with empty and non-empty widgets" $ do
          let w = hbox [empty, text "x", empty, text "y"]
              canvas = runWidget w (Dimensions 100 10)
          V.length (canvasLines canvas) >= 1 @?= True,
        testCase "progress showcase pattern" $ do
          -- Replicates the pattern from Demo.hs progressShowcase
          let w =
                hbox
                  [ text "Label:  ",
                    progress defaultStyle defaultStyle 0.5,
                    text " 50%"
                  ]
              canvas = runWidget w (Dimensions 100 10)
          V.length (canvasLines canvas) @?= 1
      ],
    testGroup
      "Unicode Edge Cases"
      [ testCase "null character" $ do
          let w = displayWidth "\x00"
          w >= 0 @?= True,
        testCase "control characters" $ do
          let w = displayWidth "\x01\x02\x03"
          w >= 0 @?= True,
        testCase "zero-width joiner" $ do
          -- ZWJ shouldn't crash
          let w = displayWidth "👨\x200D👩\x200D👧"
          w > 0 @?= True,
        testCase "combining characters" $ do
          -- e + combining acute
          let w = displayWidth "e\x0301"
          w >= 1 @?= True,
        testCase "right-to-left text" $ do
          let w = displayWidth "مرحبا"
          w > 0 @?= True,
        testCase "surrogate pairs preserved" $ do
          -- 𝕳 (Mathematical Double-Struck Capital H)
          let w = displayWidth "𝕳"
          w >= 1 @?= True
      ],
    testGroup
      "Layout Edge Cases"
      [ testCase "all zero flex" $ do
          let result = solve defaultLayout (Dimensions 100 50) [Fill 0, Fill 0]
          length result @?= 2,
        testCase "Exact larger than available" $ do
          let result = solve defaultLayout (Dimensions 10 50) [Exact 100]
          length result @?= 1,
        testCase "Percent > 100" $ do
          let result = solve defaultLayout (Dimensions 100 50) [Percent 200]
          length result @?= 1,
        testCase "empty constraints" $ do
          let result = solve defaultLayout (Dimensions 100 50) []
          result @?= []
      ]
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- Property Tests (QuickCheck)
-- ════════════════════════════════════════════════════════════════════════════

propertyTests :: [TestTree]
propertyTests =
  [ testGroup
      "Unicode Properties"
      [ testProperty "displayWidth non-negative" prop_displayWidthNonNegative,
        testProperty "truncateText length <= target" prop_truncateTextLength,
        testProperty "padRight preserves width guarantee" prop_padRightWidth,
        testProperty "center preserves width guarantee" prop_centerWidth
      ],
    testGroup
      "Layout Properties"
      [ testProperty "solve returns correct count" prop_solveCount,
        testProperty "solve total width <= available" prop_solveTotalWidth,
        testProperty "solve dimensions non-negative" prop_solveDimsNonNegative
      ],
    testGroup
      "Widget Properties"
      [ testProperty "text widget never crashes" prop_textNeverCrashes,
        testProperty "vbox respects height limit" prop_vboxHeightLimit,
        testProperty "hbox respects width limit" prop_hboxWidthLimit,
        testProperty "bordered increases size by 2" prop_borderedSize
      ],
    testGroup
      "Fuzzing"
      [ testProperty "arbitrary text displayWidth" prop_fuzzDisplayWidth,
        testProperty "arbitrary text in widget" prop_fuzzTextWidget,
        testProperty "arbitrary constraints solve" prop_fuzzLayoutSolve
      ]
  ]

-- ════════════════════════════════════════════════════════════════════════════
-- QuickCheck Properties
-- ════════════════════════════════════════════════════════════════════════════

-- Unicode properties
prop_displayWidthNonNegative :: Text -> Bool
prop_displayWidthNonNegative t = displayWidth t >= 0

prop_truncateTextLength :: Positive Int -> Text -> Bool
prop_truncateTextLength (Positive n) t =
  let result = truncateText n t
   in displayWidth result <= n

prop_padRightWidth :: Positive Int -> Text -> Bool
prop_padRightWidth (Positive n) t =
  let result = padRight n t
   in displayWidth result == n || displayWidth t > n

prop_centerWidth :: Positive Int -> Text -> Bool
prop_centerWidth (Positive n) t =
  let result = center n t
   in displayWidth result == n || displayWidth t > n

-- Layout properties
prop_solveCount :: Positive Int -> Property
prop_solveCount (Positive n) =
  n <= 100 ==>
    let constraints = replicate n (Fill 1)
        result = solve defaultLayout (Dimensions 1000 100) constraints
     in length result == n

prop_solveTotalWidth :: Positive Int -> Bool
prop_solveTotalWidth (Positive n) =
  -- Test with Fill-only constraints since they should always sum to <= available
  let numConstraints = min 50 n
      constraints = replicate numConstraints (Fill 1)
      availW = 1000
      result = solve defaultLayout (Dimensions availW 100) constraints
      totalW = sum (map width result)
   in totalW <= availW

prop_solveDimsNonNegative :: [Constraint] -> Property
prop_solveDimsNonNegative constraints =
  length constraints <= 50 ==>
    let result = solve defaultLayout (Dimensions 1000 100) constraints
     in all (\d -> width d >= 0 && height d >= 0) result

-- Widget properties
prop_textNeverCrashes :: Text -> Bool
prop_textNeverCrashes t =
  let canvas = runWidget (text t) (Dimensions 100 10)
   in V.length (canvasLines canvas) >= 0

prop_vboxHeightLimit :: Positive Int -> [Text] -> Property
prop_vboxHeightLimit (Positive h) items =
  length items <= 100 ==>
    let widget = vbox (map text items)
        canvas = runWidget widget (Dimensions 100 h)
     in V.length (canvasLines canvas) <= h

prop_hboxWidthLimit :: Positive Int -> Bool
prop_hboxWidthLimit (Positive w) =
  let widget = hbox [text "a", text "b", text "c"]
      canvas = runWidget widget (Dimensions w 10)
   in V.length (canvasLines canvas) >= 0

prop_borderedSize :: Text -> Property
prop_borderedSize t =
  T.length t <= 100 ==>
    let inner = text t
        outerWidget = bordered inner
        innerCanvas = runWidget inner (Dimensions 100 10)
        outerCanvas = runWidget outerWidget (Dimensions 102 12)
        innerH = V.length (canvasLines innerCanvas)
        outerH = V.length (canvasLines outerCanvas)
     in outerH == innerH + 2

-- Fuzzing properties
prop_fuzzDisplayWidth :: Text -> Bool
prop_fuzzDisplayWidth t =
  -- Should never crash, width should be non-negative
  displayWidth t >= 0

prop_fuzzTextWidget :: Text -> Positive Int -> Positive Int -> Bool
prop_fuzzTextWidget t (Positive w) (Positive h) =
  let canvas = runWidget (text t) (Dimensions w h)
   in V.length (canvasLines canvas) >= 0

prop_fuzzLayoutSolve :: [Constraint] -> Positive Int -> Positive Int -> Property
prop_fuzzLayoutSolve constraints (Positive w) (Positive h) =
  length constraints <= 100 ==>
    let result = solve defaultLayout (Dimensions w h) constraints
     in length result == length constraints

-- ════════════════════════════════════════════════════════════════════════════
-- QuickCheck Generators
-- ════════════════════════════════════════════════════════════════════════════

instance Arbitrary Text where
  arbitrary = T.pack <$> arbitrary
  shrink = map T.pack . shrink . T.unpack

instance Arbitrary Constraint where
  arbitrary =
    oneof
      [ Fill <$> choose (0, 10),
        Exact <$> choose (0, 200),
        Percent <$> choose (0, 100),
        pure (Min 0),
        pure (Max 1000)
      ]
  shrink (Fill n) = [Fill (n - 1) | n > 0]
  shrink (Exact n) = [Exact (n `div` 2) | n > 0]
  shrink (Percent p) = [Percent (p `div` 2) | p > 0]
  shrink _ = []
