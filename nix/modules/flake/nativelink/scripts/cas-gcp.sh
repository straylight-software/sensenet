#!/usr/bin/env bash
# Deploy NativeLink CAS to GCP
# Uses startup script approach instead of containers (nix2gpu is x86_64 only)
set -euo pipefail

PROJECT="@gcpProject@"
ZONE="@gcpZone@"
INSTANCE_NAME="@appPrefix@-cas"
MACHINE_TYPE="e2-standard-2" # CAS needs 2 vCPU, 8GB for nix build
DISK_SIZE="@casVolumeSize@"
CAS_PORT="@casPort@"
NATIVELINK_STORE="@nativelinkStore@"
CAS_CONFIG="@casConfig@"

echo "=== Deploying NativeLink CAS to GCP ==="
echo "Project: $PROJECT"
echo "Zone: $ZONE"
echo "Instance: $INSTANCE_NAME"
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

log "=== NativeLink CAS Startup ==="

# Mount CAS data disk
mkdir -p /data/cas
if ! mountpoint -q /data/cas; then
    log "Mounting CAS data disk..."
    mount -o discard,defaults /dev/disk/by-id/google-cas-data /data/cas || {
        log "Formatting CAS data disk..."
        mkfs.ext4 -F /dev/disk/by-id/google-cas-data
        mount -o discard,defaults /dev/disk/by-id/google-cas-data /data/cas
    }
fi

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
    ARCH=$(uname -m)
    if [[ "$ARCH" == "aarch64" ]]; then
        nix build github:TraceMachina/nativelink#packages.aarch64-linux.nativelink --out-link /tmp/nativelink-result
    else
        nix build github:TraceMachina/nativelink#packages.x86_64-linux.nativelink --out-link /tmp/nativelink-result
    fi
    NATIVELINK_PATH=$(readlink -f /tmp/nativelink-result)
}

# Write CAS config
mkdir -p /etc/nativelink
cat > /etc/nativelink/cas.json <<'CONFIG'
CAS_CONFIG_PLACEHOLDER
CONFIG

# Ensure CAS directories exist
mkdir -p /data/cas/{content,ac}
chown -R nobody:nogroup /data/cas 2>/dev/null || true

log "Starting NativeLink CAS..."
exec "$NATIVELINK_PATH/bin/nativelink" /etc/nativelink/cas.json
SCRIPT
)

# Substitute placeholders
STARTUP_SCRIPT="${STARTUP_SCRIPT//NATIVELINK_STORE_PLACEHOLDER/$NATIVELINK_STORE}"
STARTUP_SCRIPT="${STARTUP_SCRIPT//CAS_CONFIG_PLACEHOLDER/$(cat "$CAS_CONFIG")}"

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

	# Reserve static IP for CAS
	if ! gcloud compute addresses describe "$INSTANCE_NAME-ip" --region="${ZONE%-*}" --project="$PROJECT" &>/dev/null; then
		echo "Reserving static IP..."
		gcloud compute addresses create "$INSTANCE_NAME-ip" \
			--region="${ZONE%-*}" \
			--project="$PROJECT"
	fi

	STATIC_IP=$(gcloud compute addresses describe "$INSTANCE_NAME-ip" --region="${ZONE%-*}" --project="$PROJECT" --format="get(address)")

	# Create persistent disk for CAS data
	if ! gcloud compute disks describe "$INSTANCE_NAME-data" --zone="$ZONE" --project="$PROJECT" &>/dev/null; then
		echo "Creating persistent disk..."
		gcloud compute disks create "$INSTANCE_NAME-data" \
			--zone="$ZONE" \
			--project="$PROJECT" \
			--size="$DISK_SIZE" \
			--type="pd-ssd"
	fi

	# Create instance with Ubuntu (for nix support)
	gcloud compute instances create "$INSTANCE_NAME" \
		--zone="$ZONE" \
		--project="$PROJECT" \
		--machine-type="$MACHINE_TYPE" \
		--boot-disk-size="20GB" \
		--boot-disk-type="pd-standard" \
		--disk="name=$INSTANCE_NAME-data,device-name=cas-data,mode=rw" \
		--image-family="ubuntu-2204-lts" \
		--image-project="ubuntu-os-cloud" \
		--metadata-from-file="startup-script=$STARTUP_FILE" \
		--tags="nativelink-cas" \
		--address="$STATIC_IP" \
		--scopes="cloud-platform"

	# Create firewall rule if it doesn't exist
	if ! gcloud compute firewall-rules describe allow-nativelink-cas --project="$PROJECT" &>/dev/null; then
		echo "Creating firewall rule..."
		gcloud compute firewall-rules create allow-nativelink-cas \
			--project="$PROJECT" \
			--allow="tcp:$CAS_PORT" \
			--target-tags="nativelink-cas" \
			--description="Allow NativeLink CAS traffic"
	fi

	echo ""
	echo "CAS IP: $STATIC_IP"
fi

echo ""
echo "=== CAS Deployment Complete ==="
echo "Instance: $INSTANCE_NAME"
echo "Port: $CAS_PORT"
echo "Connect: gcloud compute ssh $INSTANCE_NAME --zone=$ZONE --project=$PROJECT"
