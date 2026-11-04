#!/usr/bin/env bash
# Add or replace a Radicale user, hashing with the container's OWN passlib so the
# format can never mismatch what Radicale verifies (no openssl/htpasswd guessing).
#
#   ./adduser.sh reina
#
# The tomsquest image installs Radicale into /venv, so the system `python3` has no
# passlib — this script locates the interpreter that actually has it.
set -euo pipefail
cd "$(dirname "$0")"

user="${1:-}"
[ -n "$user" ] || { echo "usage: $0 <username>"; exit 2; }
case "$user" in *:*|*' '*) echo "username must not contain ':' or spaces"; exit 2 ;; esac

docker inspect radicale >/dev/null 2>&1 || { echo "radicale container not found — start the stack first"; exit 1; }

# Find the interpreter that can actually import passlib.
PY=$(docker exec radicale sh -c '
  for p in /venv/bin/python3 /venv/bin/python /app/venv/bin/python3 python3 python; do
    [ -x "$p" ] || continue
    "$p" -c "import passlib" 2>/dev/null && { echo "$p"; exit 0; }
  done' | tr -d '\r')
if [ -z "$PY" ]; then
  echo "no python with passlib found inside the container:"
  docker exec radicale sh -c 'ls -l /venv/bin 2>/dev/null | head; echo ---; python3 -c "import passlib" 2>&1' || true
  exit 1
fi
echo "using interpreter: $PY"

read -rsp "password for $user: " pass; echo
[ -n "$pass" ] || { echo "empty password"; exit 2; }

hash=$(docker exec -i radicale "$PY" - "$pass" <<'PY'
import sys
from passlib.hash import sha512_crypt
print(sha512_crypt.hash(sys.argv[1]))
PY
)

[ -n "$hash" ] || { echo "could not hash the password inside the container"; exit 1; }

touch radicale/users
grep -v "^${user}:" radicale/users > radicale/users.tmp || true
printf '%s:%s\n' "$user" "$hash" >> radicale/users.tmp
mv radicale/users.tmp radicale/users
chmod 644 radicale/users

echo "wrote $user to radicale/users (hash length ${#hash})"
docker compose restart radicale >/dev/null

# verify with the same library Radicale uses
if docker exec -i radicale "$PY" - "$pass" "$hash" <<'PY'
import sys
from passlib.hash import sha512_crypt
sys.exit(0 if sha512_crypt.verify(sys.argv[1], sys.argv[2]) else 1)
PY
then
  echo "hash verified inside the container"
else
  echo "WARNING: hash did not verify — do not trust this login"
  exit 1
fi

echo
echo "test it:  curl -si -u '$user:PASS' https://HOST:8446/ | head -3    (expect 207)"
