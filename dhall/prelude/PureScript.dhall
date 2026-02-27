--| PureScript Rules

let T = ./Types.dhall

-- | Source specification - explicit list, single glob, or multiple globs
let SrcSpec = < Explicit : List Text | Glob : Text | Globs : List Text >

-- | PureScript web application (Halogen, etc.)
--   deps: Direct dependencies (package names from the registry)
--   package_set: Package set version (e.g., "psc-0.15.15-20240416")
let App =
      { name : Text
      , srcs : SrcSpec
      , deps : List Text
      , package_set : Text
      , main : Text
      , index_html : Optional Text
      , style_css : Optional Text
      , vis : T.Vis
      }

-- | Default package set - PureScript 0.15.15 from April 2024
let defaultPackageSet = "psc-0.15.15-20240416"

let app
    : Text -> SrcSpec -> List Text -> App
    = \(name : Text) ->
      \(srcs : SrcSpec) ->
      \(deps : List Text) ->
        { name, srcs, deps
        , package_set = defaultPackageSet
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

-- | PureScript web application using spago (supports extraPackages)
let WebApp =
      { name : Text
      , srcs : SrcSpec
      , spago_yaml : Text
      , main : Text
      , index_html : Optional Text
      , style_css : Optional Text
      , vis : T.Vis
      }

let webapp
    : Text -> SrcSpec -> Text -> WebApp
    = \(name : Text) ->
      \(srcs : SrcSpec) ->
      \(spago_yaml : Text) ->
        { name, srcs, spago_yaml
        , main = "Main"
        , index_html = Some "index.html"
        , style_css = Some "style.css"
        , vis = T.Vis.Public
        }

in  { App, app, Binary, binary, Library, library, WebApp, webapp, SrcSpec }
