-- buckconfig-re.dhall
-- Generate [buck2_re_client] section for .buckconfig.local
--
-- Environment variables:
--   ENGINE_ADDRESS, CAS_ADDRESS, ACTION_CACHE_ADDRESS (optional)
--   TLS (true/false), INSTANCE_NAME

let engine_address = env:ENGINE_ADDRESS as Text
let cas_address = env:CAS_ADDRESS as Text
let action_cache_address = env:ACTION_CACHE_ADDRESS ? "" as Text
let tls = env:TLS as Text
let instance_name = env:INSTANCE_NAME as Text

in ''
[buck2_re_client]
engine_address = ${engine_address}
cas_address = ${cas_address}
${if action_cache_address == "" then "" else "action_cache_address = ${action_cache_address}"}
tls = ${tls}
instance_name = ${instance_name}

[buck2_re_client.platform_properties]
OSFamily = linux
container-image = docker://ghcr.io/straylight-software/nativelink-worker:latest
''
