{-# LANGUAGE OverloadedStrings #-}

module ModelSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)

import Slide.Model (
    Model (..),
    ModelFamily (..),
    SemanticDelimiters (..),
    identityTokenizer,
    modelFamilyFromName,
    modelFromFamily,
    tokenizerDecode,
    tokenizerEncode,
    tokenizerVocabSize,
 )

spec :: Spec
spec = do
    describe "modelFamilyFromName" $ do
        it "identifies Qwen models" $ do
            modelFamilyFromName "Qwen/Qwen2.5-7B" `shouldBe` FamilyQwen3
            modelFamilyFromName "qwen3-32b" `shouldBe` FamilyQwen3

        it "identifies Llama models" $ do
            modelFamilyFromName "meta-llama/Llama-3.1-8B" `shouldBe` FamilyLlama3
            modelFamilyFromName "llama3-70b" `shouldBe` FamilyLlama3

        it "identifies DeepSeek models" $ do
            modelFamilyFromName "deepseek-ai/DeepSeek-V3" `shouldBe` FamilyDeepSeekV3
            modelFamilyFromName "deepseek-r1" `shouldBe` FamilyDeepSeekV3

        it "identifies Kimi models" $ do
            modelFamilyFromName "moonshotai/Kimi-K2.5" `shouldBe` FamilyKimi
            modelFamilyFromName "kimi-v1" `shouldBe` FamilyKimi

        it "returns FamilyUnknown for unrecognized names" $ do
            modelFamilyFromName "unknown-model-v1" `shouldBe` FamilyUnknown

    describe "identityTokenizer" $ do
        it "has vocab size 256" $ do
            tokenizerVocabSize identityTokenizer `shouldBe` 256

        it "encodes ASCII text as UTF-8 bytes" $ do
            tokenizerEncode identityTokenizer "hello" `shouldReturn` [104, 101, 108, 108, 111]

        it "decodes bytes back to text" $ do
            tokenizerDecode identityTokenizer [104, 101, 108, 108, 111] `shouldReturn` "hello"

        it "roundtrips arbitrary ASCII" $ do
            let text = "Hello, World! 123"
            bytes <- tokenizerEncode identityTokenizer text
            result <- tokenizerDecode identityTokenizer bytes
            result `shouldBe` text

    describe "modelFromFamily" $ do
        it "creates Qwen3 model with correct vocab size" $ do
            model <- modelFromFamily "test-model" FamilyQwen3
            modelVocabSize model `shouldBe` 151936

        it "creates Llama3 model with correct vocab size" $ do
            model <- modelFromFamily "test-model" FamilyLlama3
            modelVocabSize model `shouldBe` 128256

    describe "SemanticDelimiters" $ do
        it "has text patterns for thinking" $ do
            let delims =
                    SemanticDelimiters
                        { delimThinkStartToken = Just 151646
                        , delimThinkEndToken = Just 151647
                        , delimToolCallStartToken = Just 151648
                        , delimToolCallEndToken = Just 151649
                        , delimCodeFenceToken = Just 74
                        , delimEosToken = 151645
                        , delimBosToken = Just 151643
                        , delimThinkStartText = Just "<think>"
                        , delimThinkEndText = Just "</think>"
                        , delimToolCallStartText = Just "<tool_call>"
                        , delimToolCallEndText = Just "</tool_call>"
                        , delimCodeFenceText = "```"
                        }
            delimThinkStartText delims `shouldBe` Just "<think>"
            delimCodeFenceText delims `shouldBe` "```"
