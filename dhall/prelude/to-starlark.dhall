--| Dhall -> Starlark

let P = ./Prelude.dhall
let T = ./Types.dhall
let C = ./Cxx.dhall

let q = \(t : Text) -> "\"${t}\""

let list = \(xs : List Text) ->
    "[" ++ P.Text.concatSep ", " (P.List.map Text Text q xs) ++ "]"

let flakes
    : List T.Dep -> List Text
    = \(ds : List T.Dep) ->
        P.List.concatMap T.Dep Text
          (\(d : T.Dep) -> merge { Local = \(_ : Text) -> [] : List Text
                                 , Flake = \(r : Text) -> [r] } d) ds

let locals
    : List T.Dep -> List Text
    = \(ds : List T.Dep) ->
        P.List.concatMap T.Dep Text
          (\(d : T.Dep) -> merge { Local = \(t : Text) -> [t]
                                 , Flake = \(_ : Text) -> [] : List Text } d) ds

let std = \(s : T.CxxStd) -> merge
    { Cxx11 = "-std=c++11", Cxx14 = "-std=c++14", Cxx17 = "-std=c++17"
    , Cxx20 = "-std=c++20", Cxx23 = "-std=c++23" } s

let vis = \(v : T.Vis) -> merge { Public = "[\"PUBLIC\"]", Private = "[]" } v

let Flags = { compiler : List Text, linker : List Text }

let binary
    : C.Binary -> Flags -> Text
    = \(b : C.Binary) -> \(f : Flags) ->
        let cf = [std b.std] # b.cflags # f.compiler
        let lf = b.ldflags # f.linker
        in ''
        cxx_binary(
            name = ${q b.name},
            srcs = ${list b.srcs},
            deps = ${list (locals b.deps)},
            compiler_flags = ${list cf},
            linker_flags = ${list lf},
            visibility = ${vis b.vis},
        )
        ''

let deps = \(b : C.Binary) -> P.Text.concatSep "\n" (flakes b.deps)

in  { q, list, flakes, locals, std, vis, Flags, binary, deps }
