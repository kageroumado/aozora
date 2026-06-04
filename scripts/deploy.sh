#!/bin/bash
set -euo pipefail

AOZORA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_DIR="$HOME/.aozora/bin"
BINARY="$INSTALL_DIR/aozora"
PLIST="$HOME/Library/LaunchAgents/ai.aozora.daemon.plist"
PLIST_TEMPLATE="$AOZORA_DIR/scripts/ai.aozora.daemon.plist"
SERVICE="ai.aozora.daemon"

# Optional code-signing identity, e.g.
#   export AOZORA_SIGNING_IDENTITY="Apple Development: you@example.com (TEAMID)"
# Falls back to ad-hoc signing when unset.
SIGNING_IDENTITY="${AOZORA_SIGNING_IDENTITY:-}"

mkdir -p "$INSTALL_DIR"

echo "1/4  Building release..."
cd "$AOZORA_DIR"
swift build -c release --product Aozora 2>&1 | tail -3

echo "2/4  Installing to $BINARY"
cp .build/release/Aozora "$BINARY"
chmod +x "$BINARY"

echo "3/4  Signing..."
if [ -n "$SIGNING_IDENTITY" ] && codesign --sign "$SIGNING_IDENTITY" --force "$BINARY" 2>/dev/null; then
    echo "     (signed with $SIGNING_IDENTITY)"
else
    [ -n "$SIGNING_IDENTITY" ] && echo "     (dev cert unavailable, using ad-hoc signing)"
    codesign --sign - --force "$BINARY"
fi

if [ ! -f "$PLIST" ]; then
    echo "     Installing launchd plist to $PLIST"
    sed "s|__HOME__|$HOME|g" "$PLIST_TEMPLATE" > "$PLIST"
fi

echo "4/4  Restarting daemon..."
launchctl unload "$PLIST" 2>/dev/null || true
sleep 1
launchctl load "$PLIST"
sleep 3

if pgrep -f "$BINARY" >/dev/null 2>&1; then
    echo ""
    echo "Deployed. Checking logs..."
    tail -5 ~/.aozora/logs/daemon.log
else
    echo "WARNING: daemon may not have started. Check:"
    echo "  tail -20 ~/.aozora/logs/daemon.log"
    echo "  tail -20 ~/.aozora/logs/daemon.err.log"
fi
