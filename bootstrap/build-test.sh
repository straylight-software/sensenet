#!/usr/bin/env bash
# Build sensenet test suite
set -euo pipefail

mkdir -p build

# Compile test suite
"@ghcTest@/bin/ghc" -O2 -threaded \
  -isrc/sensenet \
  -ivendor/hyperconsole/src \
  -itest \
  -XLambdaCase \
  -XOverloadedStrings \
  -XOverloadedRecordDot \
  -XRecordWildCards \
  -XScopedTypeVariables \
  -XGHC2024 \
  -outputdir build \
  -hidir build \
  -odir build \
  --make \
  test/Main.hs \
  -o sensenet-test \
  -rtsopts \
  "-with-rtsopts=-N"
