--| Remote execution configuration for sensenet
--|
--| This defines how sensenet connects to NativeLink for remote builds.
--| Place a copy at .sensenet/remote.dhall to configure RE for your project.

-- | Remote execution endpoint
let RemoteConfig =
      { scheduler : Text         -- Scheduler hostname or IP
      , port : Natural           -- gRPC port (default 50051)
      , useTLS : Bool            -- Use TLS encryption
      , instanceName : Text      -- Instance name (usually empty)
      }

-- | Default config for local NativeLink testing
let defaultConfig : RemoteConfig =
      { scheduler = "localhost"
      , port = 50051
      , useTLS = False
      , instanceName = ""
      }

-- | GCP Gigafleet configuration
let gcpGigafleet : RemoteConfig =
      { scheduler = "34.28.196.149"
      , port = 50051
      , useTLS = False
      , instanceName = ""
      }

-- | Fly.io deployment (TLS enabled)
let flyio : RemoteConfig =
      { scheduler = "aleph-scheduler.fly.dev"
      , port = 443
      , useTLS = True
      , instanceName = "main"
      }

in  { RemoteConfig
    , defaultConfig
    , gcpGigafleet
    , flyio
    }
