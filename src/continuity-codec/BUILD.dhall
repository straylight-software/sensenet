--| Continuity.Codec - C++23 Dhall Interpreter
--|
--| An LL(k) parser and evaluator for the Dhall configuration language.
--| Part of the libevring/Continuity build system.
--|
--| straylight.software · 2026

let E = ../../dhall/evring/Compat.dhall

let codec_lib = E.cxx_library
    "continuity-codec"
    [ "Parser.cpp", "Eval.cpp" ]
    [ "Codec.hpp", "Utf8.hpp" ]
  // { cflags = [ "-std=c++23", "-O2", "-Wall", "-Wextra" ]
     , deps = [] : List E.Dep
     }

let codec_test = E.cxx_binary
    "codec-test"
    [ "test/main.cpp" ]
  // { cflags = [ "-std=c++23", "-O2" ]
     , deps = [ E.local "continuity-codec" ]
     }

in  { lib = codec_lib
    , test = codec_test
    }
