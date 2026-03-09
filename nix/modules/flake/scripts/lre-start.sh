#!/usr/bin/env bash
set -euo pipefail

# lre-start: Start NativeLink for local remote execution with sensenet
#
# Usage:
#   lre-start [--port=PORT] [--status] [--stop]
#
# This starts NativeLink with:
#   - CAS (content-addressed storage)
#   - Action cache
#   - Scheduler
#   - Local worker (executes on this machine)

PORT="${LRE_PORT:-50051}"
WORKER_PORT="${LRE_WORKER_PORT:-50061}"
CONFIG_DIR="${XDG_RUNTIME_DIR:-/tmp}/nativelink"
NATIVELINK="@nativelink@"

show_help() {
	echo "lre-start: Start NativeLink for local remote execution"
	echo ""
	echo "Usage: lre-start [OPTIONS]"
	echo ""
	echo "Options:"
	echo "  --port=PORT        Public API port (default: 50051)"
	echo "  --worker-port=PORT Worker API port (default: 50061)"
	echo "  --status           Show status of running instance"
	echo "  --stop             Stop running instance"
	echo "  --help             Show this help"
}

show_status() {
	if [[ -f "$CONFIG_DIR/nativelink.pid" ]]; then
		PID=$(cat "$CONFIG_DIR/nativelink.pid")
		if kill -0 "$PID" 2>/dev/null; then
			echo "NativeLink running (PID: $PID)"
			echo "  Public API: localhost:$PORT"
			echo "  Worker API: localhost:$WORKER_PORT"
			echo "  Log: $CONFIG_DIR/nativelink.log"
			return 0
		fi
	fi
	echo "NativeLink not running"
	return 1
}

stop_instance() {
	if [[ -f "$CONFIG_DIR/nativelink.pid" ]]; then
		PID=$(cat "$CONFIG_DIR/nativelink.pid")
		if kill -0 "$PID" 2>/dev/null; then
			echo "Stopping NativeLink (PID: $PID)..."
			kill "$PID"
			rm -f "$CONFIG_DIR/nativelink.pid"
			echo "Stopped"
			return 0
		fi
	fi
	echo "NativeLink not running"
	return 1
}

# Parse arguments
for arg in "$@"; do
	case $arg in
	--port=*)
		PORT="${arg#*=}"
		;;
	--worker-port=*)
		WORKER_PORT="${arg#*=}"
		;;
	--status)
		show_status
		exit $?
		;;
	--stop)
		stop_instance
		exit $?
		;;
	--help | -h)
		show_help
		exit 0
		;;
	*)
		echo "Unknown option: $arg"
		show_help
		exit 1
		;;
	esac
done

# Check if already running
if [[ -f "$CONFIG_DIR/nativelink.pid" ]]; then
	PID=$(cat "$CONFIG_DIR/nativelink.pid")
	if kill -0 "$PID" 2>/dev/null; then
		echo "NativeLink already running (PID: $PID)"
		echo "Use --stop to stop it first"
		exit 1
	fi
fi

# Detect CPU architecture
ARCH=$(uname -m)
case "$ARCH" in
x86_64)
	ISA="x86-64"
	;;
aarch64 | arm64)
	ISA="aarch64"
	;;
*)
	ISA="$ARCH"
	;;
esac

# Get CPU count
CPU_COUNT=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo "4")

# Get memory in KB
MEM_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo "8000000")

# Create config directory
mkdir -p "$CONFIG_DIR"

# Write config file with local worker
cat >"$CONFIG_DIR/config.json" <<EOF
{
  "stores": [
    {
      "name": "AC_MAIN_STORE",
      "filesystem": {
        "content_path": "$CONFIG_DIR/ac/content",
        "temp_path": "$CONFIG_DIR/ac/tmp",
        "eviction_policy": { "max_bytes": 1073741824 }
      }
    },
    {
      "name": "CAS_FAST_SLOW_STORE",
      "fast_slow": {
        "fast": {
          "filesystem": {
            "content_path": "$CONFIG_DIR/cas/content",
            "temp_path": "$CONFIG_DIR/cas/tmp",
            "eviction_policy": { "max_bytes": 10737418240 }
          }
        },
        "slow": { "noop": {} }
      }
    }
  ],
  "schedulers": [
    {
      "name": "MAIN_SCHEDULER",
      "simple": {
        "supported_platform_properties": {
          "cpu_count": "minimum",
          "memory_kb": "minimum",
          "OSFamily": "priority",
          "container-image": "priority",
          "ISA": "exact"
        }
      }
    }
  ],
  "workers": [
    {
      "local": {
        "worker_api_endpoint": {
          "uri": "grpc://127.0.0.1:$WORKER_PORT"
        },
        "cas_fast_slow_store": "CAS_FAST_SLOW_STORE",
        "upload_action_result": {
          "ac_store": "AC_MAIN_STORE"
        },
        "work_directory": "$CONFIG_DIR/work",
        "platform_properties": {
          "cpu_count": { "values": ["$CPU_COUNT"] },
          "memory_kb": { "values": ["$MEM_KB"] },
          "OSFamily": { "values": ["linux"] },
          "container-image": { "values": [""] },
          "ISA": { "values": ["$ISA"] }
        }
      }
    }
  ],
  "servers": [
    {
      "name": "public",
      "listener": {
        "http": { "socket_address": "0.0.0.0:$PORT" }
      },
      "services": {
        "cas": [{ "instance_name": "main", "cas_store": "CAS_FAST_SLOW_STORE" }],
        "ac": [{ "instance_name": "main", "ac_store": "AC_MAIN_STORE" }],
        "execution": [{ "instance_name": "main", "cas_store": "CAS_FAST_SLOW_STORE", "scheduler": "MAIN_SCHEDULER" }],
        "capabilities": [{ "instance_name": "main", "remote_execution": { "scheduler": "MAIN_SCHEDULER" } }],
        "bytestream": [{ "instance_name": "main", "cas_store": "CAS_FAST_SLOW_STORE" }],
        "health": {}
      }
    },
    {
      "name": "worker",
      "listener": {
        "http": { "socket_address": "127.0.0.1:$WORKER_PORT" }
      },
      "services": {
        "worker_api": { "scheduler": "MAIN_SCHEDULER" },
        "admin": {},
        "health": {}
      }
    }
  ],
  "global": { "max_open_files": 65536 }
}
EOF

# Create storage directories
mkdir -p "$CONFIG_DIR/cas/content" "$CONFIG_DIR/cas/tmp"
mkdir -p "$CONFIG_DIR/ac/content" "$CONFIG_DIR/ac/tmp"
mkdir -p "$CONFIG_DIR/work"

# Start NativeLink
echo "Starting NativeLink..."
echo "  Public API: localhost:$PORT"
echo "  Worker API: localhost:$WORKER_PORT"
$NATIVELINK "$CONFIG_DIR/config.json" >"$CONFIG_DIR/nativelink.log" 2>&1 &
PID=$!
echo "$PID" >"$CONFIG_DIR/nativelink.pid"

# Wait a moment and check if it started
sleep 2
if kill -0 "$PID" 2>/dev/null; then
	echo "NativeLink started successfully (PID: $PID)"
	echo ""
	echo "Usage:"
	echo "  sensenet build --remote //..."
	echo "  lre-start --status"
	echo "  lre-start --stop"
else
	echo "Failed to start NativeLink"
	cat "$CONFIG_DIR/nativelink.log"
	exit 1
fi
