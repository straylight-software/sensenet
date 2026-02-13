echo "ℵ Sensenet project: @name@"

if [ -n "@reEnabled@" ]; then
	echo "  Remote execution: @reScheduler@:@reSchedulerPort@"
	echo "  Usage: buck2 build //..."
fi

if [ -n "@haskellEnabled@" ]; then
	# Ensure ghcWithPackages is first in PATH (before HLS's ghc dependency)
	export PATH="@ghcBin@:$PATH"
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
echo "Generated .buckconfig.local"

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
