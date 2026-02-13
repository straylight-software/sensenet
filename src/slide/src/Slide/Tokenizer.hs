{-# LANGUAGE OverloadedStrings #-}

{- | High-level tokenizer interface

Provides safe Haskell wrappers around the tokenizers-cpp FFI bindings.
Supports loading tokenizers from HuggingFace JSON format or SentencePiece models.

== Usage

@
-- Load a tokenizer from JSON
tok <- loadTokenizerJSON "path/to/tokenizer.json"

-- Encode text to token IDs
let ids = encode tok "Hello, world!"

-- Decode token IDs back to text
let text = decode tok ids
@

== Thread Safety

'HFTokenizer' is thread-safe for concurrent read operations (encode/decode).
Multiple threads can safely call encode/decode on the same tokenizer.
-}
module Slide.Tokenizer (
    -- * Tokenizer type
    HFTokenizer,

    -- * Loading tokenizers
    loadTokenizerJSON,
    loadIdentityTokenizer,
    loadTokenizerSentencePiece,
    loadTokenizerFromBlob,
    TokenizerFormat (..),

    -- * Encoding
    encode,
    encodeBS,

    -- * Decoding
    decode,
    decodeToken,

    -- * Metadata
    vocabSize,
    tokenToId,

    -- * Conversion to Model tokenizer
    toModelTokenizer,
) where

import Control.Exception (throwIO)
import Data.Bits ((.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BSU
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Word (Word32)
import Foreign.C.Types
import Foreign.ForeignPtr
import Foreign.Marshal.Alloc
import Foreign.Marshal.Array
import Foreign.Ptr
import Foreign.Storable

import Slide.Model qualified as Model
import Slide.Tokenizer.FFI

-- ════════════════════════════════════════════════════════════════════════════════
-- Types
-- ════════════════════════════════════════════════════════════════════════════════

{- | High-level tokenizer wrapper
-}
data HFTokenizer
    = -- | Wrapper around tokenizers-cpp FFI
      HFTokenizerFFI !(ForeignPtr ())
    | -- | Identity tokenizer (UTF-8 bytes = tokens)
      HFTokenizerIdentity

-- | Tokenizer file format
data TokenizerFormat
    = -- | HuggingFace tokenizer.json
      FormatJSON
    | -- | SentencePiece .model file
      FormatSentencePiece
    deriving stock (Show, Eq)

-- ════════════════════════════════════════════════════════════════════════════════
-- Loading
-- ════════════════════════════════════════════════════════════════════════════════

-- | Load tokenizer from HuggingFace JSON file (or "identity" pseudo-path)
loadTokenizerJSON :: FilePath -> IO HFTokenizer
loadTokenizerJSON "identity" = pure HFTokenizerIdentity
loadTokenizerJSON path = do
    blob <- BS.readFile path
    loadTokenizerFromBlob FormatJSON blob

-- | Load identity tokenizer explicitly
loadIdentityTokenizer :: IO HFTokenizer
loadIdentityTokenizer = pure HFTokenizerIdentity

-- | Load tokenizer from SentencePiece model file
loadTokenizerSentencePiece :: FilePath -> IO HFTokenizer
loadTokenizerSentencePiece path = do
    blob <- BS.readFile path
    loadTokenizerFromBlob FormatSentencePiece blob

-- | Load tokenizer from in-memory blob
loadTokenizerFromBlob :: TokenizerFormat -> ByteString -> IO HFTokenizer
loadTokenizerFromBlob format blob = do
    ptr <- BSU.unsafeUseAsCStringLen blob $ \(dataPtr, dataLen) -> do
        let len = fromIntegral dataLen
        case format of
            FormatJSON -> c_tokenizer_from_json dataPtr len
            FormatSentencePiece -> c_tokenizer_from_sentencepiece dataPtr len

    if ptr == nullPtr
        then throwIO $ userError "Failed to load tokenizer"
        else do
            foreignPtr <- newForeignPtr finalizerPtr ptr
            pure $ HFTokenizerFFI foreignPtr
  where
    finalizerPtr = castFunPtr c_tokenizer_free_ptr

-- | Get function pointer for finalizer
foreign import ccall "&tokenizer_free" c_tokenizer_free_ptr :: FunPtr (Ptr () -> IO ())

-- ════════════════════════════════════════════════════════════════════════════════
-- Encoding
-- ════════════════════════════════════════════════════════════════════════════════

-- | Encode text to token IDs
encode :: HFTokenizer -> Text -> IO [Word32]
encode HFTokenizerIdentity text = pure $ map fromIntegral (BS.unpack (TE.encodeUtf8 text))
encode tok text = encodeBS tok (TE.encodeUtf8 text)

-- | Encode UTF-8 bytes to token IDs
encodeBS :: HFTokenizer -> ByteString -> IO [Word32]
encodeBS HFTokenizerIdentity bytes = pure $ map fromIntegral (BS.unpack bytes)
encodeBS (HFTokenizerFFI fptr) textBytes =
    withForeignPtr fptr $ \ptr ->
        BSU.unsafeUseAsCStringLen textBytes $ \(textPtr, textLen) ->
            alloca $ \outIdsPtr ->
                alloca $ \outLenPtr -> do
                    result <- c_tokenizer_encode_alloc ptr textPtr (fromIntegral textLen) outIdsPtr outLenPtr
                    if result /= 0
                        then throwIO $ userError "Tokenizer encode failed"
                        else do
                            idsPtr <- peek outIdsPtr
                            len <- peek outLenPtr
                            ids <- peekArray (fromIntegral len) idsPtr
                            c_tokenizer_free_ids idsPtr
                            pure $ map (fromIntegral . (\(CInt x) -> x)) ids

-- ════════════════════════════════════════════════════════════════════════════════
-- Decoding
-- ════════════════════════════════════════════════════════════════════════════════

-- | Decode token IDs to text
decode :: HFTokenizer -> [Word32] -> IO Text
decode HFTokenizerIdentity ids =
    pure $ TE.decodeUtf8With (\_ _ -> Just '\xFFFD') (BS.pack (map (fromIntegral . (\x -> x .&. 0xFF)) ids))
decode (HFTokenizerFFI fptr) ids =
    withForeignPtr fptr $ \ptr ->
        withArrayLen (map (CInt . fromIntegral) ids) $ \len idsPtr ->
            alloca $ \outTextPtr ->
                alloca $ \outLenPtr -> do
                    result <- c_tokenizer_decode_alloc ptr idsPtr (fromIntegral len) outTextPtr outLenPtr
                    if result /= 0
                        then throwIO $ userError "Tokenizer decode failed"
                        else do
                            textPtr <- peek outTextPtr
                            textLen <- peek outLenPtr
                            text <- BS.packCStringLen (textPtr, fromIntegral textLen)
                            c_tokenizer_free_text textPtr
                            pure $ TE.decodeUtf8 text

-- | Decode single token ID to its string representation
decodeToken :: HFTokenizer -> Word32 -> IO (Maybe ByteString)
decodeToken HFTokenizerIdentity tokenId
    | tokenId < 256 = pure $ Just (BS.singleton (fromIntegral tokenId))
    | otherwise = pure Nothing
decodeToken tok@(HFTokenizerFFI fptr) tokenId = do
    size <- vocabSize tok
    if fromIntegral tokenId >= size
        then pure Nothing
        else withForeignPtr fptr $ \ptr ->
            allocaBytes 256 $ \bufPtr -> do
                result <- c_tokenizer_id_to_token ptr (CInt $ fromIntegral tokenId) bufPtr 256
                if result < 0
                    then pure Nothing
                    else do
                        bytes <- BS.packCStringLen (bufPtr, fromIntegral result)
                        pure $ Just bytes

-- ════════════════════════════════════════════════════════════════════════════════
-- Metadata
-- ════════════════════════════════════════════════════════════════════════════════

-- | Get vocabulary size
vocabSize :: HFTokenizer -> IO Int
vocabSize HFTokenizerIdentity = pure 256
vocabSize (HFTokenizerFFI fptr) =
    withForeignPtr fptr $ \ptr -> do
        size <- c_tokenizer_vocab_size ptr
        pure $ fromIntegral size

-- | Convert token string to ID
tokenToId :: HFTokenizer -> Text -> IO (Maybe Word32)
tokenToId HFTokenizerIdentity token = do
    let bytes = TE.encodeUtf8 token
    if BS.length bytes == 1
        then pure $ Just (fromIntegral (BS.head bytes))
        else pure Nothing
tokenToId (HFTokenizerFFI fptr) token =
    withForeignPtr fptr $ \ptr ->
        BSU.unsafeUseAsCStringLen (TE.encodeUtf8 token) $ \(tokenPtr, tokenLen) -> do
            result <- c_tokenizer_token_to_id ptr tokenPtr (fromIntegral tokenLen)
            if result < 0
                then pure Nothing
                else pure $ Just (fromIntegral result)

-- ════════════════════════════════════════════════════════════════════════════════
-- Model Integration
-- ════════════════════════════════════════════════════════════════════════════════

{- | Convert HFTokenizer to Model.Tokenizer interface

This allows using a loaded HFTokenizer with the Model abstraction.
The HFTokenizer is captured in the closures, keeping it alive as long
as the Model.Tokenizer is reachable.
-}
toModelTokenizer :: HFTokenizer -> ByteString -> IO Model.Tokenizer
toModelTokenizer tok hash = do
    size <- vocabSize tok
    pure
        Model.Tokenizer
            { Model.tokenizerEncode = encode tok
            , Model.tokenizerDecode = decode tok
            , Model.tokenizerDecodeOne = decodeToken tok
            , Model.tokenizerVocabSize = size
            , Model.tokenizerConfig =
                Model.TokenizerConfig
                    { Model.tokenizerModelId = "huggingface"
                    , Model.tokenizerHash = hash
                    }
            }
