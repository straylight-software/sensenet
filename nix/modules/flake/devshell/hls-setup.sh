#!/usr/bin/env bash
set -e

GHC_VERSION=$(ghc --numeric-version)
PKG_DB="${GHC_WITH_DEPS}/lib/ghc-${GHC_VERSION}/lib/package.conf.d"

# Generate hie.yaml pointing to Buck2-generated .hie files
cat >hie.yaml <<HIEEOF
cradle:
  direct:
    arguments:
      - -package-db=${PKG_DB}
      - -Wall
      - -Wno-unused-imports
HIEEOF

mkdir -p .hie
echo "Generated hie.yaml (Buck2 will generate .hie files in buck-out/)"

echo "Checking library sources for HLS..."
mkdir -p .haskell-sources

for pkg_conf in "$PKG_DB"/*.conf; do
  if [ -f "$pkg_conf" ]; then
    pkg_name=$(grep "^name:" "$pkg_conf" | head -1 | sed 's/^name: *//')
    pkg_version=$(grep "^version:" "$pkg_conf" | head -1 | sed 's/^version: *//')

    # Skip boot packages
    # shellcheck disable=SC2221,SC2222
    case "$pkg_name" in
    rts | ghc | ghc-boot | ghc-boot-th | ghc-heap | ghci | ghc-prim | integer-gmp | integer-simple | base | array | deepseq | bytestring | containers | directory | filepath | time | unix | process | transformers | mtl | parsec | text | unix | Win32)
      continue
      ;;
    esac

    src_dir=".haskell-sources/$pkg_name-$pkg_version"
    if [ ! -d "$src_dir" ]; then
      tarball="$src_dir.tar.gz"
      url="https://hackage.haskell.org/package/$pkg_name-$pkg_version/$pkg_name-$pkg_version.tar.gz"

      if curl -fsL --max-time 30 "$url" -o "$tarball" 2>/dev/null; then
        tar -xzf "$tarball" -C .haskell-sources/ 2>/dev/null && rm -f "$tarball"
        echo "  ✓ $pkg_name-$pkg_version"
      else
        rm -f "$tarball" 2>/dev/null
      fi
    fi
  fi
done

echo "Library sources ready in .haskell-sources/"
echo "Note: Buck2 will generate .hie files during build (run: buck2 build //...)"
