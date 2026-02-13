{-# LANGUAGE OverloadedStrings #-}

module FrameSpec (spec) where

import Data.ByteString qualified as BS
import Test.Hspec (Spec, describe, it, shouldBe)

import Slide.Wire.Encode (encodeExtendedToken, encodeHotToken)
import Slide.Wire.Types (Frame (..))
import Slide.Wire.Varint (decodeVarint, encodeVarint)

spec :: Spec
spec = do
    describe "varint encoding" $ do
        it "encodes small values in 1 byte" $ do
            encodeVarint 0 `shouldBe` BS.pack [0x00]
            encodeVarint 127 `shouldBe` BS.pack [0x7F]

        it "encodes larger values with continuation" $ do
            encodeVarint 128 `shouldBe` BS.pack [0x80, 0x01]
            encodeVarint 16384 `shouldBe` BS.pack [0x80, 0x80, 0x01]

    describe "varint decoding" $ do
        it "decodes single byte" $ do
            decodeVarint (BS.pack [0x7F]) `shouldBe` Just (127, 1)

        it "decodes multi-byte" $ do
            decodeVarint (BS.pack [0x80, 0x01]) `shouldBe` Just (128, 2)

    describe "hot token encoding" $ do
        it "encodes hot tokens as single byte" $ do
            frameBytes (encodeHotToken 42) `shouldBe` BS.pack [42]

    describe "extended token encoding" $ do
        it "uses escape byte + varint" $ do
            frameBytes (encodeExtendedToken 1000) `shouldBe` BS.pack [0x80, 0xE8, 0x07]
