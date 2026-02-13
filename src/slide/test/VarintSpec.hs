{-# LANGUAGE OverloadedStrings #-}

module VarintSpec (spec) where

import Data.ByteString qualified as BS
import Data.Word (Word32, Word64)
import Test.Hspec (Spec, describe, it, shouldBe)
import Test.Hspec.QuickCheck (modifyMaxSuccess, prop)
import Test.QuickCheck (Property, (.&.), (===))

import Slide.Wire.Varint (decodeVarint, encodeVarint)

spec :: Spec
spec = do
    describe "LEB128 varint encoding/decoding" $ do
        describe "edge cases" $ do
            it "encodes 0 as single byte" $ do
                encodeVarint 0 `shouldBe` BS.pack [0x00]

            it "encodes 127 as single byte (max hot token)" $ do
                encodeVarint 127 `shouldBe` BS.pack [0x7F]

            it "encodes 128 with continuation" $ do
                encodeVarint 128 `shouldBe` BS.pack [0x80, 0x01]

            it "encodes 16384 with two continuations" $ do
                encodeVarint 16384 `shouldBe` BS.pack [0x80, 0x80, 0x01]

            it "encodes max Word32" $ do
                let encoded = encodeVarint (fromIntegral (maxBound :: Word32))
                BS.length encoded `shouldBe` 5

        describe "decoding" $ do
            it "decodes single byte" $ do
                decodeVarint (BS.pack [0x00]) `shouldBe` Just (0, 1)
                decodeVarint (BS.pack [0x7F]) `shouldBe` Just (127, 1)

            it "decodes multi-byte" $ do
                decodeVarint (BS.pack [0x80, 0x01]) `shouldBe` Just (128, 2)
                decodeVarint (BS.pack [0x80, 0x80, 0x01]) `shouldBe` Just (16384, 3)

            it "returns Nothing for empty input" $ do
                decodeVarint BS.empty `shouldBe` Nothing

            it "returns Nothing for truncated multi-byte" $ do
                decodeVarint (BS.pack [0x80]) `shouldBe` Nothing

        describe "roundtrip property" $ do
            modifyMaxSuccess (const 1000) $ do
                prop "decode . encode == id for Word32" prop_roundtripWord32
                prop "decode . encode == id for Word64" prop_roundtripWord64
  where
    prop_roundtripWord32 :: Word32 -> Property
    prop_roundtripWord32 w =
        let encoded = encodeVarint (fromIntegral w)
         in case decodeVarint encoded of
                Just (decoded, len) -> decoded === fromIntegral w .&. (len === BS.length encoded)
                Nothing -> False === True

    prop_roundtripWord64 :: Word64 -> Property
    prop_roundtripWord64 w =
        let encoded = encodeVarint (fromIntegral w)
         in case decodeVarint encoded of
                Just (decoded, len) -> decoded === fromIntegral w .&. (len === BS.length encoded)
                Nothing -> False === True
