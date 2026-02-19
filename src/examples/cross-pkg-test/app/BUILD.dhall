--| App that depends on greeter library (cross-package dependency test)

let A = ../../../../dhall/prelude/package.dhall

-- Cross-package dependency: //src/examples/cross-pkg-test/lib:greeter
let greeterApp = A.cxxBinary "greeter-app" ["main.cpp"] 
  [ A.local "//src/examples/cross-pkg-test/lib:greeter" ]

in  { targets = [ A.rule.cxxBinary greeterApp ] }
