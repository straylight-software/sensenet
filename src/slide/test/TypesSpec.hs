{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module TypesSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe)

import Slide.Wire.Types (
    FrameOp (..),
    HotId,
    TokenId,
    isControlByte,
    isExtendedByte,
    isHotByte,
    maxHotId,
    pattern OP_CHUNK_END,
    pattern OP_CODE_BLOCK_END,
    pattern OP_CODE_BLOCK_START,
    pattern OP_ERROR,
    pattern OP_ENVELOPE,
    pattern OP_EXTENDED,
    pattern OP_STREAM_END,
    pattern OP_THINK_END,
    pattern OP_THINK_START,
    pattern OP_TOOL_CALL_END,
    pattern OP_TOOL_CALL_START,
 )

spec :: Spec
spec = do
    describe "FrameOp patterns" $ do
        it "has correct opcode values" $ do
            unFrameOp OP_EXTENDED `shouldBe` 0x80
            unFrameOp OP_CHUNK_END `shouldBe` 0xC0
            unFrameOp OP_TOOL_CALL_START `shouldBe` 0xC1
            unFrameOp OP_TOOL_CALL_END `shouldBe` 0xC2
            unFrameOp OP_THINK_START `shouldBe` 0xC3
            unFrameOp OP_THINK_END `shouldBe` 0xC4
            unFrameOp OP_CODE_BLOCK_START `shouldBe` 0xC5
            unFrameOp OP_CODE_BLOCK_END `shouldBe` 0xC6
            unFrameOp OP_STREAM_END `shouldBe` 0xCF
            unFrameOp OP_ERROR `shouldBe` 0xCE
            unFrameOp OP_ENVELOPE `shouldBe` 0xF0

    describe "isHotByte" $ do
        it "returns True for bytes 0x00-0x7E" $ do
            isHotByte 0x00 `shouldBe` True
            isHotByte 0x40 `shouldBe` True
            isHotByte 0x7E `shouldBe` True

        it "returns False for extended byte" $ do
            isHotByte 0x7F `shouldBe` False

        it "returns False for control bytes" $ do
            isHotByte 0x00 `shouldBe` True -- OP_ERROR is hot
            isHotByte 0x01 `shouldBe` True -- OP_STREAM_END is hot
    describe "isExtendedByte" $ do
        it "returns True for escape bytes (0x80-0xBF)" $ do
            isExtendedByte 0x80 `shouldBe` True
            isExtendedByte 0xBF `shouldBe` True
            isExtendedByte 0x7F `shouldBe` False
            isExtendedByte 0x00 `shouldBe` False

    describe "isControlByte" $ do
        it "returns True for control range (0xC0-0xCF)" $ do
            isControlByte 0xC0 `shouldBe` True
            isControlByte 0xC1 `shouldBe` True
            isControlByte 0xCF `shouldBe` True

        it "returns True for ENVELOPE (0xF0)" $ do
            isControlByte 0xF0 `shouldBe` True

        it "returns False outside control range" $ do
            isControlByte 0xBF `shouldBe` False
            isControlByte 0xD0 `shouldBe` False

    describe "maxHotId" $ do
        it "equals 126" $ do
            maxHotId `shouldBe` 126

    describe "type aliases" $ do
        it "TokenId is Word32" $ do
            let _x :: TokenId = 42
            True `shouldBe` True

        it "HotId is Word8" $ do
            let _x :: HotId = 42
            True `shouldBe` True
