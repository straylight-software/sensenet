{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}

{- | jaylene-slide: Console cowboy for the sprawl

Jacks into OpenAI-compatible inference endpoints (Baseten, Together, etc.),
parses their SSE/JSON garbage, and emits clean SIGIL binary frames over ZMQ.
-}
module Main (main) where

-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
--                                                                 // imports
-- ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

import Control.Concurrent.Async (async)
import Control.Exception (bracket, throwIO)
import Control.Monad (forever, unless, when)
import Control.Monad.IO.Class (liftIO)
import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector.Unboxed qualified as VU
import Data.Word (Word32, Word64)
import Dhall qualified
import Katip
import Network.HTTP.Types (status200)
import Network.Wai qualified as Wai
import Network.Wai.Handler.Warp (run)
import Numeric (showHex)
import Options.Applicative (
    Parser,
    ParserInfo,
    argument,
    auto,
    command,
    execParser,
    fullDesc,
    header,
    help,
    helper,
    hsubparser,
    info,
    long,
    metavar,
    maybeReader,
    option,
    optional,
    progDesc,
    short,
    str,
    strOption,
    switch,
    value,
    (<**>),
 )
import Prometheus qualified as P
import Prometheus.Metric.GHC qualified as P
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hFlush, hPutStrLn, isEOF, stderr, stdout)
import System.Random (randomIO)
import System.ZMQ4 (Pub (..), Socket, Sub (..), bind, close, connect, context, receive, send, socket, subscribe, term)

import Slide.Chunk (
    ChunkState,
    ProcessResult (..),
    finalizeChunk,
    initChunkState,
    processToken,
    flushTextChunk,
 )
import Slide.Configuration qualified as Config
import Slide.Configuration (JackConfig (..), verifyHash)
import Slide.HotTable (HotTable, defaultHotTable, loadHotTable)
import Slide.Parse (ToolCallDelta (..))
import Slide.Provider (defaultStreamConfig, StreamEvent(..), AuthScheme(..))
import Slide.Provider.OpenAI (OpenAIConfig(..), OpenAIConnection, withOpenAIConnection, streamCompletion)
import Slide.Provider.OpenRouter qualified as OpenRouter
import Slide.Provider.Vertex.Anthropic qualified as VertexAnthropic
import Slide.Tokenizer (HFTokenizer, decode, encode, loadTokenizerJSON, loadIdentityTokenizer, tokenToId)
import Slide.Wire.Decode (Chunk (..), ChunkContent (..), decodeFrameIncremental, initDecodeState)
import Slide.Wire.Frame (Frame (..), FrameOp, newFrameBuilder, writeControl, writeExtendedToken, builderLength, finishFrame)
import Slide.Wire.Types (
    pattern OP_TOOL_CALL_START,
    pattern OP_TOOL_CALL_END
 )

-- ════════════════════════════════════════════════════════════════════════════
--                                                       // cli // configuration
-- ════════════════════════════════════════════════════════════════════════════

data Command
    = CommandJack !JackOptions
    | CommandListen !ListenOptions

data JackOptions = JackOptions
    { jackEndpoint :: !(Maybe Text)
    , jackEndpointFlag :: !(Maybe Text)
    , jackApiKey :: !(Maybe Text)
    , jackModel :: !(Maybe Text)
    , jackZmqBind :: !Text
    , jackHotTable :: !(Maybe FilePath)
    , jackTokenizer :: !(Maybe FilePath)
    , jackVerbose :: !Bool
    , jackJsonLogs :: !Bool
    , jackMetricsPort :: !Int
    , jackFlushThreshold :: !Int
    , jackProvider :: !ProviderType
    , jackConfigPath :: !(Maybe FilePath)
    }

data ProviderType
    = ProviderBaseten
    | ProviderOpenAI
    | ProviderOpenRouter
    | ProviderVertex
    deriving (Show, Eq)

data ListenOptions = ListenOptions
    { listenZmqConnect :: !Text
    , listenTokenizer :: !FilePath
    , listenVerbose :: !Bool
    , listenShowThink :: !Bool
    , listenDumpFrames :: !Bool
    }

parseCommand :: Parser Command
parseCommand =
    hsubparser
        ( command "jack" (info (CommandJack <$> parseJackOptions) (progDesc "Jack into provider and emit frames"))
            <> command "listen" (info (CommandListen <$> parseListenOptions) (progDesc "Listen to frames and print text"))
        )

parseJackOptions :: Parser JackOptions
parseJackOptions =
    JackOptions
        <$> optional
            ( argument
                str
                ( metavar "ENDPOINT"
                    <> help "Provider endpoint URL"
                )
            )
        <*> optional
            ( strOption
                ( long "endpoint"
                    <> short 'e'
                    <> metavar "URL"
                    <> help "Provider endpoint URL (flag form)"
                )
            )
        <*> optional
            ( strOption
                ( long "api-key"
                    <> short 'k'
                    <> metavar "KEY"
                    <> help "API key (default: $JAYLENE_API_KEY)"
                )
            )
        <*> optional
            ( strOption
                ( long "model"
                    <> short 'm'
                    <> metavar "MODEL"
                    <> help "Model override"
                )
            )
        <*> strOption
            ( long "zmq"
                <> short 'z'
                <> metavar "BIND"
                <> value "tcp://*:5555"
                <> help "ZMQ PUB bind address"
            )
        <*> optional
            ( strOption
                ( long "hot-table"
                    <> metavar "PATH"
                    <> help "Hot token table path"
                )
            )
        <*> optional
            ( strOption
                ( long "tokenizer"
                    <> short 't'
                    <> metavar "PATH"
                    <> help "Tokenizer JSON path"
                )
            )
        <*> switch
            ( long "verbose"
                <> short 'v'
                <> help "Verbose logging"
            )
        <*> switch
            ( long "json-logs"
                <> help "Emit structured JSON logs (good for Datadog/CloudWatch)"
            )
        <*> option
            auto
            ( long "metrics-port"
                <> value 9090
                <> metavar "PORT"
                <> help "Prometheus metrics port (default: 9090)"
            )
        <*> option
            auto
            ( long "flush-every"
                <> value 8
                <> metavar "N"
                <> help "Flush chunk every N tokens (default: 8)"
            )
        <*> option
            (maybeReader parseProvider)
            ( long "provider"
                <> value ProviderBaseten
                <> metavar "PROVIDER"
                <> help "Provider type (baseten, openai, vertex)"
            )
        <*> optional
            ( strOption
                ( long "config"
                    <> short 'c'
                    <> metavar "DHALL"
                    <> help "Load configuration from Dhall file"
                )
            )

parseProvider :: String -> Maybe ProviderType
parseProvider "baseten" = Just ProviderBaseten
parseProvider "openai" = Just ProviderOpenAI
parseProvider "openrouter" = Just ProviderOpenRouter
parseProvider "vertex" = Just ProviderVertex
parseProvider _ = Nothing

parseListenOptions :: Parser ListenOptions
parseListenOptions =
    ListenOptions
        <$> strOption
            ( long "zmq"
                <> short 'z'
                <> metavar "CONNECT"
                <> value "tcp://localhost:5555"
                <> help "ZMQ SUB connect address"
            )
        <*> strOption
            ( long "tokenizer"
                <> short 't'
                <> metavar "PATH"
                <> help "Tokenizer JSON path"
            )
        <*> switch
            ( long "verbose"
                <> short 'v'
                <> help "Show debug info"
            )
        <*> switch
            ( long "show-think"
                <> help "Display <think> blocks in output"
            )
        <*> switch
            ( long "dump-frames"
                <> help "Dump raw frame bytes and structure"
            )

commandLineParserInfo :: ParserInfo Command
commandLineParserInfo =
    info
        (parseCommand <**> helper)
        ( fullDesc
            <> progDesc "jaylene-slide ingress adapter"
            <> header "jaylene-slide — console cowboy for the sprawl"
        )

-- ════════════════════════════════════════════════════════════════════════════
--                                                           // logging // setup
-- ════════════════════════════════════════════════════════════════════════════

initLogging :: Bool -> Bool -> Namespace -> (LogEnv -> IO a) -> IO a
initLogging verbose _useJson _namespace action = do
    handleScribe <- mkHandleScribe ColorIfTerminal stderr (permitItem logLevel) V2
    let mkLogEnv = initLogEnv "slide" "production"
    bracket mkLogEnv closeScribes $ \le -> do
        let scribeName = "stderr"
        le' <- registerScribe scribeName handleScribe defaultScribeSettings le
        action le'
  where
    logLevel = if verbose then DebugS else InfoS

-- ════════════════════════════════════════════════════════════════════════════
--                                                        // main // entry point
-- ════════════════════════════════════════════════════════════════════════════

main :: IO ()
main = do
    cmd <- execParser commandLineParserInfo
    case cmd of
        CommandJack options ->
            initLogging (jackVerbose options) (jackJsonLogs options) (Namespace ["jack"]) $ \le ->
                runKatipContextT le () (Namespace ["jack"]) (runJack options)
        CommandListen options ->
            initLogging (listenVerbose options) False (Namespace ["listen"]) $ \le ->
                runKatipContextT le () (Namespace ["listen"]) (runListen options)

-- ════════════════════════════════════════════════════════════════════════════════
-- Metrics
-- ════════════════════════════════════════════════════════════════════════════════

data Metrics = Metrics
    { mFramesEmitted :: P.Counter
    , mBytesEmitted :: P.Counter
    , mTokensProcessed :: P.Counter
    }

setupMetrics :: Int -> IO Metrics
setupMetrics port = do
    -- Register GHC metrics
    _ <- P.register P.ghcMetrics

    -- Register App metrics
    frames <- P.register $ P.counter (P.Info "slide_frames_emitted_total" "Total frames emitted via ZMQ")
    bytes <- P.register $ P.counter (P.Info "slide_bytes_emitted_total" "Total bytes emitted via ZMQ")
    tokens <- P.register $ P.counter (P.Info "slide_tokens_processed_total" "Total tokens processed from provider")

    -- Start metrics server in background
    let metricsApp :: Wai.Application
        metricsApp _req respond = do
            metrics <- P.exportMetricsAsText
            respond $ Wai.responseLBS status200 [("Content-Type", "text/plain")] metrics

    _ <- async $ run port metricsApp

    pure $ Metrics frames bytes tokens

-- ════════════════════════════════════════════════════════════════════════════
--                                                                  // jack mode
-- ════════════════════════════════════════════════════════════════════════════

--                                                                  // jack mode
-- ════════════════════════════════════════════════════════════════════════════

runJack :: (KatipContext m) => JackOptions -> m ()
runJack options = do
    printBanner options

    -- Resolve configuration sources
    (resolvedEndpoint, resolvedTokenizerPath, resolvedModel, resolvedHotTablePath, resolvedAuth, resolvedDelimiters, resolvedProviderType) <- liftIO $ resolveConfig options

    -- Determine provider priority: Config > CLI > Default
    let selectedProvider = case resolvedProviderType of
            Just t -> t
            Nothing -> jackProvider options

    apiKey <- liftIO $ resolveApiKey options resolvedAuth

    -- Log authentication status (masked)
    case apiKey of
        Just k -> do
            let masked = if T.length k > 8 then T.take 4 k <> "..." <> T.takeEnd 4 k else "***"
            logFM InfoS $ ls $ "authentication: key loaded (" <> masked <> ")"
        Nothing -> do
            logFM WarningS "authentication: no api key found (checked CLI, Config, Env)"

    hotTable <- liftIO $ resolveHotTable options resolvedHotTablePath


    logFM InfoS $ ls $ "loading tokenizer: " <> resolvedTokenizerPath
    
    -- Verify tokenizer if using config (TODO: pass ModelSpec hash down)
    -- For now we just load it
    tokenizer <- liftIO $ if resolvedTokenizerPath == "identity"
        then loadIdentityTokenizer
        else loadTokenizerJSON resolvedTokenizerPath

    _boundaryTokens <- liftIO $ createBoundaryTokenSet tokenizer
    specialTokens <- liftIO $ createSpecialTokenConfig tokenizer resolvedDelimiters

    -- Setup metrics
    metrics <- liftIO $ setupMetrics (jackMetricsPort options)

    logFM InfoS "jacking in..."

    -- Capture logging context to restore it inside IO callbacks
    le <- getLogEnv
    ctx <- getKatipContext
    ns <- getKatipNamespace

    -- Initialize ZMQ context and socket
    liftIO $ bracket context term $ \ctxZmq ->
        bracket (socket ctxZmq Pub) close $ \publisherSocket -> do
            bind publisherSocket (T.unpack $ jackZmqBind options)

            let authScheme = case apiKey of
                    Just key -> case resolvedAuth of
                        Just Config.ApiKey -> AuthApiKey key
                        Just Config.Bearer -> AuthBearer key
                        Just (Config.ApiKeyFile _) -> AuthApiKey key -- Resolved content is the key
                        Just Config.None -> AuthNone
                        Nothing -> case selectedProvider of
                            ProviderBaseten -> AuthApiKey key
                            ProviderOpenAI -> AuthBearer key
                            ProviderOpenRouter -> AuthBearer key
                            ProviderVertex -> AuthBearer key
                    Nothing -> case resolvedAuth of
                        Just Config.None -> AuthNone
                        _ -> AuthNone -- Default if no key found

            -- Determine provider and dispatch connection logic
            case selectedProvider of
                ProviderOpenAI -> do

                    let config = OpenAIConfig
                            { openaiEndpoint = resolvedEndpoint
                            , openaiAuth = authScheme
                            , openaiModel = resolvedModel
                            }
                    withOpenAIConnection config $ \conn -> do
                        let activeConn = ConnOpenAI conn
                        runKatipContextT le ctx ns $ do
                            logFM InfoS "connected (OpenAI). prompts on stdin, frames on zmq."
                            runPromptLoop options activeConn tokenizer hotTable _boundaryTokens specialTokens publisherSocket metrics

                ProviderBaseten -> do
                    -- Baseten uses OpenAI protocol
                    let config = OpenAIConfig
                            { openaiEndpoint = resolvedEndpoint
                            , openaiAuth = authScheme
                            , openaiModel = resolvedModel
                            }
                    withOpenAIConnection config $ \conn -> do
                        let activeConn = ConnOpenAI conn
                        runKatipContextT le ctx ns $ do
                            logFM InfoS "connected (Baseten/OpenAI). prompts on stdin, frames on zmq."
                            runPromptLoop options activeConn tokenizer hotTable _boundaryTokens specialTokens publisherSocket metrics

                ProviderOpenRouter -> do
                    -- OpenRouter unified API
                    case (apiKey, resolvedModel) of
                        (Just key, Just model) -> do
                            let config = OpenRouter.defaultOpenRouterConfig key model
                            OpenRouter.withOpenRouterConnection config $ \conn -> do
                                let activeConn = ConnOpenRouter conn
                                runKatipContextT le ctx ns $ do
                                    logFM InfoS $ ls $ "connected (OpenRouter). model: " <> model
                                    runPromptLoop options activeConn tokenizer hotTable _boundaryTokens specialTokens publisherSocket metrics
                        (Nothing, _) -> do
                            runKatipContextT le ctx ns $
                                logFM ErrorS "OpenRouter requires an API key (--api-key or OPENROUTER_API_KEY)"
                            exitFailure
                        (_, Nothing) -> do
                            runKatipContextT le ctx ns $
                                logFM ErrorS "OpenRouter requires a model (--model, e.g., anthropic/claude-sonnet-4)"
                            exitFailure

                ProviderVertex -> do
                    -- Anthropic on Vertex
                    -- We need region/project, currently hardcoded or inferred?
                    -- The user provided full endpoint: https://us-east5-aiplatform...
                    -- Our provider parses it.
                    let config = VertexAnthropic.VertexAnthropicConfig
                            { VertexAnthropic.vertexEndpoint = resolvedEndpoint
                            , VertexAnthropic.vertexAuth = authScheme
                            , VertexAnthropic.vertexModel = maybe "claude-3-5-sonnet@20240620" id resolvedModel
                            , VertexAnthropic.vertexRegion = "" -- Parsed from endpoint
                            , VertexAnthropic.vertexProject = "" -- Parsed from endpoint
                            }
                    VertexAnthropic.withVertexAnthropicConnection config $ \conn -> do
                        let activeConn = ConnVertexAnthropic conn
                        runKatipContextT le ctx ns $ do
                            logFM InfoS "connected (Vertex/Anthropic). prompts on stdin, frames on zmq."
                            runPromptLoop options activeConn tokenizer hotTable _boundaryTokens specialTokens publisherSocket metrics

resolveConfig :: JackOptions -> IO (Text, FilePath, Maybe Text, Maybe FilePath, Maybe Config.AuthScheme, Config.Delimiters, Maybe ProviderType)
resolveConfig options = do
    case jackConfigPath options of
        Just path -> do
            config <- Dhall.inputFile Dhall.auto path :: IO JackConfig
            
            -- Verify tokenizer
            let tPath = T.unpack $ Config.tokenizer_path config
            -- Skip verification for identity
            unless (tPath == "identity") $ do
                tContent <- BS.readFile tPath
                let tSpecHash = Config.tokenizer $ Config.model config
                unless (verifyHash tContent tSpecHash) $ do
                    throwIO $ userError $ "Tokenizer hash verification failed for " <> tPath
            
            let providerSpec = Config.provider config
            
            -- Determine provider type from config
            let pType = case Config.providerType providerSpec of
                    Config.OpenAI -> ProviderOpenAI
                    Config.Baseten -> ProviderBaseten
                    Config.Vertex -> ProviderVertex

            pure ( Config.endpoint providerSpec
                 , tPath
                 , Config.model_override providerSpec
                 , fmap T.unpack (Config.hot_table_path config)
                 , Just (Config.auth providerSpec)
                 , Config.delimiters (Config.model config)
                 , Just pType
                 )
        Nothing -> do

            -- Fallback to CLI
            -- OpenRouter doesn't require an endpoint (it's fixed)
            let providerType = jackProvider options
            endpoint <- case jackEndpointFlag options of
                Just e -> pure e
                Nothing -> case jackEndpoint options of
                    Just e -> pure e
                    Nothing -> case providerType of
                        ProviderOpenRouter -> pure ""  -- OpenRouter has a fixed endpoint
                        _ -> throwIO $ userError "No endpoint specified (use argument, --endpoint, or --config)"
            
            tokenizer <- case jackTokenizer options of
                Just t -> pure t
                Nothing -> throwIO $ userError "No tokenizer specified (use --tokenizer or --config)"
            
            -- Default delimiters for CLI mode
            let defaults = Config.Delimiters 
                    { Config.think_start = Just "<think>"
                    , Config.think_end = Just "</think>"
                    , Config.tool_start = Just "<tool_call>"
                    , Config.tool_end = Just "</tool_call>"
                    , Config.code_fence = "```"
                    }

            pure (endpoint, tokenizer, jackModel options, jackHotTable options, Nothing, defaults, Nothing)

resolveApiKey :: JackOptions -> Maybe Config.AuthScheme -> IO (Maybe Text)
resolveApiKey options maybeAuth = do
    -- 1. CLI Override
    case jackApiKey options of
        Just providedKey -> pure (Just providedKey)
        Nothing -> do
            -- 2. Config File Strategy
            case maybeAuth of
                Just (Config.ApiKeyFile path) -> do
                    -- Read key from file (trimming whitespace)
                    content <- TIO.readFile (T.unpack path)
                    pure $ Just (T.strip content)
                _ -> do
                    -- 3. Provider-specific environment variable
                    providerKey <- case jackProvider options of
                        ProviderOpenRouter -> lookupEnv "OPENROUTER_API_KEY"
                        ProviderOpenAI -> lookupEnv "OPENAI_API_KEY"
                        ProviderVertex -> lookupEnv "VERTEX_API_KEY"
                        ProviderBaseten -> lookupEnv "BASETEN_API_KEY"
                    case providerKey of
                        Just keyFromEnv -> pure (Just $ T.pack keyFromEnv)
                        Nothing -> do
                            -- 4. Generic environment variable (Legacy/Dev)
                            environmentKey <- lookupEnv "JAYLENE_API_KEY"
                            case environmentKey of
                                Just keyFromEnv -> pure (Just $ T.pack keyFromEnv)
                                Nothing -> pure Nothing

-- ════════════════════════════════════════════════════════════════════════════
--                                                                // listen mode
-- ════════════════════════════════════════════════════════════════════════════

runListen :: (KatipContext m) => ListenOptions -> m ()
runListen options = do
    logFM InfoS $ ls $ "loading tokenizer: " <> listenTokenizer options
    tokenizer <- liftIO $ if listenTokenizer options == "identity"
        then loadIdentityTokenizer
        else loadTokenizerJSON (listenTokenizer options)

    logFM InfoS $ ls $ "connecting to: " <> listenZmqConnect options

    liftIO $ bracket context term $ \ctx ->
        bracket (socket ctx Sub) close $ \subscriberSocket -> do
            connect subscriberSocket (T.unpack $ listenZmqConnect options)
            subscribe subscriberSocket ""

            hPutStrLn stderr "[slide] [listen] waiting for frames..."
            
            -- Run stateful decoding loop
            let loop !decoderState = do
                    frameData <- receive subscriberSocket
                    
                    when (listenDumpFrames options) $ do
                        -- Ensure we start on a new line for the header
                        TIO.putStrLn ""
                        TIO.putStrLn $ "── // frame // " <> T.pack (show (BS.length frameData)) <> " bytes ──────────────────────────────────────────"
                        TIO.putStrLn $ "   " <> T.pack (foldMap (`showHex` "") (BS.unpack frameData))

                    -- Use decodeFrameIncremental to maintain state across frames
                    let (nextState, chunks) = decodeFrameIncremental decoderState frameData
                    mapM_ (printChunk tokenizer (listenShowThink options) (listenDumpFrames options)) chunks
                    hFlush stdout
                    loop nextState

            loop initDecodeState

printChunk :: HFTokenizer -> Bool -> Bool -> Chunk -> IO ()
printChunk tokenizer showThink dumpFrames (Chunk content isComplete) = do
    when dumpFrames $ do
        TIO.putStrLn $ "   [chunk] complete: " <> T.pack (show isComplete)
        TIO.putStrLn $ "   [content] " <> T.pack (show content)
        TIO.putStrLn "────────────────────────────────────────────────────────────────────────────────"

    case content of
        TextContent tokens -> do
            text <- decode tokenizer tokens
            TIO.putStr text
        ThinkContent tokens -> do
            when showThink $ do
                text <- decode tokenizer tokens
                TIO.putStr $ "\n<think>\n" <> text <> "\n</think>\n"
        ToolCallContent tokens -> do
            text <- decode tokenizer tokens
            TIO.putStr $ "\n[TOOL] " <> text <> "\n"
        CodeBlockContent tokens -> do
            text <- decode tokenizer tokens
            TIO.putStr text
        StreamEnd -> do
            TIO.putStrLn "\n[EOS]"
        DecodeError err -> do
            TIO.putStrLn $ "\n[ERROR] " <> err

-- ════════════════════════════════════════════════════════════════════════════
--                                                     // initialization helpers
-- ════════════════════════════════════════════════════════════════════════════

printBanner :: (KatipContext m) => JackOptions -> m ()
printBanner _ = do
    logFM InfoS "  ╷┌─┐┐ ┬┬  ┌─┐┌┐┐┌─┐  ┐─┐┬  o┬─┐┌─┐"
    logFM InfoS "  ││─┤└┬┘│  ├─ │││├─   └─┐│  ││ │├─ "
    logFM InfoS "╶─┘┘ ┴ ┴ ┘─┘┴─┘┘└┘┴─┘  ──┘┘─┘┘┘─┘┴─┘"
    logFM InfoS ""

    logFM InfoS "    \"I'm Slide,” the figure said, hands on its hips, “Jaylene. You don't fuck"
    logFM InfoS "     with me. Nobody in L.A.” she gestured, a window suddenly snapping into"
    logFM InfoS "     existence behind her “fucks with me. You got that?\""
    logFM InfoS ""
    logFM InfoS "                                                           — Neuromancer"
    logFM InfoS ""

    -- We print resolved endpoint later

resolveHotTable :: JackOptions -> Maybe FilePath -> IO HotTable
resolveHotTable options resolvedPath = case resolvedPath of
    Just tablePath -> loadHotTable tablePath
    Nothing -> case jackHotTable options of
        Just cliPath -> loadHotTable cliPath
        Nothing -> pure defaultHotTable

-- | Create boundary token set for semantic chunking
createBoundaryTokenSet :: HFTokenizer -> IO (VU.Vector Bool)
createBoundaryTokenSet tokenizer = do
    -- Common boundary characters
    let boundaries = ["\n", ";", "}", ")", "]"]

    -- Resolve IDs for these tokens
    boundaryIds <- mapM (tokenToId tokenizer) boundaries

    let maxId = 256 * 1024

    pure $ VU.generate maxId $ \idx ->
        let wIdx = fromIntegral idx
         in Just wIdx `elem` boundaryIds

-- | Special token configuration
data SpecialTokenConfig = SpecialTokenConfig
    { specialThinkStart :: !Word32
    , specialThinkEnd :: !Word32
    , specialToolStart :: !Word32
    , specialToolEnd :: !Word32
    , specialCodeFence :: !Word32
    }

createSpecialTokenConfig :: HFTokenizer -> Config.Delimiters -> IO SpecialTokenConfig
createSpecialTokenConfig tokenizer delimiters = do
    -- Helper to resolve token or return 0 (unk) if missing
    let resolve mText = case mText of
            Just t -> do
                mId <- tokenToId tokenizer t
                case mId of
                    Just i -> pure i
                    Nothing -> pure 0 -- Fallback to 0 if token not in vocab
            Nothing -> pure 0
            
    thinkStart <- resolve (Config.think_start delimiters)
    thinkEnd <- resolve (Config.think_end delimiters)
    toolStart <- resolve (Config.tool_start delimiters)
    toolEnd <- resolve (Config.tool_end delimiters)
    
    -- Code fence is mandatory Text in config
    fenceId <- tokenToId tokenizer (Config.code_fence delimiters)
    let codeFence = case fenceId of
            Just i -> i
            Nothing -> 0

    pure $
        SpecialTokenConfig
            { specialThinkStart = thinkStart
            , specialThinkEnd = thinkEnd
            , specialToolStart = toolStart
            , specialToolEnd = toolEnd
            , specialCodeFence = codeFence
            }

-- ════════════════════════════════════════════════════════════════════════════
--                                                        // main processing loop
-- ════════════════════════════════════════════════════════════════════════════

data ActiveConnection
    = ConnOpenAI OpenAIConnection
    | ConnOpenRouter OpenRouter.OpenRouterConnection
    | ConnVertexAnthropic VertexAnthropic.VertexAnthropicConnection

runPromptLoop ::
    (KatipContext m) =>
    JackOptions ->
    ActiveConnection ->
    HFTokenizer ->
    HotTable ->
    VU.Vector Bool ->
    SpecialTokenConfig ->
    Socket Pub ->
    Metrics ->
    m ()
runPromptLoop options connection tokenizer hotTable boundaryTokens specialTokens publisherSocket metrics =
    forever $ do
        end <- liftIO isEOF
        if end
            then do
                logFM InfoS "EOF received, exiting."
                liftIO exitFailure
            else do
                userPrompt <- liftIO TIO.getLine
                unless (T.null userPrompt) $ do
                    when (jackVerbose options) $
                        logFM InfoS $
                            ls $
                                ">> " <> T.unpack userPrompt

                    processPrompt options connection tokenizer hotTable boundaryTokens specialTokens publisherSocket metrics userPrompt

processPrompt ::
    (KatipContext m) =>
    JackOptions ->
    ActiveConnection ->
    HFTokenizer ->
    HotTable ->
    VU.Vector Bool ->
    SpecialTokenConfig ->
    Socket Pub ->
    Metrics ->
    Text ->
    m ()
processPrompt options activeConnection tokenizer hotTable boundaryTokens specialTokens publisherSocket metrics userPrompt = do
    frameBuilder <- liftIO $ newFrameBuilder (64 * 1024)

    let initialChunkState =
            initChunkState
                frameBuilder
                hotTable
                boundaryTokens
                (specialThinkStart specialTokens, specialThinkEnd specialTokens)
                (specialToolStart specialTokens, specialToolEnd specialTokens)
                (specialCodeFence specialTokens)
                (jackFlushThreshold options)

    chunkStateRef <- liftIO $ newIORef initialChunkState

    -- Generate session identifiers (random 64-bit hex strings)
    r1 <- liftIO (randomIO :: IO Word64)
    r2 <- liftIO (randomIO :: IO Word64)
    let toHex w = T.pack $ showHex w ""
        slideId = toHex r1
        httpId = toHex r2

    -- Add IDs to logging context
    katipAddContext (sl "slide_id" slideId <> sl "http_id" httpId) $ do
        logEnv <- getLogEnv
        katipCtx <- getKatipContext
        namespace <- getKatipNamespace

        let logAction :: Severity -> Text -> IO ()
            logAction sev msg = runKatipContextT logEnv katipCtx namespace $ logFM sev (ls msg)

        -- Track tool call state
        activeToolCall <- liftIO $ newIORef Nothing

        case activeConnection of
            ConnOpenAI openAIConn -> liftIO $
                streamCompletion
                    openAIConn
                    userPrompt
                    defaultStreamConfig
                    (handleStreamEvent options tokenizer chunkStateRef activeToolCall publisherSocket metrics logAction)
                    (handleStreamFinish options chunkStateRef activeToolCall publisherSocket metrics logAction)
                    (logAction DebugS)
            ConnOpenRouter openRouterConn -> liftIO $
                OpenRouter.streamCompletion
                    openRouterConn
                    userPrompt
                    defaultStreamConfig
                    (handleStreamEvent options tokenizer chunkStateRef activeToolCall publisherSocket metrics logAction)
                    (handleStreamFinish options chunkStateRef activeToolCall publisherSocket metrics logAction)
                    (logAction DebugS)
            ConnVertexAnthropic vertexConn -> liftIO $
                VertexAnthropic.streamCompletion
                    vertexConn
                    userPrompt
                    defaultStreamConfig
                    (handleStreamEvent options tokenizer chunkStateRef activeToolCall publisherSocket metrics logAction)
                    (handleStreamFinish options chunkStateRef activeToolCall publisherSocket metrics logAction)
                    (logAction DebugS)

handleStreamEvent ::
    JackOptions ->
    HFTokenizer ->
    IORef ChunkState ->
    IORef (Maybe Int) -> -- Active tool call index
    Socket Pub ->
    Metrics ->
    (Severity -> Text -> IO ()) ->
    StreamEvent ->
    IO ()
handleStreamEvent options tokenizer chunkStateRef activeToolCallRef publisherSocket metrics logger event = case event of
    EventContent contentDelta -> do
        -- If we were in a tool call, close it
        maybeActive <- readIORef activeToolCallRef
        case maybeActive of
            Just _ -> do
                -- Close tool call
                emitControlFrame publisherSocket metrics logger OP_TOOL_CALL_END
                writeIORef activeToolCallRef Nothing
            Nothing -> pure ()

        -- Handle content normally
        handleContentDelta options tokenizer chunkStateRef publisherSocket metrics logger contentDelta

    EventToolCall delta -> do
        -- Flush any pending text chunk first
        state <- readIORef chunkStateRef
        maybeFrame <- flushTextChunk state
        case maybeFrame of
            Just frame -> emitFrame publisherSocket metrics logger frame
            Nothing -> pure ()
        
        -- Check if we need to start a new tool call
        maybeActive <- readIORef activeToolCallRef
        let idx = tcIndex delta
        
        case maybeActive of
            Just activeIdx | activeIdx == idx -> pure () -- Continue
            Just _ -> do
                -- Close previous
                emitControlFrame publisherSocket metrics logger OP_TOOL_CALL_END
                emitControlFrame publisherSocket metrics logger OP_TOOL_CALL_START
                writeIORef activeToolCallRef (Just idx)
            Nothing -> do
                -- Start new
                emitControlFrame publisherSocket metrics logger OP_TOOL_CALL_START
                writeIORef activeToolCallRef (Just idx)

        -- Emit content
        -- We construct a JSON fragment for the token stream
        -- Ideally this would be robust JSON construction
        let content = buildToolCallContent delta
        unless (T.null content) $ do
             handleRawTokens options tokenizer publisherSocket metrics logger content

buildToolCallContent :: ToolCallDelta -> Text
buildToolCallContent delta =
    let namePart = case tcName delta of
            Just n -> "{\"name\": \"" <> n <> "\", \"arguments\": \""
            Nothing -> ""
        argsPart = case tcArgs delta of
            Just a -> a
            Nothing -> ""
        -- This is hacky JSON reconstruction, but matches "streaming" reality
    in namePart <> argsPart

handleContentDelta ::
    JackOptions ->
    HFTokenizer ->
    IORef ChunkState ->
    Socket Pub ->
    Metrics ->
    (Severity -> Text -> IO ()) ->
    Text ->
    IO ()
handleContentDelta options tokenizer chunkStateRef publisherSocket metrics logger contentDelta = do
    -- Log the raw delta
    when (jackVerbose options) $
        logger DebugS $
            "delta: " <> T.replace "\n" "\\n" contentDelta

    tokenIds <- encode tokenizer contentDelta
    _ <- P.addCounter (mTokensProcessed metrics) (fromIntegral $ length tokenIds)

    mapM_ (processAndEmitToken options chunkStateRef publisherSocket metrics logger) tokenIds

handleRawTokens ::
    JackOptions ->
    HFTokenizer ->
    Socket Pub ->
    Metrics ->
    (Severity -> Text -> IO ()) ->
    Text ->
    IO ()
handleRawTokens _options tokenizer publisherSocket metrics logger content = do
    -- Bypass chunk state, just emit tokens
    tokenIds <- encode tokenizer content
    _ <- P.addCounter (mTokensProcessed metrics) (fromIntegral $ length tokenIds)
    
    -- We need a temporary builder to pack these tokens into frames
    -- Since we're inside a tool call block (delimited by control frames), 
    -- we can just emit extended/hot tokens directly.
    -- BUT they need to be inside a Frame.
    
    -- Use a fresh builder for this batch
    builder <- newFrameBuilder (64 * 1024)
    -- We assume the hot table is the same... strictly we should use the one in ChunkState
    -- but for now let's just use extended tokens to be safe/simple, or pass HotTable.
    -- Actually, let's just write extended tokens for now.
    
    mapM_ (writeExtendedToken builder) tokenIds
    
    -- Finish and send
    len <- builderLength builder
    when (len > 0) $ do
        frame <- finishFrame builder
        emitFrame publisherSocket metrics logger frame

emitFrame :: Socket Pub -> Metrics -> (Severity -> Text -> IO ()) -> Frame -> IO ()
emitFrame sock metrics logger frame = do
    let bytes = frameBytes frame
        len = BS.length bytes
    
    logger DebugS $ "-> frame (" <> T.pack (show len) <> " bytes)"
    
    send sock [] bytes
    P.incCounter (mFramesEmitted metrics)
    _ <- P.addCounter (mBytesEmitted metrics) (fromIntegral len)
    pure ()

emitControlFrame :: Socket Pub -> Metrics -> (Severity -> Text -> IO ()) -> Slide.Wire.Frame.FrameOp -> IO ()
emitControlFrame sock metrics logger op = do
    builder <- newFrameBuilder 128
    writeControl builder op
    frame <- finishFrame builder
    emitFrame sock metrics logger frame

processAndEmitToken ::
    JackOptions ->
    IORef ChunkState ->
    Socket Pub ->
    Metrics ->
    (Severity -> Text -> IO ()) ->
    Word32 ->
    IO ()
processAndEmitToken options chunkStateRef publisherSocket metrics logger tokenId = do
    currentState <- readIORef chunkStateRef
    (updatedState, processingResult) <- processToken currentState tokenId
    writeIORef chunkStateRef updatedState

    case processingResult of
        ResultEmitChunk completedFrame -> do
            emitFrame publisherSocket metrics logger completedFrame
            when (jackVerbose options) $
                logger InfoS "<- chunk frame"
        ResultStateChange _controlOp -> pure ()
        ResultContinue -> pure ()

handleStreamFinish ::
    JackOptions ->
    IORef ChunkState ->
    IORef (Maybe Int) ->
    Socket Pub ->
    Metrics ->
    (Severity -> Text -> IO ()) ->
    IO ()
handleStreamFinish options chunkStateRef activeToolCallRef publisherSocket metrics logger = do
    -- Close active tool call if any
    maybeActive <- readIORef activeToolCallRef
    case maybeActive of
        Just _ -> emitControlFrame publisherSocket metrics logger OP_TOOL_CALL_END
        Nothing -> pure ()

    finalState <- readIORef chunkStateRef
    finalFrame <- finalizeChunk finalState

    emitFrame publisherSocket metrics logger finalFrame

    when (jackVerbose options) $
        logger InfoS "<- stream end"
