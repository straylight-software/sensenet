--| Haskell calling C++ via FFI
--|
--| Demonstrates:
--|   - foreign import ccall for C++ functions
--|   - Pointer passing (arrays, strings)
--|   - Opaque handle pattern for C++ objects

let E = ../../../dhall/evring/Compat.dhall

let test_ffi =
      (E.haskell_ffi_binary "test_ffi" ["FFI.hs", "Main.hs"] ["ffi.cpp"])
        with cxx_headers = ["ffi.h"]

in  { targets = [ E.rule.haskellFFIBinary test_ffi ] }
