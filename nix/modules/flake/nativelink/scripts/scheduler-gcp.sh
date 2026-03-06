#!/usr/bin/env bash
# Deploy NativeLink scheduler to GCP
# Uses startup script approach instead of containers (nix2gpu is x86_64 only)
set -euo pipefail

PROJECT="@gcpProject@"
ZONE="@gcpZone@"
INSTANCE_NAME="@appPrefix@-scheduler"
MACHINE_TYPE="e2-standard-2" # Scheduler needs 2 vCPU, 8GB for nix build
SCHEDULER_PORT="@schedulerPort@"
NATIVELINK_STORE="@nativelinkStore@"
SCHEDULER_CONFIG="@schedulerConfig@"

echo "=== Deploying NativeLink Scheduler to GCP ==="
echo "Project: $PROJECT"
echo "Zone: $ZONE"
echo "Instance: $INSTANCE_NAME"
echo ""

# Create startup script that installs nix and runs nativelink
STARTUP_SCRIPT=$(
	cat <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

export HOME=/root
export PATH=/root/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "=== NativeLink Scheduler Startup ==="

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

# Configure nix for binary caches
mkdir -p /etc/nix
cat > /etc/nix/nix.conf <<EOF
experimental-features = nix-command flakes
substituters = https://cache.nixos.org https://nativelink.cachix.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nativelink.cachix.org-1:adJd7GA3GLPY8T2lCmOOHvCGKfhAbbPNlVd3p0sHj78=
max-jobs = auto
sandbox = false
EOF

# Build/fetch nativelink
log "Fetching NativeLink from Nix store..."
NATIVELINK_PATH="NATIVELINK_STORE_PLACEHOLDER"

# Ensure the store path exists (fetch from binary cache)
nix-store --realise "$NATIVELINK_PATH" || {
    log "Fetching from flake..."
    # For scheduler on x86, use the standard package
    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" ]]; then
        nix build github:TraceMachina/nativelink#packages.aarch64-linux.nativelink --out-link /tmp/nativelink-result
    else
        nix build github:TraceMachina/nativelink#packages.x86_64-linux.nativelink --out-link /tmp/nativelink-result
    fi
    NATIVELINK_PATH=$(readlink -f /tmp/nativelink-result)
}

# Write scheduler config
mkdir -p /etc/nativelink
cat > /etc/nativelink/scheduler.json <<'CONFIG'
SCHEDULER_CONFIG_PLACEHOLDER
CONFIG

log "Starting NativeLink scheduler..."
exec "$NATIVELINK_PATH/bin/nativelink" /etc/nativelink/scheduler.json
SCRIPT
)

# Substitute placeholders
STARTUP_SCRIPT="${STARTUP_SCRIPT//NATIVELINK_STORE_PLACEHOLDER/$NATIVELINK_STORE}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//SCHEDULER_CONFIG_PLACEHOLDER/$(cat "$SCHEDULER_CONFIG")}"

# Write startup script to temp file
STARTUP_FILE=$(mktemp)
echo "$STARTUP_SCRIPT" >"$STARTUP_FILE"
# shellcheck disable=SC2064
trap "rm -f $STARTUP_FILE" EXIT

# Check if instance exists
if gcloud compute instances describe "$INSTANCE_NAME" --zone="$ZONE" --project="$PROJECT" &>/dev/null; then
	echo "Instance $INSTANCE_NAME already exists"

	# Update startup script
	echo "Updating startup script..."
	gcloud compute instances add-metadata "$INSTANCE_NAME" \
		--zone="$ZONE" \
		--project="$PROJECT" \
		--metadata-from-file="startup-script=$STARTUP_FILE"

	read -p "Restart instance to apply changes? [y/N] " -n 1 -r
	echo
	if [[ $REPLY =~ ^[Yy]$ ]]; then
		gcloud compute instances reset "$INSTANCE_NAME" --zone="$ZONE" --project="$PROJECT"
	fi
else
	echo "Creating instance $INSTANCE_NAME..."

	# Reserve static IP for scheduler
	if ! gcloud compute addresses describe "$INSTANCE_NAME-ip" --region="${ZONE%-*}" --project="$PROJECT" &>/dev/null; then
		echo "Reserving static IP..."
		gcloud compute addresses create "$INSTANCE_NAME-ip" \
			--region="${ZONE%-*}" \
			--project="$PROJECT"
	fi

	STATIC_IP=$(gcloud compute addresses describe "$INSTANCE_NAME-ip" --region="${ZONE%-*}" --project="$PROJECT" --format="get(address)")

	# Create instance with Ubuntu (for nix support)
	gcloud compute instances create "$INSTANCE_NAME" \
		--zone="$ZONE" \
		--project="$PROJECT" \
		--machine-type="$MACHINE_TYPE" \
		--boot-disk-size="20GB" \
		--boot-disk-type="pd-standard" \
		--image-family="ubuntu-2204-lts" \
		--image-project="ubuntu-os-cloud" \
		--metadata-from-file="startup-script=$STARTUP_FILE" \
		--tags="nativelink-scheduler" \
		--address="$STATIC_IP" \
		--scopes="cloud-platform"

	# Create firewall rule if it doesn't exist
	if ! gcloud compute firewall-rules describe allow-nativelink-scheduler --project="$PROJECT" &>/dev/null; then
		echo "Creating firewall rule..."
		gcloud compute firewall-rules create allow-nativelink-scheduler \
			--project="$PROJECT" \
			--allow="tcp:$SCHEDULER_PORT" \
			--target-tags="nativelink-scheduler" \
			--description="Allow NativeLink scheduler traffic"
	fi

	echo ""
	echo "Scheduler IP: $STATIC_IP"
fi

echo ""
echo "=== Scheduler Deployment Complete ==="
echo "Instance: $INSTANCE_NAME"
echo "Port: $SCHEDULER_PORT"
echo "Connect: gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT"
