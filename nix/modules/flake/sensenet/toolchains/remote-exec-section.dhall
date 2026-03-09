-- remote-exec-section.dhall
-- Generate remote execution section for buckconfig.local

let scheduler = env:SCHEDULER as Text
let scheduler_port = env:SCHEDULER_PORT as Text
let cas = env:CAS as Text
let cas_port = env:CAS_PORT as Text
let tls = env:TLS as Text
let instance_name = env:INSTANCE_NAME as Text

in ''

# ────────────────────────────────────────────────────────────────────────────
# NativeLink Remote Execution
# ────────────────────────────────────────────────────────────────────────────

[build]
execution_platforms = toolchains//:lre

[buck2_re_client]
engine_address = grpc://${scheduler}:${scheduler_port}
cas_address = grpc://${cas}:${cas_port}
action_cache_address = grpc://${cas}:${cas_port}
tls = ${tls}
instance_name = ${instance_name}

[buck2_re_client.platform_properties]
OSFamily = linux
container-image = nix-worker
''
