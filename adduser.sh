#!/usr/bin/env bash
# Add or replace a Radicale user, hashing with the container's OWN passlib so the
# format can never mismatch what Radicale verifies (no openssl/htpasswd guessing).
#
#   ./adduser.sh reina
#
# Then test:  curl -si -u reina:PASS https://HOST:8446/  ->  expect 207, not 401
set -euo pipefail
cd "$(dirname "$0")"

user="${1:-}"
[ -n "$user" ] || { echo "usage: $0 <username>"; exit 2; }
case "$user" in *:*|*' '*) echo "username must not contain ':' or spaces"; exit 2 ;; esac

docker inspect radicale >/dev/null 2>&1 || { echo "radicale container not found — start the stack first"; exit 1; }

read -rsp "password for $user: " pass; echo
[ -n "$pass" ] || { echo "empty password"; exit 2; }

hash=$(docker exec -i radicale python3 - "$pass" <<'PY'
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

echo "wrote $user to radicale/users"
docker compose restart radicale >/dev/null

# verify with the same library Radicale uses
if docker exec -i radicale python3 - "$pass" "$hash" <<'PY'
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
