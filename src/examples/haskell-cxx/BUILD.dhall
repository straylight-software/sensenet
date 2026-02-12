--| Haskell calling C++ via FFI
--|
--| Demonstrates:
--|   - foreign import ccall for C++ functions
--|   - Pointer passing (arrays, strings)
--|   - Opaque handle pattern for C++ objects

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let test_ffi =
      (A.haskellFFIBinary "test_ffi" ["FFI.hs", "Main.hs"] ["ffi.cpp"])
        with cxx_headers = ["ffi.h"]

in  { rules = [ S.haskellFFIBinary test_ffi ]
    , header = ''
        load("@toolchains//:haskell.bzl", "haskell_ffi_binary")
        ''
    }
