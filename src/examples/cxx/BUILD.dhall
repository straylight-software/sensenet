--| C++ examples using LLVM toolchain
--|
--| Uses evring-style constructors via Compat layer

let E = ../../../dhall/evring/Compat.dhall

let hello = E.cxx_binary "hello-cxx" ["hello.cpp"]
let foo = E.cxx_binary "foo" ["foo.cpp"]
let bar = E.cxx_binary "bar" ["bar.cpp"]
let baz = E.cxx_binary "baz" ["baz.cpp"]

in  { targets = 
        [ E.rule.cxxBinary hello
        , E.rule.cxxBinary foo
        , E.rule.cxxBinary bar
        , E.rule.cxxBinary baz
        ] 
    }
