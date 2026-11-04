#!/usr/bin/env bash
# Stop the stack. Data lives in named volumes and is never touched.
#   ./stop.sh            stop containers, keep volumes
#   ./stop.sh --down     remove containers + network, keep volumes
set -euo pipefail
cd "$(dirname "$0")"
if [ "${1:-}" = "--down" ]; then
  docker compose down
  echo "containers and network removed. volumes kept:"
  docker volume ls --filter name=selfhost_
else
  docker compose stop
fi
