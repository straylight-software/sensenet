--| Rule implementation DSL
--|
--| Generates .bzl rule implementations from Dhall.
--|
--| Approach: Generate structure (loads, attrs, rule def) from Dhall,
--| but allow embedding raw starlark for complex impl bodies.

let Prelude = ../prelude/Prelude.dhall

-- ══════════════════════════════════════════════════════════════════════════════
-- Core Types
-- ══════════════════════════════════════════════════════════════════════════════

-- | Attribute type
let AttrType =
      < String : { default : Optional Text }
      | StringList : {}
      | Bool : { default : Bool }
      | Int : { default : Integer }
      | Dep : {}
      | DepList : {}
      | ExecDep : { default : Optional Text }  -- Default is a target label
      | Source : {}
      | SourceList : {}
      | OptionSource : {}
      | OptionString : {}  -- attrs.option(attrs.string(), default = None)
      | OptionExecDep : { providers : List Text, default : Optional Text }
      | Output : {}
      | Label : {}
      | StringDict : {}  -- attrs.dict(attrs.string(), attrs.string(), default = {})
      >

-- | Attribute definition
let Attr =
      { name : Text
      , type : AttrType
      , doc : Text
      }

-- | Load statement
let Load =
      { bzl : Text
      , symbols : List Text
      }

-- | Provider field - either typed (with provider_field) or simple (just name)
let ProviderField =
      < Typed : { name : Text, type : Text, default : Optional Text }
      | Simple : Text  -- Just the field name (for list-style providers)
      >

-- | Provider definition
let ProviderDef =
      { name : Text
      , fields : List ProviderField
      }

-- | Helper function definition
let HelperFn =
      { name : Text
      , params : List Text
      , returnType : Optional Text
      , body : Text  -- Raw starlark
      }

-- | Rule implementation - raw starlark body
let RuleImpl =
      { name : Text
      , doc : Text
      , body : Text  -- Raw starlark implementation
      , is_toolchain : Bool
      }

-- | Complete .bzl file
let BzlFile =
      { header : Text
      , loads : List Load
      , globals : Text  -- Raw starlark for constants, config helpers, etc. (before providers)
      , providers : List ProviderDef
      , helpers : List HelperFn
      , rules : List { impl : RuleImpl, attrs : List Attr }
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- Constructors
-- ══════════════════════════════════════════════════════════════════════════════

let attr =
      \(name : Text) ->
      \(type : AttrType) ->
        { name, type, doc = "" }

let stringAttr = 
      \(name : Text) -> 
      \(default : Optional Text) ->
        attr name (AttrType.String { default })

let stringListAttr = \(name : Text) -> attr name (AttrType.StringList {=})
let boolAttr = \(name : Text) -> \(default : Bool) -> attr name (AttrType.Bool { default })
let sourceListAttr = \(name : Text) -> attr name (AttrType.SourceList {=})
let depListAttr = \(name : Text) -> attr name (AttrType.DepList {=})
let optionStringAttr = \(name : Text) -> attr name (AttrType.OptionString {=})
let stringDictAttr = \(name : Text) -> attr name (AttrType.StringDict {=})

let load =
      \(bzl : Text) ->
      \(symbols : List Text) ->
        { bzl, symbols }

let provider =
      \(name : Text) ->
        { name, fields = [] : List ProviderField }

-- | Provider with simple string fields (list-style)
let simpleProvider =
      \(name : Text) ->
      \(fields : List Text) ->
        { name, fields = Prelude.List.map Text ProviderField ProviderField.Simple fields }

-- | Typed provider field (for dict-style providers)
let typedField =
      \(name : Text) ->
      \(type : Text) ->
        ProviderField.Typed { name, type, default = None Text }

-- | Typed provider field with default value
let typedFieldDefault =
      \(name : Text) ->
      \(type : Text) ->
      \(default : Text) ->
        ProviderField.Typed { name, type, default = Some default }

-- | Provider with typed fields (dict-style)
let typedProvider =
      \(name : Text) ->
      \(fields : List ProviderField) ->
        { name, fields }

let helper =
      \(name : Text) ->
      \(params : List Text) ->
      \(body : Text) ->
        { name, params, returnType = None Text, body }

let ruleImpl =
      \(name : Text) ->
      \(body : Text) ->
        { name, doc = "", body, is_toolchain = False }

let bzlFile =
      { header = ""
      , loads = [] : List Load
      , globals = ""
      , providers = [] : List ProviderDef
      , helpers = [] : List HelperFn
      , rules = [] : List { impl : RuleImpl, attrs : List Attr }
      }

in  { -- Types
      AttrType, Attr, Load, ProviderDef, ProviderField, HelperFn, RuleImpl, BzlFile
      -- Constructors
    , attr, stringAttr, stringListAttr, boolAttr, sourceListAttr, depListAttr
    , optionStringAttr, stringDictAttr
    , load, provider, simpleProvider, typedProvider, typedField, typedFieldDefault
    , helper, ruleImpl, bzlFile
    }
