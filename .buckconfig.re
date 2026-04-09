# NativeLink Remote Execution Configuration
# Include this with: buck2 build --config-file .buckconfig.re

[buck2_re_client]
engine_address = grpc://34.28.196.149:50052
cas_address = grpc://34.28.196.149:50051
action_cache_address = grpc://34.28.196.149:50051
tls = false

[build]
# Use remote execution platform instead of local
execution_platforms = toolchains//:lre
