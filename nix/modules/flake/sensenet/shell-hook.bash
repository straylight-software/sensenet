echo "ℵ Sensenet project: @name@"

if [ -n "@reEnabled@" ]; then
	echo "  Remote execution: @reScheduler@:@reSchedulerPort@"
	echo "  Usage: buck2 build //..."
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

# Set up prelude symlink
mkdir -p nix/build
if [ ! -L nix/build/prelude ]; then
	ln -sfn @preludePath@ nix/build/prelude
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

	# Generate BUCK files from BUILD.dhall in src/, toolchains/, and root
	for search_dir in src toolchains .; do
		if [ -d "$search_dir" ]; then
			while IFS= read -r -d '' dhall_file; do
				local dir=$(dirname "$dhall_file")
				local buck_file="$dir/BUCK"

				# Regenerate if BUCK doesn't exist or BUILD.dhall is newer
				if [ ! -f "$buck_file" ] || [ "$dhall_file" -nt "$buck_file" ]; then
					if ./dhall-to-buck "$dhall_file" >"$buck_file" 2>/dev/null; then
						((count++)) || true
					fi
				fi
			done < <(find "$search_dir" -maxdepth 2 -name "BUILD.dhall" -print0 2>/dev/null)
		fi
	done

	if [ "$count" -gt 0 ]; then
		echo "Generated $count BUCK file(s) from BUILD.dhall"
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
