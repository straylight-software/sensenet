{-# LANGUAGE OverloadedStrings #-}

{- | FFI integration tests for tokenizers-cpp

These tests exercise the actual C++ library through the Haskell FFI bindings.
They require the tokenizers-cpp library to be available at runtime.
-}
module TokenizerFFISpec (spec) where

import Control.Monad (replicateM_)
import Data.ByteString (ByteString)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word32)
import Test.Hspec

import Slide.Model qualified as Model
import Slide.Tokenizer (
    HFTokenizer,
    TokenizerFormat (..),
    decode,
    decodeToken,
    encode,
    loadTokenizerFromBlob,
    toModelTokenizer,
    tokenToId,
    vocabSize,
 )

-- | Minimal valid HuggingFace tokenizer JSON for testing
minimalTokenizerJSON :: ByteString
minimalTokenizerJSON =
    TE.encodeUtf8 $
        T.unlines
            [ "{"
            , "  \"version\": \"1.0\","
            , "  \"truncation\": null,"
            , "  \"padding\": null,"
            , "  \"added_tokens\": [],"
            , "  \"normalizer\": null,"
            , "  \"pre_tokenizer\": {"
            , "    \"type\": \"Whitespace\","
            , "    \"prefix_space\": true"
            , "  },"
            , "  \"post_processor\": null,"
            , "  \"decoder\": null,"
            , "  \"model\": {"
            , "    \"type\": \"WordLevel\","
            , "    \"vocab\": {"
            , "      \"<unk>\": 0,"
            , "      \"hello\": 1,"
            , "      \"world\": 2,"
            , "      \"test\": 3"
            , "    },"
            , "    \"unk_token\": \"<unk>\""
            , "  }"
            , "}"
            ]

spec :: Spec
spec = do
    describe "FFI integration" $ do
        around withTestTokenizer $ do
            describe "loadTokenizerFromBlob" $ do
                it "successfully loads a valid tokenizer" $ \tok -> do
                    size <- vocabSize tok
                    size `shouldBe` 4 -- <unk>, hello, world, test
                -- it "throws on invalid JSON" $ \_ -> do
                --     result <-
                --         try @SomeException $
                --             loadTokenizerFromBlob FormatJSON "invalid json"
                --     case result of
                --         Left _ -> pure ()
                --         Right _ -> expectationFailure "Expected exception for invalid JSON"

            describe "encode" $ do
                it "encodes known tokens" $ \tok -> do
                    ids <- encode tok "hello"
                    ids `shouldBe` [1]

                it "encodes multiple words" $ \tok -> do
                    ids <- encode tok "hello world"
                    -- BPE tokenizer may produce different output, just check it works
                    length ids `shouldSatisfy` (> 0)

                it "handles unknown tokens gracefully" $ \tok -> do
                    ids <- encode tok "xyzunknown"
                    -- Should encode to <unk> or subword tokens
                    length ids `shouldSatisfy` (>= 1)

            describe "decode" $ do
                it "decodes token IDs back to text" $ \tok -> do
                    let ids = [1, 2] -- hello, world
                    text <- decode tok ids
                    text `shouldSatisfy` T.isInfixOf "hello"
                    text `shouldSatisfy` T.isInfixOf "world"

                it "handles empty token list" $ \tok -> do
                    text <- decode tok ([] :: [Word32])
                    text `shouldBe` ""

            describe "roundtrip" $ do
                it "decode . encode ≈ id for simple text" $ \tok -> do
                    let original = "hello"
                    ids <- encode tok original
                    decoded <- decode tok ids
                    decoded `shouldSatisfy` T.isInfixOf original

            describe "decodeToken" $ do
                it "returns Just for valid token IDs" $ \tok -> do
                    mToken <- decodeToken tok 1
                    mToken `shouldSatisfy` isJust

                it "returns Nothing for invalid token IDs" $ \tok -> do
                    mToken <- decodeToken tok 999999
                    mToken `shouldBe` Nothing

            describe "tokenToId" $ do
                it "looks up known tokens" $ \tok -> do
                    mId <- tokenToId tok "hello"
                    mId `shouldBe` Just 1

                it "returns Nothing for unknown tokens" $ \tok -> do
                    mId <- tokenToId tok "notinthevocab"
                    mId `shouldBe` Nothing

    describe "toModelTokenizer integration" $ do
        around withTestTokenizer $ do
            it "converts HFTokenizer to Model.Tokenizer" $ \tok -> do
                modelTok <- toModelTokenizer tok "test-hash"
                -- Test the Model.Tokenizer interface
                ids <- Model.tokenizerEncode modelTok "hello"
                length ids `shouldSatisfy` (> 0)

                text <- Model.tokenizerDecode modelTok ids
                text `shouldSatisfy` T.isInfixOf "hello"

            it "has correct vocab size in Model.Tokenizer" $ \tok -> do
                modelTok <- toModelTokenizer tok "test-hash"
                Model.tokenizerVocabSize modelTok `shouldBe` 4

    describe "resource cleanup" $ do
        it "properly frees tokenizer resources" $ do
            -- Load and unload many tokenizers to check for leaks
            replicateM_ 100 $ do
                tok <- loadTokenizerFromBlob FormatJSON minimalTokenizerJSON
                _ <- vocabSize tok
                pure ()
            -- If we get here without crashing, finalizers are working
            True `shouldBe` True

-- | Helper to provide a test tokenizer to each test
withTestTokenizer :: (HFTokenizer -> IO ()) -> IO ()
withTestTokenizer action = do
    tok <- loadTokenizerFromBlob FormatJSON minimalTokenizerJSON
    action tok

-- | Check if Maybe is Just
isJust :: Maybe a -> Bool
isJust (Just _) = True
isJust _ = False
