{-# LANGUAGE OverloadedStrings #-}

module RoundtripSpec (spec) where

import Data.ByteString qualified as BS
import Data.Word (Word32, Word8)
import Test.Hspec (Spec, describe, it)
import Test.QuickCheck (property, (==>))

import Slide.Wire.Decode (Chunk (..), ChunkContent (..), decodeFrame)
import Slide.Wire.Encode (encodeHotToken)
import Slide.Wire.Types (Frame (..), maxHotId)
import Slide.Wire.Varint (decodeVarint, encodeVarint)

spec :: Spec
spec = do
    describe "varint roundtrip" $ do
        it "roundtrips arbitrary Word32" $ property $ \(originalValue :: Word32) ->
            let encodedBytes = encodeVarint originalValue
             in decodeVarint encodedBytes == Just (originalValue, BS.length encodedBytes)

    describe "token encoding roundtrip" $ do
        it "hot tokens decode correctly" $ property $ \(hotId :: Word8) ->
            hotId <= maxHotId ==>
                let encodedFrame = encodeHotToken hotId
                    frameWithStreamEnd = frameBytes encodedFrame <> "\xCF"
                    decodedChunks = decodeFrame frameWithStreamEnd
                 in case decodedChunks of
                        [Chunk (TextContent [decodedToken]) _, Chunk StreamEnd True] ->
                            decodedToken == fromIntegral hotId
                        [Chunk (TextContent [decodedToken]) True] ->
                            decodedToken == fromIntegral hotId
                        _ -> False
