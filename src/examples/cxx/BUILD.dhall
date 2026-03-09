--| C++ examples using LLVM toolchain (new format)

let A = ../../../dhall/prelude/package.dhall

let hello = A.cxxBinary "hello-cxx" ["hello.cpp"] ([] : List A.Dep)

in  { targets = [ A.rule.cxxBinary hello ] }
