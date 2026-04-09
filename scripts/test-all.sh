#!/usr/bin/env bash
# Norman Stansfield Test Suite for sensenet
# NO SURVIVORS - comprehensive integration tests

# If SENSENET_QUICK_TEST is set, only run CLI tests (for nix sandbox)
QUICK_TEST="${SENSENET_QUICK_TEST:-}"

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASS=0
FAIL=0
TESTS=()

# Helper functions
pass() {
  echo -e "${GREEN}PASS${NC}: $1"
  PASS=$((PASS + 1))
  TESTS+=("PASS: $1")
}

fail() {
  echo -e "${RED}FAIL${NC}: $1"
  echo "  Error: $2"
  FAIL=$((FAIL + 1))
  TESTS+=("FAIL: $1")
}

section() {
  echo ""
  echo -e "${YELLOW}=== $1 ===${NC}"
}

# Ensure we're in the right directory
cd "$(dirname "$0")/.."

# Ensure sense binary exists
if [ ! -x "./sense" ]; then
  echo "Building sensenet..."
  nix build .#sensenet && cp result/bin/sensenet ./sense
fi

section "CLI Tests"

# Test --version
if ./sense --version 2>&1 | grep -q "sensenet"; then
  pass "--version returns sensenet info"
else
  fail "--version" "did not contain 'sensenet'"
fi

# Test --help
if ./sense --help 2>&1 | grep -qi "usage\|command\|build"; then
  pass "--help shows usage info"
else
  fail "--help" "did not show usage info"
fi

# If quick test mode, skip build tests (for nix sandbox without toolchains)
if [ -n "$QUICK_TEST" ]; then
  section "Summary (Quick Mode)"
  echo ""
  echo "========================================"
  echo -e "Total: $((PASS + FAIL)) tests (quick mode)"
  echo -e "${GREEN}Passed: $PASS${NC}"
  echo -e "${RED}Failed: $FAIL${NC}"
  echo "========================================"
  if [ $FAIL -gt 0 ]; then
    exit 1
  fi
  echo -e "${GREEN}Quick tests passed.${NC}"
  exit 0
fi

section "Single Target Builds"

# C++ build
./sense build --no-tui //src/examples/cxx:hello-cxx >/dev/null 2>&1
if [ -x "sensenet-out/src/examples/cxx/hello-cxx" ]; then
  pass "C++ target builds"
else
  fail "C++ target" "output not found"
fi

# C++ binary runs
if ./sensenet-out/src/examples/cxx/hello-cxx 2>&1 | grep -qi "straylight\|operational"; then
  pass "C++ binary runs correctly"
else
  fail "C++ binary" "output incorrect"
fi

# Rust build
./sense build --no-tui //src/examples/rust:hello-rs >/dev/null 2>&1
if [ -x "sensenet-out/src/examples/rust/hello-rs" ]; then
  pass "Rust target builds"
else
  fail "Rust target" "output not found"
fi

# Rust binary runs
if ./sensenet-out/src/examples/rust/hello-rs 2>&1 | grep -qi "rust\|operational"; then
  pass "Rust binary runs correctly"
else
  fail "Rust binary" "output incorrect"
fi

# Haskell build
./sense build --no-tui //src/examples/haskell:hello-hs >/dev/null 2>&1
if [ -x "sensenet-out/src/examples/haskell/hello-hs" ]; then
  pass "Haskell target builds"
else
  fail "Haskell target" "output not found"
fi

# Haskell binary runs
if ./sensenet-out/src/examples/haskell/hello-hs 2>&1 | grep -qi "haskell\|hello"; then
  pass "Haskell binary runs correctly"
else
  fail "Haskell binary" "output incorrect"
fi

section "Multi-Target Builds"

# Build 2 targets
OUTPUT=$(./sense build --no-tui //src/examples/cxx:hello-cxx //src/examples/rust:hello-rs 2>&1)
if echo "$OUTPUT" | grep -q "2 targets"; then
  pass "2 targets: correct count reported"
else
  fail "2 targets" "count not reported correctly"
fi

# Build 3 targets
OUTPUT=$(./sense build --no-tui //src/examples/cxx:hello-cxx //src/examples/rust:hello-rs //src/examples/haskell:hello-hs 2>&1)
if echo "$OUTPUT" | grep -q "3 targets"; then
  pass "3 targets: correct count reported"
else
  fail "3 targets" "count not reported correctly (got: $OUTPUT)"
fi

section "Error Handling"

# Nonexistent target
if ! ./sense build --no-tui //nonexistent:target >/dev/null 2>&1; then
  pass "Nonexistent target fails gracefully"
else
  fail "Nonexistent target" "should have failed"
fi

# Nonexistent package
if ! ./sense build --no-tui //totally/fake/path:target >/dev/null 2>&1; then
  pass "Nonexistent package fails gracefully"
else
  fail "Nonexistent package" "should have failed"
fi

section "Stub Mode"

# Stub mode works
OUTPUT=$(./sense build --stub //src/sensenet/... 2>&1)
if echo "$OUTPUT" | grep -q "\[stub\]"; then
  pass "--stub mode runs"
else
  fail "--stub mode" "did not show [stub] markers"
fi

section "TUI Fallback"

# Piped output should not contain TUI escape sequences
OUTPUT=$(./sense build //src/examples/cxx:hello-cxx 2>&1)
if echo "$OUTPUT" | grep -q $'\x1b\[?1049h'; then
  fail "TUI fallback" "TUI escape sequences in piped output"
else
  pass "TUI fallback: no escape sequences in piped output"
fi

section "Wildcard Expansion"

# Build //pkg/...
OUTPUT=$(./sense build --no-tui //src/examples/cxx/... 2>&1)
if echo "$OUTPUT" | grep -qi "built\|target"; then
  pass "Wildcard //pkg/... expands"
else
  fail "Wildcard expansion" "did not build targets"
fi

section "Summary"

echo ""
echo "========================================"
echo -e "Total: $((PASS + FAIL)) tests"
echo -e "${GREEN}Passed: $PASS${NC}"
echo -e "${RED}Failed: $FAIL${NC}"
echo "========================================"

if [ $FAIL -gt 0 ]; then
  echo ""
  echo "Failed tests:"
  for test in "${TESTS[@]}"; do
    if [[ $test == FAIL* ]]; then
      echo "  - ${test#FAIL: }"
    fi
  done
  exit 1
fi

echo ""
echo -e "${GREEN}All tests passed. No survivors.${NC}"
exit 0
