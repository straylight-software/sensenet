--| Greeter library (for cross-package dependency test)

let E = ../../../../dhall/evring/Compat.dhall

let greeterLib = 
      (E.cxx_library "greeter" ["greeter.cpp"] ([] : List Text))
        with hdrs = ["greeter.hpp"]

in  { targets = [ E.rule.cxxLibrary greeterLib ] }
