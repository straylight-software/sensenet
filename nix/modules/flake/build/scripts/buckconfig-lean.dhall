-- buckconfig-lean.dhall
-- Generate [lean] section for .buckconfig.local
--
-- Environment variables:
--   LEAN, LEANC, LAKE (optional)
--   LEAN_LIB_DIR, LEAN_INCLUDE_DIR

let lean = env:LEAN as Text
let leanc = env:LEANC as Text
let lean_lib_dir = env:LEAN_LIB_DIR as Text
let lean_include_dir = env:LEAN_INCLUDE_DIR as Text

in ''
[lean]
# Lean 4 toolchain from Nix
lean = ${lean}
leanc = ${leanc}
lean_lib_dir = ${lean_lib_dir}
lean_include_dir = ${lean_include_dir}
''
