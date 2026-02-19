--| Greeter library (for cross-package dependency test)

let A = ../../../../dhall/prelude/package.dhall

let greeterLib = 
  (A.cxxLibrary "greeter" ["greeter.cpp"] ([] : List A.Dep))
    with hdrs = ["greeter.hpp"]

in  { targets = [ A.rule.cxxLibrary greeterLib ] }
