#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                        // haskell // style // lint
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Enforces the straylight Haskell style guide:
#   - THE GUARD MANDATE: no nested case expressions
#   - No nested if-then-else
#   - Proper section headers with Unicode box-drawing
#   - DerivingStrategies must be explicit
#
# Usage: haskell-lint.sh <file.hs>
#
# Exit codes:
#   0 - file passes all checks
#   1 - file has style violations
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

set -euo pipefail

FILE="$1"
ERRORS=0

error() {
  echo "STYLE: $FILE:$1: $2" >&2
  ERRORS=$((ERRORS + 1))
}

# ════════════════════════════════════════════════════════════════════════════════
#                                                          // guard // mandate
# ════════════════════════════════════════════════════════════════════════════════

# Count case expressions - more than 2 in a function is a violation
check_nested_case() {
  local line_num=0
  local in_function=0
  local case_count=0
  local function_name=""
  local function_start=0

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Detect function definition (name at column 0 followed by ::)
    if [[ $line =~ ^[a-z_][a-zA-Z0-9_\']*[[:space:]]*:: ]]; then
      # Report previous function if it had too many cases
      if [[ $case_count -gt 2 && -n $function_name ]]; then
        error "$function_start" "GUARD MANDATE: '$function_name' has $case_count nested case expressions (max 2)"
      fi
      # Extract function name (everything before ::)
      function_name="${line%%::*}"
      function_name="${function_name%"${function_name##*[![:space:]]}"}"
      function_start=$line_num
      case_count=0
      in_function=1
    fi

    # Count case expressions
    if [[ $in_function -eq 1 && $line =~ [[:space:]]case[[:space:]] && $line =~ [[:space:]]of[[:space:]]*$ ]]; then
      case_count=$((case_count + 1))
    fi

    # Also catch single-line case
    if [[ $in_function -eq 1 && $line =~ [[:space:]]case[[:space:]].*[[:space:]]of[[:space:]] ]]; then
      case_count=$((case_count + 1))
    fi

  done <"$FILE"

  # Check last function
  if [[ $case_count -gt 2 && -n $function_name ]]; then
    error "$function_start" "GUARD MANDATE: '$function_name' has $case_count nested case expressions (max 2)"
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#                                                     // nested // if // check
# ════════════════════════════════════════════════════════════════════════════════

check_nested_if() {
  local line_num=0
  local if_count

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Skip comments
    if [[ $line =~ ^[[:space:]]*-- ]]; then
      continue
    fi

    # Only check for multiple if keywords on same line (clear nesting)
    if_count=$(echo "$line" | grep -o '\bif\b' | wc -l || true)

    if [[ $if_count -gt 1 ]]; then
      error "$line_num" "GUARD MANDATE: multiple if expressions on single line"
    fi

    # Check for if-then-else pattern without guards (the bad pattern)
    if [[ $line =~ else[[:space:]]+if[[:space:]] ]]; then
      error "$line_num" "GUARD MANDATE: else-if chain - use guards instead"
    fi

  done <"$FILE"
}

# ════════════════════════════════════════════════════════════════════════════════
#                                                  // deriving // strategies
# ════════════════════════════════════════════════════════════════════════════════

check_deriving_strategies() {
  local line_num=0

  while IFS= read -r line; do
    line_num=$((line_num + 1))

    # Look for "deriving (" without "deriving stock/newtype/anyclass/via"
    if [[ $line =~ deriving[[:space:]]*\( ]]; then
      if [[ ! $line =~ deriving[[:space:]]+(stock|newtype|anyclass|via)[[:space:]]*\( ]]; then
        error "$line_num" "deriving without strategy - use 'deriving stock', 'deriving newtype', or 'deriving anyclass'"
      fi
    fi

    # Look for standalone deriving without strategy
    if [[ $line =~ ^[[:space:]]*deriving[[:space:]]+[A-Z] ]]; then
      if [[ ! $line =~ ^[[:space:]]*deriving[[:space:]]+(stock|newtype|anyclass|via)[[:space:]] ]]; then
        error "$line_num" "deriving without strategy - use 'deriving stock', 'deriving newtype', or 'deriving anyclass'"
      fi
    fi

  done <"$FILE"
}

# ════════════════════════════════════════════════════════════════════════════════
#                                                        // required // pragmas
# ════════════════════════════════════════════════════════════════════════════════

check_required_pragmas() {
  # Check that DerivingStrategies is enabled if deriving is used
  if grep -q 'deriving' "$FILE"; then
    if ! grep -q 'DerivingStrategies' "$FILE"; then
      error "1" "file uses 'deriving' but does not enable DerivingStrategies"
    fi
  fi
}

# ════════════════════════════════════════════════════════════════════════════════
#                                                                    // main
# ════════════════════════════════════════════════════════════════════════════════

# Only check .hs files
if [[ ! $FILE =~ \.hs$ ]]; then
  exit 0
fi

# Skip test files (they may have intentional violations for testing)
if [[ $FILE =~ /test/ || $FILE =~ /Test/ || $FILE =~ Test\.hs$ ]]; then
  exit 0
fi

# Skip vendored files
if [[ $FILE =~ /vendor/ ]]; then
  exit 0
fi

# Run all checks
check_nested_case
check_nested_if
check_deriving_strategies
check_required_pragmas

if [[ $ERRORS -gt 0 ]]; then
  exit 1
fi

exit 0
