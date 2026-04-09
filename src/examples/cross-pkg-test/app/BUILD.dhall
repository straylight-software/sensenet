--| App that depends on greeter library (cross-package dependency test)

let E = ../../../../dhall/evring/Compat.dhall

-- Cross-package dependency: //src/examples/cross-pkg-test/lib:greeter
let greeterApp =
      (E.cxx_binary "greeter-app" ["main.cpp"])
        with deps = [ E.local "//src/examples/cross-pkg-test/lib:greeter" ]

in  { targets = [ E.rule.cxxBinary greeterApp ] }
