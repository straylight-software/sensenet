{- | Provider abstraction for inference endpoints

Different providers (Baseten, Together, Fireworks, local vLLM) have
different auth schemes and quirks. This module provides a common interface.
-}
module Slide.Provider (
    -- * Provider configuration
    ProviderConfig (..),
    AuthScheme (..),

    -- * Connection
    ProviderConnection (..),
    withProvider,

    -- * Streaming
    StreamConfig (..),
    defaultStreamConfig,
    StreamEvent (..),
    StreamCompletionHandler,
) where

import Data.Text (Text)
import Slide.Parse (ToolCallDelta)

-- ════════════════════════════════════════════════════════════════════════════════
-- Provider Configuration
-- ════════════════════════════════════════════════════════════════════════════════

-- | Event from the inference stream
data StreamEvent
    = EventContent !Text
    | EventToolCall !ToolCallDelta
    deriving stock (Show, Eq)

-- | Authentication scheme for the provider
data AuthScheme
    = -- | Authorization: Bearer <token>
      AuthBearer !Text
    | -- | Authorization: Api-Key <token>
      AuthApiKey !Text
    | -- | X-Api-Key: <token>
      AuthXApiKey !Text
    | -- | No authentication (local endpoints)
      AuthNone
    deriving stock (Show, Eq)

-- | Provider-specific configuration
data ProviderConfig = ProviderConfig
    { providerEndpoint :: !Text
    , providerAuth :: !AuthScheme
    , providerModel :: !(Maybe Text)
    , providerTimeoutSecs :: !Int
    }
    deriving stock (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════════
-- Connection
-- ════════════════════════════════════════════════════════════════════════════════

-- | Opaque connection handle
data ProviderConnection = ProviderConnection
    { connectionConfig :: !ProviderConfig
    , connectionState :: !ConnectionState
    }

-- | Internal connection state (will be extended with connection pool, etc.)
newtype ConnectionState = ConnectionState
    { stateRequestCount :: Int
    }

-- | Create a provider connection
withProvider :: ProviderConfig -> (ProviderConnection -> IO a) -> IO a
withProvider config action = do
    let initialState = ConnectionState{stateRequestCount = 0}
    let connection =
            ProviderConnection
                { connectionConfig = config
                , connectionState = initialState
                }
    action connection

-- ════════════════════════════════════════════════════════════════════════════════
-- Streaming Configuration
-- ════════════════════════════════════════════════════════════════════════════════

-- | Configuration for a streaming completion request
data StreamConfig = StreamConfig
    { streamMaxTokens :: !(Maybe Int)
    , streamTemperature :: !(Maybe Double)
    , streamTopP :: !(Maybe Double)
    , streamStopSequences :: ![Text]
    }
    deriving stock (Show, Eq)

-- | Default streaming configuration
defaultStreamConfig :: StreamConfig
defaultStreamConfig =
    StreamConfig
        { streamMaxTokens = Nothing
        , streamTemperature = Nothing
        , streamTopP = Nothing
        , streamStopSequences = []
        }

{- | Stream completion type signature

This module provides the abstract interface. Concrete implementations:

  - 'Slide.Provider.OpenAI.streamCompletion' - OpenAI/Baseten/Together/etc.
  - 'Slide.Provider.Vertex.Anthropic.streamCompletion' - Anthropic on Vertex AI

Use the provider-specific modules directly rather than this abstract interface.
-}
type StreamCompletionHandler =
    -- | User prompt
    Text ->
    -- | Streaming configuration
    StreamConfig ->
    -- | Content delta handler
    (Text -> IO ()) ->
    -- | On finish handler
    IO () ->
    IO ()
