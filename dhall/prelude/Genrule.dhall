--| Genrule - arbitrary shell commands

let T = ./Types.dhall

let Genrule =
      { name : Text
      , out : Text
      , cmd : Text
      , srcs : List Text
      , vis : T.Vis
      }

let genrule
    : Text -> Text -> Text -> Genrule
    = \(name : Text) ->
      \(out : Text) ->
      \(cmd : Text) ->
        { name, out, cmd
        , srcs = [] : List Text
        , vis = T.Vis.Public
        }

in  { Genrule, genrule }
