#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                       // test // sensenet //
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#     "He'd operated on an almost permanent adrenaline high, a byproduct of
#      youth and proficiency, jacked into a custom cyberspace deck that
#      projected his disembodied consciousness into the consensual
#      hallucination that was the matrix."
#
#                                                               — Neuromancer
#
# Test runner for sense/net + nix-compile integration.
#
# USAGE:
#   ./test/sensenet/run-tests.sh           # run all tests
#   ./test/sensenet/run-tests.sh --bless   # regenerate expected outputs
#   ./test/sensenet/run-tests.sh --verbose # show all output
#
# EXIT CODES:
#   0 - all tests passed (or expected failures)
#   1 - unexpected failure
#   2 - test infrastructure error
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0
EXPECTED_FAIL=0
SKIPPED=0

# Options
BLESS=false
VERBOSE=false

# ════════════════════════════════════════════════════════════════════════════════
# Helpers
# ════════════════════════════════════════════════════════════════════════════════

log() { echo -e "${BLUE}[sense/net]${NC} $*"; }
pass() { echo -e "${GREEN}[PASS]${NC} $*"; ((PASSED++)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; ((FAILED++)); }
xfail() { echo -e "${YELLOW}[XFAIL]${NC} $*"; ((EXPECTED_FAIL++)); }
skip() { echo -e "${YELLOW}[SKIP]${NC} $*"; ((SKIPPED++)); }

check_command() {
    if ! command -v "$1" &>/dev/null; then
        skip "$2: $1 not found"
        return 1
    fi
    return 0
}

# ════════════════════════════════════════════════════════════════════════════════
# Test: Dhall type checking
# ════════════════════════════════════════════════════════════════════════════════

test_dhall_typecheck() {
    log "Testing Dhall type checking..."
    
    check_command dhall "dhall-typecheck" || return 0
    
    local dhall_files=(
        "$PROJECT_ROOT/dhall/Resource.dhall"
        "$PROJECT_ROOT/dhall/DischargeProof.dhall"
        "$PROJECT_ROOT/dhall/Toolchain.dhall"
        "$PROJECT_ROOT/dhall/Build.dhall"
        "$PROJECT_ROOT/dhall/package.dhall"
    )
    
    for f in "${dhall_files[@]}"; do
        if [[ -f "$f" ]]; then
            if dhall --file "$f" >/dev/null 2>&1; then
                pass "dhall typecheck: $(basename "$f")"
            else
                fail "dhall typecheck: $(basename "$f")"
            fi
        else
            skip "dhall typecheck: $(basename "$f") (file not found)"
        fi
    done
}

# ════════════════════════════════════════════════════════════════════════════════
# Test: Proof obligations
# ════════════════════════════════════════════════════════════════════════════════

test_proof_obligations() {
    log "Testing proof obligations..."
    
    check_command dhall "proof-obligations" || return 0
    
    local test_file="$SCRIPT_DIR/proof-obligations.dhall"
    
    if [[ -f "$test_file" ]]; then
        if dhall --file "$test_file" >/dev/null 2>&1; then
            pass "proof-obligations: Dhall type check"
        else
            fail "proof-obligations: Dhall type check"
        fi
        
        # Expected failure: Lean4 verification not implemented
        xfail "proof-obligations: Lean4 verification (not implemented)"
    else
        skip "proof-obligations: test file not found"
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Test: nix-compile integration
# ════════════════════════════════════════════════════════════════════════════════

test_nix_compile() {
    log "Testing nix-compile integration..."
    
    check_command nix-compile "nix-compile" || {
        xfail "nix-compile: binary not in PATH (expected, run from devshell)"
        return 0
    }
    
    # Test toolchain types
    local toolchain_test="$SCRIPT_DIR/toolchain-types.nix"
    if [[ -f "$toolchain_test" ]]; then
        # This should parse but type inference will be incomplete
        if nix-compile --parse "$toolchain_test" >/dev/null 2>&1; then
            pass "nix-compile: parse toolchain-types.nix"
        else
            fail "nix-compile: parse toolchain-types.nix"
        fi
        
        # Expected failure: cross-file inference not implemented
        xfail "nix-compile: full type inference (cross-file not implemented)"
    fi
    
    # Test cross-language
    local cross_test="$SCRIPT_DIR/cross-language.nix"
    if [[ -f "$cross_test" ]]; then
        if nix-compile --parse "$cross_test" >/dev/null 2>&1; then
            pass "nix-compile: parse cross-language.nix"
        else
            fail "nix-compile: parse cross-language.nix"
        fi
        
        # Expected failure: cross-language report not implemented
        xfail "nix-compile: --cross-lang-report (not implemented)"
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Test: Build graph analysis
# ════════════════════════════════════════════════════════════════════════════════

test_build_graph() {
    log "Testing build graph analysis..."
    
    check_command dhall "build-graph" || return 0
    
    local test_file="$SCRIPT_DIR/build-graph.dhall"
    
    if [[ -f "$test_file" ]]; then
        if dhall --file "$test_file" >/dev/null 2>&1; then
            pass "build-graph: Dhall type check"
        else
            fail "build-graph: Dhall type check"
        fi
        
        # Expected failures
        xfail "build-graph: coeffect propagation (not implemented)"
        xfail "build-graph: proof generation (not implemented)"
        xfail "build-graph: Lean4 verification (not implemented)"
    else
        skip "build-graph: test file not found"
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Test: Flake module
# ════════════════════════════════════════════════════════════════════════════════

test_flake_module() {
    log "Testing flake module..."
    
    local module_file="$PROJECT_ROOT/nix/modules/flake/nix-compile/default.nix"
    
    if [[ -f "$module_file" ]]; then
        pass "flake-module: file exists"
        
        # Check it's valid Nix
        if nix-instantiate --parse "$module_file" >/dev/null 2>&1; then
            pass "flake-module: valid Nix syntax"
        else
            fail "flake-module: invalid Nix syntax"
        fi
    else
        fail "flake-module: file not found"
    fi
}

# ════════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════════

main() {
    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bless) BLESS=true; shift ;;
            --verbose) VERBOSE=true; shift ;;
            *) echo "Unknown option: $1"; exit 2 ;;
        esac
    done
    
    log "sense/net test suite"
    log "===================="
    echo
    
    # Run tests
    test_dhall_typecheck
    echo
    test_proof_obligations
    echo
    test_nix_compile
    echo
    test_build_graph
    echo
    test_flake_module
    echo
    
    # Summary
    log "===================="
    log "Results:"
    echo -e "  ${GREEN}Passed:${NC}          $PASSED"
    echo -e "  ${RED}Failed:${NC}          $FAILED"
    echo -e "  ${YELLOW}Expected fail:${NC}   $EXPECTED_FAIL"
    echo -e "  ${YELLOW}Skipped:${NC}         $SKIPPED"
    echo
    
    if [[ $FAILED -gt 0 ]]; then
        log "Some tests failed unexpectedly"
        exit 1
    fi
    
    if [[ $EXPECTED_FAIL -gt 0 ]]; then
        log "All tests passed (with $EXPECTED_FAIL expected failures)"
        log "Expected failures indicate work-in-progress features"
    else
        log "All tests passed"
    fi
    
    exit 0
}

main "$@"
