module ToolCallSpec where

import Test.Hspec
import Slide.Parse (extractToolCalls, ToolCallDelta(..))

spec :: Spec
spec = do
  describe "Tool Call Parsing" $ do
    it "extracts initial tool call with name" $ do
      let json = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_123\",\"function\":{\"name\":\"search\",\"arguments\":\"\"}}]}}]}"
      extractToolCalls json `shouldBe` [ToolCallDelta 0 (Just "call_123") (Just "search") (Just "")]

    it "extracts tool call arguments chunk" $ do
      let json = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"q\"}}]}}]}"
      extractToolCalls json `shouldBe` [ToolCallDelta 0 Nothing Nothing (Just "{\"q")]

    it "extracts multiple tool calls" $ do
      let json = "{\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"a\"}},{\"index\":1,\"function\":{\"arguments\":\"b\"}}]}}]}"
      extractToolCalls json `shouldBe` 
        [ ToolCallDelta 0 Nothing Nothing (Just "a")
        , ToolCallDelta 1 Nothing Nothing (Just "b")
        ]

