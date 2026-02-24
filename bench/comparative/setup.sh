#!/usr/bin/env bash
# Setup synthetic projects for benchmarking sensenet vs buck2
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${BENCH_DIR}/workspaces"

# Clean previous runs
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

# ════════════════════════════════════════════════════════════════════════════
# Generate synthetic project with N targets
# ════════════════════════════════════════════════════════════════════════════

generate_buck2_project() {
	local name=$1
	local num_targets=$2
	local deps_per_target=${3:-3}
	local project_dir="${WORKDIR}/${name}"

	mkdir -p "$project_dir"
	cd "$project_dir"

	# Buck2 root files
	cat >.buckconfig <<'EOF'
[repositories]
root = .

[buildfile]
name = BUCK

[project]
ignore = .git
EOF

	cat >.buckroot <<'EOF'
EOF

	cat >BUCK <<EOF
# Auto-generated benchmark with $num_targets targets
EOF

	# Generate targets
	for i in $(seq 1 $num_targets); do
		local target_name="target_${i}"
		local src_file="src/file_${i}.txt"

		mkdir -p "src"
		echo "// Source file $i" >"$src_file"

		# Calculate dependencies (previous targets, up to deps_per_target)
		local deps=""
		if [ $i -gt 1 ]; then
			local max_dep=$((i - 1))
			local num_deps=$((max_dep < deps_per_target ? max_dep : deps_per_target))
			for j in $(seq 1 $num_deps); do
				local dep_idx=$((i - j))
				if [ -n "$deps" ]; then
					deps="${deps}, "
				fi
				deps="${deps}\":target_${dep_idx}\""
			done
		fi

		cat >>BUCK <<EOF

genrule(
    name = "${target_name}",
    srcs = ["${src_file}"],
    out = "out_${i}.txt",
    cmd = "cat \$SRCS > \$OUT",
    deps = [${deps}],
)
EOF
	done

	echo "Generated Buck2 project: $project_dir with $num_targets targets"
}

generate_sensenet_project() {
	local name=$1
	local num_targets=$2
	local deps_per_target=${3:-3}
	local project_dir="${WORKDIR}/${name}"

	mkdir -p "$project_dir"
	cd "$project_dir"

	# sensenet uses Dhall, but for this benchmark we'll measure the Haskell core directly
	# Create a simple JSON representation that our benchmark can parse

	cat >targets.json <<EOF
{
  "targets": [
EOF

	for i in $(seq 1 $num_targets); do
		local target_name="target_${i}"

		# Calculate dependencies
		local deps="[]"
		if [ $i -gt 1 ]; then
			local max_dep=$((i - 1))
			local num_deps=$((max_dep < deps_per_target ? max_dep : deps_per_target))
			deps="["
			for j in $(seq 1 $num_deps); do
				local dep_idx=$((i - j))
				if [ $j -gt 1 ]; then
					deps="${deps}, "
				fi
				deps="${deps}\"target_${dep_idx}\""
			done
			deps="${deps}]"
		fi

		local comma=""
		if [ $i -lt $num_targets ]; then
			comma=","
		fi

		cat >>targets.json <<EOF
    {
      "name": "${target_name}",
      "command": ["cat", "src/file_${i}.txt"],
      "inputs": ["src/file_${i}.txt"],
      "outputs": ["out_${i}.txt"],
      "deps": ${deps}
    }${comma}
EOF
	done

	cat >>targets.json <<EOF
  ]
}
EOF

	# Create source files
	mkdir -p src
	for i in $(seq 1 $num_targets); do
		echo "// Source file $i" >"src/file_${i}.txt"
	done

	echo "Generated sensenet project: $project_dir with $num_targets targets"
}

# ════════════════════════════════════════════════════════════════════════════
# Generate benchmark projects of various sizes
# ════════════════════════════════════════════════════════════════════════════

echo "Generating benchmark projects..."

# Small (100 targets)
generate_buck2_project "buck2_100" 100
generate_sensenet_project "sensenet_100" 100

# Medium (1000 targets)
generate_buck2_project "buck2_1000" 1000
generate_sensenet_project "sensenet_1000" 1000

# Large (10000 targets)
generate_buck2_project "buck2_10000" 10000
generate_sensenet_project "sensenet_10000" 10000

echo ""
echo "Setup complete. Projects in: $WORKDIR"
echo ""
ls -la "$WORKDIR"
