--| C++ examples using LLVM toolchain (new format)

let A = ../../../dhall/prelude/package.dhall

let hello = A.cxxBinary "hello-cxx" ["hello.cpp"] ([] : List A.Dep)
let foo = A.cxxBinary "foo" ["foo.cpp"] ([] : List A.Dep)
let bar = A.cxxBinary "bar" ["bar.cpp"] ([] : List A.Dep)
let baz = A.cxxBinary "baz" ["baz.cpp"] ([] : List A.Dep)

in  { targets = 
        [ A.rule.cxxBinary hello
        , A.rule.cxxBinary foo
        , A.rule.cxxBinary bar
        , A.rule.cxxBinary baz
        ] 
    }
