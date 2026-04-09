#!/usr/bin/env bash
# deploy-all.sh - Deploy all NativeLink services to Fly.io
#
# Substituted variables:
#   @FLY_APP_PREFIX@ - App name prefix (e.g., "aleph")
#   @FLY_REGION@ - Primary region
#
# Usage: ./deploy-all.sh

set -euo pipefail

PREFIX="@FLY_APP_PREFIX@"
REGION="@FLY_REGION@"

echo "Deploying NativeLink services to Fly.io"
echo "  Prefix: $PREFIX"
echo "  Region: $REGION"

# Deploy in order: CAS first, then scheduler, then workers
echo "==> Deploying CAS..."
fly deploy --app "$PREFIX-cas" --region "$REGION" --config cas-fly.toml

echo "==> Deploying Scheduler..."
fly deploy --app "$PREFIX-scheduler" --region "$REGION" --config scheduler-fly.toml

echo "==> Deploying Worker..."
fly deploy --app "$PREFIX-worker" --region "$REGION" --config worker-fly.toml

echo "==> All services deployed!"
fly status --app "$PREFIX-scheduler"
