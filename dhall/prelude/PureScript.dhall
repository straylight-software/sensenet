--| PureScript Rules

let T = ./Types.dhall

-- | Source specification - explicit list, single glob, or multiple globs
let SrcSpec = < Explicit : List Text | Glob : Text | Globs : List Text >

-- | PureScript web application (Halogen, etc.)
let App =
      { name : Text
      , srcs : SrcSpec
      , spago_yaml : Text
      , spago_lock : Optional Text
      , main : Text
      , index_html : Optional Text
      , style_css : Optional Text
      , vis : T.Vis
      }

let app
    : Text -> SrcSpec -> Text -> App
    = \(name : Text) ->
      \(srcs : SrcSpec) ->
      \(spago_yaml : Text) ->
        { name, srcs, spago_yaml
        , spago_lock = None Text
        , main = "Main"
        , index_html = Some "index.html"
        , style_css = Some "style.css"
        , vis = T.Vis.Public
        }

-- | PureScript Node.js binary
let Binary =
      { name : Text
      , srcs : SrcSpec
      , spago_yaml : Text
      , main : Text
      , vis : T.Vis
      }

let binary
    : Text -> SrcSpec -> Text -> Binary
    = \(name : Text) ->
      \(srcs : SrcSpec) ->
      \(spago_yaml : Text) ->
        { name, srcs, spago_yaml
        , main = "Main"
        , vis = T.Vis.Public
        }

-- | PureScript library
let Library =
      { name : Text
      , srcs : SrcSpec
      , spago_yaml : Optional Text
      , vis : T.Vis
      }

let library
    : Text -> SrcSpec -> Library
    = \(name : Text) ->
      \(srcs : SrcSpec) ->
        { name, srcs
        , spago_yaml = None Text
        , vis = T.Vis.Public
        }

in  { App, app, Binary, binary, Library, library, SrcSpec }
