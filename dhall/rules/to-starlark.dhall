--| Render Rule definitions to Starlark .bzl files

let Prelude = ../prelude/Prelude.dhall
let R = ./Rule.dhall

let q = \(t : Text) -> "\"${t}\""

-- ══════════════════════════════════════════════════════════════════════════════
-- Render Load statements
-- ══════════════════════════════════════════════════════════════════════════════

let renderLoad
    : R.Load -> Text
    = \(l : R.Load) ->
        let symbols = Prelude.Text.concatSep ", " (Prelude.List.map Text Text q l.symbols)
        in "load(${q l.bzl}, ${symbols})"

let renderLoads
    : List R.Load -> Text
    = \(loads : List R.Load) ->
        Prelude.Text.concatSep "\n" (Prelude.List.map R.Load Text renderLoad loads)

-- ══════════════════════════════════════════════════════════════════════════════
-- Render Attributes
-- ══════════════════════════════════════════════════════════════════════════════

let renderAttrType
    : R.AttrType -> Text
    = \(t : R.AttrType) ->
        merge
          { String = \(cfg : { default : Optional Text }) ->
              merge { Some = \(d : Text) -> "attrs.string(default = ${q d})"
                    , None = "attrs.string()" } cfg.default
          , StringList = \(_ : {}) -> "attrs.list(attrs.string(), default = [])"
          , Bool = \(cfg : { default : Bool }) ->
              "attrs.bool(default = ${if cfg.default then "True" else "False"})"
          , Int = \(cfg : { default : Integer }) ->
              "attrs.int(default = ${Integer/show cfg.default})"
          , Dep = \(_ : {}) -> "attrs.dep()"
          , DepList = \(_ : {}) -> "attrs.list(attrs.dep(), default = [])"
          , ExecDep = \(cfg : { default : Optional Text }) ->
              merge { Some = \(d : Text) -> "attrs.exec_dep(default = ${q d})"
                    , None = "attrs.exec_dep()" } cfg.default
          , Source = \(_ : {}) -> "attrs.source()"
          , SourceList = \(_ : {}) -> "attrs.list(attrs.source(), default = [])"
          , OptionSource = \(_ : {}) -> "attrs.option(attrs.source(), default = None)"
          , OptionString = \(_ : {}) -> "attrs.option(attrs.string(), default = None)"
          , OptionExecDep = \(cfg : { providers : List Text, default : Optional Text }) ->
              let provs = if Prelude.List.null Text cfg.providers
                          then ""
                          else "providers = [${Prelude.Text.concatSep ", " cfg.providers}], "
              let def = merge { Some = \(d : Text) -> "default = ${q d}"
                              , None = "default = None" } cfg.default
              in "attrs.option(attrs.exec_dep(${provs}), ${def})"
          , Output = \(_ : {}) -> "attrs.output()"
          , Label = \(_ : {}) -> "attrs.label()"
          , StringDict = \(_ : {}) -> "attrs.dict(attrs.string(), attrs.string(), default = {})"
          }
          t

let renderAttr
    : R.Attr -> Text
    = \(a : R.Attr) ->
        "        ${q a.name}: ${renderAttrType a.type},"

let renderAttrs
    : List R.Attr -> Text
    = \(attrs : List R.Attr) ->
        Prelude.Text.concatSep "\n" (Prelude.List.map R.Attr Text renderAttr attrs)

-- ══════════════════════════════════════════════════════════════════════════════
-- Render Providers
-- ══════════════════════════════════════════════════════════════════════════════

let renderProviderField
    : R.ProviderField -> Text
    = \(f : R.ProviderField) ->
        merge
          { Typed = \(tf : { name : Text, type : Text, default : Optional Text }) ->
              let def = merge { Some = \(d : Text) -> ", default = ${d}"
                              , None = "" } tf.default
              in "    ${q tf.name}: provider_field(${tf.type}${def}),"
          , Simple = \(name : Text) -> "    ${q name},"
          }
          f

-- | Check if all fields are simple (list-style)
-- Implemented using fold since Prelude doesn't have List.all
let allSimple
    : List R.ProviderField -> Bool
    = \(fields : List R.ProviderField) ->
        List/fold R.ProviderField fields Bool
          (\(f : R.ProviderField) -> \(acc : Bool) ->
            acc && merge { Typed = \(_ : { name : Text, type : Text, default : Optional Text }) -> False
                         , Simple = \(_ : Text) -> True } f)
          True

-- | Extract simple field names
let simpleFieldName
    : R.ProviderField -> Text
    = \(f : R.ProviderField) ->
        merge { Typed = \(tf : { name : Text, type : Text, default : Optional Text }) -> tf.name
              , Simple = \(name : Text) -> name } f

let renderProvider
    : R.ProviderDef -> Text
    = \(p : R.ProviderDef) ->
        if allSimple p.fields
        then
          -- List-style provider: provider(fields = ["a", "b", "c"])
          let fieldNames = Prelude.List.map R.ProviderField Text simpleFieldName p.fields
          let fieldList = Prelude.Text.concatSep ", " (Prelude.List.map Text Text q fieldNames)
          in "${p.name} = provider(fields = [${fieldList}])"
        else
          -- Dict-style provider with typed fields
          let fields = Prelude.Text.concatSep "\n" 
                (Prelude.List.map R.ProviderField Text renderProviderField p.fields)
          in ''
${p.name} = provider(fields = {
${fields}
})
''

let renderProviders
    : List R.ProviderDef -> Text
    = \(providers : List R.ProviderDef) ->
        Prelude.Text.concatSep "\n" (Prelude.List.map R.ProviderDef Text renderProvider providers)

-- ══════════════════════════════════════════════════════════════════════════════
-- Render Helper Functions
-- ══════════════════════════════════════════════════════════════════════════════

let renderHelper
    : R.HelperFn -> Text
    = \(h : R.HelperFn) ->
        let params = Prelude.Text.concatSep ", " h.params
        let retType = merge { Some = \(t : Text) -> " -> ${t}"
                            , None = "" } h.returnType
        in ''
def ${h.name}(${params})${retType}:
${h.body}
''

let renderHelpers
    : List R.HelperFn -> Text
    = \(helpers : List R.HelperFn) ->
        Prelude.Text.concatSep "\n" (Prelude.List.map R.HelperFn Text renderHelper helpers)

-- ══════════════════════════════════════════════════════════════════════════════
-- Render Rules
-- ══════════════════════════════════════════════════════════════════════════════

let renderRule
    : { impl : R.RuleImpl, attrs : List R.Attr } -> Text
    = \(r : { impl : R.RuleImpl, attrs : List R.Attr }) ->
        let attrs = renderAttrs r.attrs
        let toolchainFlag = if r.impl.is_toolchain 
                            then "\n    is_toolchain_rule = True," 
                            else ""
        in ''
def _${r.impl.name}_impl(ctx: AnalysisContext) -> list[Provider]:
    """${r.impl.doc}"""
${r.impl.body}

${r.impl.name} = rule(
    impl = _${r.impl.name}_impl,
    attrs = {
${attrs}
    },${toolchainFlag}
)
''

-- ══════════════════════════════════════════════════════════════════════════════
-- Render Complete File
-- ══════════════════════════════════════════════════════════════════════════════

let renderBzlFile
    : R.BzlFile -> Text
    = \(f : R.BzlFile) ->
        let loads = renderLoads f.loads
        let providers = renderProviders f.providers
        let helpers = renderHelpers f.helpers
        let rules = Prelude.Text.concatSep "\n" 
              (Prelude.List.map { impl : R.RuleImpl, attrs : List R.Attr } Text renderRule f.rules)
        in ''
# Generated from Dhall - DO NOT EDIT
${f.header}

${loads}

${providers}

${f.globals}

${helpers}

${rules}
''

in  { renderBzlFile, renderRule, renderLoad, renderLoads, renderAttr, renderAttrs
    , renderProvider, renderProviders, renderHelper, renderHelpers, renderAttrType
    }
