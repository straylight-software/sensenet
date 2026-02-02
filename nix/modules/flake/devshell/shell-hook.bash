echo "ℵ-0xFF devshell"

# Set up Buck2 prelude symlink
mkdir -p nix/build
if [ ! -L nix/build/prelude ]; then
  ln -sfn @prelude@ nix/build/prelude
fi

# Generate .buckconfig.local with Nix store paths
cp @buckconfig_local@ .buckconfig.local
chmod 644 .buckconfig.local
echo "Generated .buckconfig.local with Nix toolchain paths"
