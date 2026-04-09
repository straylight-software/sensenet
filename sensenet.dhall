-- SENSE // NET Project Configuration
--
-- Project-level configuration. sensenet reads this and generates
-- all Buck2 artifacts (toolchains, prelude, BUCK files) into a tmpdir.

{ name = "sensenet"
, toolchains =
    { cxx = True
    , haskell = True
    , rust = True
    , lean = True
    , purescript = True
    , nv = True
    }
}
