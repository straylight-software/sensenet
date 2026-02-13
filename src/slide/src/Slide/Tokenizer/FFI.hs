{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}

{- | FFI bindings to tokenizers-cpp

Low-level bindings to the C wrapper around tokenizers-cpp library.
For high-level usage, see 'Slide.Tokenizer'.
-}
module Slide.Tokenizer.FFI (
    -- * Tokenizer handle
    TokenizerPtr,
    nullTokenizerPtr,

    -- * Construction / Destruction
    c_tokenizer_from_json,
    c_tokenizer_from_sentencepiece,
    c_tokenizer_free,

    -- * Encoding
    c_tokenizer_encode,
    c_tokenizer_encode_alloc,
    c_tokenizer_free_ids,

    -- * Decoding
    c_tokenizer_decode,
    c_tokenizer_decode_alloc,
    c_tokenizer_free_text,
    c_tokenizer_id_to_token,

    -- * Metadata
    c_tokenizer_vocab_size,
    c_tokenizer_token_to_id,
) where

import Foreign.C.String
import Foreign.C.Types
import Foreign.Ptr

-- | Opaque pointer to tokenizer handle
type TokenizerPtr = Ptr ()

-- | Null tokenizer pointer
nullTokenizerPtr :: TokenizerPtr
nullTokenizerPtr = nullPtr

-- ════════════════════════════════════════════════════════════════════════════════
-- Construction / Destruction
-- ════════════════════════════════════════════════════════════════════════════════

-- | Create tokenizer from HuggingFace JSON blob
foreign import capi unsafe "tokenizers_c.h tokenizer_from_json"
    c_tokenizer_from_json ::
        -- | JSON data
        CString ->
        -- | JSON length
        CSize ->
        IO TokenizerPtr

-- | Create tokenizer from SentencePiece model blob
foreign import capi unsafe "tokenizers_c.h tokenizer_from_sentencepiece"
    c_tokenizer_from_sentencepiece ::
        -- | Model data
        CString ->
        -- | Model length
        CSize ->
        IO TokenizerPtr

-- | Free tokenizer
foreign import capi unsafe "tokenizers_c.h tokenizer_free"
    c_tokenizer_free :: TokenizerPtr -> IO ()

-- ════════════════════════════════════════════════════════════════════════════════
-- Encoding
-- ════════════════════════════════════════════════════════════════════════════════

-- | Encode text to token IDs (caller-allocated buffer)
foreign import capi unsafe "tokenizers_c.h tokenizer_encode"
    c_tokenizer_encode ::
        -- | Tokenizer handle
        TokenizerPtr ->
        -- | Text to encode
        CString ->
        -- | Text length
        CSize ->
        -- | Output buffer
        Ptr CInt ->
        -- | Buffer capacity
        CSize ->
        -- | Number of tokens, or -1 on error
        IO CInt

-- | Encode text to token IDs (allocated buffer)
foreign import capi unsafe "tokenizers_c.h tokenizer_encode_alloc"
    c_tokenizer_encode_alloc ::
        -- | Tokenizer handle
        TokenizerPtr ->
        -- | Text to encode
        CString ->
        -- | Text length
        CSize ->
        -- | Output buffer pointer
        Ptr (Ptr CInt) ->
        -- | Output length
        Ptr CSize ->
        -- | 0 on success, -1 on error
        IO CInt

-- | Free token ID buffer
foreign import capi unsafe "tokenizers_c.h tokenizer_free_ids"
    c_tokenizer_free_ids :: Ptr CInt -> IO ()

-- ════════════════════════════════════════════════════════════════════════════════
-- Decoding
-- ════════════════════════════════════════════════════════════════════════════════

-- | Decode token IDs to text (caller-allocated buffer)
foreign import capi unsafe "tokenizers_c.h tokenizer_decode"
    c_tokenizer_decode ::
        -- | Tokenizer handle
        TokenizerPtr ->
        -- | Token IDs
        Ptr CInt ->
        -- | Number of tokens
        CSize ->
        -- | Output buffer
        CString ->
        -- | Buffer capacity
        CSize ->
        -- | Bytes written, or -1 on error
        IO CInt

-- | Decode token IDs to text (allocated buffer)
foreign import capi unsafe "tokenizers_c.h tokenizer_decode_alloc"
    c_tokenizer_decode_alloc ::
        -- | Tokenizer handle
        TokenizerPtr ->
        -- | Token IDs
        Ptr CInt ->
        -- | Number of tokens
        CSize ->
        -- | Output buffer pointer
        Ptr CString ->
        -- | Output length
        Ptr CSize ->
        -- | 0 on success, -1 on error
        IO CInt

-- | Free text buffer
foreign import capi unsafe "tokenizers_c.h tokenizer_free_text"
    c_tokenizer_free_text :: CString -> IO ()

-- | Decode single token ID to text
foreign import capi unsafe "tokenizers_c.h tokenizer_id_to_token"
    c_tokenizer_id_to_token ::
        -- | Tokenizer handle
        TokenizerPtr ->
        -- | Token ID
        CInt ->
        -- | Output buffer
        CString ->
        -- | Buffer capacity
        CSize ->
        -- | Bytes written, or -1 on error
        IO CInt

-- ════════════════════════════════════════════════════════════════════════════════
-- Metadata
-- ════════════════════════════════════════════════════════════════════════════════

-- | Get vocabulary size
foreign import capi unsafe "tokenizers_c.h tokenizer_vocab_size"
    c_tokenizer_vocab_size :: TokenizerPtr -> IO CSize

-- | Convert token string to ID
foreign import capi unsafe "tokenizers_c.h tokenizer_token_to_id"
    c_tokenizer_token_to_id ::
        -- | Tokenizer handle
        TokenizerPtr ->
        -- | Token string
        CString ->
        -- | Token length
        CSize ->
        -- | Token ID, or -1 if not found
        IO CInt
