--| PureScript Halogen Todo App (new format)

let A = ../../../dhall/prelude/package.dhall

let halogenTodo =
      (A.purescriptApp "halogen-todo" (A.SrcSpec.Glob "src/**/*.purs") "spago.yaml")
        with main = "Main"
        with index_html = Some "index.html"
        with style_css = Some "style.css"

in  { targets = [ A.rule.purescriptApp halogenTodo ] }
