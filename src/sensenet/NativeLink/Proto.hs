{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

{- |
Module      : NativeLink.Proto
Description : gRPC RPC type definitions for grapesy

Defines RawRpc type aliases for the Remote Execution API and ByteStream
services. These work with grapesy for gRPC client/server communication.
-}
module NativeLink.Proto (
    -- * ByteStream RPCs
    ByteStreamRead,
    ByteStreamWrite,

    -- * CAS RPCs
    CASFindMissingBlobs,
    CASBatchUpdateBlobs,
    CASBatchReadBlobs,

    -- * Execution RPCs
    ExecutionExecute,
    ExecutionWaitExecution,

    -- * ActionCache RPCs
    ActionCacheGetActionResult,
    ActionCacheUpdateActionResult,

    -- * Capabilities RPCs
    CapabilitiesGetCapabilities,
) where

import Network.GRPC.Common (NoMetadata)
import Network.GRPC.Spec (
    RawRpc,
    RequestMetadata,
    ResponseInitialMetadata,
    ResponseTrailingMetadata,
 )

-- | ByteStream.Read: Server-streaming RPC
type ByteStreamRead =
    RawRpc
        "google.bytestream.ByteStream"
        "Read"

-- | ByteStream.Write: Client-streaming RPC
type ByteStreamWrite =
    RawRpc
        "google.bytestream.ByteStream"
        "Write"

-- | CAS.FindMissingBlobs: Non-streaming RPC
type CASFindMissingBlobs =
    RawRpc
        "build.bazel.remote.execution.v2.ContentAddressableStorage"
        "FindMissingBlobs"

-- | CAS.BatchUpdateBlobs: Non-streaming RPC
type CASBatchUpdateBlobs =
    RawRpc
        "build.bazel.remote.execution.v2.ContentAddressableStorage"
        "BatchUpdateBlobs"

-- gRPC Metadata type instances
type instance RequestMetadata ByteStreamRead = NoMetadata
type instance ResponseInitialMetadata ByteStreamRead = NoMetadata
type instance ResponseTrailingMetadata ByteStreamRead = NoMetadata

type instance RequestMetadata ByteStreamWrite = NoMetadata
type instance ResponseInitialMetadata ByteStreamWrite = NoMetadata
type instance ResponseTrailingMetadata ByteStreamWrite = NoMetadata

type instance RequestMetadata CASFindMissingBlobs = NoMetadata
type instance ResponseInitialMetadata CASFindMissingBlobs = NoMetadata
type instance ResponseTrailingMetadata CASFindMissingBlobs = NoMetadata

type instance RequestMetadata CASBatchUpdateBlobs = NoMetadata
type instance ResponseInitialMetadata CASBatchUpdateBlobs = NoMetadata
type instance ResponseTrailingMetadata CASBatchUpdateBlobs = NoMetadata

-- | CAS.BatchReadBlobs: Non-streaming RPC
type CASBatchReadBlobs =
    RawRpc
        "build.bazel.remote.execution.v2.ContentAddressableStorage"
        "BatchReadBlobs"

type instance RequestMetadata CASBatchReadBlobs = NoMetadata
type instance ResponseInitialMetadata CASBatchReadBlobs = NoMetadata
type instance ResponseTrailingMetadata CASBatchReadBlobs = NoMetadata

-- | Execution.Execute: Server-streaming RPC (returns stream of Operations)
type ExecutionExecute =
    RawRpc
        "build.bazel.remote.execution.v2.Execution"
        "Execute"

type instance RequestMetadata ExecutionExecute = NoMetadata
type instance ResponseInitialMetadata ExecutionExecute = NoMetadata
type instance ResponseTrailingMetadata ExecutionExecute = NoMetadata

-- | Execution.WaitExecution: Server-streaming RPC (returns stream of Operations)
type ExecutionWaitExecution =
    RawRpc
        "build.bazel.remote.execution.v2.Execution"
        "WaitExecution"

type instance RequestMetadata ExecutionWaitExecution = NoMetadata
type instance ResponseInitialMetadata ExecutionWaitExecution = NoMetadata
type instance ResponseTrailingMetadata ExecutionWaitExecution = NoMetadata

-- | ActionCache.GetActionResult: Non-streaming RPC
type ActionCacheGetActionResult =
    RawRpc
        "build.bazel.remote.execution.v2.ActionCache"
        "GetActionResult"

type instance RequestMetadata ActionCacheGetActionResult = NoMetadata
type instance ResponseInitialMetadata ActionCacheGetActionResult = NoMetadata
type instance ResponseTrailingMetadata ActionCacheGetActionResult = NoMetadata

-- | ActionCache.UpdateActionResult: Non-streaming RPC
type ActionCacheUpdateActionResult =
    RawRpc
        "build.bazel.remote.execution.v2.ActionCache"
        "UpdateActionResult"

type instance RequestMetadata ActionCacheUpdateActionResult = NoMetadata
type instance ResponseInitialMetadata ActionCacheUpdateActionResult = NoMetadata
type instance ResponseTrailingMetadata ActionCacheUpdateActionResult = NoMetadata

-- | Capabilities.GetCapabilities: Non-streaming RPC
type CapabilitiesGetCapabilities =
    RawRpc
        "build.bazel.remote.execution.v2.Capabilities"
        "GetCapabilities"

type instance RequestMetadata CapabilitiesGetCapabilities = NoMetadata
type instance ResponseInitialMetadata CapabilitiesGetCapabilities = NoMetadata
type instance ResponseTrailingMetadata CapabilitiesGetCapabilities = NoMetadata
