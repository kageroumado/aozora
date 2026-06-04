#!/bin/bash
# Dump the assembled context via the daemon's IPC socket.
# Uses the same code path as inference — shows exactly what the model sees.
#
# Usage: ./scripts/dump-context-cli.sh <user@host>
#   host: SSH host running the Aozora daemon

HOST="${1:?usage: dump-context-cli.sh <user@host>}"
DUMP_PATH="~/.aozora/debug-context.txt"

echo "Triggering context dump on $HOST..."

# Send a dump_context tool call via the IPC socket
# The daemon's tool registry handles it and writes to debug-context.txt
ssh "$HOST" "echo '{\"sendMessage\":{\"sessionKey\":\"cli-dump\",\"text\":\"Please run dump_context immediately and nothing else.\",\"_0\":null}}' | nc -U ~/.aozora/daemon.sock -w 5 2>/dev/null; sleep 8; echo '---'; head -50 $DUMP_PATH 2>/dev/null && echo '...' && echo '---' && wc -l $DUMP_PATH 2>/dev/null"
