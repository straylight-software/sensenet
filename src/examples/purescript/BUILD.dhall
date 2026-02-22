--| PureScript Halogen Todo App (new format)
--  No spago required - sensenet fetches packages directly from the registry

let A = ../../../dhall/prelude/package.dhall

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
      (A.purescriptApp "halogen-todo" (A.SrcSpec.Glob "src/**/*.purs") deps)
        with main = "Main"
        with index_html = Some "index.html"
        with style_css = Some "style.css"

in  { targets = [ A.rule.purescriptApp halogenTodo ] }
