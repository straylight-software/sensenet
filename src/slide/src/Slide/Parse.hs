{-# LANGUAGE OverloadedStrings #-}

{- | SSE parsing for OpenAI-compatible endpoints

We use Megaparsec to surgically extract just the "content" field from
OpenAI-format JSON. This avoids parsing 650 bytes of garbage we don't need.
-}
module Slide.Parse (
    -- * SSE types
    SSEEvent (..),

    -- * Parsing
    parseSSE,
    parseSSELine,
    parseSSEIncremental,

    -- * Content extraction
    extractDelta,
    extractAnthropicDelta,
    extractFinishReason,
    extractToolCalls,
    ToolCallDelta (..),
) where

import Control.Applicative ((<|>))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Text.Megaparsec (
    Parsec,
    anySingle,
    anySingleBut,
    choice,
    count,
    eof,
    errorBundlePretty,
    many,
    manyTill,
    optional,
    parse,
    some,
    takeWhileP,
    try,
 )

import Text.Megaparsec.Char (char, digitChar, hexDigitChar, newline, space, string)

type Parser = Parsec Void Text

-- ════════════════════════════════════════════════════════════════════════════════
-- SSE Types
-- ════════════════════════════════════════════════════════════════════════════════

-- | Parsed SSE event
data SSEEvent
    = -- | data: line content
      SSEData !Text
    | -- | [DONE] marker
      SSEDone
    | -- | retry: milliseconds
      SSERetry !Int
    | -- | : comment
      SSEComment !Text
    | -- | event: type (Anthropic SSE format)
      SSEEventType !Text
    | -- | empty line (event separator)
      SSEEmpty
    deriving stock (Show, Eq)

-- | Tool call delta
data ToolCallDelta = ToolCallDelta
    { tcIndex :: !Int
    , tcId :: !(Maybe Text)
    , tcName :: !(Maybe Text)
    , tcArgs :: !(Maybe Text)
    }
    deriving stock (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════════
-- SSE Parsing
-- ════════════════════════════════════════════════════════════════════════════════

-- | Parse SSE text into events
parseSSE :: Text -> Either String [SSEEvent]
parseSSE input = case parse parseSSEBlock "sse" input of
    Left parseError -> Left $ errorBundlePretty parseError
    Right events -> Right events

-- | Parse single SSE line
parseSSELine :: Text -> Either String SSEEvent
parseSSELine input = case parse parseSingleSSELine "sse" input of
    Left parseError -> Left $ errorBundlePretty parseError
    Right event -> Right event

parseSSEBlock :: Parser [SSEEvent]
parseSSEBlock = many parseSingleSSELine <* eof

parseSingleSSELine :: Parser SSEEvent
parseSingleSSELine =
    choice
        [ parseDoneMarker
        , parseDataLine
        , parseEventTypeLine
        , parseRetryLine
        , parseCommentLine
        , SSEEmpty <$ some newline
        ]

-- ════════════════════════════════════════════════════════════════════════════════
-- Incremental SSE Parsing
--
-- SSE events are separated by blank lines (\n\n). We parse complete events
-- and return any incomplete trailing data for buffering.
-- ════════════════════════════════════════════════════════════════════════════════

{- | Parse SSE stream incrementally

Takes a buffer of accumulated text and returns:
  - List of complete, parsed SSE events
  - Remaining unparsed text (incomplete event)

This properly handles:
  - Multiple events in a single chunk
  - Events split across chunks
  - Malformed events (skipped with no error)

SSE events are delimited by double newlines (\n\n). An event without
a trailing \n\n is considered incomplete and returned as remainder.

Example:
  >>> parseSSEIncremental "data: hello\n\ndata: world\n\ndata: incomp"
  ([SSEData "hello", SSEData "world"], "data: incomp")
-}
parseSSEIncremental :: Text -> ([SSEEvent], Text)
parseSSEIncremental buffer =
    -- SSE events are separated by blank lines (double newline)
    -- Split on \n\n and parse each complete segment
    let segments = T.splitOn "\n\n" buffer
    in case segments of
        [] -> ([], "")
        [incomplete] -> ([], incomplete)  -- No \n\n found, entire buffer is incomplete
        parts ->
            -- All but the last segment are complete events
            -- Last segment is incomplete (no trailing \n\n)
            let completeSegments = init parts
                remainder = last parts
                events = concatMap parseSegment completeSegments
            in (events, remainder)
  where
    parseSegment :: Text -> [SSEEvent]
    parseSegment segment
        | T.null (T.strip segment) = []  -- Empty segment
        | otherwise = case parse parseSingleSSELine "sse" (segment <> "\n") of
            Left _ -> []  -- Malformed, skip
            Right event -> [event]

parseDoneMarker :: Parser SSEEvent
parseDoneMarker = SSEDone <$ string "data: [DONE]" <* optional newline

parseDataLine :: Parser SSEEvent
parseDataLine = do
    _ <- string "data: "
    content <- takeWhileP Nothing (/= '\n')
    _ <- optional newline
    pure $ SSEData content

parseEventTypeLine :: Parser SSEEvent
parseEventTypeLine = do
    _ <- string "event: "
    eventType <- takeWhileP Nothing (/= '\n')
    _ <- optional newline
    pure $ SSEEventType eventType

parseRetryLine :: Parser SSEEvent
parseRetryLine = do
    _ <- string "retry: "
    digits <- some digitChar
    _ <- optional newline
    pure $ SSERetry (read digits)

parseCommentLine :: Parser SSEEvent
parseCommentLine = do
    _ <- char ':'
    content <- takeWhileP Nothing (/= '\n')
    _ <- optional newline
    pure $ SSEComment content

-- ════════════════════════════════════════════════════════════════════════════════
-- JSON Content Extraction
--
-- We DON'T use aeson for streaming. We use Megaparsec to surgically extract
-- just the "content" field from OpenAI-format JSON. This avoids parsing 650
-- bytes of garbage we don't need per token.
-- ════════════════════════════════════════════════════════════════════════════════

-- | Extract content delta from OpenAI-format JSON
extractDelta :: Text -> Maybe Text
extractDelta input = case parse parseContentField "json" input of
    Left _parseError -> Nothing
    Right maybeContent -> maybeContent

parseContentField :: Parser (Maybe Text)
parseContentField = do
    _ <- manyTill anySingle (try $ string "\"content\"")
    _ <- char ':'
    _ <- space
    choice
        [ Nothing <$ string "null"
        , Just <$> parseJSONString
        ]

-- | Extract content delta from Anthropic-format JSON
-- {"type":"content_block_delta", "delta":{"type":"text_delta", "text":"..."}}
extractAnthropicDelta :: Text -> Maybe Text
extractAnthropicDelta input = case parse parseAnthropicDelta "json" input of
    Left _ -> Nothing
    Right content -> content

parseAnthropicDelta :: Parser (Maybe Text)
parseAnthropicDelta = do
    -- Look for "delta" object
    _ <- manyTill anySingle (try $ string "\"delta\"")
    _ <- char ':'
    _ <- space
    _ <- char '{'
    
    -- Inside delta object, look for "text"
    _ <- manyTill anySingle (try $ string "\"text\"")
    _ <- char ':'
    _ <- space
    
    Just <$> parseJSONString

-- | Extract finish_reason from OpenAI-format JSON
extractFinishReason :: Text -> Maybe Text
extractFinishReason input = case parse parseFinishReasonField "json" input of
    Left _parseError -> Nothing
    Right maybeReason -> maybeReason

parseFinishReasonField :: Parser (Maybe Text)
parseFinishReasonField = do
    _ <- manyTill anySingle (try $ string "\"finish_reason\"")
    _ <- char ':'
    _ <- space
    choice
        [ Nothing <$ string "null"
        , Just <$> parseJSONString
        ]

-- | Extract tool calls from OpenAI-format JSON
extractToolCalls :: Text -> [ToolCallDelta]
extractToolCalls input = case parse parseToolCallsField "json" input of
    Left _ -> []
    Right calls -> calls

parseToolCallsField :: Parser [ToolCallDelta]
parseToolCallsField = do
    _ <- manyTill anySingle (try $ string "\"tool_calls\"")
    _ <- char ':'
    _ <- space
    _ <- char '['
    _ <- space
    parseToolCallObjects

parseToolCallObjects :: Parser [ToolCallDelta]
parseToolCallObjects = do
    first <- parseToolCallObject
    rest <- many (try (space *> char ',' *> space *> parseToolCallObject))
    pure (first : rest)

parseToolCallObject :: Parser ToolCallDelta
parseToolCallObject = do
    _ <- char '{'
    index <- parseIndex
    id_ <- optional (try parseId)
    (name, args) <- parseFunction
    _ <- manyTill anySingle (char '}')
    pure $ ToolCallDelta index id_ name args

parseIndex :: Parser Int
parseIndex = do
    _ <- manyTill anySingle (try $ string "\"index\"")
    _ <- char ':'
    _ <- space
    digits <- some digitChar
    pure $ read digits

parseId :: Parser Text
parseId = do
    _ <- manyTill anySingle (try $ string "\"id\"")
    _ <- char ':'
    _ <- space
    parseJSONString

parseFunction :: Parser (Maybe Text, Maybe Text)
parseFunction = do
    _ <- manyTill anySingle (try $ string "\"function\"")
    _ <- char ':'
    _ <- space
    _ <- char '{'
    name <- optional (try parseName)
    args <- optional (try parseArguments)
    _ <- manyTill anySingle (char '}') -- Close function object
    pure (name, args)

parseName :: Parser Text
parseName = do
    _ <- manyTill anySingle (try $ string "\"name\"")
    _ <- char ':'
    _ <- space
    parseJSONString

parseArguments :: Parser Text
parseArguments = do
    _ <- manyTill anySingle (try $ string "\"arguments\"")
    _ <- char ':'
    _ <- space
    parseJSONString

-- ════════════════════════════════════════════════════════════════════════════════
-- JSON String Parser
-- ════════════════════════════════════════════════════════════════════════════════

parseJSONString :: Parser Text
parseJSONString = do
    _ <- char '"'
    characters <- manyTill parseStringCharacter (char '"')
    pure $ T.pack characters

parseStringCharacter :: Parser Char
parseStringCharacter = parseEscapedCharacter <|> anySingleBut '"'

parseEscapedCharacter :: Parser Char
parseEscapedCharacter =
    char '\\'
        *> choice
            [ '"' <$ char '"'
            , '\\' <$ char '\\'
            , '/' <$ char '/'
            , '\b' <$ char 'b'
            , '\f' <$ char 'f'
            , '\n' <$ char 'n'
            , '\r' <$ char 'r'
            , '\t' <$ char 't'
            , parseUnicodeEscape
            ]

parseUnicodeEscape :: Parser Char
parseUnicodeEscape = do
    _ <- char 'u'
    hexDigits <- count 4 hexDigitChar
    pure $ toEnum $ read ("0x" ++ hexDigits)
