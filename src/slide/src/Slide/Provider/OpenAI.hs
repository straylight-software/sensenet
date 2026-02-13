{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

{- | OpenAI inference provider using HTTP/2


OpenAI serves models via OpenAI-compatible endpoints with Api-Key or Bearer auth.
Their SSE format is standard OpenAI streaming format.

This provider uses HTTP/2 for multiplexing and better performance.
-}
module Slide.Provider.OpenAI (
    -- * Configuration
    OpenAIConfig (..),

    -- * Connection
    OpenAIConnection (..),
    withOpenAIConnection,

    -- * Streaming
    streamCompletion,
    streamCompletionWithMessages,
    streamRaw,

    -- * URL Parsing (exported for testing)
    ParsedEndpoint (..),
    parseEndpoint,
) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as C8
import Data.ByteString.Lazy qualified as LBS

import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Void (Void)
import Network.Socket (PortNumber)
import Text.Megaparsec (Parsec, (<|>), parse, optional, many, some, eof, try, satisfy)
import Text.Megaparsec.Char (char, digitChar, alphaNumChar)

import Slide.Parse (SSEEvent (..), extractDelta, extractToolCalls, parseSSEIncremental)
import Slide.Provider (AuthScheme (..), StreamConfig (..), StreamEvent (..), defaultStreamConfig)
import Slide.Provider.HTTP2 (Http2Connection (..), StreamResult (..), streamRequest, withHttp2Connection)


-- ════════════════════════════════════════════════════════════════════════════════
-- Configuration
-- ════════════════════════════════════════════════════════════════════════════════

data OpenAIConfig = OpenAIConfig
    { openaiEndpoint :: !Text
    , openaiAuth :: !AuthScheme
    , openaiModel :: !(Maybe Text)
    }

-- ════════════════════════════════════════════════════════════════════════════════
-- Connection
-- ════════════════════════════════════════════════════════════════════════════════

{- | OpenAI-specific HTTP/2 connection handle
Note: All operations on this connection must happen within the withOpenAIConnection callback
-}
data OpenAIConnection = OpenAIConnection
    { connH2 :: !Http2Connection
    , connAuth :: !AuthScheme
    , connModel :: !(Maybe Text)
    , connPath :: !ByteString
    }

{- | Create OpenAI connection with HTTP/2 and TLS
All streaming operations must happen within the callback
-}
withOpenAIConnection ::
    OpenAIConfig ->
    (OpenAIConnection -> IO a) ->
    IO a
withOpenAIConnection config action = do
    -- Parse endpoint URL
    endpoint <- case parseEndpoint (openaiEndpoint config) of
        Left err -> fail err
        Right e -> pure e
    
    withHttp2Connection (endpointHost endpoint) (fromIntegral $ endpointPort endpoint) $ \h2Conn -> do
        let connection =
                OpenAIConnection
                    { connH2 = h2Conn
                    , connAuth = openaiAuth config
                    , connModel = openaiModel config
                    , connPath = endpointPath endpoint
                    }
        action connection

-- ════════════════════════════════════════════════════════════════════════════════
-- URL Parsing
-- ════════════════════════════════════════════════════════════════════════════════

type URLParser = Parsec Void Text

-- | Parsed endpoint components
data ParsedEndpoint = ParsedEndpoint
    { endpointHost :: !Text
    , endpointPort :: !PortNumber
    , endpointPath :: !ByteString
    , endpointUseTLS :: !Bool
    }
    deriving stock (Show, Eq)

-- | Parse endpoint URL into structured components
--
-- Handles:
--   - https://host/path (port 443)
--   - http://host/path (port 80)
--   - https://host:port/path
--   - Missing path defaults to /v1/chat/completions
--
-- Examples:
--   >>> parseEndpoint "https://api.openai.com/v1/chat/completions"
--   Right (ParsedEndpoint "api.openai.com" 443 "/v1/chat/completions" True)
--
--   >>> parseEndpoint "http://localhost:8080/v1/completions"
--   Right (ParsedEndpoint "localhost" 8080 "/v1/completions" False)
parseEndpoint :: Text -> Either String ParsedEndpoint
parseEndpoint url = case parse urlParser "endpoint" url of
    Left err -> Left $ "Invalid endpoint URL: " <> show err
    Right endpoint -> Right endpoint

urlParser :: URLParser ParsedEndpoint
urlParser = do
    (useTLS, defaultPort) <- schemeParser
    host <- hostParser
    port <- portParser defaultPort
    path <- pathParser
    eof
    pure ParsedEndpoint
        { endpointHost = host
        , endpointPort = fromIntegral port
        , endpointPath = C8.pack $ T.unpack path
        , endpointUseTLS = useTLS
        }

schemeParser :: URLParser (Bool, Int)
schemeParser =
    try httpsScheme <|> httpScheme
  where
    httpsScheme = (True, 443) <$ (char 'h' *> char 't' *> char 't' *> char 'p' *> char 's' *> char ':' *> char '/' *> char '/')
    httpScheme = (False, 80) <$ (char 'h' *> char 't' *> char 't' *> char 'p' *> char ':' *> char '/' *> char '/')

hostParser :: URLParser Text
hostParser = do
    -- Host can contain alphanumeric, dots, and hyphens
    chars <- some (alphaNumChar <|> char '.' <|> char '-')
    pure $ T.pack chars

portParser :: Int -> URLParser Int
portParser defaultPort =
    (char ':' *> (read <$> some digitChar))
    <|> pure defaultPort

pathParser :: URLParser Text
pathParser = do
    maybePath <- optional $ do
        _ <- char '/'
        rest <- many (satisfy (\c -> c /= ' ' && c /= '\t' && c /= '\n'))
        pure $ "/" <> T.pack rest
    pure $ case maybePath of
        Just p | not (T.null p) && p /= "/" -> p
        _ -> "/v1/chat/completions"

-- ════════════════════════════════════════════════════════════════════════════════
-- Streaming
-- ════════════════════════════════════════════════════════════════════════════════

{- | Stream completion, calling handler for each content delta
Must be called within withOpenAIConnection callback
-}
streamCompletion ::
    OpenAIConnection ->
    -- | User prompt
    Text ->
    -- | Streaming configuration
    StreamConfig ->
    -- | Event handler (Content or ToolCall)
    (StreamEvent -> IO ()) ->
    -- | On finish handler
    IO () ->
    -- | Wire logger
    (Text -> IO ()) ->
    IO ()
streamCompletion connection prompt streamConfig onEvent onFinish onWireLog = do
    let userMessage =
            object
                [ "role" .= ("user" :: Text)
                , "content" .= prompt
                ]
    streamCompletionWithMessages connection [userMessage] streamConfig onEvent onFinish onWireLog

{- | Stream completion with full message list
Must be called within withOpenAIConnection callback
-}
streamCompletionWithMessages ::
    OpenAIConnection ->
    -- | Messages array
    [Value] ->
    -- | Streaming configuration
    StreamConfig ->
    -- | Event handler
    (StreamEvent -> IO ()) ->
    -- | On finish handler
    IO () ->
    -- | Wire logger
    (Text -> IO ()) ->
    IO ()
streamCompletionWithMessages = streamCompletionWithMessagesStateful

streamCompletionWithMessagesStateful :: 
    OpenAIConnection -> [Value] -> StreamConfig -> (StreamEvent -> IO ()) -> IO () -> (Text -> IO ()) -> IO ()
streamCompletionWithMessagesStateful connection messages streamConfig onEvent onFinish onWireLog = do
    bufferRef <- newIORef ""
    
    let requestPayload = buildRequestPayload connection messages streamConfig
    let body = LBS.toStrict $ encode requestPayload
    
    let authHeader = case connAuth connection of
            AuthApiKey key -> "Api-Key " <> C8.pack (T.unpack key)
            AuthBearer token -> "Bearer " <> C8.pack (T.unpack token)
            AuthXApiKey _ -> error "X-Api-Key not supported in headers list logic yet"
            AuthNone -> ""

    let headers = 
            [ ("content-type", "application/json")
            , ("authorization", authHeader)
            ]

    streamRequest (connH2 connection) (connPath connection) headers body $ \result -> case result of
        StreamChunk chunk -> do
            liftIO $ onWireLog "received chunk"
            buffer <- readIORef bufferRef
            let decodedChunk = TE.decodeUtf8With lenientDecoder chunk
                fullBuffer = buffer <> decodedChunk
                (parsedEvents, remainingText) = splitIntoSSEEvents fullBuffer
            
            writeIORef bufferRef remainingText
            liftIO $ mapM_ (handleSSEEvent onEvent onFinish) parsedEvents
            
        StreamEnd -> liftIO onFinish
        StreamError err -> liftIO $ onWireLog $ "Stream error: " <> T.pack err

    where
        lenientDecoder _ _ = Just '\xFFFD'


{- | Stream raw SSE chunks (for debugging)
Must be called within withOpenAIConnection callback
-}
streamRaw ::
    OpenAIConnection ->
    -- | User prompt
    Text ->
    -- | Raw chunk handler
    (ByteString -> IO ()) ->
    IO ()
streamRaw connection prompt onChunk = do
    let userMessage =
            object
                [ "role" .= ("user" :: Text)
                , "content" .= prompt
                ]
    let requestPayload = buildRequestPayload connection [userMessage] defaultStreamConfig
    let body = LBS.toStrict $ encode requestPayload
    
    let authHeader = case connAuth connection of
            AuthApiKey key -> "Api-Key " <> C8.pack (T.unpack key)
            AuthBearer token -> "Bearer " <> C8.pack (T.unpack token)
            AuthXApiKey _ -> error "X-Api-Key not supported in headers list logic yet"
            AuthNone -> ""

    let headers = 
            [ ("content-type", "application/json")
            , ("authorization", authHeader)
            ]

    streamRequest (connH2 connection) (connPath connection) headers body $ \result -> case result of
        StreamChunk chunk -> onChunk chunk
        StreamEnd -> pure ()
        StreamError _ -> pure ()

-- ════════════════════════════════════════════════════════════════════════════════
-- Request Building
-- ════════════════════════════════════════════════════════════════════════════════

buildRequestPayload :: OpenAIConnection -> [Value] -> StreamConfig -> Value
buildRequestPayload connection messages config =
    object $
        concat
            [
                [ "messages" .= messages
                , "stream" .= True
                ]
            , maybe [] (\m -> ["model" .= m]) (connModel connection)
            , maybe [] (\t -> ["max_tokens" .= t]) (streamMaxTokens config)
            , maybe [] (\t -> ["temperature" .= t]) (streamTemperature config)
            , maybe [] (\p -> ["top_p" .= p]) (streamTopP config)
            , -- Remove stop sequence field if empty to avoid Vertex errors
              ["stop" .= streamStopSequences config | not (null (streamStopSequences config))]
            ]

-- ════════════════════════════════════════════════════════════════════════════════
-- SSE Processing
-- ════════════════════════════════════════════════════════════════════════════════

-- | Split buffer into complete SSE events and remainder
--
-- Uses Megaparsec-based incremental parsing for robust handling of:
--   - Events split across chunk boundaries
--   - Multiple events in single chunk
--   - Malformed events (gracefully skipped)
splitIntoSSEEvents :: Text -> ([SSEEvent], Text)
splitIntoSSEEvents = parseSSEIncremental

handleSSEEvent :: (StreamEvent -> IO ()) -> IO () -> SSEEvent -> IO ()
handleSSEEvent onEvent onFinish sseEvent = case sseEvent of
    SSEData jsonContent -> do
        -- Try content delta
        for_ (extractDelta jsonContent) $ \content ->
            onEvent (EventContent content)
        -- Try tool calls
        let toolCalls = extractToolCalls jsonContent
        for_ toolCalls $ \toolCall ->
            onEvent (EventToolCall toolCall)
    SSEDone -> onFinish
    SSERetry _milliseconds -> pure ()
    SSEComment _commentText -> pure ()
    SSEEventType _eventType -> pure () -- Anthropic-style event type, ignored
    SSEEmpty -> pure ()
