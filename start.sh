#!/usr/bin/env bash
# Configure the dashboard URLs, preflight, then bring the whole stack up.
#   ./start.sh
set -euo pipefail
cd "$(dirname "$0")"

[ -f .env ] || { echo "no .env — cp .env.example .env and fill it in"; exit 1; }
set -a; . ./.env; set +a
host="${TAILNET_HOST:-}"

# Radicale will not even start without its htpasswd file; the real one is
# gitignored so hashes never get committed.
if [ ! -f radicale/users ]; then
  cp radicale/users.example radicale/users
  echo "created radicale/users from the template — add a user line before logging into DAV"
fi

# ── dashboard URLs ────────────────────────────────────────────────────────────
# Homepage cannot read env vars for hrefs, so the YAML carries __HOST__ tokens.
# Underscores are not legal in a hostname: an unreplaced token throws
# "TypeError: Failed to construct 'URL': Invalid URL" all over the browser
# console. So substitute here, every run, idempotently — no manual step to forget.
if [ -n "$host" ]; then
  # repair damage from an earlier run that substituted an empty host
  # (`|| true`: grep exits 1 when it finds nothing, and pipefail + set -e would
  # abort the whole script for the normal case)
  { grep -rl "https://:" homepage/ 2>/dev/null | xargs -r sed -i "s|https://:|https://__HOST__:|g"; } || true
  if grep -rq "__HOST__" homepage/ 2>/dev/null; then
    grep -rl "__HOST__" homepage/ | xargs -r sed -i "s|__HOST__|$host|g"
    echo "dashboard URLs set to $host"
  fi
fi

leftover=$(grep -rn "__HOST__\|https://:" homepage/ 2>/dev/null || true)
if [ -n "$leftover" ]; then
  echo "FAIL: dashboard URLs are still not concrete — Homepage will break:"
  echo "$leftover"
  echo "Set TAILNET_HOST in .env, then re-run ./start.sh"
  [ "${SKIP_PREFLIGHT:-0}" = "1" ] || exit 1
fi

if ! ./preflight.sh; then
  echo
  echo "preflight failed. Nothing was started."
  echo "Fix the FAIL lines, or bypass once with:  SKIP_PREFLIGHT=1 ./start.sh"
  [ "${SKIP_PREFLIGHT:-0}" = "1" ] || exit 1
fi

docker compose up -d
docker compose ps
echo
echo "now publish them on the tailnet:  ./serve.sh"
echo "then: README step 2 (ntfy ACL), step 3 (beszel token), step 5 (radicale user)"
