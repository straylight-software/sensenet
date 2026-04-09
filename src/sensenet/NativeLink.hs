{- |
Module      : NativeLink
Description : NativeLink CAS and Remote Execution client library

Haskell client for NativeLink / Remote Execution API.
Provides access to ByteStream, ContentAddressableStorage, and Execution services.

Example usage:

@
import NativeLink

main :: IO ()
main = do
    let config = CASConfig
            { casHost = "cas.example.com"
            , casPort = 443
            , casUseTLS = True
            , casInstanceName = "main"
            }
    withCASClient config $ \\client -> do
        -- Upload a blob
        digest <- uploadBlob client "hello world"
        print digest

        -- Check existence
        exists <- blobExists client digest
        print exists

        -- Download
        content <- downloadBlob client digest
        print content
@
-}
module NativeLink (
    -- * Client
    module NativeLink.Client,

    -- * Execution
    module NativeLink.Execution,

    -- * Proto types
    module NativeLink.Proto,
) where

import NativeLink.Client
import NativeLink.Execution
import NativeLink.Proto
