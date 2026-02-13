{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- | SIGIL Configuration Types

Maps strictly to the Dhall schemas in schemas/sigil/
-}
module Slide.Configuration where

import qualified BLAKE3
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as T
import Dhall (FromDhall, Generic)
import Data.Word (Word32)

-- ════════════════════════════════════════════════════════════════════════════
--                                                                    // core
-- ════════════════════════════════════════════════════════════════════════════

data HashAlgorithm
    = BLAKE3
    | SHA256
    | SHA3_256
    deriving (Generic, FromDhall, Show, Eq)

data Hash a = Hash
    { algorithm :: HashAlgorithm
    , digest :: Text
    }
    deriving (Generic, FromDhall, Show, Eq)

-- Phantom types for Hash content
data Weights
    deriving (Generic, FromDhall, Show)

data Architecture
    deriving (Generic, FromDhall, Show)

data Vocab
    deriving (Generic, FromDhall, Show)

data TestVectors
    deriving (Generic, FromDhall, Show)

data ToolFormat
    deriving (Generic, FromDhall, Show)

-- ════════════════════════════════════════════════════════════════════════════
--                                                               // tokenizer
-- ════════════════════════════════════════════════════════════════════════════

data Algorithm
    = BPE
    | Unigram
    | WordLevel
    | WordPiece
    | Identity
    deriving (Generic, FromDhall, Show, Eq)

data SpecialToken = SpecialToken
    { id :: Word32
    , text :: Text
    }
    deriving (Generic, FromDhall, Show, Eq)

data SpecialTokens = SpecialTokens
    { bos :: SpecialToken
    , eos :: SpecialToken
    , pad :: Maybe SpecialToken
    , unk :: Maybe SpecialToken
    }
    deriving (Generic, FromDhall, Show, Eq)

-- Stub types for complex nested records we don't fully validate yet
data Normalizer = Normalizer { _type :: Text }
    deriving (Generic, FromDhall, Show)

data PreTokenizer = PreTokenizer { _type :: Text }
    deriving (Generic, FromDhall, Show)

data TokenizerSpec = TokenizerSpec
    { vocab :: Hash Vocab
    , merges :: Maybe (Hash Vocab) -- reusing Vocab as placeholder for "text file"
    , normalization :: [Normalizer]
    , pre_tokenization :: PreTokenizer
    , algorithm :: Algorithm
    , special_tokens :: SpecialTokens
    , test_vectors :: Hash TestVectors
    }
    deriving (Generic, FromDhall, Show)

-- ════════════════════════════════════════════════════════════════════════════
--                                                                   // model
-- ════════════════════════════════════════════════════════════════════════════

data Delimiters = Delimiters
    { think_start :: Maybe Text
    , think_end :: Maybe Text
    , tool_start :: Maybe Text
    , tool_end :: Maybe Text
    , code_fence :: Text
    }
    deriving (Generic, FromDhall, Show, Eq)

data ModelSpec = ModelSpec
    { weights :: Hash Weights
    , architecture :: Hash Architecture
    , tokenizer :: Hash TokenizerSpec
    , vocab :: Hash Vocab
    , tool_format :: Hash ToolFormat
    , delimiters :: Delimiters
    , test_vectors :: Hash TestVectors
    }
    deriving (Generic, FromDhall, Show)

-- ════════════════════════════════════════════════════════════════════════════
--                                                                // provider
-- ════════════════════════════════════════════════════════════════════════════

data AuthScheme
    = ApiKey
    | Bearer
    | None
    | ApiKeyFile Text
    deriving (Generic, FromDhall, Show, Eq)

data ProviderType
    = OpenAI
    | Baseten
    | Vertex
    deriving (Generic, FromDhall, Show, Eq)

data ProviderSpec = ProviderSpec
    { providerType :: ProviderType
    , endpoint :: Text
    , auth :: AuthScheme
    , model_override :: Maybe Text
    , timeout_secs :: Word32
    }
    deriving (Generic, FromDhall, Show)

-- ════════════════════════════════════════════════════════════════════════════
--                                                                    // jack
-- ════════════════════════════════════════════════════════════════════════════

data JackConfig = JackConfig
    { provider :: ProviderSpec
    , model :: ModelSpec
    , tokenizer_path :: Text
    , hot_table_path :: Maybe Text
    }
    deriving (Generic, FromDhall, Show)

-- ════════════════════════════════════════════════════════════════════════════
--                                                              // verification
-- ════════════════════════════════════════════════════════════════════════════

verifyHash :: ByteString -> Hash a -> Bool
verifyHash content (Hash algo expectedDigest) =
    case algo of
        SHA256 ->
            let digest :: Digest SHA256 = hash content
                actual = T.pack $ show digest
            in actual == expectedDigest
        BLAKE3 ->
            let digest :: BLAKE3.Digest 32
                digest = BLAKE3.hash Nothing [content]
                actual = T.pack $ show digest
            in actual == expectedDigest
        -- TODO: Implement SHA3_256
        _ -> False
