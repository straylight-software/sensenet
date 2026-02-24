# Export paths for sensenet CLI
export SENSENET_PRELUDE="@preludePath@"
export SENSENET_TOOLCHAINS="@toolchainsPath@"

echo "ℵ sensenet // @name@"
echo "  Usage: sense build //...  (or buck2 directly)"

if [ -n "@reEnabled@" ]; then
  echo "  Remote execution: @reScheduler@:@reSchedulerPort@"
fi

if [ -n "@haskellEnabled@" ]; then
  # Ensure ghcWithPackages is first in PATH (before HLS's ghc dependency)
  export PATH="@ghcBin@:$PATH"

  # GHC 9.12 workaround: -package flag doesn't work with ghcWithPackages
  # We need to use -package-id with full unit IDs instead
  # Generate package ID mappings and append to .buckconfig.local
  _generate_pkg_ids() {
    local ghc_pkg="@ghcBin@/ghc-pkg"
    echo ""
    echo "[haskell_package_ids]"
    # Get all exposed packages and their unit IDs
    "$ghc_pkg" list --simple-output 2>/dev/null | tr ' ' '\n' | while read -r pkg; do
      if [ -n "$pkg" ]; then
        # Extract base name (without version) for lookup key
        # e.g., "vector-0.13.2.0" -> "vector"
        local base_name=$(echo "$pkg" | sed 's/-[0-9].*//')
        local pkg_id=$("$ghc_pkg" field "$pkg" id --simple-output 2>/dev/null)
        if [ -n "$pkg_id" ]; then
          echo "$base_name = $pkg_id"
        fi
      fi
    done
  }

  # Flag to append package IDs after buckconfig.local is generated
  export _SENSENET_GENERATE_PKG_IDS=1
fi

if [ -n "@nvEnabled@" ]; then
  # Add CUDA runtime libraries to LD_LIBRARY_PATH
  export LD_LIBRARY_PATH="@nvSdkLib@${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
fi

# Set up prelude symlink and toolchains copy
# Note: prelude symlinks work, but toolchains must be copied because
# Buck2 canonicalizes cell paths and rejects symlinks to external paths.
mkdir -p nix/build
if [ ! -L nix/build/prelude ]; then
  ln -sfn @preludePath@ nix/build/prelude
fi
# Copy toolchains (Buck2 doesn't follow symlinks to paths outside project root)
if [ ! -d nix/build/toolchains ] || [ "@toolchainsPath@" != "$(cat nix/build/toolchains/.source 2>/dev/null)" ]; then
  rm -rf nix/build/toolchains
  cp -rL @toolchainsPath@ nix/build/toolchains
  chmod -R u+w nix/build/toolchains
  echo "@toolchainsPath@" >nix/build/toolchains/.source
fi

# Generate .buckconfig.local
cp @buckconfigLocalFile@ .buckconfig.local
chmod 644 .buckconfig.local

# Append package IDs for GHC 9.12 workaround
if [ -n "${_SENSENET_GENERATE_PKG_IDS:-}" ]; then
  _generate_pkg_ids >>.buckconfig.local
fi

echo "Generated .buckconfig.local"

# ══════════════════════════════════════════════════════════════════════════════
# Zero Starlark: Auto-generate BUCK files from BUILD.dhall
# ══════════════════════════════════════════════════════════════════════════════
# Users only edit BUILD.dhall files; BUCK files are generated and gitignored.
# This runs on every shell entry to ensure BUCK files are always in sync.

_generate_buck_files() {
  local count=0
  local failed=0

  # Generate BUCK files from BUILD.dhall in src/, toolchains/, and root
  for search_dir in src toolchains .; do
    if [ -d "$search_dir" ]; then
      while IFS= read -r -d '' dhall_file; do
        local dir=$(dirname "$dhall_file")
        local buck_file="$dir/BUCK"

        # Regenerate if BUCK doesn't exist or BUILD.dhall is newer
        if [ ! -f "$buck_file" ] || [ "$dhall_file" -nt "$buck_file" ]; then
          if ./dhall-to-buck "$dhall_file" >"$buck_file"; then
            ((count++)) || true
          else
            echo "ERROR: Failed to generate BUCK from $dhall_file" >&2
            rm -f "$buck_file" # Don't leave partial/empty BUCK files
            ((failed++)) || true
          fi
        fi
      done < <(find "$search_dir" -name "BUILD.dhall" -print0 2>/dev/null)
    fi
  done

  if [ "$count" -gt 0 ]; then
    echo "Generated $count BUCK file(s) from BUILD.dhall"
  fi

  if [ "$failed" -gt 0 ]; then
    echo "WARNING: $failed BUILD.dhall file(s) failed to generate" >&2
    return 1
  fi
}

# Only run if dhall-to-buck exists
if [ -x "./dhall-to-buck" ]; then
  _generate_buck_files
fi

# Symlink editor/LSP configs from nix/configs/
configsPath="@configsPath@"
for cfg in .clangd .clang-format .clang-tidy .rustfmt.toml .stylua.toml; do
  if [ -f "$configsPath/$cfg" ] && [ ! -e "$cfg" ]; then
    ln -sf "$configsPath/$cfg" "$cfg"
  fi
done

# Note: hie.yaml generation moved to devshell.nix for default devshell
# Sensenet devShells (sensenet-examples, etc.) still use the build module

# Generate compile_commands.json for clangd (C++ LSP)
if [ -n "@cxxEnabled@" ]; then
  if [ ! -f compile_commands.json ] || [ .buckconfig.local -nt compile_commands.json ]; then
    # We use 'tail -1' to get the last line which should be the path, avoiding logs
    COMPDB_PATH=$(buck2 bxl prelude//cxx/tools/compilation_database.bxl:generate -- --targets @targets@ 2>/dev/null | tail -1) || true
    if [ -n "$COMPDB_PATH" ] && [ -f "$COMPDB_PATH" ]; then
      cp "$COMPDB_PATH" compile_commands.json
      echo "Generated compile_commands.json"
    fi
  fi
fi

@devshellhook@
