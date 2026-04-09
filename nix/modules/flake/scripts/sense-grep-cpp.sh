# nix/modules/flake/scripts/sense-grep-cpp.sh
#
# ast-grep wrapper for C++ linting with sense rules.
# Runs each cpp-*.yml rule and exits on first failure.
#
# Environment variables (substituted by Nix):
#   RULES_DIR    - path to linter/rules directory
#   AST_GREP_BIN - path to ast-grep binary
#
# Some rules are header-only (cpp-using-namespace-header).
# We filter the file list accordingly.

exit_code=0

# Separate files into headers vs all
headers=()
all_files=()
for f in "$@"; do
  all_files+=("$f")
  case "$f" in
  *.h | *.hpp | *.hh | *.hxx | *.cuh)
    headers+=("$f")
    ;;
  esac
done

for rule in "$RULES_DIR"/cpp-*.yml; do
  if [[ -f $rule ]]; then
    rule_name=$(basename "$rule" .yml)

    # Header-only rules
    if [[ $rule_name == "cpp-using-namespace-header" ]]; then
      if [[ ${#headers[@]} -gt 0 ]]; then
        "$AST_GREP_BIN" scan --rule "$rule" "${headers[@]}" || exit_code=1
      fi
    else
      # All C++ files
      if [[ ${#all_files[@]} -gt 0 ]]; then
        "$AST_GREP_BIN" scan --rule "$rule" "${all_files[@]}" || exit_code=1
      fi
    fi
  fi
done

exit $exit_code
