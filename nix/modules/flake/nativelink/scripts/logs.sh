#!/usr/bin/env bash
# logs.sh - Stream logs from NativeLink services on Fly.io
#
# Substituted variables:
#   @FLY_APP_PREFIX@ - App name prefix
#
# Usage: ./logs.sh [scheduler|cas|worker]

set -euo pipefail

PREFIX="@FLY_APP_PREFIX@"
SERVICE="${1:-scheduler}"

echo "Streaming logs from $PREFIX-$SERVICE..."
fly logs --app "$PREFIX-$SERVICE"
