--| PureScript Halogen Todo App
--|
--| Demonstrates:
--|   - Halogen UI framework
--|   - State management with hooks
--|   - CSS styling

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let halogenTodo =
      (A.purescriptApp "halogen-todo" (A.SrcSpec.Glob "src/**/*.purs") "spago.yaml")
        with main = "Main"
        with index_html = Some "index.html"
        with style_css = Some "style.css"

in  { rules = [ S.purescriptApp halogenTodo ]
    , header = ''
        load("@toolchains//:purescript.bzl", "purescript_app")
        ''
    }
