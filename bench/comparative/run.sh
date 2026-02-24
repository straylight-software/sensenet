#!/usr/bin/env bash
# Benchmark sensenet vs Buck2
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS_FILE="$SCRIPT_DIR/RESULTS.md"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}▸${NC} $1"; }
ok() { echo -e "${GREEN}✓${NC} $1"; }
err() { echo -e "${RED}✗${NC} $1"; }

# ════════════════════════════════════════════════════════════════════════════
# Timing helper (using awk instead of bc)
# ════════════════════════════════════════════════════════════════════════════

time_cmd() {
	local start end
	start=$(date +%s.%N)
	"$@" >/dev/null 2>&1
	end=$(date +%s.%N)
	awk "BEGIN {printf \"%.6f\", $end - $start}"
}

time_cmd_ms() {
	local elapsed
	elapsed=$(time_cmd "$@")
	awk "BEGIN {printf \"%d ms\", $elapsed * 1000}"
}

# Add helper function for averaging
avg_time() {
	local sum=$1 count=$2
	awk "BEGIN {printf \"%.3f\", $sum / $count}"
}

# ════════════════════════════════════════════════════════════════════════════
# Benchmarks
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║         sensenet vs Buck2 Comparative Benchmarks                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# Check dependencies
log "Checking dependencies..."
command -v buck2 >/dev/null 2>&1 || {
	err "buck2 not found"
	exit 1
}
command -v dhall >/dev/null 2>&1 || {
	err "dhall not found"
	exit 1
}
command -v hyperfine >/dev/null 2>&1 && HAS_HYPERFINE=1 || HAS_HYPERFINE=0
ok "buck2: $(buck2 --version 2>&1 | head -1)"
ok "dhall: $(dhall --version 2>&1 | head -1)"
[ "$HAS_HYPERFINE" -eq 1 ] && ok "hyperfine: available" || log "hyperfine: not found (using basic timing)"

# Start results file
cat >"$RESULTS_FILE" <<EOF
# Benchmark Results

Generated: $(date -Iseconds)

## Environment
EOF
echo "- buck2: $(buck2 --version 2>&1 | head -1)" >>"$RESULTS_FILE"
echo "- dhall: $(dhall --version 2>&1 | head -1)" >>"$RESULTS_FILE"
echo "- CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)" >>"$RESULTS_FILE"
echo "" >>"$RESULTS_FILE"

# ════════════════════════════════════════════════════════════════════════════
# Benchmark 1: Dhall evaluation speed
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo "┌──────────────────────────────────────────────────────────────────┐"
echo "│ 1. DHALL EVALUATION SPEED                                        │"
echo "└──────────────────────────────────────────────────────────────────┘"
echo ""

cat >>"$RESULTS_FILE" <<'EOF'
## 1. Dhall Evaluation Speed

How fast can we render BUILD.dhall → IR?

EOF

# Test with existing example
EXAMPLE_DIR="$REPO_ROOT/src/examples/cxx"
if [ -f "$EXAMPLE_DIR/BUILD.dhall" ]; then
	log "Testing Dhall evaluation on $EXAMPLE_DIR/BUILD.dhall"

	# Warm up dhall cache
	dhall --file "$EXAMPLE_DIR/BUILD.dhall" >/dev/null 2>&1 || true

	if [ "$HAS_HYPERFINE" -eq 1 ]; then
		hyperfine --warmup 3 --min-runs 10 \
			"dhall --file $EXAMPLE_DIR/BUILD.dhall" \
			2>&1 | tee -a "$RESULTS_FILE"
	else
		log "Running 10 iterations..."
		total=0
		for i in $(seq 1 10); do
			t=$(time_cmd dhall --file "$EXAMPLE_DIR/BUILD.dhall")
			total=$(awk "BEGIN {printf \"%.6f\", $total + $t}")
		done
		avg=$(awk "BEGIN {printf \"%.3f\", $total / 10}")
		echo "  Average: ${avg}s per evaluation" | tee -a "$RESULTS_FILE"
	fi
else
	err "No BUILD.dhall found at $EXAMPLE_DIR"
fi

# ════════════════════════════════════════════════════════════════════════════
# Benchmark 2: to-buck2.dhall rendering
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo "┌──────────────────────────────────────────────────────────────────┐"
echo "│ 2. DHALL → BUCK RENDERING                                        │"
echo "└──────────────────────────────────────────────────────────────────┘"
echo ""

cat >>"$RESULTS_FILE" <<'EOF'

## 2. Dhall → BUCK Rendering

Time to generate BUCK file from BUILD.dhall.

EOF

TO_BUCK2="$REPO_ROOT/dhall/to-buck2.dhall"
if [ -f "$TO_BUCK2" ]; then
	log "Testing to-buck2.dhall rendering"

	# This requires a proper Target, not a Package - skip if format doesn't match
	log "Skipping to-buck2 direct test (requires Target type, not Package)"
	echo "Skipped: to-buck2.dhall expects Target type" >>"$RESULTS_FILE"
else
	err "to-buck2.dhall not found"
fi

# ════════════════════════════════════════════════════════════════════════════
# Benchmark 3: Buck2 analysis time
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo "┌──────────────────────────────────────────────────────────────────┐"
echo "│ 3. BUCK2 ANALYSIS TIME                                           │"
echo "└──────────────────────────────────────────────────────────────────┘"
echo ""

cat >>"$RESULTS_FILE" <<'EOF'

## 3. Buck2 Analysis Time

How fast can Buck2 parse and analyze the generated BUCK files?

EOF

# Check if we have a buck2 root
if [ -f "$REPO_ROOT/.buckconfig" ]; then
	log "Testing Buck2 analysis (targets command)"

	cd "$REPO_ROOT"

	# Warm up
	buck2 targets //src/examples/cxx:hello 2>/dev/null || true

	if [ "$HAS_HYPERFINE" -eq 1 ]; then
		hyperfine --warmup 2 --min-runs 5 \
			"buck2 targets //src/examples/cxx:..." \
			2>&1 | tee -a "$RESULTS_FILE"
	else
		log "Running 5 iterations..."
		total=0
		for i in $(seq 1 5); do
			t=$(time_cmd buck2 targets //src/examples/cxx:...)
			total=$(awk "BEGIN {printf \"%.6f\", $total + $t}")
		done
		avg=$(awk "BEGIN {printf \"%.3f\", $total / 5}")
		echo "  Average: ${avg}s per analysis" | tee -a "$RESULTS_FILE"
	fi
else
	log "No .buckroot found, skipping Buck2 analysis test"
	echo "Skipped: No .buckroot in repo" >>"$RESULTS_FILE"
fi

# ════════════════════════════════════════════════════════════════════════════
# Benchmark 4: sensenet DICE vs Buck2 caching
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo "┌──────────────────────────────────────────────────────────────────┐"
echo "│ 4. SENSENET DICE PERFORMANCE                                     │"
echo "└──────────────────────────────────────────────────────────────────┘"
echo ""

cat >>"$RESULTS_FILE" <<'EOF'

## 4. sensenet DICE Performance

ActionKey computation and graph construction benchmarks.

EOF

# Run our Haskell benchmark
BENCH_MAIN="$REPO_ROOT/bench/Main.hs"
if [ -f "$BENCH_MAIN" ]; then
	log "Running sensenet DICE benchmark..."

	cd "$REPO_ROOT"

	# Compile if needed
	if [ ! -f "$REPO_ROOT/bench-main" ]; then
		log "Compiling benchmark..."
		ghc -O2 -threaded \
			-package deepseq -package containers -package text \
			-package crypton -package memory -package time -package bytestring \
			-o bench-main bench/Main.hs 2>/dev/null || {
			err "Failed to compile benchmark"
			echo "Failed to compile" >>"$RESULTS_FILE"
		}
	fi

	if [ -f "$REPO_ROOT/bench-main" ]; then
		./bench-main --quick 2>&1 | tee -a "$RESULTS_FILE"
	fi
else
	err "bench/Main.hs not found"
fi

# ════════════════════════════════════════════════════════════════════════════
# Summary
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║                      Benchmarks Complete                         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Results written to: $RESULTS_FILE"
