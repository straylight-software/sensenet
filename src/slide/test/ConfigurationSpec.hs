{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}

module ConfigurationSpec (spec) where

import qualified BLAKE3
import qualified Crypto.Hash as Crypto
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.Text as T
import Slide.Configuration
import Test.Hspec
import Test.QuickCheck

genByteString :: Gen ByteString
genByteString = BS.pack <$> arbitrary

spec :: Spec
spec = do
    describe "Configuration.verifyHash" $ do
        it "verifies valid SHA256 hashes" $ property $ forAll genByteString $ \content -> do
            let digest :: Crypto.Digest Crypto.SHA256
                digest = Crypto.hash content
                hashObj = Hash SHA256 (T.pack $ show digest)
            verifyHash content hashObj `shouldBe` True

        it "verifies valid BLAKE3 hashes" $ property $ forAll genByteString $ \content -> do
            let digest :: BLAKE3.Digest 32
                digest = BLAKE3.hash Nothing [content]
                hashObj = Hash BLAKE3 (T.pack $ show digest)
            verifyHash content hashObj `shouldBe` True

        it "rejects invalid SHA256 hashes (adversarial)" $ property $ forAll genByteString $ \content -> do
            let digest :: Crypto.Digest Crypto.SHA256
                digest = Crypto.hash (content <> "modified")
                hashObj = Hash SHA256 (T.pack $ show digest)
            verifyHash content hashObj `shouldBe` False

        it "rejects invalid BLAKE3 hashes (adversarial)" $ property $ forAll genByteString $ \content -> do
            let digest :: BLAKE3.Digest 32
                digest = BLAKE3.hash Nothing [content <> "modified"]
                hashObj = Hash BLAKE3 (T.pack $ show digest)
            verifyHash content hashObj `shouldBe` False
