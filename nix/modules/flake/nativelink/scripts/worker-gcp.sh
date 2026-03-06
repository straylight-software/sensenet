#!/usr/bin/env bash
# Deploy NativeLink worker to GCP (aarch64 via T2A instances)
# Uses startup script approach instead of containers (nix2gpu is x86_64 only)
set -euo pipefail

PROJECT="@gcpProject@"
ZONE="@gcpZone@"
INSTANCE_NAME="${INSTANCE_NAME:-@appPrefix@-worker}"
MACHINE_TYPE="@gcpMachineType@"
DISK_SIZE="@workerVolumeSize@"
# Worker addresses (embedded in config, exported for debugging)
export SCHEDULER_ADDR="@schedulerAddr@"
export CAS_ADDR="@casAddr@"
NATIVELINK_STORE="@nativelinkStore@"
WORKER_CONFIG="@workerConfig@"

echo "=== Deploying NativeLink Worker to GCP ==="
echo "Project: $PROJECT"
echo "Zone: $ZONE"
echo "Instance: $INSTANCE_NAME"
echo "Machine type: $MACHINE_TYPE (aarch64)"
echo "Disk size: $DISK_SIZE"
echo ""

# Create startup script that installs nix and runs nativelink
STARTUP_SCRIPT=$(
	cat <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

export HOME=/root
export PATH=/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== NativeLink Worker Startup ==="

# Install nix if not present
if ! command -v nix &>/dev/null; then
    log "Installing Nix..."
    curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

# Ensure nix daemon is running
if ! pgrep -x nix-daemon &>/dev/null; then
    log "Starting nix-daemon..."
    systemctl start nix-daemon || /nix/var/nix/profiles/default/bin/nix-daemon &
    sleep 2
fi

# Configure nix for better caching
mkdir -p /etc/nix
cat > /etc/nix/nix.conf <<EOF
experimental-features = nix-command flakes
substituters = https://cache.nixos.org https://nativelink.cachix.org https://nix-community.cachix.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nativelink.cachix.org-1:adJd7GA3GLPY8T2lCmOOHvCGKfhAbbPNlVd3p0sHj78= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=
max-jobs = auto
sandbox = false
EOF

# Build/fetch nativelink
log "Fetching NativeLink from Nix store..."
NATIVELINK_PATH="NATIVELINK_STORE_PLACEHOLDER"

# Ensure the store path exists (fetch from binary cache)
nix-store --realise "$NATIVELINK_PATH" || {
    log "Fetching from flake..."
    nix build github:TraceMachina/nativelink#packages.aarch64-linux.nativelink --out-link /tmp/nativelink-result
    NATIVELINK_PATH=$(readlink -f /tmp/nativelink-result)
}

# Write worker config
mkdir -p /etc/nativelink
cat > /etc/nativelink/worker.json <<'CONFIG'
WORKER_CONFIG_PLACEHOLDER
CONFIG

# Create work directories
mkdir -p /data/nativelink/{cas,worker}
chown -R nobody:nogroup /data/nativelink 2>/dev/null || true

log "Starting NativeLink worker..."
exec "$NATIVELINK_PATH/bin/nativelink" /etc/nativelink/worker.json
SCRIPT
)

# Substitute placeholders
STARTUP_SCRIPT="${STARTUP_SCRIPT//NATIVELINK_STORE_PLACEHOLDER/$NATIVELINK_STORE}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//WORKER_CONFIG_PLACEHOLDER/$(cat "$WORKER_CONFIG")}"

# Write startup script to temp file
STARTUP_FILE=$(mktemp)
echo "$STARTUP_SCRIPT" >"$STARTUP_FILE"
# shellcheck disable=SC2064
trap "rm -f $STARTUP_FILE" EXIT

# Check if instance exists
if gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --project="$PROJECT" &>/dev/null; then
	echo "Instance $INSTANCE_NAME already exists"

	# Update startup script (takes effect on next boot)
	echo "Updating startup script..."
	gcloud compute instances add-metadata "$INSTANCE_NAME" \
		--zone="$ZONE" \
		--project="$PROJECT" \
		--metadata-from-file="startup-script=$STARTUP_FILE"

	# Optionally restart to pick up changes
	read -p "Restart instance to apply changes? [y/N] " -n 1 -r
	echo
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		gcloud compute instances reset "$INSTANCE_NAME" --zone="$ZONE" --project="$PROJECT"
	fi
else
	echo "Creating instance $INSTANCE_NAME..."

	# Create instance with startup script
	gcloud compute instances create "$INSTANCE_NAME" \
		--zone="$ZONE" \
		--project="$PROJECT" \
		--machine-type="$MACHINE_TYPE" \
		--boot-disk-size="$DISK_SIZE" \
		--boot-disk-type="pd-ssd" \
		--image-family="ubuntu-2204-lts-arm64" \
		--image-project="ubuntu-os-cloud" \
		--metadata-from-file="startup-script=$STARTUP_FILE" \
		--tags="nativelink-worker" \
		--scopes="cloud-platform"

	# Create firewall rule if it doesn't exist
	if ! gcloud compute firewall-rules describe allow-nativelink-worker --project="$PROJECT" &>/dev/null; then
		echo "Creating firewall rule..."
		gcloud compute firewall-rules create allow-nativelink-worker \
			--project="$PROJECT" \
			--allow="tcp:50051,tcp:50052" \
			--target-tags="nativelink-worker" \
			--description="Allow NativeLink worker traffic"
	fi
fi

echo ""
echo "=== Worker Deployment Complete ==="
echo "Instance: $INSTANCE_NAME"
echo "Zone: $ZONE"
echo "Connect: gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT"
echo "Logs: gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT --command='journalctl -f'"
