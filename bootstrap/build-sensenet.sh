#!/usr/bin/env bash
# Build sensenet bootstrap binary
set -euo pipefail

mkdir -p build

# Compile with GHC --make (handles dependency order automatically)
"@ghc@/bin/ghc" -O2 -threaded \
  -isrc/sensenet \
  -ivendor/hyperconsole/src \
  -XLambdaCase \
  -XOverloadedStrings \
  -XOverloadedRecordDot \
  -XGHC2024 \
  -outputdir build \
  -hidir build \
  -odir build \
  --make \
  src/sensenet/app/Main.hs \
  -o sensenet \
  -rtsopts \
  "-with-rtsopts=-N"
