# sensenet v0.5 Roadmap: Distributed Build System

## Executive Summary

sensenet v0.5 transforms from a local build system into a fully distributed, coeffect-tracked build system where:

1. **Any machine can be a builder** - Workers are just `nix run .#sensenet-worker`
1. **Builds are cryptographically verified** - DischargeProofs attest that coeffects were satisfied
1. **Toolchains are byte-for-byte identical** - Same Nix closure on client and worker
1. **Zero configuration remote execution** - Workers auto-discover from flake, no YAML/TOML

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              DEVELOPER MACHINE                               │
│                                                                             │
│   BUILD.dhall ──> sensenet build //pkg:target ──> RE API v2 ──> Results    │
│                         │                              │                    │
│                         │ (local fallback)             │ (preferred)        │
│                         ▼                              ▼                    │
│                   sensenet-out/              ┌─────────────────────┐        │
│                                              │   CAS (R2/S3/local) │        │
│                                              └─────────────────────┘        │
└─────────────────────────────────────────────────────────────────────────────┘
                                                         │
                    ┌────────────────────────────────────┼────────────────────┐
                    │                                    │                    │
                    ▼                                    ▼                    ▼
          ┌─────────────────┐                ┌─────────────────┐    ┌─────────────────┐
          │  Worker (Fly)   │                │  Worker (local) │    │  Worker (k8s)   │
          │                 │                │                 │    │                 │
          │  Same Nix       │                │  Same Nix       │    │  Same Nix       │
          │  closure as     │                │  closure as     │    │  closure as     │
          │  client         │                │  client         │    │  client         │
          └─────────────────┘                └─────────────────┘    └─────────────────┘
```

## Current State vs Target State

| Component | v0.4 (Current) | v0.5 (Target) |
|-----------|----------------|---------------|
| Build execution | Haskell DICE (local only) | Haskell DICE + gRPC RE client |
| Remote execution | Buck2 shim (if enabled) | Native RE API v2 in Haskell |
| Workers | External NativeLink | `nix run .#sensenet-worker` |
| CAS | None (local files) | Native Haskell CAS client |
| Toolchain sync | Manual .buckconfig.local | Automatic from flake closure |
| Coeffect tracking | `aCoeffects :: [Text]` | `Resource` algebra + proofs |
| Container images | Manual Dockerfile | `nix build .#worker-image` |

## New Components

### 1. sensenet-worker

A Haskell daemon that executes build actions in sandboxed environments.

**Responsibilities**:

- Register with scheduler and advertise capabilities
- Fetch inputs from CAS
- Execute commands in Linux namespace sandbox
- Bind-mount Nix toolchain closure
- Track coeffects (network, filesystem, auth)
- Upload outputs to CAS
- Generate signed DischargeProofs

**Location**: `src/sensenet-worker/`

### 2. sensenet-scheduler

A Haskell service that routes actions to appropriate workers.

**Responsibilities**:

- Implement RE API v2 Execute/WaitExecution
- Match platform requirements to worker capabilities
- Manage action queue with priorities
- Track worker health via heartbeats
- Handle worker failures and retries

**Location**: `src/sensenet-scheduler/`

### 3. sensenet-cas

A Haskell CAS (Content-Addressable Storage) service.

**Responsibilities**:

- Implement RE API v2 ByteStream and ContentAddressableStorage
- Pluggable storage backends (memory, filesystem, S3/R2, Nix store)
- Deduplication across all builds
- Garbage collection of orphaned blobs

**Location**: `src/sensenet-cas/`

### 4. Remote Client (in sensenet CLI)

Native gRPC client for remote execution.

**Location**: `src/sensenet/SenseNet/Remote/`

## Directory Structure

```
sensenet/
├── src/
│   ├── sensenet/                    # CLI + local build (existing)
│   │   ├── Main.hs
│   │   ├── SenseNet/
│   │   │   ├── IR.hs               # Internal representation
│   │   │   ├── Dhall.hs            # Parser
│   │   │   ├── Build.hs            # Local execution
│   │   │   ├── DICE.hs             # Incremental computation
│   │   │   ├── Coeffect.hs         # NEW: Resource algebra
│   │   │   ├── Remote/             # NEW: RE API v2 client
│   │   │   │   ├── Client.hs       # gRPC client setup
│   │   │   │   ├── CAS.hs          # Content-addressable storage
│   │   │   │   ├── Execution.hs    # Action execution
│   │   │   │   └── Proto.hs        # proto-lens generated types
│   │   │   └── Attestation.hs      # NEW: DischargeProof generation
│   │   └── DhallFast/              # Optimized evaluator
│   │
│   ├── sensenet-worker/             # NEW: Worker daemon
│   │   ├── Main.hs                 # Entry point
│   │   ├── Worker/
│   │   │   ├── Server.hs           # gRPC server (RE API v2)
│   │   │   ├── Executor.hs         # Sandbox execution
│   │   │   ├── Sandbox.hs          # Linux namespace management
│   │   │   ├── CAS.hs              # Local CAS client
│   │   │   └── Attestation.hs      # Proof generation
│   │   ├── sensenet-worker.cabal
│   │   └── BUILD.dhall
│   │
│   ├── sensenet-scheduler/          # NEW: Scheduler service
│   │   ├── Main.hs
│   │   ├── Scheduler/
│   │   │   ├── Server.hs           # gRPC server
│   │   │   ├── Queue.hs            # Action queue
│   │   │   ├── Matcher.hs          # Worker selection
│   │   │   ├── Workers.hs          # Worker registry
│   │   │   └── Platform.hs         # Platform matching
│   │   ├── sensenet-scheduler.cabal
│   │   └── BUILD.dhall
│   │
│   ├── sensenet-cas/                # NEW: CAS service
│   │   ├── Main.hs
│   │   ├── CAS/
│   │   │   ├── Server.hs           # gRPC + HTTP server
│   │   │   ├── Storage.hs          # Backend abstraction
│   │   │   ├── Backends/
│   │   │   │   ├── Memory.hs       # In-memory (testing)
│   │   │   │   ├── Filesystem.hs   # Local disk
│   │   │   │   ├── S3.hs           # S3/R2 compatible
│   │   │   │   └── NixStore.hs     # Nix store as CAS
│   │   │   └── GC.hs               # Garbage collection
│   │   ├── sensenet-cas.cabal
│   │   └── BUILD.dhall
│   │
│   └── nix-analyze/                 # Existing
│
├── dhall/
│   ├── prelude/                     # Simple types (existing)
│   ├── Resource.dhall               # Coeffect algebra (integrate)
│   ├── DischargeProof.dhall         # Attestations (integrate)
│   ├── Triple.dhall                 # Target triples (integrate)
│   ├── CFlags.dhall                 # Typed flags (integrate)
│   ├── LDFlags.dhall                # Typed linker flags (integrate)
│   └── Remote.dhall                 # NEW: Remote execution config
│
├── proto/                           # NEW: RE API v2 protos
│   ├── build/bazel/remote/
│   │   └── execution/v2/
│   │       └── remote_execution.proto
│   ├── google/
│   │   ├── bytestream/
│   │   │   └── bytestream.proto
│   │   └── longrunning/
│   │       └── operations.proto
│   └── sensenet/
│       └── attestation.proto        # NEW: DischargeProof proto
│
├── nix/
│   ├── modules/flake/
│   │   ├── sensenet/               # Build system module
│   │   ├── worker/                 # NEW: Worker module
│   │   │   ├── default.nix
│   │   │   └── container.nix
│   │   ├── scheduler/              # NEW: Scheduler module
│   │   │   └── default.nix
│   │   └── cas/                    # NEW: CAS module
│   │       └── default.nix
│   │
│   └── packages/
│       ├── sensenet.nix
│       ├── sensenet-worker.nix      # NEW
│       ├── sensenet-scheduler.nix   # NEW
│       ├── sensenet-cas.nix         # NEW
│       └── worker-image.nix         # NEW: OCI container
│
└── deploy/                          # NEW: Deployment configs
    ├── fly/
    │   ├── worker.toml
    │   ├── scheduler.toml
    │   └── cas.toml
    └── k8s/
        ├── worker.yaml
        ├── scheduler.yaml
        └── cas.yaml
```

## Data Flow

### Build Request Flow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            CLIENT (sensenet build)                          │
│                                                                             │
│  1. Parse BUILD.dhall → IR.Package                                          │
│  2. Build ActionGraph with DICE                                             │
│  3. For each Action:                                                        │
│     a. Compute ActionKey (BLAKE3)                                           │
│     b. Check local cache → hit? done                                        │
│     c. Check remote CAS for outputs → hit? download, done                   │
│     d. Upload inputs to CAS                                                 │
│     e. Submit to Scheduler via Execute RPC                                  │
│     f. Wait for completion via WaitExecution RPC                            │
│     g. Download outputs from CAS                                            │
│     h. Verify DischargeProof                                                │
│     i. Store in local cache                                                 │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ gRPC (RE API v2)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                 SCHEDULER                                    │
│                                                                             │
│  1. Receive Execute request with Action + Platform requirements             │
│  2. Match platform requirements to available workers                        │
│  3. Queue action for matched worker (priority-based)                        │
│  4. Dispatch to worker when available                                       │
│  5. Track execution state (queued → executing → complete/failed)            │
│  6. Return Operation with result when complete                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ gRPC (internal protocol)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                  WORKER                                      │
│                                                                             │
│  1. Receive action from scheduler                                           │
│  2. Verify Nix toolchain closure is available (fetch if needed)             │
│  3. Fetch inputs from CAS → materialize to sandbox                          │
│  4. Create Linux namespace sandbox                                          │
│  5. Bind-mount Nix toolchain into sandbox                                   │
│  6. Execute command with coeffect tracking:                                 │
│     - Network proxy records all connections                                 │
│     - Filesystem audit records all file access                              │
│     - Auth usage is tracked                                                 │
│  7. Collect outputs from sandbox                                            │
│  8. Upload outputs to CAS                                                   │
│  9. Generate DischargeProof with coeffect evidence                          │
│  10. Sign proof with worker's Ed25519 key                                   │
│  11. Return result with attestation to scheduler                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ gRPC/HTTP (ByteStream API)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                                    CAS                                       │
│                                                                             │
│  Content-Addressable Storage:                                               │
│  - BLAKE3 hashing (faster than SHA256)                                      │
│  - Pluggable backends:                                                      │
│    • Memory (testing)                                                       │
│    • Filesystem (local dev)                                                 │
│    • S3/R2 (production)                                                     │
│    • Nix store (hermetic, already content-addressed!)                       │
│  - Deduplication across all builds                                          │
│  - Optional encryption at rest                                              │
│  - Configurable TTL and garbage collection                                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Implementation Plan

### Phase 1: Native CAS Client (Week 1-2)

**Goal**: Replace any Buck2/NativeLink dependency for CAS operations.

#### Module: `SenseNet.Remote.CAS`

```haskell
module SenseNet.Remote.CAS
  ( CASClient
  , newCASClient
  , uploadBlob
  , downloadBlob
  , uploadDirectory
  , downloadDirectory
  , findMissingBlobs
  ) where

data CASClient = CASClient
  { casChannel  :: GrpcClient
  , casInstance :: Text
  , casTimeout  :: Int  -- milliseconds
  }

-- | Create a new CAS client
newCASClient :: CASConfig -> IO CASClient

-- | Upload a blob, return its digest
-- Uses BatchUpdateBlobs for small blobs, ByteStream.Write for large
uploadBlob :: CASClient -> ByteString -> IO Digest

-- | Download a blob by digest
-- Uses BatchReadBlobs for small, ByteStream.Read for large
downloadBlob :: CASClient -> Digest -> IO ByteString

-- | Upload a directory tree recursively, return root digest
uploadDirectory :: CASClient -> FilePath -> IO Digest

-- | Download and materialize a directory tree
downloadDirectory :: CASClient -> Digest -> FilePath -> IO ()

-- | Find which blobs from a list are missing in CAS
findMissingBlobs :: CASClient -> [Digest] -> IO [Digest]
```

#### Deliverables

- [ ] `SenseNet.Remote.CAS` module with ByteStream client
- [ ] `SenseNet.Remote.Proto` with proto-lens bindings for RE API v2
- [ ] BLAKE3 hashing (via `blake3` package or FFI)
- [ ] Integration with `Build.hs` for remote cache checks
- [ ] CLI flag: `sensenet build --remote-cache <url>`
- [ ] Tests against local CAS server

### Phase 2: Native RE Client (Week 2-3)

**Goal**: Execute actions on remote workers via RE API v2.

#### Module: `SenseNet.Remote.Execution`

```haskell
module SenseNet.Remote.Execution
  ( ExecutionClient
  , newExecutionClient
  , executeAction
  , waitOperation
  , cancelOperation
  ) where

data ExecutionClient = ExecutionClient
  { execChannel  :: GrpcClient
  , execInstance :: Text
  , execTimeout  :: Int
  }

-- | Execute an action remotely
-- Uploads inputs, submits action, waits for result, downloads outputs
executeAction :: ExecutionClient -> CASClient -> Action -> IO ActionResult
executeAction exec cas action = do
  -- 1. Upload input tree to CAS
  inputRoot <- uploadActionInputs cas action
  
  -- 2. Create Command proto
  let command = Proto.Command
        { arguments = action.aCommand
        , environmentVariables = toEnvVars action.aEnv
        , outputPaths = action.aOutputs
        , workingDirectory = ""
        , ...
        }
  commandDigest <- uploadBlob cas (encodeMessage command)
  
  -- 3. Create Action proto
  let reAction = Proto.Action
        { commandDigest = commandDigest
        , inputRootDigest = inputRoot
        , timeout = Nothing
        , doNotCache = False
        , ...
        }
  actionDigest <- uploadBlob cas (encodeMessage reAction)
  
  -- 4. Submit to execution service
  let request = ExecuteRequest
        { instanceName = execInstance
        , actionDigest = actionDigest
        , skipCacheLookup = False
        , ...
        }
  operation <- execute exec request
  
  -- 5. Wait for completion
  result <- waitOperation exec operation.name
  
  -- 6. Download outputs
  outputs <- downloadActionOutputs cas result
  
  -- 7. Extract and verify attestation
  attestation <- extractAttestation result
  
  pure ActionResult
    { arOutputs = outputs
    , arExitCode = result.exitCode
    , arAttestation = attestation
    , ...
    }
```

#### Deliverables

- [ ] `SenseNet.Remote.Execution` module
- [ ] Action → RE Action/Command conversion
- [ ] Long-polling for operation completion
- [ ] Streaming output support (optional)
- [ ] CLI flag: `sensenet build --remote` uses native client
- [ ] Integration tests with NativeLink

### Phase 3: Haskell Worker (Week 3-4)

**Goal**: A worker daemon that executes actions in sandboxed environments.

#### Binary: `sensenet-worker`

```haskell
-- src/sensenet-worker/Main.hs

module Main where

main :: IO ()
main = do
  config <- parseConfig
  
  -- Load worker's Ed25519 signing key
  signingKey <- loadOrGenerateKey config.keyPath
  
  -- Connect to CAS
  cas <- newCASClient config.casEndpoint
  
  -- Start worker server
  runWorker config cas signingKey
```

#### Module: `Worker.Server`

```haskell
module Worker.Server
  ( WorkerConfig(..)
  , runWorker
  ) where

data WorkerConfig = WorkerConfig
  { wcSchedulerEndpoint :: Text
  , wcCASEndpoint :: Text
  , wcCapabilities :: Platform
  , wcSandboxType :: SandboxType
  , wcToolchainClosure :: Maybe StorePath
  , wcKeyPath :: FilePath
  , wcWorkDir :: FilePath
  }

data SandboxType
  = SandboxNone           -- No isolation (testing only)
  | SandboxNamespace      -- Linux user namespaces
  | SandboxDocker         -- Docker container
  | SandboxNixSandbox     -- nix-sandbox style

runWorker :: WorkerConfig -> CASClient -> Ed25519.SecretKey -> IO ()
runWorker config cas signingKey = do
  -- 1. Register with scheduler
  workerId <- registerWithScheduler config
  
  -- 2. Start heartbeat thread
  async $ heartbeatLoop config workerId
  
  -- 3. Main work loop
  forever $ do
    -- Poll for action
    action <- pollForAction config workerId
    
    -- Execute in sandbox
    result <- executeInSandbox config cas signingKey action
    
    -- Report result
    reportResult config workerId action result
```

#### Module: `Worker.Executor`

```haskell
module Worker.Executor
  ( executeInSandbox
  ) where

executeInSandbox 
  :: WorkerConfig 
  -> CASClient 
  -> Ed25519.SecretKey
  -> REAction 
  -> IO REActionResult
executeInSandbox config cas signingKey action = do
  -- 1. Create workspace directory
  withTempDirectory config.wcWorkDir "action-" $ \workspace -> do
    
    -- 2. Materialize inputs from CAS
    downloadDirectory cas action.inputRootDigest (workspace </> "input")
    
    -- 3. Verify/fetch Nix toolchain closure
    toolchainPath <- ensureToolchainClosure cas action.platformProperties
    
    -- 4. Create sandbox
    withSandbox config.wcSandboxType workspace $ \sandbox -> do
      
      -- 5. Bind-mount toolchain
      mountReadOnly sandbox toolchainPath "/nix/store"
      
      -- 6. Execute with coeffect tracking
      (exitCode, stdout, stderr, evidence) <- 
        withCoeffectTracking sandbox $ do
          runCommand sandbox
            (workspace </> "input")
            action.command
            action.environmentVariables
      
      -- 7. Collect outputs
      outputs <- collectOutputs sandbox action.outputPaths
      
      -- 8. Upload outputs to CAS
      outputDigests <- forM outputs $ \(path, content) -> do
        digest <- uploadBlob cas content
        pure (path, digest)
      
      -- 9. Generate and sign discharge proof
      proof <- generateDischargeProof
        action
        evidence
        outputDigests
        signingKey
      
      pure REActionResult
        { exitCode = exitCode
        , stdoutDigest = ...
        , stderrDigest = ...
        , outputFiles = outputDigests
        , attestation = proof
        }
```

#### Deliverables

- [ ] `sensenet-worker` binary
- [ ] Linux user namespace sandbox (`Worker.Sandbox`)
- [ ] Nix toolchain closure bind-mounting
- [ ] Basic coeffect tracking (timing, memory, exit code)
- [ ] DischargeProof generation
- [ ] Ed25519 signing
- [ ] `nix run .#sensenet-worker`
- [ ] `nix build .#sensenet-worker`

### Phase 4: Haskell Scheduler (Week 4-5)

**Goal**: Route actions to appropriate workers.

#### Binary: `sensenet-scheduler`

```haskell
-- src/sensenet-scheduler/Main.hs

module Main where

main :: IO ()
main = do
  config <- parseConfig
  state <- initSchedulerState
  
  -- Start gRPC server
  runGrpcServer config.port
    [ executeHandler state
    , waitExecutionHandler state
    , getOperationHandler state
    ]
```

#### Module: `Scheduler.Server`

```haskell
module Scheduler.Server
  ( SchedulerState
  , initSchedulerState
  , executeHandler
  , waitExecutionHandler
  ) where

data SchedulerState = SchedulerState
  { ssWorkers :: TVar (Map WorkerId WorkerInfo)
  , ssQueue :: TBQueue QueuedAction
  , ssPending :: TVar (Map OperationName PendingOp)
  , ssCompleted :: TVar (Map OperationName CompletedOp)
  }

data WorkerInfo = WorkerInfo
  { wiId :: WorkerId
  , wiCapabilities :: Platform
  , wiChannel :: GrpcClient
  , wiActiveActions :: Int
  , wiMaxActions :: Int
  , wiLastHeartbeat :: UTCTime
  }

data QueuedAction = QueuedAction
  { qaOperation :: OperationName
  , qaAction :: REAction
  , qaPriority :: Int
  , qaQueuedAt :: UTCTime
  }

-- RE API v2: Execute
executeHandler :: SchedulerState -> ExecuteRequest -> IO Operation
executeHandler state req = do
  -- 1. Generate operation name
  opName <- generateOperationName
  
  -- 2. Find matching workers
  workers <- atomically $ readTVar (ssWorkers state)
  let matching = filterByPlatform req.actionDigest workers
  
  when (null matching) $
    throwIO $ NoMatchingWorkers req.executionRequirements
  
  -- 3. Create pending operation
  let pending = PendingOp
        { poName = opName
        , poAction = req.actionDigest
        , poState = Queued
        , poCreatedAt = now
        }
  
  atomically $ do
    modifyTVar' (ssPending state) (Map.insert opName pending)
    writeTBQueue (ssQueue state) QueuedAction
      { qaOperation = opName
      , qaAction = req.actionDigest
      , qaPriority = extractPriority req
      , qaQueuedAt = now
      }
  
  -- 4. Return operation (client will poll)
  pure Operation
    { name = opName
    , done = False
    , metadata = Just $ ExecuteOperationMetadata
        { stage = QUEUED
        , actionDigest = req.actionDigest
        }
    }

-- RE API v2: WaitExecution (long-poll)
waitExecutionHandler :: SchedulerState -> WaitExecutionRequest -> IO Operation
waitExecutionHandler state req = do
  -- Block until operation completes or timeout
  result <- atomically $ do
    pending <- readTVar (ssPending state)
    completed <- readTVar (ssCompleted state)
    
    case Map.lookup req.name completed of
      Just op -> pure (Right op)
      Nothing -> case Map.lookup req.name pending of
        Just _ -> retry  -- STM retry, will wake when state changes
        Nothing -> pure (Left OperationNotFound)
  
  case result of
    Right completed -> pure $ operationFromCompleted completed
    Left err -> throwIO err
```

#### Module: `Scheduler.Matcher`

```haskell
module Scheduler.Matcher
  ( matchWorker
  , filterByPlatform
  ) where

-- | Find best worker for an action based on platform requirements
matchWorker :: [WorkerInfo] -> Platform -> Maybe WorkerInfo
matchWorker workers required =
  -- Sort by: availability, then locality, then load
  listToMaybe
    $ sortOn workerScore
    $ filter (platformMatches required . wiCapabilities)
    $ workers

-- | Check if worker capabilities satisfy requirements
platformMatches :: Platform -> Platform -> Bool
platformMatches required offered =
  all (propertyMatches offered) (platformProperties required)

propertyMatches :: Platform -> (Text, Text) -> Bool
propertyMatches platform (key, value) =
  case lookup key (platformProperties platform) of
    Just v -> v == value || isWildcard value
    Nothing -> False
```

#### Deliverables

- [ ] `sensenet-scheduler` binary
- [ ] RE API v2 Execute/WaitExecution/GetOperation handlers
- [ ] Worker registration and heartbeat protocol
- [ ] Platform matching algorithm
- [ ] Priority queue for actions
- [ ] Operation state tracking
- [ ] `nix run .#sensenet-scheduler`

### Phase 5: Container Images (Week 5-6)

**Goal**: One-command worker deployment anywhere.

#### Nix Package: `worker-image.nix`

```nix
# nix/packages/worker-image.nix

{ pkgs
, sensenet-worker
, toolchainClosure
}:

pkgs.dockerTools.buildLayeredImage {
  name = "ghcr.io/straylight-software/sensenet-worker";
  tag = "latest";
  
  # Layer 1: Base system
  contents = [
    pkgs.coreutils
    pkgs.bash
    pkgs.cacert
  ];
  
  # Layer 2: Sensenet worker
  extraCommands = ''
    mkdir -p opt/sensenet
    cp -r ${sensenet-worker}/bin opt/sensenet/
  '';
  
  # Layer 3: Toolchain (largest, changes least often)
  # This is bind-mounted at runtime, not baked in
  
  config = {
    Entrypoint = [ "/opt/sensenet/bin/sensenet-worker" ];
    
    Env = [
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "SENSENET_SANDBOX=namespace"
    ];
    
    ExposedPorts = {
      "50051/tcp" = {};  # gRPC
      "8080/tcp" = {};   # Health check
    };
    
    Labels = {
      "org.opencontainers.image.source" = "https://github.com/straylight-software/sensenet";
      "org.opencontainers.image.description" = "sensenet build worker";
    };
  };
  
  # Maximize layer sharing
  maxLayers = 100;
}
```

#### Fly.io Deployment: `deploy/fly/worker.toml`

```toml
# deploy/fly/worker.toml

app = "sensenet-worker"
primary_region = "iad"

[build]
image = "ghcr.io/straylight-software/sensenet-worker:latest"

[env]
SENSENET_SCHEDULER = "sensenet-scheduler.fly.dev:443"
SENSENET_CAS = "sensenet-cas.fly.dev:443"
SENSENET_SANDBOX = "namespace"

[http_service]
internal_port = 8080
force_https = true

[[services]]
internal_port = 50051
protocol = "tcp"

[[services.ports]]
port = 443
handlers = ["tls"]

[mounts]
source = "nix_store"
destination = "/nix/store"

[[vm]]
cpu_kind = "shared"
cpus = 4
memory_mb = 8192
```

#### Kubernetes Deployment: `deploy/k8s/worker.yaml`

```yaml
# deploy/k8s/worker.yaml

apiVersion: apps/v1
kind: Deployment
metadata:
  name: sensenet-worker
spec:
  replicas: 3
  selector:
    matchLabels:
      app: sensenet-worker
  template:
    metadata:
      labels:
        app: sensenet-worker
    spec:
      containers:
      - name: worker
        image: ghcr.io/straylight-software/sensenet-worker:latest
        ports:
        - containerPort: 50051
          name: grpc
        - containerPort: 8080
          name: health
        env:
        - name: SENSENET_SCHEDULER
          value: "sensenet-scheduler:443"
        - name: SENSENET_CAS
          value: "sensenet-cas:443"
        resources:
          requests:
            cpu: "2"
            memory: "4Gi"
          limits:
            cpu: "4"
            memory: "8Gi"
        securityContext:
          privileged: true  # Required for namespaces
        volumeMounts:
        - name: nix-store
          mountPath: /nix/store
          readOnly: true
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
      volumes:
      - name: nix-store
        persistentVolumeClaim:
          claimName: nix-store-pvc
```

#### Deliverables

- [ ] `nix build .#worker-image` produces OCI image
- [ ] `nix build .#scheduler-image` produces OCI image
- [ ] `nix build .#cas-image` produces OCI image
- [ ] Fly.io deployment configs and scripts
- [ ] Kubernetes manifests
- [ ] GitHub Actions workflow for image building/pushing
- [ ] Toolchain closure synchronization mechanism

### Phase 6: Coeffect Integration (Week 6-7)

**Goal**: Full coeffect tracking with cryptographic proofs.

#### Module: `SenseNet.Coeffect`

```haskell
module SenseNet.Coeffect
  ( -- Types (from Resource.dhall)
    Resource(..)
  , Resources
    -- Inference
  , ruleCoeffects
  , actionCoeffects
    -- Combination
  , combine
  , tensor
    -- Predicates
  , isPure
  , requiresNetwork
  ) where

-- | Typed coeffects (mirrors dhall/Resource.dhall)
data Resource
  = Pure                    -- Needs nothing external
  | Network                 -- Needs network access
  | Auth Text               -- Needs credential (provider name)
  | Sandbox Text            -- Needs specific sandbox type
  | Filesystem Text         -- Needs filesystem path access
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | A set of resources (tensor product)
type Resources = [Resource]

-- | Combine resources (⊗ operator)
combine :: Resources -> Resources -> Resources
combine = (++)

-- | ASCII alias for tensor product
tensor :: Resources -> Resources -> Resources
tensor = combine

-- | Check if resources are pure
isPure :: Resources -> Bool
isPure = null

-- | Infer coeffects from a rule
ruleCoeffects :: Rule -> Resources
ruleCoeffects = \case
  RCxxBinary bin ->
    [Filesystem (T.unpack s) | s <- bin.srcs]
    ++ [Network | DepFlake _ <- bin.deps]  -- Nix fetch
    
  RHaskellBinary bin ->
    [Filesystem (T.unpack s) | s <- bin.srcs]
    ++ [Network | DepFlake _ <- bin.deps]
    ++ [Network | not (null bin.packages)]  -- GHC package fetch
    
  RGenrule gen ->
    -- Genrules are maximally permissive by default
    [Network, Filesystem "."]
    
  RPureScriptApp app ->
    [Network]  -- Always fetches packages
    ++ [Filesystem (T.unpack s) | s <- srcSpecFiles app.srcs]
    
  _ -> [Pure]

-- | Infer coeffects from an action
actionCoeffects :: Action -> Resources
actionCoeffects action =
  map parseCoeffect (aCoeffects action)
  where
    parseCoeffect t
      | "fs:" `T.isPrefixOf` t = Filesystem (T.unpack $ T.drop 3 t)
      | "network" == t = Network
      | "auth:" `T.isPrefixOf` t = Auth (T.drop 5 t)
      | otherwise = Pure
```

#### Module: `SenseNet.Attestation`

```haskell
module SenseNet.Attestation
  ( -- Types (from DischargeProof.dhall)
    DischargeProof(..)
  , NetworkAccess(..)
  , FilesystemAccess(..)
  , AuthUsage(..)
  , AccessMode(..)
    -- Generation
  , generateProof
  , signProof
    -- Verification
  , verifyProof
  , verifySignature
    -- Serialization
  , encodeProof
  , decodeProof
  ) where

-- | Evidence of coeffect satisfaction
data DischargeProof = DischargeProof
  { dpCoeffects :: Resources
  , dpNetworkAccess :: [NetworkAccess]
  , dpFilesystemAccess :: [FilesystemAccess]
  , dpAuthUsage :: [AuthUsage]
  , dpBuildId :: Text
  , dpDerivationHash :: Hash
  , dpOutputHashes :: [(Text, Hash)]
  , dpStartTime :: UTCTime
  , dpEndTime :: UTCTime
  , dpSignature :: Maybe Ed25519Signature
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data NetworkAccess = NetworkAccess
  { naUrl :: Text
  , naMethod :: Text
  , naContentHash :: Hash
  , naTimestamp :: UTCTime
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data FilesystemAccess = FilesystemAccess
  { faPath :: Text
  , faMode :: AccessMode
  , faContentHash :: Maybe Hash
  , faTimestamp :: UTCTime
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data AccessMode = Read | Write | Execute
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

data AuthUsage = AuthUsage
  { auProvider :: Text
  , auScope :: Maybe Text
  , auTimestamp :: UTCTime
  }
  deriving (Eq, Show, Generic, ToJSON, FromJSON)

-- | Generate a discharge proof from execution evidence
generateProof 
  :: Action 
  -> ExecutionEvidence 
  -> [(Text, Hash)] 
  -> IO DischargeProof
generateProof action evidence outputHashes = do
  now <- getCurrentTime
  buildId <- generateBuildId
  
  pure DischargeProof
    { dpCoeffects = actionCoeffects action
    , dpNetworkAccess = evidenceNetworkAccess evidence
    , dpFilesystemAccess = evidenceFilesystemAccess evidence
    , dpAuthUsage = evidenceAuthUsage evidence
    , dpBuildId = buildId
    , dpDerivationHash = actionKey action
    , dpOutputHashes = outputHashes
    , dpStartTime = evidenceStartTime evidence
    , dpEndTime = now
    , dpSignature = Nothing  -- Unsigned
    }

-- | Sign a discharge proof with Ed25519
signProof :: Ed25519.SecretKey -> DischargeProof -> DischargeProof
signProof sk proof =
  let payload = canonicalizeProof proof
      sig = Ed25519.sign sk (Ed25519.toPublic sk) payload
  in proof { dpSignature = Just (Ed25519Signature sig) }

-- | Verify a discharge proof signature
verifySignature :: Ed25519.PublicKey -> DischargeProof -> Bool
verifySignature pk proof =
  case dpSignature proof of
    Nothing -> True  -- Unsigned proofs are valid but untrusted
    Just (Ed25519Signature sig) ->
      let payload = canonicalizeProof proof { dpSignature = Nothing }
      in Ed25519.verify pk payload sig

-- | Verify that proof evidence matches declared coeffects
verifyProof :: DischargeProof -> Bool
verifyProof proof =
  -- Check that all declared coeffects have corresponding evidence
  all (hasEvidence proof) (dpCoeffects proof)
  where
    hasEvidence p = \case
      Pure -> True
      Network -> not (null $ dpNetworkAccess p)
      Filesystem path -> 
        any (\fa -> T.unpack (faPath fa) == path) (dpFilesystemAccess p)
      Auth provider ->
        any (\au -> auProvider au == provider) (dpAuthUsage p)
      Sandbox _ -> True  -- Sandbox is verified by execution context
```

#### Module: `Worker.Attestation`

```haskell
module Worker.Attestation
  ( withCoeffectTracking
  , ExecutionEvidence(..)
  ) where

-- | Track coeffects during action execution
withCoeffectTracking 
  :: Sandbox 
  -> IO a 
  -> IO (a, ExecutionEvidence)
withCoeffectTracking sandbox action = do
  startTime <- getCurrentTime
  
  -- Set up network proxy (records all connections)
  networkLog <- newIORef []
  withNetworkProxy sandbox networkLog $ do
    
    -- Set up filesystem audit (records all file opens)
    fsLog <- newIORef []
    withFilesystemAudit sandbox fsLog $ do
      
      -- Set up auth tracking
      authLog <- newIORef []
      withAuthTracking authLog $ do
        
        -- Execute the action
        result <- action
        
        -- Collect evidence
        endTime <- getCurrentTime
        network <- readIORef networkLog
        fs <- readIORef fsLog
        auth <- readIORef authLog
        
        let evidence = ExecutionEvidence
              { evidenceStartTime = startTime
              , evidenceEndTime = endTime
              , evidenceNetworkAccess = network
              , evidenceFilesystemAccess = fs
              , evidenceAuthUsage = auth
              }
        
        pure (result, evidence)
```

#### Deliverables

- [ ] `SenseNet.Coeffect` module with Resource type
- [ ] `SenseNet.Attestation` module with DischargeProof
- [ ] Automatic coeffect inference from rules
- [ ] Ed25519 signing/verification
- [ ] Network proxy for tracking connections (using TLS MITM)
- [ ] Filesystem audit via fanotify or similar
- [ ] Proto definition for attestation wire format
- [ ] CLI: `sensenet verify //pkg:target`

### Phase 7: Full Integration (Week 7-8)

**Goal**: Everything works together seamlessly.

#### Flake Module Configuration

```nix
# Example flake.nix usage

{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sensenet.url = "github:straylight-software/sensenet";
  };

  outputs = { self, nixpkgs, sensenet, ... }:
    sensenet.lib.mkFlake {
      inherit nixpkgs;
      
      sensenet.projects.myapp = {
        src = ./.;
        targets = [ "//src:myapp" "//src:mylib" ];
        
        # Toolchain configuration
        toolchain = {
          cxx = {
            enable = true;
            std = "c++23";
            flags = [ "-O2" "-Wall" "-Werror" ];
          };
          haskell = {
            enable = true;
            packages = hp: [ hp.aeson hp.text hp.bytestring ];
          };
          rust.enable = true;
        };
        
        # Remote execution configuration
        remote = {
          enable = true;
          
          # Use your own infrastructure
          scheduler = "scheduler.mycompany.com:443";
          cas = "cas.mycompany.com:443";
          
          # Or use Straylight's shared infrastructure
          # scheduler = "sensenet.straylight.dev:443";
          
          # TLS configuration
          tls = {
            enable = true;
            # Optional: client certificate for mTLS
            # certFile = ./certs/client.pem;
            # keyFile = ./certs/client-key.pem;
          };
          
          # Platform requirements for remote workers
          platform = {
            os = "linux";
            arch = "x86_64";
            # Require specific GPU
            # properties.gpu = "sm_90";
          };
          
          # Caching behavior
          cache = {
            # Check remote cache before building
            readEnabled = true;
            # Upload build outputs to cache
            writeEnabled = true;
          };
        };
        
        # Attestation requirements
        attestation = {
          # Require all builds to have valid attestations
          require = true;
          
          # Trusted signing keys (Ed25519 public keys)
          trustedKeys = [
            "ed25519:AAAA..."  # CI worker
            "ed25519:BBBB..."  # Cloud workers
          ];
          
          # Generate attestations for local builds too
          signLocal = true;
          localKeyFile = "~/.sensenet/signing-key";
        };
      };
    };
}
```

#### CLI Usage

```bash
# Local build (default)
sensenet build //src:myapp

# Remote build (uses configured scheduler/CAS)
sensenet build --remote //src:myapp

# Remote build with explicit endpoints
sensenet build \
  --scheduler scheduler.example.com:443 \
  --cas cas.example.com:443 \
  //src:myapp

# Build with remote cache only (no remote execution)
sensenet build --remote-cache //src:myapp

# Verify attestations for a target
sensenet verify //src:myapp

# Show attestation details
sensenet verify --verbose //src:myapp

# List available targets
sensenet targets

# Clean local cache
sensenet clean

# Clean and rebuild
sensenet clean && sensenet build //src:myapp

# Start a local worker (joins the cluster)
sensenet worker \
  --scheduler scheduler.mycompany.com:443 \
  --cas cas.mycompany.com:443

# Start local development cluster
sensenet cluster start

# Stop local cluster
sensenet cluster stop
```

#### Environment Variables

```bash
# Default scheduler endpoint
export SENSENET_SCHEDULER="scheduler.mycompany.com:443"

# Default CAS endpoint
export SENSENET_CAS="cas.mycompany.com:443"

# Disable TLS (for local development)
export SENSENET_TLS="false"

# Signing key path
export SENSENET_SIGNING_KEY="~/.sensenet/signing-key"

# Cache directory
export SENSENET_CACHE_DIR="~/.cache/sensenet"

# Log level
export SENSENET_LOG_LEVEL="info"  # debug, info, warn, error
```

#### Deliverables

- [ ] End-to-end remote builds working
- [ ] Attestation generation and verification
- [ ] Flake module for easy project setup
- [ ] `sensenet cluster` subcommand for local dev
- [ ] Comprehensive documentation
- [ ] Example projects demonstrating all features
- [ ] CI/CD integration examples (GitHub Actions, GitLab CI)
- [ ] Performance benchmarks (local vs remote)

## Toolchain Synchronization

### The Problem

Remote workers must have identical toolchains to local builds. Different compiler versions, library versions, or even build flags can produce different outputs.

### The Solution

Workers use the exact same Nix closure as the client.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            TOOLCHAIN FLOW                                    │
│                                                                             │
│  1. Project flake.nix defines toolchain requirements                        │
│  2. Nix evaluates to a derivation with specific store paths:                │
│     /nix/store/abc123-clang-18.1.0                                          │
│     /nix/store/def456-ghc-9.12.1                                            │
│     /nix/store/ghi789-toolchain-closure  (combined)                         │
│                                                                             │
│  3. Client includes closure hash in action's platform properties:           │
│     { "nix-closure": "/nix/store/ghi789-toolchain-closure" }                │
│                                                                             │
│  4. Scheduler routes to workers that have (or can fetch) this closure       │
│                                                                             │
│  5. Worker bind-mounts closure into sandbox:                                │
│     mount --bind /nix/store/ghi789-... /sandbox/nix/store                   │
│                                                                             │
│  6. Build executes with identical tools                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Implementation

```haskell
-- In sensenet CLI (client side)
buildRemote :: ExecutionClient -> CASClient -> Action -> IO ActionResult
buildRemote exec cas action = do
  -- Get toolchain closure from environment
  toolchainClosure <- getToolchainClosure
  
  -- Add to platform properties
  let platform = action.platform
        { platformProperties = 
            Map.insert "nix-closure" toolchainClosure
            (platformProperties action.platform)
        }
  
  executeAction exec cas action { aPlatform = platform }
```

```haskell
-- In sensenet-worker
executeInSandbox config cas action = do
  -- Extract required closure from platform properties
  let requiredClosure = lookup "nix-closure" 
        (platformProperties action.platform)
  
  case requiredClosure of
    Nothing -> 
      -- No specific closure required, use worker's default
      executeWithDefaultToolchain action
      
    Just closurePath -> do
      -- Ensure we have this closure
      hasLocal <- doesDirectoryExist closurePath
      
      unless hasLocal $ do
        -- Fetch from Nix binary cache or CAS
        fetchNixClosure closurePath
      
      -- Bind-mount into sandbox
      withSandbox $ \sandbox -> do
        mountReadOnly sandbox closurePath "/nix/store"
        executeCommand sandbox action
```

### Closure Fetching

Workers can obtain closures from multiple sources:

1. **Local Nix store** - Already present from previous builds
1. **Nix binary cache** - Standard Nix infrastructure (cache.nixos.org, cachix)
1. **CAS** - Closures can be uploaded to CAS alongside build inputs
1. **Nix copy** - Direct copy from client: `nix copy --to ssh://worker /nix/store/xxx`

```haskell
fetchNixClosure :: StorePath -> IO ()
fetchNixClosure path = do
  -- Try binary cache first (fastest)
  success <- tryBinaryCache path
  when (not success) $ do
    -- Fall back to CAS
    success' <- tryCASFetch path
    when (not success') $ do
      -- Last resort: request from scheduler/client
      requestClosureFromScheduler path
```

## Comparison with Existing Solutions

### vs NativeLink Alone

| Feature | NativeLink | sensenet v0.5 |
|---------|-----------|---------------|
| Configuration | TOML + CLI flags | Dhall (typed) |
| Toolchains | Docker images | Nix closures (reproducible) |
| Build rules | External (Bazel/Buck2) | Native Dhall |
| Coeffect tracking | None | Full algebra + proofs |
| Attestations | None | Ed25519 signed |
| Language support | Whatever client sends | Native C++/Rust/Haskell/Lean/CUDA |
| Development UX | Separate infrastructure | `nix develop` includes everything |

### vs Bazel + Remote Build Execution

| Feature | Bazel + RBE | sensenet v0.5 |
|---------|------------|---------------|
| Configuration | Starlark (runtime types) | Dhall (compile-time types) |
| Toolchains | Container images | Nix closures |
| Hermeticity | Best-effort | Guaranteed (Nix) |
| Reproducibility | Platform-dependent | Byte-for-byte (Nix) |
| Attestations | None | Full coeffect proofs |
| Setup complexity | High | `nix develop` |

### vs Buck2 + NativeLink

| Feature | Buck2 + NativeLink | sensenet v0.5 |
|---------|-------------------|---------------|
| Configuration | Starlark + TOML | Dhall only |
| Build engine | DICE (Rust) | DICE-inspired (Haskell) |
| Incremental | Yes | Yes |
| Remote execution | RE API v2 | RE API v2 (native) |
| Toolchains | Manual setup | Nix closures |
| Self-hosting | Cargo + Buck2 | sensenet builds sensenet |

## Security Model

### Threat Model

1. **Malicious workers** - Could return incorrect outputs
1. **MITM attacks** - Could intercept build traffic
1. **Replay attacks** - Could serve stale/wrong cached outputs
1. **Supply chain attacks** - Could inject malicious dependencies

### Mitigations

#### 1. Attestations

Every build output is accompanied by a signed DischargeProof:

```
Output + DischargeProof + Signature
         │
         ├── Coeffects declared (what was needed)
         ├── Evidence collected (what actually happened)
         ├── Input/output hashes
         └── Ed25519 signature by worker
```

Clients verify:

- Signature is valid
- Signing key is trusted
- Evidence matches declared coeffects
- Output hashes match

#### 2. Content Addressing

All artifacts are content-addressed (BLAKE3 hash). Tampering changes the hash, which invalidates the reference.

#### 3. TLS Everywhere

All gRPC connections use TLS. Optional mTLS for client authentication.

#### 4. Nix Closure Integrity

Toolchain closures are content-addressed Nix store paths. The closure hash is verified before use.

#### 5. Sandbox Isolation

Workers execute actions in isolated sandboxes:

- User namespaces (no root)
- Network namespace (controlled egress)
- Mount namespace (minimal filesystem)
- Seccomp filters (syscall restrictions)

### Trust Levels

| Source | Trust Level | Verification |
|--------|-------------|--------------|
| Local build | Highest | Self-signed or unsigned |
| Trusted CI worker | High | Ed25519, key in config |
| Straylight cloud | Medium | Ed25519, key published |
| Unknown worker | None | Rejected unless `--allow-untrusted` |

## Performance Considerations

### Latency Budget

For a remote build to be worthwhile, network overhead must be less than build time savings.

```
Remote build time = 
    Upload inputs +
    Queue wait +
    Execution +
    Download outputs

Local build time =
    Execution
```

**Break-even**: Remote is faster when `Upload + Queue + Download < Local - Remote Execution`

For a 1-minute local build on a 4-core laptop vs 64-core worker:

- Local: 60 seconds
- Remote execution: ~4 seconds (16x faster)
- Upload (10MB): ~1 second
- Download (1MB): ~0.1 second
- Queue wait: ~1 second (assuming low contention)
- **Total remote: ~6 seconds** (10x faster overall)

### Optimizations

1. **Streaming uploads** - Start execution before all inputs uploaded
1. **Input deduplication** - Only upload changed files
1. **Speculative execution** - Start building likely-to-be-needed targets
1. **Local cache** - Skip remote entirely for cached actions
1. **Persistent connections** - Reuse gRPC channels

### Benchmarks (Target)

| Operation | Target Latency |
|-----------|---------------|
| ActionKey computation | < 2 µs |
| CAS blob upload (1MB) | < 100 ms |
| CAS blob download (1MB) | < 100 ms |
| Execute RPC | < 50 ms |
| WaitExecution (long-poll) | < 10 ms after completion |
| Sandbox creation | < 100 ms |
| Toolchain mount | < 50 ms |

## Milestones Summary

| Week | Phase | Milestone | Key Deliverable |
|------|-------|-----------|-----------------|
| 1-2 | 1 | CAS Client | `sensenet build --remote-cache` |
| 2-3 | 2 | RE Client | `sensenet build --remote` on NativeLink |
| 3-4 | 3 | Worker | `sensenet-worker` binary |
| 4-5 | 4 | Scheduler | `sensenet-scheduler` binary |
| 5-6 | 5 | Containers | `nix build .#worker-image` |
| 6-7 | 6 | Coeffects | DischargeProof generation/verification |
| 7-8 | 7 | Integration | End-to-end, docs, examples |

## Open Questions

### 1. CAS Backend for Production

Options:

- **S3/R2**: Obvious choice, well-understood, cheap
- **Nix binary cache**: Already content-addressed, could reuse infrastructure
- **Custom**: Optimized for build artifacts (e.g., delta compression)

Recommendation: Start with S3/R2, evaluate Nix cache integration later.

### 2. Worker Discovery

Options:

- **Static config**: Scheduler has hardcoded worker list
- **Registration**: Workers register on startup (current plan)
- **mDNS**: For local network discovery
- **Consul/etcd**: For datacenter deployments

Recommendation: Registration with heartbeats, add service mesh integration later.

### 3. Scheduler High Availability

Options:

- **Single scheduler**: Fine for small deployments
- **Active-passive**: With health checks and failover
- **Raft consensus**: True HA, complex
- **External coordination**: etcd/Consul for leader election

Recommendation: Start single, add leader election via etcd when needed.

### 4. GPU Scheduling

Workers advertise GPU capabilities in platform properties:

```
{ "gpu": "sm_90", "gpu_count": "8", "gpu_memory": "80GB" }
```

Scheduler matches actions requiring specific GPUs to appropriate workers.

Challenge: GPU memory management (multiple small jobs vs one large job).

### 5. Cost Allocation

Track per-action:

- CPU-seconds
- Memory-seconds
- Network bytes
- Storage bytes

Attribute to project/team via action metadata. Expose in scheduler metrics.

## Getting Started

### Prerequisites

```bash
# Install Nix with flakes
curl -L https://nixos.org/nix/install | sh
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
```

### Development

```bash
# Enter devshell
cd sensenet
nix develop

# Build all binaries
sensenet build //src/sensenet:sensenet
sensenet build //src/sensenet-worker:sensenet-worker
sensenet build //src/sensenet-scheduler:sensenet-scheduler
sensenet build //src/sensenet-cas:sensenet-cas

# Run tests
./scripts/test-all.sh

# Start local cluster
sensenet cluster start

# Build with local cluster
sensenet build --remote //src/examples/cxx:hello-cxx
```

### Deployment

```bash
# Build container images
nix build .#worker-image
nix build .#scheduler-image
nix build .#cas-image

# Push to registry
docker load < result
docker push ghcr.io/straylight-software/sensenet-worker:latest

# Deploy to Fly.io
cd deploy/fly
fly deploy -c worker.toml
fly deploy -c scheduler.toml
fly deploy -c cas.toml

# Or deploy to Kubernetes
kubectl apply -f deploy/k8s/
```

## References

- [RE API v2 Specification](https://github.com/bazelbuild/remote-apis/blob/main/build/bazel/remote/execution/v2/remote_execution.proto)
- [NativeLink](https://github.com/TraceMachina/nativelink)
- [Buck2 DICE](https://buck2.build/docs/developers/dice/)
- [Nix Flakes](https://nixos.wiki/wiki/Flakes)
- [Petricek's Coeffects](https://tomasp.net/coeffects/)
