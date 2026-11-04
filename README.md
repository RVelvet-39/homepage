# Selfhost — one compose file, thirteen services, tailnet-only

No public DNS, no ACME, no open 80/443. Everything binds to `127.0.0.1` and is
published through `tailscale serve`, which terminates TLS with a real `*.ts.net`
certificate. Only devices signed into your tailnet can reach anything.

```
notify       ntfy (notification bus)
monitoring   Beszel (hub + agent) · Uptime Kuma · Diun
dashboard    Homepage
apps         Memos · Radicale · Linkding · Miniflux (+Postgres) · PrivateBin
```

Target host: 2 vCPU / 4 GB RAM, no swap. Container caps total ~2.8 GB; keep ~500 MB
free. On a no-swap host the OOM killer bites first during image pulls.

## Port map (fixed, in both compose and serve.sh)

| URL | service |
|---|---|
| `https://HOST/` (443) | Homepage |
| `https://HOST:8443` | Memos |
| `https://HOST:8444` | Linkding |
| `https://HOST:8445` | Miniflux |
| `https://HOST:8446` | Radicale (DAV) |
| `https://HOST:8447` | PrivateBin |
| `https://HOST:8448` | ntfy |
| `https://HOST:8449` | Beszel |
| `https://HOST:8450` | Uptime Kuma |

Paths were the alternative; they break apps that generate absolute URLs. Ports are
boring and they don't.

## Runtime: Docker Engine or Podman

The compose file is written to work under both, but they are not equal.

**Docker Engine (recommended).** Standard socket, real Compose v2, healthchecks honoured.
On Alpine/OpenRC:

```sh
apk add docker docker-cli-compose
rc-update add docker default && rc-service docker start
# podman-docker ships /usr/bin/docker too — remove it if it conflicts
apk del podman-docker
```

**Podman rootless (what this host currently has).** `docker` is a shim over podman and
there is no API socket by default, which is exactly what `statfs /var/run/docker.sock`
means. Start the API and point `DOCKER_SOCK` at it:

```sh
mkdir -p /run/user/$(id -u)/podman
podman system service --time=0 unix:///run/user/$(id -u)/podman/podman.sock &
# in .env:
#   DOCKER_SOCK=/run/user/1000/podman/podman.sock
```

Verified on this host: that socket answers the Docker-compatible API (`/v1.40/version`,
`/v1.40/containers/json`), so Homepage, Kuma, Diun and the Beszel agent can use it directly.

Podman caveats, learned the hard way:

- `podman-compose` 1.6.0 fails on `depends_on` ("no container with name or ID … found").
  This file has none — start order settles via `restart: unless-stopped`.
- `service_healthy` conditions are not supported. Miniflux will restart a few times until
  Postgres accepts connections. That is normal, not a bug.
- `tailscale serve` needs privilege: either `sudo tailscale serve …` or run
  `sudo tailscale set --operator=$USER` once so your user may manage serve.
- After a failed first attempt, clear half-created containers before retrying:
  `docker compose down --remove-orphans` (or `podman-compose down`).

**Why there is no socket-proxy here.** The haproxy-based proxies (Tecnativa, LinuxServer)
abort with `Cannot raise FD limit to 8028, current limit is 4096` — their baked-in
`maxconn 4000` needs more file descriptors than a rootless user gets. Rather than fight
`ulimit`, the socket is mounted straight into Homepage, Kuma, Diun and the Beszel agent.
Under **rootless podman** that API carries only your user's privileges, not root's, so the
extra hop buys little. On rootful Docker, put a proxy back (a Go one such as
`wollomatic/socket-proxy` has no FD footprint).

**Recommendation:** if this box is going to run the stack permanently, install Docker
Engine. Podman rootless works, but you inherit every rough edge of `podman-compose`.

## When something looks wrong

```sh
./doctor.sh        # one shot: socket, containers, ports, HTTP codes, config wiring, serve rules
```

It prints `ok` / `warn` / `FAIL` per check and exits non-zero on blockers, so you stop
guessing which layer broke. The two failures people hit first:

- **Every status dot says "unknown"** → Homepage cannot reach the container API.
  `doctor.sh` shows `socket missing`, or the socket path in `.env` is wrong.
- **`TypeError: Failed to construct 'URL': Invalid URL`** → a link in `homepage/*.yaml`
  has an empty host (`https://:8443`) or an unreplaced `__HOST__`. `doctor.sh` prints the
  offending URL under `homepage urls`.

## Accounts (current decision)

One shared Radicale account, username `lobelia`, used by both Reina's devices and Ruko.
There is no `from_file` rights sharing: with a single account, `rights type = owner_only`
is exactly right, and everything under `/lobelia/…` is reachable by both.

- Calendar: `https://<TAILNET_HOST>:8446/lobelia/schedule/` (VEVENT + VTODO)
- Ruko's credential file lives outside this repo: `~/.config/radicale/ruko.pass` (mode 600),
  never in git and never in chat.
- Tradeoff accepted with the shared account: no audit trail. Anything Ruko writes carries
  `CATEGORIES:ruko` so it stays distinguishable from what Reina typed.
- Revoking Ruko means rotating that password, which also breaks her devices — that is the
  cost of a single account.

## 0. Configure (once)

```sh
cd selfhost
cp .env.example .env && ${EDITOR:-vi} .env      # TAILNET_HOST + every password
./start.sh                                       # fills dashboard URLs, then preflight
```

`./start.sh` substitutes `TAILNET_HOST` into `homepage/*.yaml` for you, every run, and
refuses to continue if the result still has a placeholder. Homepage cannot read
environment variables in `href` fields, which is why those URLs are literal — and why an
unreplaced `__HOST__` produces `TypeError: Failed to construct 'URL': Invalid URL` in the
browser console. Underscores are not legal in a hostname.

`./preflight.sh` must print PASS before anything starts.

Prerequisites: Docker Engine + Compose v2, a running `tailscaled`, and **HTTPS
Certificates enabled** for the tailnet (admin console → DNS → HTTPS Certificates).
Without that last toggle, `tailscale serve --https` refuses.

`NTFY_ALERT_TOPIC` must be unguessable: `alerts-$(openssl rand -hex 16)`.

## 1. Start

```sh
./start.sh        # preflight, then docker compose up -d
sudo tailscale set --operator=$USER   # once: lets your user manage serve
./serve.sh        # publishes the nine URLs, then verifies each one
./serve.sh check  # re-verify any time, changes nothing
```

`./serve.sh` verifies against `tailscale serve status --json` instead of trusting exit
codes — an unprivileged `tailscale serve` writes an "Access denied: serve config denied"
message and silently leaves the tailnet untouched. If you skip the operator line, the
script stops at the first refusal and tells you what to run.

`./stop.sh` stops containers, keeps data. `./stop.sh --down` removes containers and
the network, volumes stay. `./serve.sh reset` clears the serve rules.

Fallback if you prefer not to use serve: bind ports to the tailnet IP instead
(`tailscale ip -4` → `100.x.y.z:PORT:PORT`) and open `http://100.x.y.z:PORT`.
Uglier URLs, no certs, same isolation.

## 1b. Applying a change

`restart` keeps the container and its environment; `recreate` builds a new one from the
current compose file and `.env`. Getting that wrong is why `BESZEL_KEY` and Radicale
passwords look like they "didn't take" — the old container is still running with the old
environment.

```sh
docker compose restart radicale                      # re-reads radicale/config + users
docker compose up -d --force-recreate beszel-agent   # REQUIRED after editing .env
docker compose up -d --force-recreate radicale       # REQUIRED after editing .env
docker compose up -d                                 # enough when only the compose file changed
```

| You changed | Command |
|---|---|
| `.env` value used by a service (`BESZEL_KEY`, `BESZEL_TOKEN`, `LINKDING_*`, `MINIFLUX_*`) | `docker compose up -d --force-recreate <service>` |
| `radicale/config` or `radicale/users` (bind-mounted files) | `docker compose restart radicale` |
| `homepage/*.yaml` | `./start.sh` (substitutes `__HOST__`), then `docker compose restart homepage` |
| `diun/diun.yml` | `docker compose restart diun` |
| `docker-compose.yml` (image tag, env list, ports) | `docker compose up -d` |

`docker compose up -d` alone already recreates a container whose *definition* changed.
`--force-recreate` is for the case where the definition did not change but the value it
reads (`.env`) did — compose sees no diff, so it leaves the old container alone.

## 2. Lock down ntfy

Anonymous access is `deny-all`. Grant exactly one topic write-only, so any script
can publish and only a logged-in user can read:

```sh
docker compose exec ntfy ntfy user add --role=admin admin
docker compose exec ntfy ntfy access everyone "$(grep '^NTFY_ALERT_TOPIC=' .env | cut -d= -f2)" wo
docker compose exec ntfy ntfy access        # confirm
```

Install the ntfy app **with Tailscale active on the phone**, log in as `admin`,
subscribe to the topic, then prove it:

```sh
docker compose exec ntfy ntfy publish "$(grep '^NTFY_ALERT_TOPIC=' .env | cut -d= -f2)" "hello from $(hostname)"
```

**iOS:** instant push still goes through the vendor relay, which is why
`NTFY_UPSTREAM_BASE_URL=https://ntfy.sh` is set — your topic name becomes visible to
ntfy.sh, hence "unguessable" is not optional. The server URL you type into the app
must be exactly `https://HOST:8448`. Android-only? Delete that env line.

## 3. Beszel agent token

`https://HOST:8449`, log in with `ADMIN_EMAIL` / `BESZEL_ADMIN_PASSWORD`, then
Add System → WebSocket. Copy **both** values into `.env`:

- `BESZEL_KEY` — the hub's public key. Mandatory: without it the agent exits on boot
  with `Failed to load public keys: no key provided`.
- `BESZEL_TOKEN` — enables WebSocket auto-registration.

```sh
docker compose up -d --force-recreate beszel-agent   # recreate: it reads .env
docker logs beszel-agent --tail 20     # should stop complaining about keys
```

Alerts → ntfy, in the Beszel UI under Settings → Notifications (Shoutrrr URL):

```
ntfy://ntfy:80/alerts-xxxxxxxx
```

## 4. Uptime Kuma

`https://HOST:8450`, create the admin account, then add two kinds of monitor:

- internal: `http://linkding:9090`, `http://miniflux:8080`, `http://memos:5230`,
  `http://radicale:5232`, `http://privatebin:8080`
- external: `https://HOST:844x` for each published port, to catch cert expiry

Notification type `ntfy`: server `http://ntfy`, topic = `NTFY_ALERT_TOPIC`.

Diun publishes image updates to the same topic daily at 04:30 and never touches a
container — upgrade on your schedule, not a maintainer's.

## 5. Radicale user

Radicale refuses every login until `radicale/users` has a line:

```sh
printf '%s:%s\n' "reina" "$(openssl passwd -6 'your-password')" >> radicale/users
docker compose restart radicale
```

- CalDAV/CardDAV: `https://HOST:8446` — DAVx5, Apple Calendar, Thunderbird.
  Tasks come free: Radicale stores VTODO, so no separate task manager needed.
- Linkding: log in with `LINKDING_ADMIN_USER`, then Settings → API token for the widget.
- Miniflux: log in with `MINIFLUX_ADMIN_USER`, add feeds, API key for the widget.
- Memos: the first account created in the UI becomes admin.
- PrivateBin: server cannot read pastes; use "burn after reading" for anything sensitive.

## Security model — read this once

The tailnet is the boundary. There is no login on Homepage, no basic auth in front of
it, and ntfy topics other than the alert topic are closed. That is acceptable **only**
because:

- every container publishes to `127.0.0.1`, so nothing answers on the LAN or WAN;
- `tailscale serve` binds the tailnet identity, not an IP allowlist.

If you ever add a non-trusted device, or share a node with someone else, put
`tailscale serve` behind an ACL tag or turn on Tailscale's own auth. Losing the
tailnet trick means losing the lock, not just the key.

## Backups — not optional

```sh
docker compose exec -T miniflux-db pg_dump -U miniflux miniflux | gzip > miniflux-$(date +%F).sql.gz
docker run --rm -v selfhost_memos_data:/v -v "$PWD":/out alpine tar czf /out/memos-$(date +%F).tgz -C /v .
```

Wrap it in a script + cron, ship off-box with `restic`/`borg`, and **restore one
file once**. An untested backup is a rumour.

## Red flags to expect

- `tailscale serve` errors with "Access denied: serve config denied" → `sudo tailscale set --operator=$USER` once, then re-run `./serve.sh`.
- `serve.sh` reports all MISS → the write was refused (check for the message above), or tailscaled predates `serve --bg`.
- `tailscale serve` errors with "HTTPS is not enabled" → enable HTTPS Certificates in the admin console (DNS → HTTPS Certificates).
- `TypeError: Failed to construct 'URL': Invalid URL` spamming the console → a `__HOST__` (or an empty host, `https://:8443`) survived in `homepage/*.yaml`. Re-run `./start.sh`; it substitutes and repairs.
- `403` logging into Linkding → `LD_CSRF_TRUSTED_ORIGINS` doesn't match `https://HOST:8444`.
- `400 Bad Request` from Homepage → `HOMEPAGE_ALLOWED_HOSTS` isn't exactly the MagicDNS name.
- ntfy app can't connect → Tailscale is off on the phone, or the URL lacks `:8448`.
- OOM kills during an image pull → no swap and no headroom in `mem_limit`.
- DAV client stuck syncing → wrong port (8446) or http instead of https.
