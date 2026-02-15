-- haskell-section.dhall
-- Generate [haskell] section for buckconfig.local

let ghc = env:GHC as Text
let ghc_version = env:GHC_VERSION as Text
let ghc_pkg_wrapper = env:GHC_PKG_WRAPPER as Text
let stan = env:STAN as Text

-- Simply include the values - if empty, buckconfig will handle it

in ''

[haskell]
ghc = ${ghc}/bin/ghc
ghc_pkg = ${ghc}/bin/ghc-pkg
haddock = ${ghc}/bin/haddock
ghc_version = ${ghc_version}
ghc_lib_dir = ${ghc}/lib/ghc-${ghc_version}/lib
global_package_db = ${ghc}/lib/ghc-${ghc_version}/lib/package.conf.d
ghc_pkg_wrapper = ${ghc_pkg_wrapper}
stan = ${stan}
''
