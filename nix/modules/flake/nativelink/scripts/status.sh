#!/usr/bin/env bash
# Check status of NativeLink services
set -euo pipefail

APP_PREFIX="@appPrefix@"

echo "=== NativeLink Status ==="
echo ""

for service in scheduler cas worker builder; do
	app="${APP_PREFIX}-${service}"
	echo "--- $app ---"
	flyctl status --app "$app" 2>/dev/null || echo "  Not deployed"
	echo ""
done
