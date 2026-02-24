#!/usr/bin/env bash
# sense-overlay - Zero Starlark via unshare + bind mounts
#
# This script creates an isolated mount namespace where generated BUCK files
# appear in the source tree without actually existing on disk. Users only
# edit BUILD.dhall files; BUCK files are ephemeral.
#
# Usage:
#   sense-overlay [command...]    Run command in overlay environment
#   sense-overlay                 Start interactive shell in overlay
#   sense-overlay --simple ...    Generate BUCK files in place (no overlay)
#
# Requirements:
#   - Linux with user namespaces enabled (kernel.unprivileged_userns_clone=1)
#   - unshare, mount (from util-linux)
#   - dhall CLI
#
# How it works:
#   1. Generate BUCK files from BUILD.dhall into a temp directory
#   2. Create a mount namespace with unshare --user --mount
#   3. Bind-mount each BUCK file into the source tree
#   4. Run command (or shell) - it sees BUCK files but they don't pollute the repo
#   5. On exit, mounts are cleaned up (namespace isolated)

set -euo pipefail

# ══════════════════════════════════════════════════════════════════════════════
# Configuration
# ══════════════════════════════════════════════════════════════════════════════
PROJECT_ROOT="${SENSE_PROJECT_ROOT:-$(pwd)}"
DHALL_TO_BUCK="${SENSE_DHALL_TO_BUCK:-./dhall-to-buck}"

# ══════════════════════════════════════════════════════════════════════════════
# Generate BUCK files
# ══════════════════════════════════════════════════════════════════════════════
generate_buck_files() {
  local output_dir="$1"
  local count=0
  local failed=0

  while IFS= read -r -d '' dhall_file; do
    local rel_path="${dhall_file#$PROJECT_ROOT/}"
    local rel_dir
    rel_dir=$(dirname "$rel_path")
    local buck_dir="$output_dir/$rel_dir"
    local buck_file="$buck_dir/BUCK"

    mkdir -p "$buck_dir"

    if "$DHALL_TO_BUCK" "$dhall_file" >"$buck_file" 2>&1; then
      ((count++)) || true
    else
      echo "ERROR: $dhall_file" >&2
      cat "$buck_file" >&2
      rm -f "$buck_file"
      ((failed++)) || true
    fi
  done < <(find "$PROJECT_ROOT" -name "BUILD.dhall" -print0 2>/dev/null)

  if [[ $count -gt 0 ]]; then
    echo "sense: generated $count BUCK file(s)" >&2
  fi

  [[ $failed -eq 0 ]]
}

# ══════════════════════════════════════════════════════════════════════════════
# Overlay mode: bind-mount BUCK files in isolated namespace
# ══════════════════════════════════════════════════════════════════════════════
overlay_mode() {
  if [[ -n ${SENSE_OVERLAY:-} ]]; then
    exec "${@:-$SHELL}"
  fi

  if ! command -v unshare &>/dev/null; then
    echo "ERROR: unshare not found" >&2
    return 1
  fi

  # Create temp directory for generated BUCK files
  local tmpdir
  tmpdir=$(mktemp -d -t sense.XXXXXX)

  # Generate BUCK files
  if ! generate_buck_files "$tmpdir"; then
    rm -rf "$tmpdir"
    return 1
  fi

  # Export for use in subshell
  export SENSE_OVERLAY=1
  export SENSE_TMPDIR="$tmpdir"
  export SENSE_PROJECT_ROOT="$PROJECT_ROOT"

  # Enter new namespace and bind-mount BUCK files
  # Use unique isolation dir so buck2 starts a fresh daemon that sees our mounts
  export BUCK_ISOLATION_DIR="sense-overlay"

  # Kill any existing daemon for this isolation dir (it won't see our mounts)
  buck2 kill 2>/dev/null || true

  # Create a file listing mount points we create, so we can clean them up
  export SENSE_MOUNT_POINTS="$tmpdir/mount_points"
  touch "$SENSE_MOUNT_POINTS"

  # Run in namespace, capture exit code
  unshare --user --mount --map-root-user --propagation=private bash -c '
        mount --make-rprivate / 2>/dev/null || true

        # Bind-mount each generated BUCK file
        while IFS= read -r -d "" buck_file; do
            rel_path="${buck_file#$SENSE_TMPDIR/}"
            target="$SENSE_PROJECT_ROOT/$rel_path"
            
            # Create mount point if needed (and track it for cleanup)
            if [[ ! -e "$target" ]]; then
                touch "$target"
                echo "$target" >> "$SENSE_MOUNT_POINTS"
            fi
            
            mount --bind "$buck_file" "$target"
        done < <(find "$SENSE_TMPDIR" -name "BUCK" -type f -print0)

        cd "$SENSE_PROJECT_ROOT"
        "$@"
    ' -- "${@:-$SHELL}"
  exit_code=$?

  # Clean up mount points we created (outside namespace now)
  while IFS= read -r mp; do
    if [[ -f $mp && ! -s $mp ]]; then
      rm -f "$mp" 2>/dev/null || true
    fi
  done <"$SENSE_MOUNT_POINTS"
  rm -rf "$tmpdir"

  exit $exit_code
}

# ══════════════════════════════════════════════════════════════════════════════
# Simple mode: generate BUCK files in place
# ══════════════════════════════════════════════════════════════════════════════
simple_mode() {
  local count=0
  local failed=0

  while IFS= read -r -d '' dhall_file; do
    local dir
    dir=$(dirname "$dhall_file")
    local buck_file="$dir/BUCK"

    # Skip if BUCK is newer
    if [[ -f $buck_file && $buck_file -nt $dhall_file ]]; then
      continue
    fi

    if "$DHALL_TO_BUCK" "$dhall_file" >"$buck_file.tmp" 2>&1; then
      mv "$buck_file.tmp" "$buck_file"
      ((count++)) || true
    else
      echo "ERROR: $dhall_file" >&2
      cat "$buck_file.tmp" >&2
      rm -f "$buck_file.tmp"
      ((failed++)) || true
    fi
  done < <(find "$PROJECT_ROOT" -name "BUILD.dhall" -print0 2>/dev/null)

  if [[ $count -gt 0 ]]; then
    echo "sense: generated $count BUCK file(s)" >&2
  fi

  if [[ $failed -gt 0 ]]; then
    return 1
  fi

  exec "${@:-$SHELL}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════
case "${1:-}" in
--simple | -s)
  shift
  simple_mode "$@"
  ;;
--help | -h)
  cat <<'EOF'
sense-overlay - Zero Starlark environment

Usage: sense-overlay [OPTIONS] [COMMAND...]

Run COMMAND (or interactive shell) with BUCK files generated from BUILD.dhall.
BUCK files are bind-mounted in an isolated namespace and don't exist on disk.

Options:
  --simple, -s    Generate BUCK files in place (no namespace isolation)
  --help, -h      Show this help

Environment:
  SENSE_PROJECT_ROOT    Project root directory (default: pwd)
  SENSE_DHALL_TO_BUCK   Path to dhall-to-buck script (default: ./dhall-to-buck)

Examples:
  sense-overlay                     # Interactive shell with BUCK files
  sense-overlay buck2 build //...   # Build with ephemeral BUCK files
  sense-overlay --simple            # Generate BUCK files in place
EOF
  ;;
*)
  overlay_mode "$@" || simple_mode "$@"
  ;;
esac
