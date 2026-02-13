{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

{- | Vertex AI (Anthropic) Provider

Handles the specific SSE format used by Anthropic models hosted on Google Vertex AI.
Endpoint: .../publishers/anthropic/models/{model}:streamRawPredict
-}
module Slide.Provider.Vertex.Anthropic (
    -- * Configuration
    VertexAnthropicConfig (..),

    -- * Connection
    VertexAnthropicConnection (..),
    withVertexAnthropicConnection,

    -- * Streaming
    streamCompletion,
) where

import Control.Monad ()
import Control.Monad.IO.Class ()
import Data.Aeson (encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as C8
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Network.Socket (PortNumber)

import Slide.Parse (SSEEvent (..), extractAnthropicDelta, parseSSE)
import Slide.Provider (AuthScheme (..), StreamConfig (..), StreamEvent (..))
import Slide.Provider.HTTP2 (Http2Connection (..), StreamResult (..), streamRequest, withHttp2Connection)

-- ════════════════════════════════════════════════════════════════════════════════
-- Configuration
-- ════════════════════════════════════════════════════════════════════════════════

data VertexAnthropicConfig = VertexAnthropicConfig
    { vertexEndpoint :: !Text
    , vertexAuth :: !AuthScheme
    , vertexModel :: !Text -- e.g. "claude-3-5-sonnet@20240620"
    , vertexRegion :: !Text
    , vertexProject :: !Text
    }

-- ════════════════════════════════════════════════════════════════════════════════
-- Connection
-- ════════════════════════════════════════════════════════════════════════════════

data VertexAnthropicConnection = VertexAnthropicConnection
    { connH2 :: !Http2Connection
    , connAuth :: !AuthScheme
    , connPath :: !ByteString
    }

withVertexAnthropicConnection ::
    VertexAnthropicConfig ->
    (VertexAnthropicConnection -> IO a) ->
    IO a
withVertexAnthropicConnection config action = do
    let (host, port, path) = parseEndpoint (vertexEndpoint config)
    
    withHttp2Connection host (fromIntegral port) $ \h2Conn -> do
        let connection =
                VertexAnthropicConnection
                    { connH2 = h2Conn
                    , connAuth = vertexAuth config
                    , connPath = path
                    }
        action connection

-- | Parse endpoint URL (simplified for Vertex)
-- Expected: https://{region}-aiplatform.googleapis.com/...
parseEndpoint :: Text -> (Text, PortNumber, ByteString)
parseEndpoint url =
    let url' = T.dropWhile (== '/') $ T.drop 8 url
        (hostPort, path) = T.break (== '/') url'
        (host, port) = case T.break (== ':') hostPort of
            (h, "") -> (h, 443)
            (h, p) -> (h, read (T.unpack $ T.drop 1 p) :: Int)
        path' = if T.null path then "/" else C8.pack $ T.unpack path
     in (host, fromIntegral port, path')

-- ════════════════════════════════════════════════════════════════════════════════
-- Streaming
-- ════════════════════════════════════════════════════════════════════════════════

streamCompletion ::
    VertexAnthropicConnection ->
    Text -> -- Prompt
    StreamConfig ->
    (StreamEvent -> IO ()) ->
    IO () ->
    (Text -> IO ()) ->
    IO ()
streamCompletion connection prompt streamConfig onEvent onFinish onWireLog = do
    -- Stateful buffer for SSE reassembly
    bufferRef <- newIORef ""

    let requestPayload =
            object
                [ "anthropic_version" .= ("vertex-2023-10-16" :: Text)
                , "messages" .= [object ["role" .= ("user" :: Text), "content" .= prompt]]
                , "max_tokens" .= maybe 4096 id (streamMaxTokens streamConfig)
                , "stream" .= True
                ]
    
    let body = LBS.toStrict $ encode requestPayload
    
    let authHeader = case connAuth connection of
            AuthBearer token -> "Bearer " <> C8.pack (T.unpack token)
            _ -> error "Vertex requires Bearer auth"

    let headers = 
            [ ("content-type", "application/json")
            , ("authorization", authHeader)
            ]

    streamRequest (connH2 connection) (connPath connection) headers body $ \result -> case result of
        StreamChunk chunk -> do
            buffer <- readIORef bufferRef
            let decodedChunk = TE.decodeUtf8With lenientDecoder chunk
                fullBuffer = buffer <> decodedChunk
                (parsedEvents, remainingText) = splitIntoSSEEvents fullBuffer
            
            writeIORef bufferRef remainingText
            mapM_ (handleSSEEvent onEvent onFinish) parsedEvents
            
        StreamEnd -> onFinish
        StreamError err -> onWireLog $ "Stream error: " <> T.pack err

  where
    lenientDecoder _ _ = Just '\xFFFD'

-- ════════════════════════════════════════════════════════════════════════════════
-- SSE Parsing (Anthropic Specific)
-- ════════════════════════════════════════════════════════════════════════════════

splitIntoSSEEvents :: Text -> ([SSEEvent], Text)
splitIntoSSEEvents textBuffer =
    let segments = T.splitOn "\n\n" textBuffer
     in case segments of
            [] -> ([], "")
            [incomplete] -> ([], incomplete)
            multipleSegments ->
                let completeSegments = init multipleSegments
                    remainingSegment = last multipleSegments
                    parsedEvents = concatMap parseSegment completeSegments
                 in (parsedEvents, remainingSegment)
  where
    parseSegment :: Text -> [SSEEvent]
    parseSegment segment = case parseSSE (segment <> "\n") of
        Left _ -> []
        Right events -> events

handleSSEEvent :: (StreamEvent -> IO ()) -> IO () -> SSEEvent -> IO ()
handleSSEEvent onEvent _onFinish sseEvent = case sseEvent of
    SSEData jsonContent ->
        -- Anthropic sends: data: {"type":"content_block_delta", ...}
        case extractAnthropicDelta jsonContent of
            Just content -> onEvent (EventContent content)
            Nothing -> pure ()
    _ -> pure ()
