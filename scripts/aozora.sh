#!/bin/bash
# Aozora daemon launcher with auto-rebuild support.
#
# Usage:
#   ./scripts/aozora.sh              # Build + run
#   ./scripts/aozora.sh rebuild      # Rebuild + restart (sends ping)
#   ./scripts/aozora.sh stop         # Stop daemon
#   ./scripts/aozora.sh status       # Check if running
#
# The daemon PID is stored in ~/.aozora/daemon.pid.

set -euo pipefail

AOZORA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PID_FILE="$HOME/.aozora/daemon.pid"
LOG_FILE="$HOME/.aozora/daemon.log"
BUILD_DIR="$AOZORA_DIR/.build/release"
BINARY="$BUILD_DIR/Aozora"

mkdir -p "$HOME/.aozora"

# ── Functions ────────────────────────────────────────────────────────────

build() {
    echo "🔨 Building Aozora daemon..."
    cd "$AOZORA_DIR"
    swift build -c release --product Aozora 2>&1 | tail -5
    echo "✅ Build complete: $BINARY"
}

stop_daemon() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "⏹  Stopping daemon (PID $pid)..."
            kill "$pid"
            # Wait up to 5 seconds for graceful shutdown
            for i in {1..50}; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
            # Force kill if still running
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid"
            fi
            echo "   Stopped."
        fi
        rm -f "$PID_FILE"
    fi
}

start_daemon() {
    echo "🌅 Starting Aozora daemon..."
    nohup "$BINARY" >> "$LOG_FILE" 2>&1 &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    echo "   PID: $pid"
    echo "   Log: $LOG_FILE"
    echo "   PID file: $PID_FILE"
}

status() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "🟢 Aozora daemon running (PID $pid)"
            return 0
        else
            echo "🔴 Aozora daemon not running (stale PID file)"
            rm -f "$PID_FILE"
            return 1
        fi
    else
        echo "🔴 Aozora daemon not running"
        return 1
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────

case "${1:-run}" in
    run)
        build
        stop_daemon
        start_daemon
        ;;
    rebuild)
        build
        stop_daemon
        start_daemon
        echo "🔄 Rebuild complete. Daemon restarted."
        ;;
    stop)
        stop_daemon
        ;;
    status)
        status
        ;;
    build)
        build
        ;;
    logs)
        tail -f "$LOG_FILE"
        ;;
    *)
        echo "Usage: $0 {run|rebuild|stop|status|build|logs}"
        exit 1
        ;;
esac
