{-# LANGUAGE OverloadedStrings #-}

module ParseSpec (spec) where

import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)
import Data.Either (isLeft, isRight)

import Slide.Parse (SSEEvent (..), extractDelta, parseSSE, parseSSEIncremental)
import Slide.Provider.OpenAI (ParsedEndpoint (..), parseEndpoint)

spec :: Spec
spec = do
    describe "parseSSE" $ do
        it "parses data lines" $ do
            parseSSE "data: hello\n" `shouldBe` Right [SSEData "hello"]

        it "parses [DONE] marker" $ do
            parseSSE "data: [DONE]\n" `shouldBe` Right [SSEDone]

        it "parses comments" $ do
            parseSSE ": this is a comment\n" `shouldBe` Right [SSEComment " this is a comment"]

    describe "parseSSEIncremental" $ do
        it "parses complete events and returns remainder" $ do
            let (events, remainder) = parseSSEIncremental "data: hello\n\ndata: world\n\ndata: incomp"
            length events `shouldBe` 2
            remainder `shouldBe` "data: incomp"

        it "handles empty input" $ do
            let (events, remainder) = parseSSEIncremental ""
            events `shouldBe` []
            remainder `shouldBe` ""

        it "handles single incomplete event" $ do
            let (events, remainder) = parseSSEIncremental "data: partial"
            events `shouldBe` []
            remainder `shouldBe` "data: partial"

        it "handles [DONE] marker" $ do
            let (events, _) = parseSSEIncremental "data: [DONE]\n\n"
            events `shouldBe` [SSEDone]

    describe "extractDelta" $ do
        it "extracts content from OpenAI format" $ do
            let jsonPayload = "{\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}"
            extractDelta jsonPayload `shouldBe` Just "hello"

        it "returns Nothing for null content" $ do
            let jsonPayload = "{\"choices\":[{\"delta\":{\"content\":null}}]}"
            extractDelta jsonPayload `shouldBe` Nothing

        it "handles escaped quotes" $ do
            let jsonPayload = "{\"choices\":[{\"delta\":{\"content\":\"say \\\"hello\\\"\"}}]}"
            extractDelta jsonPayload `shouldBe` Just "say \"hello\""

    describe "parseEndpoint" $ do
        it "parses HTTPS URL with default port" $ do
            let result = parseEndpoint "https://api.openai.com/v1/chat/completions"
            result `shouldSatisfy` isRight
            case result of
                Right ep -> do
                    endpointHost ep `shouldBe` "api.openai.com"
                    endpointPort ep `shouldBe` 443
                    endpointPath ep `shouldBe` "/v1/chat/completions"
                    endpointUseTLS ep `shouldBe` True
                Left _ -> pure ()

        it "parses HTTP URL with custom port" $ do
            let result = parseEndpoint "http://localhost:8080/v1/completions"
            result `shouldSatisfy` isRight
            case result of
                Right ep -> do
                    endpointHost ep `shouldBe` "localhost"
                    endpointPort ep `shouldBe` 8080
                    endpointPath ep `shouldBe` "/v1/completions"
                    endpointUseTLS ep `shouldBe` False
                Left _ -> pure ()

        it "defaults path to /v1/chat/completions" $ do
            let result = parseEndpoint "https://api.example.com"
            result `shouldSatisfy` isRight
            case result of
                Right ep -> endpointPath ep `shouldBe` "/v1/chat/completions"
                Left _ -> pure ()

        it "handles Baseten endpoint" $ do
            let result = parseEndpoint "https://inference.baseten.co/v1/chat/completions"
            result `shouldSatisfy` isRight
            case result of
                Right ep -> do
                    endpointHost ep `shouldBe` "inference.baseten.co"
                    endpointPort ep `shouldBe` 443
                Left _ -> pure ()

        it "handles Vertex AI endpoint" $ do
            let result = parseEndpoint "https://us-east5-aiplatform.googleapis.com/v1/projects/foo/locations/us-east5/publishers/anthropic/models/claude-3-5-sonnet:rawPredict"
            result `shouldSatisfy` isRight
            case result of
                Right ep -> do
                    endpointHost ep `shouldBe` "us-east5-aiplatform.googleapis.com"
                    endpointPort ep `shouldBe` 443
                Left _ -> pure ()

        it "rejects malformed URLs" $ do
            parseEndpoint "not-a-url" `shouldSatisfy` isLeft
            parseEndpoint "ftp://invalid.com" `shouldSatisfy` isLeft
