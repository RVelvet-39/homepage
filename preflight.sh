#!/usr/bin/env bash
# Preflight for the tailnet stack. Fails loudly before you waste a deploy.
# Usage: ./preflight.sh
set -uo pipefail
cd "$(dirname "$0")"
fail=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }
warn() { printf '  warn  %s\n' "$*"; }

echo "== files"
[ -f .env ] && ok ".env present" || bad ".env missing — cp .env.example .env"
[ -f docker-compose.yml ] && ok "docker-compose.yml present" || bad "docker-compose.yml missing"
# source early: later checks read DOCKER_SOCK / TAILNET_HOST
if [ -f .env ]; then set -a; . ./.env; set +a; fi

echo "== docker"
command -v docker >/dev/null 2>&1 && ok "docker binary" || bad "docker not installed"
if docker compose version >/dev/null 2>&1; then
  prov=$(docker compose version 2>&1 | head -2 | tr '\n' ' ')
  case "$prov" in
    *podman*) ok "compose provider: podman-compose (works, no depends_on used)";;
    *)        ok "compose v2";;
  esac
else
  bad "no compose provider — need docker compose v2 or podman-compose"
fi

echo "== host api socket"
sock="${DOCKER_SOCK:-/var/run/docker.sock}"
if [ -S "$sock" ]; then
  ok "socket present: $sock"
else
  bad "socket missing: $sock"
  echo "        docker engine:   sudo systemctl enable --now docker"
  echo "        podman rootful:  sudo systemctl enable --now podman.socket   -> /run/podman/podman.sock"
  echo "        podman rootless: systemctl --user enable --now podman.socket -> \$XDG_RUNTIME_DIR/podman/podman.sock"
  echo "        no systemd:      sudo podman system service --time=0 unix:///run/podman/podman.sock &"
  echo "        then set DOCKER_SOCK in .env to the path that exists"
fi

echo "== tailscale"
if command -v tailscale >/dev/null 2>&1; then
  ok "tailscale binary"
  state=$(tailscale status --json 2>/dev/null | grep -o '"BackendState": *"[^"]*"' | cut -d'"' -f4 | sed -n '1p')
  [ "$state" = "Running" ] && ok "tailscaled running" || bad "tailscaled state: ${state:-unknown} (run tailscale up)"
  detected=$(tailscale status --json 2>/dev/null \
    | grep -o '"DNSName": *"[^"]*"' | cut -d'"' -f4 | sed 's/\.$//' | sed -n '1p')
  [ -n "$detected" ] && ok "this node: $detected" || bad "could not read MagicDNS name"
else
  bad "tailscale not installed"
  detected=""
fi

echo "== .env values"
if [ -f .env ]; then
  set -a; . ./.env; set +a
  for v in NTFY_ALERT_TOPIC ADMIN_EMAIL BESZEL_ADMIN_PASSWORD \
           LINKDING_ADMIN_USER LINKDING_ADMIN_PASSWORD MINIFLUX_DB_PASSWORD \
           MINIFLUX_ADMIN_USER MINIFLUX_ADMIN_PASSWORD; do
    eval "val=\${$v:-}"
    case "$val" in
      "")                            bad "$v is empty" ;;
      *replace*|*example*|*change*)  bad "$v still a placeholder" ;;
      *)                             ok "$v set" ;;
    esac
  done
  # TAILNET_HOST is checked on shape, not keywords: a real MagicDNS name may
  # legitimately contain "example" or "node".
  case "${TAILNET_HOST:-}" in
    "")            bad "TAILNET_HOST is empty" ;;
    *tailnet-name*) bad "TAILNET_HOST is still the placeholder node.tailnet-name.ts.net" ;;
    *.*)           ok "TAILNET_HOST=$TAILNET_HOST" ;;
    *)             bad "TAILNET_HOST has no dot: $TAILNET_HOST" ;;
  esac
  if [ -n "$detected" ] && [ -n "${TAILNET_HOST:-}" ] && [ "$detected" != "$TAILNET_HOST" ]; then
    bad "TAILNET_HOST=$TAILNET_HOST but this node is $detected"
  fi
  if [ -z "${BESZEL_KEY:-}" ]; then
    warn "BESZEL_KEY empty — beszel-agent will restart-loop (hub -> Add System -> key)"
  fi
  if grep -rq "__HOST__" homepage/ 2>/dev/null; then
    bad "homepage URLs still contain __HOST__ — ./start.sh substitutes it, or run the sed in README step 0"
  fi
  if grep -rq "https://:" homepage/ 2>/dev/null; then
    bad "homepage URLs have an empty host (https://:8443) — re-run ./start.sh to repair"
  fi
fi

echo "== dashboard urls"
# Homepage builds `new URL(href)` for every service; an empty host
# (`https://:8443`) throws "TypeError: Failed to construct 'URL': Invalid URL"
# in the browser console, once per service. Catch it here instead.
urls=$(grep -rhoE 'https?://[^"'"'"' ]+' homepage/ 2>/dev/null | sort -u || true)
if [ -z "$urls" ]; then
  ok "no absolute URLs in homepage config (nothing to validate)"
else
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    rest=${u#*://}
    hostpart=${rest%%/*}
    case "$hostpart" in
      "")                    bad "empty host in $u" ;;
      :*)                    bad "no host before port in $u" ;;
      *__*)                  bad "placeholder left in $u" ;;
      # single-label hosts are fine: http://linkding:9090 is a container name
      *)                     ok "$u" ;;
    esac
  done <<<"$urls"
fi

echo "== homepage bookmarks schema"
if [ -f homepage/bookmarks.yaml ]; then
  # Homepage requires each bookmark to be a mapping with `href`. A bare
  # "- https://…" entry renders "URL constructor: undefined is not a valid URL".
  if grep -nE '^[[:space:]]+-[[:space:]]+https?://' homepage/bookmarks.yaml >/dev/null 2>&1; then
    bad "bookmarks.yaml has bare URL entries (need '- abbr: XX' + 'href: …'):"
    grep -nE '^[[:space:]]+-[[:space:]]+https?://' homepage/bookmarks.yaml | sed 's/^/        /'
  else
    ok "every bookmark uses the href object form"
  fi
fi

echo "== loopback ports"
for p in 2586 3000 3001 5230 5232 8080 8081 8090 9090 45876; do
  if command -v ss >/dev/null 2>&1 && ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
    bad "127.0.0.1:$p already in use"
  else
    ok "127.0.0.1:$p free"
  fi
done

echo "== serve state"
if command -v tailscale >/dev/null 2>&1; then
  if tailscale serve status 2>/dev/null | grep -q "https://"; then
    ok "serve config present (./serve.sh status to inspect, ./serve.sh reset to clear)"
  else
    ok "no serve config yet — ./serve.sh will create it"
  fi
fi

echo
[ "$fail" -eq 0 ] && echo "preflight: PASS" || echo "preflight: FAIL — fix the lines above"
exit "$fail"
