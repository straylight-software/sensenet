#!/usr/bin/env bash
# NativeLink GCP Gigafleet Deployment Script
#
# Deploys NativeLink CAS, Scheduler, and Workers to GCP instances.
# Uses systemd user services for process management.
#
# Usage:
#   ./deploy.sh [component]
#
# Components:
#   all        - Deploy everything (default)
#   cas        - Deploy CAS server only
#   scheduler  - Deploy Scheduler only
#   workers    - Deploy all workers
#   worker-N   - Deploy specific worker (e.g., worker-1)
#
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SENSENET_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"

# GCP instance IPs
declare -A INSTANCES=(
	["giga-x86-0"]="34.28.196.149" # CAS + Scheduler
	["giga-x86-1"]="34.31.207.223" # Worker (x86_64)
	["giga-x86-2"]="34.16.66.17"   # Worker (x86_64)
	["giga-x86-3"]="34.132.123.66" # Worker (x86_64)
	["giga-arm-0"]="34.58.206.16"  # Worker (aarch64)
	["giga-arm-1"]="34.46.157.173" # Worker (aarch64)
)

# Architecture mapping
declare -A INSTANCE_ARCH=(
	["giga-x86-0"]="x86_64"
	["giga-x86-1"]="x86_64"
	["giga-x86-2"]="x86_64"
	["giga-x86-3"]="x86_64"
	["giga-arm-0"]="aarch64"
	["giga-arm-1"]="aarch64"
)

# ISA mapping for NativeLink platform properties
declare -A INSTANCE_ISA=(
	["giga-x86-0"]="x86-64"
	["giga-x86-1"]="x86-64"
	["giga-x86-2"]="x86-64"
	["giga-x86-3"]="x86-64"
	["giga-arm-0"]="aarch64"
	["giga-arm-1"]="aarch64"
)

SSH_USER="b7r6"
REMOTE_DATA_DIR="\$HOME/nativelink/data"
REMOTE_CONFIG_DIR="\$HOME/nativelink/config"
REMOTE_BIN_DIR="\$HOME/nativelink/bin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $*"; }
success() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')]${NC} $*"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')]${NC} $*" >&2; }

ssh_cmd() {
	local host="$1"
	shift
	ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SSH_USER}@${host}" "$@"
}

scp_to() {
	local src="$1"
	local host="$2"
	local dst="$3"
	scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$src" "${SSH_USER}@${host}:${dst}"
}

# Build NativeLink for a given architecture
build_nativelink() {
	local arch="$1"
	local system

	case "$arch" in
	x86_64) system="x86_64-linux" ;;
	aarch64) system="aarch64-linux" ;;
	*)
		error "Unknown architecture: $arch"
		exit 1
		;;
	esac

	log "Building NativeLink for $system..."
	nix build "github:TraceMachina/nativelink#packages.${system}.default" \
		--option substituters "https://cache.nixos.org https://nativelink.cachix.org" \
		--option trusted-public-keys "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nativelink.cachix.org-1:bLBCoRVYGLwp0PPkyKLpCqAGJIsJmsfBgppXwRmKhPs=" \
		--print-out-paths
}

# Get the store path for a given arch
get_nativelink_store_path() {
	local arch="$1"
	local system

	case "$arch" in
	x86_64) system="x86_64-linux" ;;
	aarch64) system="aarch64-linux" ;;
	*)
		error "Unknown architecture: $arch"
		exit 1
		;;
	esac

	nix build "github:TraceMachina/nativelink#packages.${system}.default" \
		--option substituters "https://cache.nixos.org https://nativelink.cachix.org" \
		--option trusted-public-keys "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= nativelink.cachix.org-1:bLBCoRVYGLwp0PPkyKLpCqAGJIsJmsfBgppXwRmKhPs=" \
		--no-link --print-out-paths 2>/dev/null
}

# Setup remote instance (directories, nix config)
setup_instance() {
	local name="$1"
	local ip="${INSTANCES[$name]}"

	log "Setting up $name ($ip)..."

	ssh_cmd "$ip" "
    mkdir -p ~/nativelink/{data,config,bin,logs}
    mkdir -p ~/nativelink/data/{cas,ac,worker,work}
    mkdir -p ~/nativelink/data/cas/{content,tmp}
    mkdir -p ~/nativelink/data/ac/{content,tmp}
    mkdir -p ~/nativelink/data/worker/{content,tmp}
    mkdir -p ~/.config/systemd/user
  "
	success "  Setup complete for $name"
}

# Deploy CAS to giga-x86-0
deploy_cas() {
	local name="giga-x86-0"
	local ip="${INSTANCES[$name]}"
	local arch="${INSTANCE_ARCH[$name]}"

	log "Deploying CAS to $name ($ip)..."

	# Build NativeLink
	local store_path
	store_path=$(get_nativelink_store_path "$arch")
	log "  NativeLink store path: $store_path"

	# Setup instance
	setup_instance "$name"

	# Prepare config (replace placeholders)
	local config_content
	config_content=$(cat "$SCRIPT_DIR/cas.json5" | sed "s|NATIVELINK_DATA_DIR|\$HOME/nativelink/data|g")

	# Copy config
	log "  Copying CAS config..."
	ssh_cmd "$ip" "cat > ~/nativelink/config/cas.json5" <<<"$config_content"

	# Copy NativeLink binary to remote (if not already cached)
	log "  Ensuring NativeLink is available on remote..."
	ssh_cmd "$ip" "
    if [[ ! -e '$store_path/bin/nativelink' ]]; then
      echo 'Fetching NativeLink from cache...'
      nix build 'github:TraceMachina/nativelink' --no-link
    fi
    ln -sf '$store_path/bin/nativelink' ~/nativelink/bin/nativelink
  "

	# Create systemd service
	log "  Creating systemd service..."
	ssh_cmd "$ip" "cat > ~/.config/systemd/user/nativelink-cas.service" <<'EOF'
[Unit]
Description=NativeLink CAS Server
After=network.target

[Service]
Type=simple
ExecStart=%h/nativelink/bin/nativelink %h/nativelink/config/cas.json5
WorkingDirectory=%h/nativelink
Restart=always
RestartSec=5
Environment=RUST_LOG=info
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

	# Enable and start service
	log "  Starting CAS service..."
	ssh_cmd "$ip" "
    systemctl --user daemon-reload
    systemctl --user enable nativelink-cas.service
    systemctl --user restart nativelink-cas.service
  "

	# Wait and check status
	sleep 2
	if ssh_cmd "$ip" "systemctl --user is-active nativelink-cas.service" | grep -q "active"; then
		success "  CAS deployed and running on $name"
	else
		error "  CAS failed to start on $name"
		ssh_cmd "$ip" "systemctl --user status nativelink-cas.service" || true
		return 1
	fi
}

# Deploy Scheduler to giga-x86-0
deploy_scheduler() {
	local name="giga-x86-0"
	local ip="${INSTANCES[$name]}"
	local arch="${INSTANCE_ARCH[$name]}"

	log "Deploying Scheduler to $name ($ip)..."

	# Build NativeLink
	local store_path
	store_path=$(get_nativelink_store_path "$arch")

	# Setup instance
	setup_instance "$name"

	# Copy config
	log "  Copying Scheduler config..."
	scp_to "$SCRIPT_DIR/scheduler.json5" "$ip" "~/nativelink/config/scheduler.json5"

	# Ensure NativeLink binary is available
	ssh_cmd "$ip" "ln -sf '$store_path/bin/nativelink' ~/nativelink/bin/nativelink 2>/dev/null || true"

	# Create systemd service
	log "  Creating systemd service..."
	ssh_cmd "$ip" "cat > ~/.config/systemd/user/nativelink-scheduler.service" <<'EOF'
[Unit]
Description=NativeLink Scheduler
After=network.target nativelink-cas.service
Requires=nativelink-cas.service

[Service]
Type=simple
ExecStart=%h/nativelink/bin/nativelink %h/nativelink/config/scheduler.json5
WorkingDirectory=%h/nativelink
Restart=always
RestartSec=5
Environment=RUST_LOG=info
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

	# Enable and start service
	log "  Starting Scheduler service..."
	ssh_cmd "$ip" "
    systemctl --user daemon-reload
    systemctl --user enable nativelink-scheduler.service
    systemctl --user restart nativelink-scheduler.service
  "

	# Wait and check status
	sleep 2
	if ssh_cmd "$ip" "systemctl --user is-active nativelink-scheduler.service" | grep -q "active"; then
		success "  Scheduler deployed and running on $name"
	else
		error "  Scheduler failed to start on $name"
		ssh_cmd "$ip" "systemctl --user status nativelink-scheduler.service" || true
		return 1
	fi
}

# Deploy Worker to a specific instance
deploy_worker() {
	local name="$1"
	local ip="${INSTANCES[$name]}"
	local arch="${INSTANCE_ARCH[$name]}"
	local isa="${INSTANCE_ISA[$name]}"

	log "Deploying Worker to $name ($ip, $arch, ISA=$isa)..."

	# Build NativeLink for this architecture
	local store_path
	store_path=$(get_nativelink_store_path "$arch")
	log "  NativeLink store path: $store_path"

	# Setup instance
	setup_instance "$name"

	# Prepare config (replace placeholders)
	local config_content
	config_content=$(cat "$SCRIPT_DIR/worker.json5" |
		sed "s|NATIVELINK_DATA_DIR|\$HOME/nativelink/data|g" |
		sed "s|WORKER_ISA|$isa|g")

	# Copy config
	log "  Copying Worker config..."
	ssh_cmd "$ip" "cat > ~/nativelink/config/worker.json5" <<<"$config_content"

	# Ensure NativeLink is available on remote
	log "  Ensuring NativeLink is available on remote..."
	ssh_cmd "$ip" "
    if [[ ! -e '$store_path/bin/nativelink' ]]; then
      echo 'Fetching NativeLink from cache...'
      nix build 'github:TraceMachina/nativelink' --no-link
    fi
    ln -sf '$store_path/bin/nativelink' ~/nativelink/bin/nativelink
  "

	# Create systemd service
	log "  Creating systemd service..."
	ssh_cmd "$ip" "cat > ~/.config/systemd/user/nativelink-worker.service" <<'EOF'
[Unit]
Description=NativeLink Worker
After=network.target

[Service]
Type=simple
ExecStart=%h/nativelink/bin/nativelink %h/nativelink/config/worker.json5
WorkingDirectory=%h/nativelink
Restart=always
RestartSec=5
Environment=RUST_LOG=info
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

	# Enable and start service
	log "  Starting Worker service..."
	ssh_cmd "$ip" "
    systemctl --user daemon-reload
    systemctl --user enable nativelink-worker.service
    systemctl --user restart nativelink-worker.service
  "

	# Wait and check status
	sleep 2
	if ssh_cmd "$ip" "systemctl --user is-active nativelink-worker.service" | grep -q "active"; then
		success "  Worker deployed and running on $name"
	else
		error "  Worker failed to start on $name"
		ssh_cmd "$ip" "systemctl --user status nativelink-worker.service" || true
		return 1
	fi
}

# Deploy all workers
deploy_workers() {
	local workers=("giga-x86-1" "giga-x86-2" "giga-x86-3" "giga-arm-0" "giga-arm-1")

	for worker in "${workers[@]}"; do
		deploy_worker "$worker"
	done
}

# Status check
status() {
	log "Checking NativeLink status across all instances..."

	for name in "${!INSTANCES[@]}"; do
		local ip="${INSTANCES[$name]}"
		echo -e "\n${BLUE}=== $name ($ip) ===${NC}"

		if [[ "$name" == "giga-x86-0" ]]; then
			echo -n "  CAS:       "
			ssh_cmd "$ip" "systemctl --user is-active nativelink-cas.service 2>/dev/null || echo 'not running'"
			echo -n "  Scheduler: "
			ssh_cmd "$ip" "systemctl --user is-active nativelink-scheduler.service 2>/dev/null || echo 'not running'"
		else
			echo -n "  Worker:    "
			ssh_cmd "$ip" "systemctl --user is-active nativelink-worker.service 2>/dev/null || echo 'not running'"
		fi
	done
}

# Stop all services
stop_all() {
	log "Stopping NativeLink services on all instances..."

	for name in "${!INSTANCES[@]}"; do
		local ip="${INSTANCES[$name]}"
		log "Stopping services on $name..."

		if [[ "$name" == "giga-x86-0" ]]; then
			ssh_cmd "$ip" "
        systemctl --user stop nativelink-scheduler.service 2>/dev/null || true
        systemctl --user stop nativelink-cas.service 2>/dev/null || true
      "
		else
			ssh_cmd "$ip" "systemctl --user stop nativelink-worker.service 2>/dev/null || true"
		fi
	done

	success "All services stopped"
}

# Main
main() {
	local component="${1:-all}"

	case "$component" in
	all)
		deploy_cas
		deploy_scheduler
		deploy_workers
		echo ""
		status
		;;
	cas)
		deploy_cas
		;;
	scheduler)
		deploy_scheduler
		;;
	workers)
		deploy_workers
		;;
	worker-*)
		local worker_name="${component/worker-/giga-x86-}"
		if [[ -z "${INSTANCES[$worker_name]:-}" ]]; then
			# Try arm
			worker_name="${component/worker-/giga-arm-}"
			# Adjust for worker-4 -> giga-arm-0, worker-5 -> giga-arm-1
			case "$component" in
			worker-4) worker_name="giga-arm-0" ;;
			worker-5) worker_name="giga-arm-1" ;;
			esac
		fi
		if [[ -z "${INSTANCES[$worker_name]:-}" ]]; then
			error "Unknown worker: $component"
			exit 1
		fi
		deploy_worker "$worker_name"
		;;
	status)
		status
		;;
	stop)
		stop_all
		;;
	*)
		echo "Usage: $0 [all|cas|scheduler|workers|worker-N|status|stop]"
		exit 1
		;;
	esac
}

main "$@"
