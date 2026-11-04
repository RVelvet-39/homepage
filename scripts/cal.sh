#!/usr/bin/env bash
# Wrapper so callers (cron, agent) do not need the venv path.
#   scripts/cal.sh today
#   scripts/cal.sh next 30
#   scripts/cal.sh add "Write docs" 09:00 90
#   scripts/cal.sh list 7
#   scripts/cal.sh del <uid> --yes
set -euo pipefail
VENV="${CALVENV:-/home/hermes/.venvs/caldav}"
exec "$VENV/bin/python" "$(dirname "$0")/cal.py" "$@"
