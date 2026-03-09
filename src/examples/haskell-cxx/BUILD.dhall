--| Haskell calling C++ via FFI (new format)
--|
--| Demonstrates:
--|   - foreign import ccall for C++ functions
--|   - Pointer passing (arrays, strings)
--|   - Opaque handle pattern for C++ objects

let A = ../../../dhall/prelude/package.dhall

let test_ffi =
      (A.haskellFFIBinary "test_ffi" ["FFI.hs", "Main.hs"] ["ffi.cpp"])
        with cxx_headers = ["ffi.h"]

in  { targets = [ A.rule.haskellFFIBinary test_ffi ] }
