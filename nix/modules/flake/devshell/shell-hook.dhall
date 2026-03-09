-- shell-hook.dhall
-- Shell hook script for devshell

let ghc_with_all_deps = env:GHC_WITH_ALL_DEPS as Text
let straylight_nix_check = env:STRAYLIGHT_NIX_CHECK as Text
let buckconfig_hook = env:BUCKCONFIG_HOOK as Text
let build_shell_hook = env:BUILD_SHELL_HOOK as Text
let shortlist_shell_hook = env:SHORTLIST_SHELL_HOOK as Text
let lre_shell_hook = env:LRE_SHELL_HOOK as Text
let hie_yaml_hook = env:HIE_YAML_HOOK as Text
let extra_shell_hook = env:EXTRA_SHELL_HOOK as Text

in ''
echo "━━━ sense devshell ━━━"
echo "GHC: $(${ghc_with_all_deps}/bin/ghc --version)"
${straylight_nix_check}
${buckconfig_hook}
# Add sense CLI to PATH (bootstrap binary in repo root)
export PATH="$PWD:$PATH"
${build_shell_hook}
${shortlist_shell_hook}
${lre_shell_hook}
${hie_yaml_hook}
${extra_shell_hook}
''
