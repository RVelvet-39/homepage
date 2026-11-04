#!/usr/bin/env bash
# Memos reader: scripts/memos.sh tasks | raw [n] | health
set -euo pipefail
exec python3 "$(dirname "$0")/memos.py" "$@"
