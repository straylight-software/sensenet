#!/usr/bin/env bash
# Deploy NativeLink infrastructure to GCP (supports aarch64 via T2A instances)
# Uses startup scripts with Nix instead of containers (nix2gpu is x86_64 only)
set -euo pipefail

PROJECT="@gcpProject@"
ZONE="@gcpZone@"
APP_PREFIX="@appPrefix@"
WORKER_COUNT="@workerCount@"
SECRETS_DIR="@secretsDir@"
SCHEDULER_PORT="@schedulerPort@"
CAS_PORT="@casPort@"

echo "=== NativeLink GCP Deployment ==="
echo "Project: $PROJECT"
echo "Zone: $ZONE"
echo "App prefix: $APP_PREFIX"
echo "Workers: $WORKER_COUNT"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Authenticate with service account (if not already authenticated)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
	ENCRYPTED_KEY="${SECRETS_DIR}/gcp-nativelink.age"
	if [[ -f "$ENCRYPTED_KEY" ]]; then
		echo "Decrypting service account key..."
		DECRYPTED_KEY=$(mktemp)
		trap "rm -f $DECRYPTED_KEY" EXIT

		# Decrypt using age with SSH key
		age -d -i ~/.ssh/id_ed25519 -o "$DECRYPTED_KEY" "$ENCRYPTED_KEY"

		echo "Activating service account..."
		gcloud auth activate-service-account --key-file="$DECRYPTED_KEY" --project="$PROJECT"
	else
		echo "Warning: No encrypted key found at $ENCRYPTED_KEY"
		echo "Using current gcloud credentials..."
	fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Deploy infrastructure using individual scripts
# ─────────────────────────────────────────────────────────────────────────────

# Deploy scheduler first (other services need to know its address)
echo ""
echo "=== Deploying Scheduler ==="
@schedulerGcpScript@

# Deploy CAS (content-addressed storage)
echo ""
echo "=== Deploying CAS ==="
@casGcpScript@

# Deploy workers (aarch64 via T2A)
echo ""
echo "=== Deploying Workers ==="
for i in $(seq 1 "$WORKER_COUNT"); do
	export INSTANCE_NAME="${APP_PREFIX}-worker-${i}"
	echo "Deploying worker $i of $WORKER_COUNT: $INSTANCE_NAME"
	@workerGcpScript@
done

# ─────────────────────────────────────────────────────────────────────────────
# Get IPs and generate config
# ─────────────────────────────────────────────────────────────────────────────

SCHEDULER_IP=$(gcloud compute addresses describe "${APP_PREFIX}-scheduler-ip" --region="${ZONE%-*}" --project="$PROJECT" --format="get(address)" 2>/dev/null || echo "pending")
CAS_IP=$(gcloud compute addresses describe "${APP_PREFIX}-cas-ip" --region="${ZONE%-*}" --project="$PROJECT" --format="get(address)" 2>/dev/null || echo "pending")

echo ""
echo "=== GCP Deployment Complete ==="
echo ""
echo "Scheduler: $SCHEDULER_IP:$SCHEDULER_PORT"
echo "CAS:       $CAS_IP:$CAS_PORT"
echo "Workers:   $WORKER_COUNT x T2A (aarch64)"
echo ""
echo "Add to .buckconfig.local:"
echo ""
echo "[buck2_re_client]"
echo "engine_address = grpc://$SCHEDULER_IP:$SCHEDULER_PORT"
echo "cas_address = grpc://$CAS_IP:$CAS_PORT"
echo "action_cache_address = grpc://$CAS_IP:$CAS_PORT"
echo "tls = false"
echo ""
echo "Check instance logs:"
echo "  gcloud compute ssh ${APP_PREFIX}-scheduler --zone=$ZONE --project=$PROJECT --command='journalctl -f'"
echo "  gcloud compute ssh ${APP_PREFIX}-cas --zone=$ZONE --project=$PROJECT --command='journalctl -f'"
echo "  gcloud compute ssh ${APP_PREFIX}-worker-1 --zone=$ZONE --project=$PROJECT --command='journalctl -f'"
