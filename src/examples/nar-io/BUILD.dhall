--| Nar.io - Nix Binary Cache Landing Site
--|
--| Cachix killer. 10x cheaper, faster, actually maintained.
--| PureScript Halogen SPA with straylight aesthetic.

let A = ../../../dhall/prelude/package.dhall
let S = ../../../dhall/prelude/to-starlark.dhall

let narIo =
      (A.purescriptApp "nar-io" (A.SrcSpec.Globs ["src/**/*.purs", "src/**/*.js"]) "spago.yaml")
        with spago_lock = Some "spago.lock"
        with main = "Main"
        with index_html = None Text
        with style_css = None Text

in  { rules = [ S.purescriptApp narIo ]
    , header = ''
        load("@toolchains//:purescript.bzl", "purescript_app")
        ''
    }
