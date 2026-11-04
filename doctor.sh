#!/usr/bin/env bash
# One-shot diagnosis. Answers "why is the dashboard showing that?" without
# guessing: socket, containers, listening ports, HTTP answers, config wiring.
#   ./doctor.sh
set -uo pipefail
cd "$(dirname "$0")"
fail=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

if [ -f .env ]; then set -a; . ./.env; set +a; else bad ".env missing"; fi

echo "== host api socket"
sock="${DOCKER_SOCK:-/var/run/docker.sock}"
if [ -S "$sock" ]; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 --unix-socket "$sock" http://d/v1.40/version || echo 000)
  [ "$code" = "200" ] && ok "$sock answers (HTTP $code)" || bad "$sock exists but API says HTTP $code"
else
  bad "$sock missing — homepage, uptime-kuma, diun and beszel-agent have nothing to talk to (see preflight)"
fi

echo "== containers (what the runtime actually has)"
all=$(docker ps -a --format '{{.Names}}' 2>/dev/null | sort -u || true)
if [ -z "$all" ]; then
  bad "no containers at all — nothing was created"
else
  docker ps -a --format '  {{.Names}}  |  {{.Status}}  |  {{.Ports}}' 2>/dev/null | sed 's/$//'
fi
for n in ntfy homepage uptime-kuma diun beszel beszel-agent memos radicale linkding miniflux miniflux-db privatebin; do
  st=$(docker ps --filter "name=^${n}$" --format '{{.Status}}' 2>/dev/null | sed -n '1p')
  if [ -n "$st" ]; then
    ok "$n — $st"
  elif printf '%s\n' "$all" | grep -qx "$n"; then
    hist=$(docker ps -a --filter "name=^${n}$" --format '{{.Status}}' 2>/dev/null | sed -n '1p')
    bad "$n exists but is not running ($hist) — docker logs $n"
  else
    bad "$n was never created"
  fi
done

echo "== local ports (what tailscale serve proxies to)"
for spec in 2586:ntfy 3000:homepage 3001:uptime-kuma 5230:memos 5232:radicale 8080:miniflux 8081:privatebin 8090:beszel 9090:linkding; do
  p=${spec%%:*}; name=${spec##*:}
  # Probe TCP/HTTP, not the socket table: rootless podman forwards ports from a
  # user namespace, so `ss` can miss a listener that really does answer.
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:$p/" 2>/dev/null || echo 000)
  case "$code" in
    2*|3*|401|403) ok "$name :$p -> HTTP $code" ;;
    000)
      if ss -ltn "sport = :$p" 2>/dev/null | grep -q LISTEN; then
        warn "$name :$p listening but no HTTP answer yet (starting or misconfigured)"
      else
        bad "$name :$p nothing answers — container down, or the port mapping is missing"
      fi
      ;;
    *) warn "$name :$p -> HTTP $code (alive, unusual code)" ;;
  esac
done

echo "== homepage urls"
urls=$(grep -rhoE 'https?://[^"'"'"' ]+' homepage/ 2>/dev/null | sort -u || true)
if [ -z "$urls" ]; then
  warn "no absolute URLs found in homepage/"
else
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    rest=${u#*://}; hostpart=${rest%%/*}
    case "$hostpart" in
      "")   bad "empty host: $u  (browser throws TypeError: Invalid URL)" ;;
      :*)   bad "no host before port: $u  (browser throws TypeError: Invalid URL)" ;;
      *__*) bad "placeholder left: $u" ;;
      *)    ok "$u" ;;
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

echo "== homepage docker wiring (this is what makes status dots work)"
if [ -f homepage/docker.yaml ] && [ -f homepage/services.yaml ]; then
  keys=$(grep -oE '^[A-Za-z0-9_-]+:' homepage/docker.yaml | tr -d ':' | sort -u)
  servers=$(grep -hoE 'server: *[A-Za-z0-9_-]+' homepage/services.yaml | awk '{print $2}' | sort -u)
  [ -n "$servers" ] || warn "no 'server:' keys in services.yaml — container status cannot work"
  for s in $servers; do
    if printf '%s\n' "$keys" | grep -qx "$s"; then
      ok "services.yaml server '$s' exists in docker.yaml"
    else
      bad "services.yaml uses server '$s' but docker.yaml defines: $(printf '%s' "$keys" | tr '\n' ' ') → every status shows 'unknown'"
    fi
  done
fi

echo "== radicale auth file"
if [ ! -e radicale/users ]; then
  bad "radicale/users missing — start.sh copies the template, but you must add a user line"
elif [ -d radicale/users ]; then
  bad "radicale/users is a DIRECTORY (podman created it because the file was absent) — remove it and write a real file"
else
  ok "radicale/users exists ($(stat -c '%s bytes, mode %a' radicale/users 2>/dev/null))"
  users=$(grep -vE '^[[:space:]]*(#|$)' radicale/users 2>/dev/null | cut -d: -f1 | tr '\n' ' ')
  if [ -z "$users" ]; then
    bad "no user lines — every login will be rejected (only comments in the file)"
  else
    ok "users: $users"
  fi
  if grep -q '\r' radicale/users 2>/dev/null; then
    bad "file has CRLF line endings — trim them or auth fails silently"
  fi
  if ! docker exec radicale sh -c 'test -r /config/users' 2>/dev/null; then
    warn "cannot confirm the container can read /config/users (container stopped? permissions?)"
  fi
fi

echo "== beszel agent"
if ! docker inspect beszel-agent >/dev/null 2>&1; then
  warn "beszel-agent container does not exist yet — docker compose up -d beszel-agent"
else
  envs=$(docker inspect beszel-agent --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null || true)
  for v in KEY TOKEN HUB_URL; do
    val=$(printf '%s\n' "$envs" | grep "^$v=" | sed -n '1p' | cut -d= -f2-)
    if [ -z "$val" ]; then bad "$v is empty in the container — agent refuses to start without KEY"; else ok "$v is set"; fi
  done
  echo "  last log lines:"
  docker logs beszel-agent --tail 5 2>&1 | sed 's/^/    /'
fi

echo "== tailscale serve"
if command -v tailscale >/dev/null 2>&1; then
  out=$(tailscale serve status 2>&1 | head -12)
  [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/  /' || warn "no serve config (nothing published on the tailnet)"
else
  warn "tailscale CLI not installed"
fi

echo
if [ "$fail" -eq 0 ]; then echo "doctor: no blockers found"; else echo "doctor: blockers above"; fi
exit "$fail"
