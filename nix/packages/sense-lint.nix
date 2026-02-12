# nix/packages/sense-lint.nix
#
# AST-grep wrapper for Nix linting with sense rules.
#
{ pkgs, lib }:
let
  linter-src = ../../linter;

  sgconfig = pkgs.writeText "sgconfig.yaml" ''
    ruleDirs:
      - ${linter-src}/rules
  '';

  script = pkgs.writeText "sense-lint.bash" ''
    # sense-lint wrapper script
    SGCONFIG_TMP="$(mktemp -t sense-lint-XXXXXX.yml)"
    cp --no-preserve=mode "${sgconfig}" "$SGCONFIG_TMP"
    trap 'rm -f "$SGCONFIG_TMP"' EXIT

    declare -a REL_ARGS=()
    for arg in "$@"; do
      if [[ $arg == /* ]] && [[ -f $arg ]]; then
        REL_ARGS+=("$(realpath --relative-to=. "$arg")")
      else
        REL_ARGS+=("$arg")
      fi
    done

    exec "${lib.getExe pkgs.ast-grep}" \
      --config "$SGCONFIG_TMP" \
      scan \
      --context 2 \
      --color always \
      "''${REL_ARGS[@]}"
  '';
in
pkgs.writeShellApplication {
  name = "sense-lint";
  runtimeInputs = [
    pkgs.ast-grep
    pkgs.coreutils
  ];
  text = builtins.readFile script;
}
