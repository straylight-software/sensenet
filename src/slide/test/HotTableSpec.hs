{-# LANGUAGE OverloadedStrings #-}

module HotTableSpec (spec) where

import Data.Word (Word32, Word8)
import Test.Hspec (Spec, describe, it, shouldBe)

import Slide.HotTable (defaultHotTable, lookupHot)

spec :: Spec
spec = do
    describe "defaultHotTable" $ do
        it "maps hot IDs 0-126 to themselves" $ do
            all (\i -> lookupHot defaultHotTable (fromIntegral i) == Just (fromIntegral i)) ([0 .. 126] :: [Int]) `shouldBe` True

        it "returns Nothing for out of range" $ do
            lookupHot defaultHotTable (127 :: Word32) `shouldBe` Nothing
            lookupHot defaultHotTable (1000 :: Word32) `shouldBe` Nothing

    describe "lookupHot" $ do
        it "handles boundary values" $ do
            lookupHot defaultHotTable (0 :: Word32) `shouldBe` Just (0 :: Word8)
            lookupHot defaultHotTable (126 :: Word32) `shouldBe` Just (126 :: Word8)
            lookupHot defaultHotTable (127 :: Word32) `shouldBe` Nothing
