-- buckconfig-flags.dhall
-- Generate [cxx.flags] section for .buckconfig.local (Turing Registry)
--
-- Environment variables:
--   C_FLAGS   - Space-separated C compiler flags
--   CXX_FLAGS - Space-separated C++ compiler flags

let c_flags = env:C_FLAGS as Text
let cxx_flags = env:CXX_FLAGS as Text

in ''
[cxx.flags]
# Turing Registry: compiler flags applied to all C/C++ compilation
c_flags = ${c_flags}
cxx_flags = ${cxx_flags}
''
