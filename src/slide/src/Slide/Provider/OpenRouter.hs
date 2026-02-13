{-# LANGUAGE OverloadedStrings #-}

{- | OpenRouter inference provider using HTTP/2

OpenRouter provides a unified API for multiple LLM providers (Anthropic, OpenAI,
Google, Meta, etc.) with OpenAI-compatible request/response format.

Endpoint: https://openrouter.ai/api/v1/chat/completions

Features:
  - Model routing via model parameter (e.g., "anthropic/claude-sonnet-4")
  - Provider preferences and fallbacks
  - Usage tracking and rate limiting
  - Streaming via SSE

Authentication:
  - Authorization: Bearer <OPENROUTER_API_KEY>

Optional headers:
  - HTTP-Referer: Your site URL (for rankings)
  - X-Title: Your app name (for rankings)
-}
module Slide.Provider.OpenRouter (
    -- * Configuration
    OpenRouterConfig (..),
    defaultOpenRouterConfig,

    -- * Connection
    OpenRouterConnection (..),
    withOpenRouterConnection,

    -- * Streaming
    streamCompletion,
    streamCompletionWithMessages,
) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Key, Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Foldable (for_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Slide.Parse (SSEEvent (..), extractDelta, extractToolCalls, parseSSEIncremental)
import Slide.Provider (StreamConfig (..), StreamEvent (..))
import Slide.Provider.HTTP2 (Http2Connection (..), StreamResult (..), streamRequest, withHttp2Connection)

-- ════════════════════════════════════════════════════════════════════════════════
-- Configuration
-- ════════════════════════════════════════════════════════════════════════════════

-- | OpenRouter-specific configuration
data OpenRouterConfig = OpenRouterConfig
    { openrouterApiKey :: !Text
    -- ^ OpenRouter API key (sk-or-...)
    , openrouterModel :: !Text
    -- ^ Model identifier (e.g., "anthropic/claude-sonnet-4", "google/gemini-2.0-flash")
    , openrouterReferer :: !(Maybe Text)
    -- ^ Optional HTTP-Referer for rankings
    , openrouterTitle :: !(Maybe Text)
    -- ^ Optional X-Title for rankings
    , openrouterProviderOrder :: !(Maybe [Text])
    -- ^ Optional provider routing preferences
    }
    deriving stock (Show, Eq)

-- | Default configuration (requires API key and model to be set)
defaultOpenRouterConfig :: Text -> Text -> OpenRouterConfig
defaultOpenRouterConfig apiKey model =
    OpenRouterConfig
        { openrouterApiKey = apiKey
        , openrouterModel = model
        , openrouterReferer = Just "https://github.com/straylight/jaylene-slide"
        , openrouterTitle = Just "jaylene-slide"
        , openrouterProviderOrder = Nothing
        }

-- ════════════════════════════════════════════════════════════════════════════════
-- Connection
-- ════════════════════════════════════════════════════════════════════════════════

-- | OpenRouter HTTP/2 connection handle
data OpenRouterConnection = OpenRouterConnection
    { orConnH2 :: !Http2Connection
    , orConnConfig :: !OpenRouterConfig
    }

-- | OpenRouter API host
openRouterHost :: Text
openRouterHost = "openrouter.ai"

-- | OpenRouter API port (HTTPS)
openRouterPort :: Int
openRouterPort = 443

-- | OpenRouter API path
openRouterPath :: ByteString
openRouterPath = "/api/v1/chat/completions"

{- | Create OpenRouter connection with HTTP/2 and TLS

All streaming operations must happen within the callback.
-}
withOpenRouterConnection ::
    OpenRouterConfig ->
    (OpenRouterConnection -> IO a) ->
    IO a
withOpenRouterConnection config action = do
    withHttp2Connection openRouterHost openRouterPort $ \h2Conn -> do
        let connection =
                OpenRouterConnection
                    { orConnH2 = h2Conn
                    , orConnConfig = config
                    }
        action connection

-- ════════════════════════════════════════════════════════════════════════════════
-- Streaming
-- ════════════════════════════════════════════════════════════════════════════════

{- | Stream completion from OpenRouter

Sends a single user message and streams the response.
-}
streamCompletion ::
    OpenRouterConnection ->
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

{- | Stream completion with full message history

Allows multi-turn conversations by passing the full message array.
-}
streamCompletionWithMessages ::
    OpenRouterConnection ->
    -- | Messages array (OpenAI format)
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
streamCompletionWithMessages connection messages streamConfig onEvent onFinish onWireLog = do
    bufferRef <- newIORef ""

    let config = orConnConfig connection
        requestPayload = buildRequestPayload config messages streamConfig
        body = LBS.toStrict $ encode requestPayload
        headers = buildHeaders config

    streamRequest (orConnH2 connection) openRouterPath headers body $ \result -> case result of
        StreamChunk chunk -> do
            liftIO $ onWireLog "received chunk"
            buffer <- readIORef bufferRef
            let decodedChunk = TE.decodeUtf8With lenientDecoder chunk
                fullBuffer = buffer <> decodedChunk
                (parsedEvents, remainingText) = parseSSEIncremental fullBuffer

            writeIORef bufferRef remainingText
            liftIO $ mapM_ (handleSSEEvent onEvent onFinish) parsedEvents

        StreamEnd -> liftIO onFinish
        StreamError err -> liftIO $ onWireLog $ "Stream error: " <> T.pack err
  where
    lenientDecoder _ _ = Just '\xFFFD'

-- ════════════════════════════════════════════════════════════════════════════════
-- Request Building
-- ════════════════════════════════════════════════════════════════════════════════

-- | Build HTTP headers for OpenRouter request
buildHeaders :: OpenRouterConfig -> [(ByteString, ByteString)]
buildHeaders config =
    [ ("content-type", "application/json")
    , ("authorization", "Bearer " <> TE.encodeUtf8 (openrouterApiKey config))
    ]
        ++ maybe [] (\r -> [("http-referer", TE.encodeUtf8 r)]) (openrouterReferer config)
        ++ maybe [] (\t -> [("x-title", TE.encodeUtf8 t)]) (openrouterTitle config)

-- | Build JSON request payload
buildRequestPayload :: OpenRouterConfig -> [Value] -> StreamConfig -> Value
buildRequestPayload config messages streamConfig =
    object $
        concat
            [
                [ "model" .= openrouterModel config
                , "messages" .= messages
                , "stream" .= True
                ]
            , maybe [] (\t -> ["max_tokens" .= t]) (streamMaxTokens streamConfig)
            , maybe [] (\t -> ["temperature" .= t]) (streamTemperature streamConfig)
            , maybe [] (\p -> ["top_p" .= p]) (streamTopP streamConfig)
            , if null (streamStopSequences streamConfig)
                then []
                else ["stop" .= streamStopSequences streamConfig]
            , buildProviderPrefs config
            ]

-- | Build provider preferences if specified
buildProviderPrefs :: OpenRouterConfig -> [(Key, Value)]
buildProviderPrefs config = case openrouterProviderOrder config of
    Nothing -> []
    Just providers ->
        [ "provider"
            .= object
                ["order" .= providers]
        ]

-- ════════════════════════════════════════════════════════════════════════════════
-- SSE Processing
-- ════════════════════════════════════════════════════════════════════════════════

-- | Handle a single SSE event
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
    SSEEventType _eventType -> pure () -- Anthropic-style, ignored
    SSEEmpty -> pure ()
