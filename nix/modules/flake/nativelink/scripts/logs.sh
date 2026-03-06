#!/usr/bin/env bash
# View logs from NativeLink services
set -euo pipefail

APP_PREFIX="@appPrefix@"
SERVICE="${1:-scheduler}"

app="${APP_PREFIX}-${SERVICE}"
echo "=== Logs for $app ==="
flyctl logs --app "$app"
