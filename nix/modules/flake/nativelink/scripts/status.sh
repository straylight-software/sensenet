#!/usr/bin/env bash
# status.sh - Check status of NativeLink services on Fly.io
#
# Substituted variables:
#   @FLY_APP_PREFIX@ - App name prefix

set -euo pipefail

PREFIX="@FLY_APP_PREFIX@"

echo "NativeLink Service Status"
echo "========================="

for service in scheduler cas worker; do
  echo ""
  echo "==> $PREFIX-$service"
  fly status --app "$PREFIX-$service" 2>/dev/null || echo "  Not deployed"
done
