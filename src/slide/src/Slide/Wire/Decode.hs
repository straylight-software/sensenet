{- | Frame decoding for SIGIL wire format

Decodes binary frames back into semantic chunks for client consumption.
-}
module Slide.Wire.Decode (
    -- * Decoded chunks
    Chunk (..),
    ChunkContent (..),

    -- * Decoding
    decodeFrame,
    decodeFrameIncremental,

    -- * Low-level
    DecodeState (..),
    initDecodeState,
    feedBytes,
    flushDecoder,
) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Word (Word8)

import Slide.Wire.Types (TokenId, isControlByte, isExtendedByte, isHotByte)
import Slide.Wire.Varint (decodeVarint)

-- ════════════════════════════════════════════════════════════════════════════════
-- Chunk Types (what the client sees)
-- ════════════════════════════════════════════════════════════════════════════════

-- | A decoded semantic chunk
data Chunk = Chunk
    { chunkContent :: !ChunkContent
    , chunkComplete :: !Bool
    -- ^ True if ends on semantic boundary
    }
    deriving stock (Show, Eq)

-- | Content types
data ChunkContent
    = -- | Regular text tokens
      TextContent ![TokenId]
    | -- | Thinking block (may be hidden)
      ThinkContent ![TokenId]
    | -- | Tool call (parse as JSON)
      ToolCallContent ![TokenId]
    | -- | Code block
      CodeBlockContent ![TokenId]
    | -- | End of stream
      StreamEnd
    | -- | Something went wrong
      DecodeError !Text
    deriving stock (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════════
-- Decode State
-- ════════════════════════════════════════════════════════════════════════════════

-- | Parser mode for semantic blocks
data ParseMode
    = ModeText
    | ModeThink
    | ModeToolCall
    | ModeCodeBlock
    deriving stock (Show, Eq)

-- | Incremental decoder state
data DecodeState = DecodeState
    { decodeParseMode :: !ParseMode
    , decodeBuffer :: ![TokenId]
    -- ^ Accumulated tokens (reversed)
    , decodeLeftover :: !ByteString
    -- ^ Incomplete bytes from last feed
    }
    deriving stock (Show, Eq)

-- | Initial decode state
initDecodeState :: DecodeState
initDecodeState = DecodeState ModeText [] BS.empty

-- ════════════════════════════════════════════════════════════════════════════════
-- Decoding
-- ════════════════════════════════════════════════════════════════════════════════

-- | Decode a complete frame into chunks
decodeFrame :: ByteString -> [Chunk]
decodeFrame inputBytes = resultChunks
  where
    (_finalState, resultChunks) = decodeFrameIncremental initDecodeState inputBytes

-- | Decode incrementally, returning new state and any complete chunks
decodeFrameIncremental :: DecodeState -> ByteString -> (DecodeState, [Chunk])
decodeFrameIncremental initialState inputBytes =
    processBytes initialState (decodeLeftover initialState <> inputBytes) []
  where
    processBytes :: DecodeState -> ByteString -> [Chunk] -> (DecodeState, [Chunk])
    processBytes !state !remainingInput !accumulatedChunks
        | BS.null remainingInput =
            (state{decodeLeftover = BS.empty}, reverse accumulatedChunks)
        | otherwise =
            let currentByte = BS.head remainingInput
                restOfInput = BS.tail remainingInput
             in case decodeSingleByte state currentByte restOfInput of
                    Left leftoverBytes ->
                        (state{decodeLeftover = leftoverBytes}, reverse accumulatedChunks)
                    Right (newState, maybeChunk, bytesRemaining) ->
                        let updatedChunks = maybe accumulatedChunks (: accumulatedChunks) maybeChunk
                         in processBytes newState bytesRemaining updatedChunks

-- | Decode one byte, possibly consuming more for varint
decodeSingleByte ::
    DecodeState ->
    Word8 ->
    ByteString ->
    Either ByteString (DecodeState, Maybe Chunk, ByteString)
decodeSingleByte state currentByte remainingBytes
    -- Hot token (0x00-0x7E)
    | isHotByte currentByte =
        let tokenId = fromIntegral currentByte
            newState = state{decodeBuffer = tokenId : decodeBuffer state}
         in Right (newState, Nothing, remainingBytes)
    -- Extended token (0x80-0xBF)
    | isExtendedByte currentByte =
        case decodeVarint remainingBytes of
            Nothing -> Left (BS.cons currentByte remainingBytes) -- incomplete varint
            Just (tokenId, bytesConsumed) ->
                let newState = state{decodeBuffer = tokenId : decodeBuffer state}
                 in Right (newState, Nothing, BS.drop bytesConsumed remainingBytes)
    -- Control (0xC0-0xCF)
    | isControlByte currentByte =
        handleControlByte state currentByte remainingBytes
    -- Reserved/unknown - ignore
    | otherwise =
        Right (state, Nothing, remainingBytes)

-- | Handle control opcodes
handleControlByte ::
    DecodeState ->
    Word8 ->
    ByteString ->
    Either ByteString (DecodeState, Maybe Chunk, ByteString)
handleControlByte state opcode remainingBytes = Right $ case opcode of
    0xC0 ->
        -- CHUNK_END
        let chunk = buildChunk state True
            newState = state{decodeBuffer = []}
         in (newState, Just chunk, remainingBytes)
    0xC1 ->
        -- TOOL_CALL_START
        let pendingChunk =
                if null (decodeBuffer state)
                    then Nothing
                    else Just (buildChunk state False)
            newState = DecodeState ModeToolCall [] BS.empty
         in (newState, pendingChunk, remainingBytes)
    0xC2 ->
        -- TOOL_CALL_END
        let chunk = buildChunk state True
            newState = DecodeState ModeText [] BS.empty
         in (newState, Just chunk, remainingBytes)
    0xC3 ->
        -- THINK_START
        let pendingChunk =
                if null (decodeBuffer state)
                    then Nothing
                    else Just (buildChunk state False)
            newState = DecodeState ModeThink [] BS.empty
         in (newState, pendingChunk, remainingBytes)
    0xC4 ->
        -- THINK_END
        let chunk = buildChunk state True
            newState = DecodeState ModeText [] BS.empty
         in (newState, Just chunk, remainingBytes)
    0xC5 ->
        -- CODE_BLOCK_START
        let pendingChunk =
                if null (decodeBuffer state)
                    then Nothing
                    else Just (buildChunk state False)
            newState = DecodeState ModeCodeBlock [] BS.empty
         in (newState, pendingChunk, remainingBytes)
    0xC6 ->
        -- CODE_BLOCK_END
        let chunk = buildChunk state True
            newState = DecodeState ModeText [] BS.empty
         in (newState, Just chunk, remainingBytes)
    0xC7 ->
        -- FLUSH (chunk incomplete)
        let chunk = buildChunk state False
            -- Maintain ParseMode for next chunk!
            newState = state{decodeBuffer = []}
         in (newState, Just chunk, remainingBytes)
    0xCF ->
        -- STREAM_END
        let chunk =
                if null (decodeBuffer state)
                    then Chunk StreamEnd True
                    else buildChunk state True
            newState = initDecodeState
         in (newState, Just chunk, remainingBytes)
    _ ->
        -- unknown control, ignore
        (state, Nothing, remainingBytes)

-- | Create chunk from current state
buildChunk :: DecodeState -> Bool -> Chunk
buildChunk state = Chunk content
  where
    tokens = reverse (decodeBuffer state)
    content = case decodeParseMode state of
        ModeText -> TextContent tokens
        ModeThink -> ThinkContent tokens
        ModeToolCall -> ToolCallContent tokens
        ModeCodeBlock -> CodeBlockContent tokens

-- ════════════════════════════════════════════════════════════════════════════════
-- Incremental Feeding
-- ════════════════════════════════════════════════════════════════════════════════

-- | Feed bytes to decoder, get chunks
feedBytes :: DecodeState -> ByteString -> (DecodeState, [Chunk])
feedBytes = decodeFrameIncremental

{- | Flush any remaining tokens in buffer as a final chunk

Use this at end of stream to emit any accumulated tokens.
-}
flushDecoder :: DecodeState -> Maybe Chunk
flushDecoder state
    | null (decodeBuffer state) = Nothing
    | otherwise = Just $ buildChunk state True
