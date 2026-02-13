{-# LANGUAGE OverloadedStrings #-}

module DecodeSpec (spec) where

import Data.ByteString qualified as BS
import Test.Hspec (Spec, describe, it, shouldBe)

import Slide.Wire.Decode (
    Chunk (..),
    ChunkContent (..),
    DecodeState (..),
    decodeFrame,
    decodeFrameIncremental,
    flushDecoder,
    initDecodeState,
 )

spec :: Spec
spec = do
    describe "decodeFrame" $ do
        it "decodes empty frame" $ do
            decodeFrame BS.empty `shouldBe` []

        it "decodes single hot token with CHUNK_END" $ do
            let input = BS.pack [42, 0xC0]
                chunks = decodeFrame input
            length chunks `shouldBe` 1
            case chunks of
                (chunk : _) ->
                    case chunkContent chunk of
                        TextContent tokens -> tokens `shouldBe` [42]
                        _ -> error "Expected TextContent"
                [] -> error "Expected at least one chunk"

        it "decodes multiple tokens with CHUNK_END" $ do
            let input = BS.pack [1, 2, 3, 0xC0]
                chunks = decodeFrame input
            case chunks of
                (chunk : _) ->
                    case chunkContent chunk of
                        TextContent tokens -> tokens `shouldBe` [1, 2, 3]
                        _ -> error "Expected TextContent"
                [] -> error "Expected at least one chunk"

    describe "flushDecoder" $ do
        it "emits accumulated tokens as chunk" $ do
            let (state, _chunks) = decodeFrameIncremental initDecodeState (BS.pack [42, 43])
            case flushDecoder state of
                Just chunk ->
                    case chunkContent chunk of
                        TextContent tokens -> tokens `shouldBe` [42, 43]
                        _ -> error "Expected TextContent"
                Nothing -> error "Expected a chunk from flush"

        it "returns Nothing for empty buffer" $ do
            flushDecoder initDecodeState `shouldBe` Nothing

    describe "decodeFrameIncremental" $ do
        it "handles empty input" $ do
            let (state, chunks) = decodeFrameIncremental initDecodeState BS.empty
            chunks `shouldBe` []
            decodeBuffer state `shouldBe` []
