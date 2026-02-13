{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

module ChunkSpec (spec) where


import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word32)
import Slide.HotTable (defaultHotTable)
import Slide.Chunk (ChunkState, initChunkState, processToken, ProcessResult(..))
import Slide.Wire.Frame (pattern OP_THINK_START)

import Slide.Wire.Frame qualified as Frame

-- Helper to run processToken and return the result
runToken :: ChunkState -> Word32 -> IO ProcessResult
runToken state token = do
    (_, result) <- processToken state token
    pure result

spec :: Spec
spec = do
    describe "Chunking State Machine" $ do
        it "detects custom delimiters (identity mode)" $ do
            -- Setup a chunk state with specific byte values as delimiters
            -- Let's say '<' (60) is think start for this test
            let boundaries = VU.replicate 256 False
                thinkStart = 60 :: Word32 -- '<'
                thinkEnd = 62 :: Word32   -- '>'
                toolStart = 0
                toolEnd = 0
                codeFence = 0
                flushThreshold = 100
                
            -- Create a dummy FrameBuilder (we discard output frames for this test)
            builderIO <- Frame.newFrameBuilder 1024
            
            let state = initChunkState 
                    builderIO 
                    defaultHotTable -- dummy hot table
                    boundaries 
                    (thinkStart, thinkEnd) 
                    (toolStart, toolEnd) 
                    codeFence 
                    flushThreshold

            -- Process the think start token
            result <- runToken state thinkStart
            
            -- Verify it emitted the state change opcode
            case result of
                ResultStateChange op -> 
                    op `shouldBe` OP_THINK_START
                _ -> 
                    expectationFailure $ "Expected StateChange OP_THINK_START, got " <> show result
