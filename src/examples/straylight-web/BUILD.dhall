--| Straylight Web - PureScript Halogen SPA (new format)
--|
--| Demonstrates:
--|   - Real-world Halogen application
--|   - Multiple components and pages
--|   - FFI with JavaScript
--|   - Router integration
--|
--| This example proves the PureScript Buck2 toolchain works with
--| a non-trivial Halogen application from straylight.software.

let A = ../../../dhall/prelude/package.dhall

-- deps from spago.yaml: halogen, halogen-vdom, effect, prelude, etc.
let straylightWeb =
      (A.purescriptApp "straylight-web" (A.SrcSpec.Globs ["src/**/*.purs", "src/**/*.js"]) 
        ["halogen", "halogen-vdom", "effect", "prelude", "aff", "web-html", "web-dom"])
        with main = "Main"
        with index_html = None Text
        with style_css = None Text

in  { targets = [ A.rule.purescriptApp straylightWeb ] }
