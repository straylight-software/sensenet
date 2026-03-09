-- buckconfig-haskell.dhall
-- Generate [haskell] section for .buckconfig.local
--
-- Environment variables:
--   GHC, GHC_PKG, HADDOCK
--   GHC_VERSION, GHC_LIB_DIR, GLOBAL_PACKAGE_DB

let ghc = env:GHC as Text
let ghc_pkg = env:GHC_PKG as Text
let haddock = env:HADDOCK as Text
let ghc_version = env:GHC_VERSION as Text
let ghc_lib_dir = env:GHC_LIB_DIR as Text
let global_package_db = env:GLOBAL_PACKAGE_DB as Text

in ''
[haskell]
# GHC with packages from Nix (ghcWithPackages)
ghc = ${ghc}
ghc_pkg = ${ghc_pkg}
haddock = ${haddock}
ghc_version = ${ghc_version}
ghc_lib_dir = ${ghc_lib_dir}
global_package_db = ${global_package_db}
''
