#!/usr/bin/env bash
# test/stan/test-stan.sh - Test Stan integration with SENSENET

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

test_file() {
  local file="$1" pattern="$2" msg="$3"
  if [[ -f $file ]] && grep -q "$pattern" "$file"; then
    echo -e "${GREEN}✓${NC} $msg"
  else
    echo -e "${RED}✗${NC} $msg"
    exit 1
  fi
}

echo "Testing Stan integration..."
echo ""

# Require stan binary
if ! command -v stan &>/dev/null; then
  echo -e "${YELLOW}Warning: stan not found in PATH${NC}"
  echo "This test requires running from nix develop shell"
  exit 1
fi

# Tests
test_file "${PROJECT_ROOT}/toolchains/haskell.bzl" "_run_stan_analysis" "_run_stan_analysis function"
test_file "${PROJECT_ROOT}/toolchains/haskell.bzl" "stan_config" "stan_config attribute"
test_file "${PROJECT_ROOT}/dhall/prelude/Haskell.dhall" "StanConfig" "StanConfig type"
test_file "${PROJECT_ROOT}/dhall/prelude/Haskell.dhall" "stan : Optional StanConfig" "stan field in types"
test_file "${PROJECT_ROOT}/dhall/prelude/to-starlark.dhall" "stanConfig" "stanConfig rendering"
test_file "${PROJECT_ROOT}/src/sense/Main.hs" '"stan"' "stan command"
test_file "${PROJECT_ROOT}/src/sense/Main.hs" "cmdStan" "cmdStan function"
test_file "${PROJECT_ROOT}/flake.nix" "hp.stan" "stan in flake.nix"

# Check .buckconfig.local
if [[ -f "${PROJECT_ROOT}/.buckconfig.local" ]] && grep -q "^stan =" "${PROJECT_ROOT}/.buckconfig.local"; then
  echo -e "${GREEN}✓${NC} Stan configured in .buckconfig.local"
else
  echo -e "${YELLOW}⚠${NC} Stan not in .buckconfig.local (expected if not in nix shell)"
fi

echo ""
echo -e "${GREEN}All tests passed!${NC}"
echo ""
echo "To test the full integration:"
echo "  nix develop"
echo "  sense build //src/examples/haskell:hello-hs"
echo "  sense stan //src/examples/haskell:hello-hs"
echo ""
