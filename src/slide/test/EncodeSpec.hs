{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module EncodeSpec (spec) where

import Data.ByteString qualified as BS
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

import Slide.Wire.Encode (
    encodeControl,
    encodeExtendedToken,
    encodeHotToken,
    encodeToken,
    encodeTokenList,
 )
import Slide.Wire.Frame (Frame (..), frameBytes)
import Slide.Wire.Types (FrameOp (..), pattern OP_CHUNK_END, pattern OP_EXTENDED, pattern OP_STREAM_END)

spec :: Spec
spec = do
    describe "encodeHotToken" $ do
        it "encodes token 0 as single byte" $ do
            frameBytes (encodeHotToken 0) `shouldBe` BS.pack [0x00]

        it "encodes token 42 as single byte" $ do
            frameBytes (encodeHotToken 42) `shouldBe` BS.pack [42]

        it "encodes max hot token (126)" $ do
            frameBytes (encodeHotToken 126) `shouldBe` BS.pack [0x7E]

    describe "encodeExtendedToken" $ do
        it "uses OP_EXTENDED prefix" $ do
            let frame = encodeExtendedToken 128
            BS.head (frameBytes frame) `shouldBe` unFrameOp OP_EXTENDED

        it "encodes 128 correctly" $ do
            frameBytes (encodeExtendedToken 128) `shouldBe` BS.pack [0x80, 0x80, 0x01]

        it "encodes large token IDs" $ do
            frameBytes (encodeExtendedToken 1000) `shouldBe` BS.pack [0x80, 0xE8, 0x07]

    describe "encodeControl" $ do
        it "encodes control byte directly" $ do
            frameBytes (encodeControl OP_CHUNK_END) `shouldBe` BS.pack [unFrameOp OP_CHUNK_END]
            frameBytes (encodeControl OP_STREAM_END) `shouldBe` BS.pack [unFrameOp OP_STREAM_END]

    describe "encodeToken" $ do
        it "encodes hot tokens directly" $ do
            let hotLookup tok = if tok < 127 then Just (fromIntegral tok) else Nothing
            frameBytes (encodeToken hotLookup 42) `shouldBe` BS.pack [42]

        it "encodes extended tokens with escape" $ do
            let hotLookup tok = if tok < 127 then Just (fromIntegral tok) else Nothing
            frameBytes (encodeToken hotLookup 1000) `shouldBe` BS.pack [0x80, 0xE8, 0x07]

    describe "encodeTokenList" $ do
        it "encodes multiple tokens" $ do
            let tokens = [1, 2, 1000, 3]
                hotLookup tok = if tok < 127 then Just (fromIntegral tok) else Nothing
                result = frameBytes (encodeTokenList hotLookup tokens)
            -- Just check it produces non-empty output without crashing
            BS.length result `shouldSatisfy` (> 0)
            -- Check that hot tokens (1, 2, 3) appear directly
            BS.elem 1 result `shouldBe` True
            BS.elem 2 result `shouldBe` True
