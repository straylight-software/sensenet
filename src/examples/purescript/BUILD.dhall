--| PureScript Halogen Todo App
--  No spago required - sensenet fetches packages directly from the registry

let E = ../../../dhall/evring/Compat.dhall

-- Direct dependencies - sensenet resolves transitive deps automatically
let deps =
      [ "aff"
      , "arrays"
      , "console"
      , "effect"
      , "foldable-traversable"
      , "halogen"
      , "halogen-vdom"
      , "maybe"
      , "prelude"
      , "strings"
      , "web-dom"
      , "web-html"
      ]

let halogenTodo =
      (E.purescript_app "halogen-todo" (E.SrcSpec.Glob "src/**/*.purs") deps)
        with main = "Main"
        with index_html = Some "index.html"
        with style_css = Some "style.css"

in  { targets = [ E.rule.purescriptApp halogenTodo ] }
