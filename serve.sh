#!/usr/bin/env bash
# Publish the stack on the tailnet. tailscaled terminates TLS with a real
# *.ts.net certificate, so there is no ACME, no public DNS, no open 80/443.
#
#   ./serve.sh            apply the mapping, then verify it landed
#   ./serve.sh status     show what is published
#   ./serve.sh check      verify the nine ports without changing anything
#   ./serve.sh reset      remove every serve rule
#   ./serve.sh off 8443   remove a single port
#
# tailscale serve needs root, or an operator set once:
#   sudo tailscale set --operator=$USER
# Then this script works as your normal user forever.
set -euo pipefail
cd "$(dirname "$0")"

command -v tailscale >/dev/null || { echo "tailscale not installed"; exit 1; }
tailscale status >/dev/null 2>&1 || { echo "tailscale is not connected — run: tailscale up"; exit 1; }

# https-port local-port name  (local ports match the 127.0.0.1 bindings in compose)
ENTRIES=(
  "443  3000 homepage"
  "8443 5230 memos"
  "8444 9090 linkding"
  "8445 8080 miniflux"
  "8446 5232 radicale"
  "8447 8081 privatebin"
  "8448 2586 ntfy"
  "8449 8090 beszel"
  "8450 3001 uptime-kuma"
)

# No `head` here: under `set -o pipefail` an early-closed pipe returns 141 and
# kills the script. sed -n '1p' drains the input instead.
host=$(tailscale status --json 2>/dev/null \
  | grep -o '"DNSName": *"[^"]*"' \
  | cut -d'"' -f4 \
  | sed 's/\.$//' \
  | sed -n '1p')

denied_help() {
  echo
  echo "tailscale refused the write: your user is not authorised to change serve config."
  echo "Fix it once, as root:"
  echo "    sudo tailscale set --operator=$USER"
  echo "…then re-run ./serve.sh (no sudo needed), or run the whole script as root:"
  echo "    sudo ./serve.sh"
  echo
  echo "Nothing was published."
}

# Verify from tailscaled's own state, not from exit codes: an unprivileged
# `tailscale serve` can fail while the shell still reports success.
verify() {
  local json missing=0
  json=$(tailscale serve status --json 2>/dev/null || echo '{}')
  for e in "${ENTRIES[@]}"; do
    read -r hp lp name <<<"$e"
    case "$json" in
      *":$hp"*) printf '  ok    https://%s:%s -> 127.0.0.1:%s (%s)\n' "$host" "$hp" "$lp" "$name" ;;
      *)        printf '  MISS  https://%s:%s -> 127.0.0.1:%s (%s)\n' "$host" "$hp" "$lp" "$name"
                missing=1 ;;
    esac
  done
  return "$missing"
}

case "${1:-apply}" in
  apply)
    for e in "${ENTRIES[@]}"; do
      read -r hp lp name <<<"$e"
      if ! err=$(tailscale serve --bg --https="$hp" "http://127.0.0.1:$lp" 2>&1); then
        case "$err" in
          *denied*|*Denied*) denied_help; exit 1 ;;
          *) printf '  FAIL  %s -> %s: %s\n' "$hp" "$lp" "$err" ;;
        esac
      fi
    done
    echo
    if verify; then
      echo
      echo "Only devices signed into this tailnet can reach those URLs."
      echo "HTTPS certificates must be enabled: admin console -> DNS -> HTTPS Certificates."
    else
      echo
      echo "Some ports did not take. Check tailscaled logs and re-run ./serve.sh check."
      exit 1
    fi
    ;;
  check)
    if verify; then echo "all nine published"; else echo "missing entries above"; exit 1; fi
    ;;
  status)
    tailscale serve status
    ;;
  reset)
    tailscale serve reset 2>&1 || { denied_help; exit 1; }
    echo "serve rules cleared"
    ;;
  off)
    [ -n "${2:-}" ] || { echo "usage: $0 off <https-port>"; exit 2; }
    tailscale serve --https="$2" off 2>&1 || { denied_help; exit 1; }
    echo "port $2 unpublished"
    ;;
  *)
    echo "usage: $0 [apply|status|check|reset|off <port>]"
    exit 2
    ;;
esac
