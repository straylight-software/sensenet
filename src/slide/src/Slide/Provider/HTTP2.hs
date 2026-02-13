{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | HTTP/2 Client Infrastructure using http2 5.x native client API
-}
module Slide.Provider.HTTP2 (
    Http2Connection (..),
    withHttp2Connection,
    streamRequest,
    StreamResult (..),
) where

import Control.Exception (bracket, catch, throwIO, SomeException)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as C8
import Data.ByteString.Builder qualified as Builder
import Data.CaseInsensitive qualified as CI
import Data.Default.Class (def)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word8)
import Foreign.Marshal.Alloc (mallocBytes, free)
import Foreign.Ptr (Ptr)
import Network.HTTP2.Client qualified as H2
import Network.HTTP.Semantics.Client
import Network.Socket (AddrInfo (..), SocketType (..), Family (..), SockAddr (..), addrAddress, close, connect, defaultHints, getAddrInfo, socket, defaultProtocol, getPeerName, getSocketName)
import Network.TLS qualified as TLS
import Network.TLS.Extra.Cipher qualified as TLS
import System.TimeManager qualified as TM

-- | Opaque connection handle
data Http2Connection = Http2Connection
    { h2SendRequest :: !SendRequest
    , h2Host :: !Text
    , h2Authority :: !ByteString
    }

-- | Result of a streaming request
data StreamResult
    = StreamChunk !ByteString
    | StreamError !String
    | StreamEnd

-- | Establish HTTP/2 connection over TLS
-- Resolves to IPv4 only to avoid IPv6 connection issues with some providers
withHttp2Connection :: Text -> Int -> (Http2Connection -> IO a) -> IO a
withHttp2Connection host port action = do
    let hostStr = T.unpack host

    -- Resolve to IPv4 only
    addrs <- getAddrInfo (Just hints) (Just hostStr) (Just (show port))
    case addrs of
        [] -> throwIO $ userError $ "Could not resolve host: " <> hostStr
        (addr:_) -> do
            -- Create and connect socket
            bracket (socket AF_INET Stream defaultProtocol) close $ \sock -> do
                connect sock (addrAddress addr)

                -- Set up TLS
                let tlsParams = makeTlsParams hostStr
                ctx <- TLS.contextNew sock tlsParams
                TLS.handshake ctx

                -- Get socket addresses for Config
                myAddr <- getSocketName sock
                peerAddr <- getPeerName sock

                -- Create timeout manager (stopManager is deprecated/no-op, but keep bracket form)
                bracket (TM.initialize (30 * 1000000)) (const $ pure ()) $ \mgr -> do
                    -- Create http2 Config
                    bracket (allocTlsConfig ctx myAddr peerAddr mgr) freeTlsConfig $ \conf -> do
                        let clientConfig = H2.defaultClientConfig
                                { H2.scheme = "https"
                                , H2.authority = hostStr
                                }

                        -- Run the HTTP/2 client
                        H2.run clientConfig (tlsConfigH2 conf) $ \sendReq _aux -> do
                            let conn = Http2Connection
                                    { h2SendRequest = sendReq
                                    , h2Host = host
                                    , h2Authority = C8.pack hostStr
                                    }
                            action conn
  where
    hints = defaultHints { addrFamily = AF_INET, addrSocketType = Stream }

-- | Perform streaming POST request
streamRequest ::
    Http2Connection ->
    -- | Path
    ByteString ->
    -- | Extra headers
    [(ByteString, ByteString)] ->
    -- | Body
    ByteString ->
    -- | Chunk handler
    (StreamResult -> IO ()) ->
    IO ()
streamRequest Http2Connection{..} path extraHeaders body onResult = do
    let headers = map (\(k, v) -> (CI.mk k, v)) extraHeaders
        req = requestBuilder "POST" path headers (Builder.byteString body)

    h2SendRequest req handleResponse `catch` \(e :: SomeException) ->
        onResult (StreamError $ show e)
  where
    handleResponse :: Response -> IO ()
    handleResponse resp = readChunks resp

    readChunks :: Response -> IO ()
    readChunks resp = do
        (chunk, eof) <- getResponseBodyChunk' resp
        if BS.null chunk && eof
            then onResult StreamEnd
            else do
                if not (BS.null chunk)
                    then onResult (StreamChunk chunk)
                    else pure ()
                if eof
                    then onResult StreamEnd
                    else readChunks resp

-- | Config with buffer pointer for cleanup
data TlsConfig = TlsConfig
    { tlsConfigH2 :: !H2.Config
    , tlsConfigBuf :: !(Ptr Word8)
    }

-- | Allocate http2 Config from TLS context
allocTlsConfig :: TLS.Context -> SockAddr -> SockAddr -> TM.Manager -> IO TlsConfig
allocTlsConfig ctx myAddr peerAddr mgr = do
    -- Allocate write buffer (16KB is typical max frame size)
    let bufSize = 16384
    buf <- mallocBytes bufSize

    -- Create leftover ref for reading
    leftoverRef <- newIORef Nothing

    let conf = H2.Config
            { H2.confWriteBuffer = buf
            , H2.confBufferSize = bufSize
            , H2.confSendAll = TLS.sendData ctx . BS.fromStrict
            , H2.confReadN = readN ctx leftoverRef
            , H2.confPositionReadMaker = defaultPositionReadMaker
            , H2.confTimeoutManager = mgr
            , H2.confMySockAddr = myAddr
            , H2.confPeerSockAddr = peerAddr
            }

    pure TlsConfig
        { tlsConfigH2 = conf
        , tlsConfigBuf = buf
        }

-- | Free http2 Config resources
freeTlsConfig :: TlsConfig -> IO ()
freeTlsConfig TlsConfig{..} = free tlsConfigBuf

-- | Read exactly n bytes from TLS context
readN :: TLS.Context -> IORef (Maybe ByteString) -> Int -> IO ByteString
readN ctx leftoverRef n = do
    leftover <- readIORef leftoverRef
    case leftover of
        Nothing -> readLoop BS.empty n
        Just bs -> do
            writeIORef leftoverRef Nothing
            if BS.length bs >= n
                then do
                    let (result, rest) = BS.splitAt n bs
                    if BS.null rest
                        then pure result
                        else do
                            writeIORef leftoverRef (Just rest)
                            pure result
                else readLoop bs (n - BS.length bs)
  where
    readLoop acc remaining
        | remaining <= 0 = pure acc
        | otherwise = do
            chunk <- TLS.recvData ctx
            if BS.null chunk
                then pure acc  -- EOF
                else do
                    let total = acc <> chunk
                    if BS.length total >= n
                        then do
                            let (result, rest) = BS.splitAt n total
                            if BS.null rest
                                then pure result
                                else do
                                    writeIORef leftoverRef (Just rest)
                                    pure result
                        else readLoop total (n - BS.length chunk)

-- | Create TLS client parameters
makeTlsParams :: String -> TLS.ClientParams
makeTlsParams host =
    (TLS.defaultParamsClient host "")
        { TLS.clientUseServerNameIndication = True
        , TLS.clientSupported = def
            { TLS.supportedVersions = [TLS.TLS13, TLS.TLS12]
            , TLS.supportedCiphers = TLS.ciphersuite_strong
            }
        , TLS.clientHooks = def
            { TLS.onServerCertificate = \_ _ _ _ -> return []
            , TLS.onSuggestALPN = return $ Just ["h2"]
            }
        }
