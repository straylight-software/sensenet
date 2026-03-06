#!/usr/bin/env bash
# Deploy NativeLink infrastructure to Fly.io
set -euo pipefail

APP_PREFIX="@appPrefix@"
REGION="@region@"
WORKER_COUNT="@workerCount@"

echo "=== NativeLink Deployment ==="
echo "App prefix: $APP_PREFIX"
echo "Region: $REGION"
echo "Workers: $WORKER_COUNT"
echo ""

# Helper to create app if it doesn't exist
ensure_app() {
	local app="$1"
	if ! flyctl apps list | grep -q "^$app "; then
		echo "Creating app: $app"
		flyctl apps create "$app" --org personal || true
	fi
}

# Helper to create volume if it doesn't exist
ensure_volume() {
	local app="$1"
	local name="$2"
	local size="$3"
	if ! flyctl volumes list -a "$app" | grep -q "$name"; then
		echo "Creating volume: $name ($size) for $app"
		flyctl volumes create "$name" --app "$app" --region "$REGION" --size "${size%gb}" || true
	fi
}

# Deploy scheduler
echo "=== Deploying Scheduler ==="
ensure_app "${APP_PREFIX}-scheduler"
flyctl deploy --config "@schedulerFlyToml@" --app "${APP_PREFIX}-scheduler" --region "$REGION"

# Deploy CAS
echo "=== Deploying CAS ==="
ensure_app "${APP_PREFIX}-cas"
ensure_volume "${APP_PREFIX}-cas" "cas_data" "@casVolumeSize@"
flyctl deploy --config "@casFlyToml@" --app "${APP_PREFIX}-cas" --region "$REGION"

# Deploy workers
echo "=== Deploying Workers ==="
ensure_app "${APP_PREFIX}-worker"
ensure_volume "${APP_PREFIX}-worker" "nix_store" "@workerVolumeSize@"
flyctl deploy --config "@workerFlyToml@" --app "${APP_PREFIX}-worker" --region "$REGION"
flyctl scale count "$WORKER_COUNT" --app "${APP_PREFIX}-worker" || true

# Deploy builder (optional)
echo "=== Deploying Builder ==="
ensure_app "${APP_PREFIX}-builder"
ensure_volume "${APP_PREFIX}-builder" "nix_store" "@builderVolumeSize@"
flyctl deploy --config "@builderFlyToml@" --app "${APP_PREFIX}-builder" --region "$REGION"

echo ""
echo "=== Deployment Complete ==="
echo "Scheduler: ${APP_PREFIX}-scheduler.fly.dev:443"
echo "CAS:       ${APP_PREFIX}-cas.fly.dev:443"
echo "Workers:   $WORKER_COUNT x ${APP_PREFIX}-worker"
