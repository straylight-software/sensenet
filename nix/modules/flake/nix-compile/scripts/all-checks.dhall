-- all-checks.dhall
-- Script for combining all checks

let check_nix = env:CHECK_NIX as Text
let check_dhall = env:CHECK_DHALL as Text
let check_cross_lang = env:CHECK_CROSS_LANG as Text
let check_buck2_graph = env:CHECK_BUCK2_GRAPH as Text
let check_proofs = env:CHECK_PROOFS as Text
let verify_dhall = env:VERIFY_DHALL as Text
let cross_language = env:CROSS_LANGUAGE as Text
let buck2_graph = env:BUCK2_GRAPH as Text
let verify_proofs = env:VERIFY_PROOFS as Text

let dhallLink = if verify_dhall == "1" then "ln -s ${check_dhall} $out/dhall" else ""
let crossLangLink = if cross_language == "1" then "ln -s ${check_cross_lang} $out/cross-language" else ""
let buck2GraphLink = if buck2_graph == "1" then "ln -s ${check_buck2_graph} $out/buck2-graph" else ""
let proofsLink = if verify_proofs == "1" then "ln -s ${check_proofs} $out/proofs" else ""

in ''
echo "sense/net: all checks passed"
mkdir -p $out
ln -s ${check_nix} $out/nix-compile
${dhallLink}
${crossLangLink}
${buck2GraphLink}
${proofsLink}
''
