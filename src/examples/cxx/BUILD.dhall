--| C++ examples using LLVM toolchain

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let hello = A.cxxBinary "hello-cxx" ["hello.cpp"] ([] : List A.Dep)

in  { rules = [ S.cxxBinary hello { compiler = [] : List Text, linker = [] : List Text } ]
    , header = ""
    }
