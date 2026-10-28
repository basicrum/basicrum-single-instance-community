# Basicrum, single-server community edition

## HTTPS setup

Choose how HTTPS will be configured before installing:

- **Cloudflare:** use a proxied DNS record, create an Origin CA certificate for
  your hostname, and set Cloudflare SSL/TLS to **Full (strict)**. Then run:

  ```bash
  curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash -s -- \
    --domain rum.example.com --tls cloudflare \
    --cert /path/to/origin.pem --key /path/to/origin.key --yes
  ```

- **Let's Encrypt:** point the hostname to this server and allow inbound ports
  80 and 443. Traefik obtains and renews the certificate automatically:

  ```bash
  curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash -s -- \
    --domain rum.example.com --tls letsencrypt --email you@example.com --yes
  ```

See [Cloudflare proxy](#cloudflare-proxy) and [Let's Encrypt](#letsencrypt)
for certificate, DNS, and troubleshooting details.

## Install or update

Run this command on the server. Docker must already be installed and running.
The installer will guide you through the hostname and HTTPS setup on the first
run. Run the same command again to update Basicrum.

```bash
curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash
```

[Basicrum](https://basicrum.com) is an open-source Real User Monitoring system:
a [Boomerang](https://github.com/basicrum/boomerang)-based script in your
visitors' browsers sends performance beacons, a Rust service stores them in
ClickHouse, and a Next.js dashboard shows Core Web Vitals, page and resource
timings per site.

This repository installs the whole stack on **one server** with Docker Compose.
It is the same six-container shape that runs the public demo at
demo.playground.basicrum.com, with generic configuration: the installer generates
every secret, writes the Traefik configuration for the TLS mode you pick, and
brings the stack up.

```
visitor's browser ── beacon ───────────┐                 ┌─▶ basicrum_beacon_service :3100 ─▶ clickhouse
                                       ▼                 │        (Rust, ingestion)              (RUM events)
your browser ── dashboard ──▶ traefik :80 / :443 ────────┼─▶ basicrum_frontend :3000 ──┐
                            routes by path, TLS          │        (Next.js)             ▼
                                                         └─▶ basicrum_backend :8080 ──▶ clickhouse + basicrum_postgres
                                                                  (Node API; runs migrations)      (users, orgs, sites)
```

| Path                     | Priority | Goes to                   |
|--------------------------|---------:|---------------------------|
| `/beacon/catcher` (exact)|      200 | `basicrum_beacon_service` |
| `/backend/v1/*`          |      100 | `basicrum_backend`        |
| everything else          |        1 | `basicrum_frontend`       |

Only Traefik publishes host ports. ClickHouse and Postgres have no host port
mappings and share an internal Docker network with the services that use them.

## Requirements

- Linux, or macOS with Docker Desktop. Docker Engine and CLI **20.10.10+**,
  server API **1.40+**, and Docker Compose **2.24.0+** are enforced. Newer
  major versions of Compose are accepted. Use a local Unix-socket Docker
  context running Linux containers; remote contexts are unsupported because
  this bundle uses local bind mounts and localhost checks.
- The Basicrum images run as **linux/amd64**. AMD64 and ARM64 Docker daemons
  are accepted; on ARM64, working AMD64 emulation is required. Before starting
  the stack, setup executes the backend and ClickHouse images to catch missing
  emulation or incompatible CPUs.
- Allocate at least **2 CPUs and 4 GiB RAM to Docker**. The RAM check accepts
  3.5 GiB reported by the daemon to allow for system reservations on a 4 GiB
  host. ClickHouse's memory cap is 70 % of host RAM. Docker data storage needs
  **20 GiB free**; the installation directory needs 100 MiB free. Disk usage
  grows with traffic.
- A hostname configured to reach the server, directly or through Cloudflare,
  and either ports 80 and 443 open (Let's Encrypt), your own certificate, or
  your own reverse proxy in front.
- Bash 3.2+, OpenSSL, curl, and standard Unix utilities. Linux also needs `ss`
  (iproute2) and `getent` (libc utilities); macOS uses its built-in `lsof` and
  `dscacheutil` for port and hostname checks.

## Install

### Self-contained installer

Install the latest stable release:

```bash
curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash
```

The [releases page](https://github.com/basicrum/basicrum-single-instance-community/releases)
also provides `install.sh` and its `install.sh.sha256` checksum.

Before changing an installation, the installer lists requirements that are
ready, items that need action, and checks that must wait for Docker. It reports
Docker Engine and the Docker Compose plugin together, even if Docker is not yet
installed. Fix all items under **Needs action**, then run the same command again.

The installer unpacks the required files into `~/basicrum`, then configures
the stack. It asks for your hostname, TLS mode, and any needed certificate
details through the terminal. The first TLS choice is Cloudflare with an Origin
CA certificate. Prompts work even when Bash is reading the script from
a pipe. Docker must already be installed and running. Running a prebuilt
`install.sh` does not require Git, Python, or a source checkout; building it
from this repository does. The host requirements above are checked before the
installer replaces any installed files.

For an unattended installation, pass the settings as arguments:

```bash
curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash -s -- \
  --install-dir "$HOME/basicrum" \
  --domain rum.example.com --tls cloudflare \
  --cert /root/basicrum-origin.pem --key /root/basicrum-origin.key --yes
```

Installer flags include `--no-start` to write and validate
configuration without pulling images or starting containers. Relative
certificate paths are resolved from the directory where you invoke setup.

**To upgrade, run the same download command again.** Each published installer
contains one tested tag shared by the backend, frontend and beacon images. A
rerun applies that tag, refreshes the packaged configuration, and starts the
stack. It keeps the hostname, TLS settings, generated secrets, Cloudflare
certificate and key, and Docker volumes. It refuses a nonempty destination
that it did not previously create.

### Other first-run TLS choices

```bash
# Let's Encrypt: Traefik obtains and renews the certificate itself
curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash -s -- \
  --domain rum.example.com --tls letsencrypt --email you@example.com --yes

# another certificate and key
curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash -s -- \
  --domain rum.example.com --tls custom --cert fullchain.pem --key privkey.pem --yes

# plain HTTP on 127.0.0.1:8080, your own reverse proxy terminates TLS
curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash -s -- \
  --domain rum.example.com --tls none --http-port 8080 --public-url https://rum.example.com --yes
```

What the installer does, in order:

1. Runs the shared preflight checks: tools, local Docker context, daemon access,
   Engine/CLI/API/Compose minimum versions, Linux container support, architecture,
   CPU/RAM allocation, and installation disk space. These run before `.env` is
   created or changed. The downloadable installer runs the same checks before
   updating installed scripts.
2. Creates `.env` (mode 600) with generated database passwords and application
   secrets. **Re-runs keep settings and secrets**, adding missing values and
   setting the shared application image tag to the version bundled in the
   latest installer. Flags override stored settings; prompts appear only for
   settings still missing.
3. Writes `traefik/traefik.yml` (and `traefik/dynamic/tls.yml` in custom mode)
   from `.env`. These two files are derived: change `.env` or pass flags and
   rerun the installer; do not edit them.
4. Validates with `docker compose config`, checks published ports for conflicts
   (allowing ports owned by this installation), and checks hostname resolution
   in Let's Encrypt mode. It pulls the images, then runs temporary, isolated
   image probes to verify execution and free Docker data storage, including
   inside Docker Desktop's VM. These probes expose no ports or installation
   data and remove their containers afterward; `--no-pull` uses cached images.
5. Runs `docker compose up -d --wait`. All six services have health checks;
   Traefik's `/ping` is on its container loopback interface and is not published.
   The backend waits for both databases, runs migrations, then the beacon,
   frontend and Traefik follow. A failed service check stops setup.
6. Requires the local login page to answer HTTP 200 through Traefik. In Let's
   Encrypt mode it also checks the public HTTPS URL using real DNS and certificate
   validation (staging mode allows its intentionally untrusted certificate).
   Local routing has a 30-second retry window; public HTTPS has 120 seconds.
   Each request has connection and total timeouts. Failure exits nonzero instead
   of printing a successful installation. The first start takes a few minutes
   (about 1 GB of images).
7. Prints the dashboard URL, the beacon endpoint and the first-run steps.

`curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash -s -- --help`
lists every flag; `--no-start` writes and validates the
configuration without starting anything. It still enforces host and version
requirements; image execution, Docker VM disk space, port/DNS checks and endpoint
readiness are checked when setup starts services. DNS resolution alone does not
prove that public DNS points to this server or that inbound ports are reachable;
the public HTTPS check confirms the observable HTTPS result after startup.

## First run

1. **Create the admin account** at `https://rum.example.com/auth/register?firstUser=true`.
   The backend creates a default organisation on its first start; the first
   account registered without an invite code becomes its admin. Passwords
   need at least 15 characters. Every later account needs an invite code,
   created under *Settings → Users*; the code is shown to you to pass on (no
   e-mail is sent, this edition has no mail setup).
2. **Add your site** under *Settings → Sites*, install the Boomerang snippet
   the page shows (the beacon endpoint is already filled in from `PUBLIC_URL`),
   then press *Verify*.
3. **Optional, synthetic traffic.** To see the dashboards before your site sends
   beacons, seed the verified test site that the Basicrum beacon simulator
   targets (`www.load-test-simulation.com`, organisation 1):

   ```bash
   docker compose exec basicrum_backend node build/scripts/seedVerifiedSite.js
   ```

   then run the simulator from the Basicrum monorepo (`beacon_simulator/`)
   against `https://rum.example.com/beacon/catcher`. Backfilling past dates
   needs `ALLOW_BEACON_TIMESTAMP_OVERRIDE=yes` in `.env` (and a rerun of the
   installer); turn it back to `no` afterwards, it lets any client set the
   timestamp of its beacons.

## TLS modes

### Cloudflare proxy

Use a [proxied DNS record](https://developers.cloudflare.com/dns/proxy-status/)
for the Basicrum hostname and create an [Origin CA certificate](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)
that covers it. Save the certificate and private key on the origin server,
outside this repository, then choose option 1 in the interactive installer or
pass `--tls cloudflare --cert /path/to/origin.pem --key /path/to/origin.key`.
Set Cloudflare SSL/TLS to [Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/).
Traefik serves HTTPS on the origin's port 443 and redirects HTTP on port 80.
The application URL is `https://` plus the hostname. Internally, `cloudflare`
uses the same certificate configuration as `custom`.

Allow inbound web traffic to the origin from [Cloudflare's published IP ranges](https://developers.cloudflare.com/fundamentals/security/protect-your-origin-server/),
while retaining your own SSH access. To preserve visitor IPs for beacon GeoIP,
set `TRAEFIK_TRUSTED_PROXY_IPS` in `.env` to those IPv4 and IPv6 CIDRs as a
comma-separated list and rerun the installer; keep the list current. Without it,
the application may see Cloudflare's edge IP instead. The installer checks the
certificate/key pair and hostname, and checks local HTTPS readiness. Verify
`https://rum.example.com/auth/login` through Cloudflare after installation;
the local check cannot establish that Cloudflare can reach the origin.

Cloudflare Origin CA certificates are trusted by Cloudflare, not by browsers
connecting directly to the origin. Use a publicly trusted certificate if the
hostname also needs to work without Cloudflare.

### `letsencrypt`

Traefik requests the certificate from Let's Encrypt over the HTTP-01 challenge
on port 80 as soon as the routers are loaded, stores it in the `traefik-acme`
volume and renews it on its own. HTTP is redirected to HTTPS.
The DNS name must resolve to this server; if it has an AAAA record, IPv6 must
reach the server as well, since Let's Encrypt prefers it. `docker compose logs
traefik` shows the ACME exchange. For rehearsals, `--acme-staging` uses Let's
Encrypt's staging CA (browser-untrusted certificates, no rate limits); remove
the `traefik-acme` volume (`docker compose down -v` destroys **all** data, so
instead `docker volume rm basicrum_traefik-acme` while the stack is down) when
switching back to production.

### `custom`

You bring the certificate (PEM, with its intermediate chain) and the private
key. The installer copies them to `traefik/ssl/cert.pem` and `traefik/ssl/key.pem`
(key mode 600), checks that they belong together and that the certificate
names the domain, and writes `traefik/dynamic/tls.yml`, which serves the pair
for every hostname. HTTP is redirected to HTTPS.

To rotate, rerun the installer with `--cert` and `--key` pointing to the new
pair. The dynamic file is written again, Traefik's file watcher reloads
within a second, no container restarts.

`--tls cloudflare` is an alias for this mode. A certificate that does not cover
the configured hostname fails setup.

### `none`

Traefik serves plain HTTP on `HTTP_BIND:HTTP_PORT`, by default
`127.0.0.1:80`, and nothing else is published. Your reverse proxy terminates
TLS and forwards to it. Three things matter:

- Pass `--public-url https://rum.example.com`: the application must know how
  browsers reach it (sign-in callbacks, the API URL the dashboard calls, the
  beacon endpoint shown in the integration snippet). Without the flag the URL
  is derived as `http://DOMAIN[:HTTP_PORT]`, which is right for a local try-out
  and wrong behind a TLS-terminating proxy.
- Forward the `Host` header unchanged: Traefik routes on `Host(DOMAIN)`.
- Forward `X-Forwarded-For` (and `-Proto`): the beacon service takes the
  visitor's address from it for GeoIP. In this mode Traefik trusts forwarded
  headers from any client, which is safe while only your proxy can reach the
  port. If the proxy runs on another machine, set `HTTP_BIND=` (empty, every
  address) and `TRAEFIK_TRUSTED_PROXY_IPS=<its address>` in `.env`, then
  rerun the installer.

nginx, for example:

```nginx
server {
    listen 443 ssl;
    server_name rum.example.com;
    # ssl_certificate ...; ssl_certificate_key ...;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Files

| Path | What it is |
|------|------------|
| `docker-compose.yml` | the six services, networks and volumes; reads everything from `.env` |
| `compose.https.yml` | adds port 443; included through `COMPOSE_FILE` in `.env` unless `TLS_MODE=none` |
| `clickhouse-config/system-logs.xml` | ClickHouse tuning for a shared host: memory cap, quiet logging, the very wide system logs disabled, 3-day retention on the rest |
| `.env` | **generated**, mode 600: every secret and setting of this install |
| `traefik/traefik.yml` | **generated** from `.env`: Traefik's static configuration for the TLS mode |
| `traefik/dynamic/tls.yml` | **generated** in custom mode: the certificate pair to serve |
| `traefik/ssl/cert.pem`, `key.pem` | your certificate pair, custom mode |

Volumes: `postgres-data`, `clickhouse-data`, and `traefik-acme`
(all prefixed with the project name, `basicrum`).

## Configuration

Everything lives in `.env`. After changing a value, rerun the installer to
apply it; secrets never change on a rerun. A value
that is part of a container's environment (`PUBLIC_URL`, `DOMAIN`, the
options below) recreates that container, a few seconds of downtime for it;
a TLS mode or port change recreates Traefik only.

| Variable | Default | Used by | Meaning |
|----------|---------|---------|---------|
| `DOMAIN` | asked | traefik | hostname the routers match |
| `PUBLIC_URL` | derived | backend, frontend | how browsers reach the site; `APP_BASE_URL`, `AUTH_URL`, `NEXT_PUBLIC_API_URL` and the beacon endpoint come from it |
| `TLS_MODE` | asked | installer | `letsencrypt`, `custom` or `none`; `--tls cloudflare` selects `custom` |
| `ACME_EMAIL` | asked | traefik | Let's Encrypt contact address |
| `ACME_STAGING` | `false` | traefik | `true` uses Let's Encrypt's staging CA |
| `HTTP_PORT`, `HTTPS_PORT` | `80`, `443` | traefik | published host ports |
| `HTTP_BIND` | empty, `127.0.0.1` in `none` mode | traefik | address the HTTP port binds to; empty means every address |
| `TRAEFIK_TRUSTED_PROXY_IPS` | empty | traefik | comma-separated addresses or CIDRs whose `X-Forwarded-*` headers are trusted |
| `TRAEFIK_ENTRYPOINT`, `COMPOSE_FILE` | derived | compose | `web`/`websecure`; whether `compose.https.yml` is included. Do not edit |
| `BASICRUM_VERSION` | release-bundled tag | the three app images | shared tag for the backend, frontend and beacon service; updated on every installer run |
| `TRAEFIK_VERSION` | `v3.7.16` | traefik | pinned patch of the 3.7 series; supports Docker API version negotiation |
| `POSTGRES_VERSION` | `17.5` | postgres | see Upgrading before changing the major version |
| `CLICKHOUSE_VERSION` | `26.8.34.13-alpine` | clickhouse | pinned patch of the 26.8 LTS series |
| `POSTGRES_USER`, `POSTGRES_DB` | `basicrum` | postgres, backend | |
| `POSTGRES_PASSWORD` | generated | postgres, backend | URL-safe characters only: it is embedded in the backend's connection URL |
| `CLICKHOUSE_USER` | `default` | clickhouse, backend, beacon | |
| `CLICKHOUSE_PASSWORD` | generated | clickhouse, backend, beacon | |
| `NEXTAUTH_SECRET` | generated | frontend | signs the dashboard's sessions |
| `JWT_SECRET`, `COOKIE_SECRET`, `REFRESH_TOKEN_SECRET` | generated | backend | sign API tokens and cookies; at least 20 characters each |
| `ORG_TOKEN_ENC_KEY_V1` | generated | backend | AES-256 key (base64) protecting the AI provider keys organisations may store |
| `TELEMETRY_EXPOSE` | `false` | backend, frontend, beacon | `true` serves Prometheus metrics at `/telemetry` on each service's internal port (8080, 9464, 3100); never routed by Traefik |
| `ALLOW_BEACON_TIMESTAMP_OVERRIDE` | `no` | beacon | `yes` lets a beacon set its own timestamp (the simulator's backfill) |
| `ALLOW_BEACON_IP_OVERRIDE` | `no` | beacon | `yes` lets a beacon set its own client address |
| `BEACON_MAX_CONCURRENCY` | `100` | beacon | processing permits |
| `BEACON_LOG_LEVEL` | `info` | beacon | `RUST_LOG` |
| `NEXT_PUBLIC_ENABLE_CHATBOT` | empty | frontend | `true` shows the AI features (chat, insights, AI keys) |
| `NEXT_PUBLIC_IS_DEMO`, `NEXT_PUBLIC_DEMO_EMAIL`, `NEXT_PUBLIC_DEMO_PASSWORD` | `false`, empty | frontend | public demo mode: the login page signs in with that account |
| `SUPER_ADMIN_EMAIL` | empty | backend | account allowed to use the cross-organisation admin endpoints |

Fixed in the compose file, on purpose: `SAAS_SIGNUP_ENABLED=false` and
`NEXT_PUBLIC_SAAS_SIGNUP_ENABLED=false`. The self-service sign-up with
e-mailed invites is a hosted-service feature that needs an e-mail provider;
this edition registers the first account openly and the rest by invite code.

## Operations

```bash
docker compose ps                          # the six containers and their health
docker compose logs -f basicrum_backend    # follow one service
docker compose restart basicrum_frontend   # restart one service
docker compose down                        # stop everything; data stays in the volumes
curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash
```

### Upgrading

The installer uses `basicrum/backend_community`,
`basicrum/frontend_community` and `basicrum/beacon_service_community`, all at
the tag bundled with the current release. The three images share the API
contract and move together. When a new installer release is published with a
new shared tag, run the same command used for the first installation:

```bash
curl -fsSL https://github.com/basicrum/basicrum-single-instance-community/releases/latest/download/install.sh | bash
```

For a nondefault installation directory, repeat the same `--install-dir`
argument. The release workflow pulls and tests all three application images
before publication. On an installed server, rerunning the installer updates
only the shared application tag; the stored database, Traefik and other image
versions stay pinned. Check `docker compose logs basicrum_backend` for
migration output after the update.

The backend applies its Postgres and ClickHouse migrations when it starts, so a
newer version migrates the data forward on its own. Going back to an older tag
works only while no migration has run in between; changing an image tag does
not undo database migrations. Prefer an explicit matching tag over `latest`.

New installations default to Traefik `v3.7.16` and ClickHouse
`26.8.34.13-alpine` (26.8 LTS). Existing installations retain the
`TRAEFIK_VERSION` and `CLICKHOUSE_VERSION` stored in `.env` when setup is
rerun; an installer update does not automatically upgrade these services.

Traefik and ClickHouse minor versions can be bumped by editing
`TRAEFIK_VERSION` and `CLICKHOUSE_VERSION` and rerunning the installer (read the
release notes first). **Postgres major versions cannot be bumped that way**: a
17 data directory does not start under 18. A major-version upgrade needs a
separate database migration procedure.

### Forgotten admin password

If your backend image ships `build/scripts/resetUserPassword.js`, run
`docker compose exec basicrum_backend node build/scripts/resetUserPassword.js
you@example.com 'new password'`. Otherwise another admin can invite a fresh
account.

### Telemetry

With `TELEMETRY_EXPOSE=true` each application container serves Prometheus
metrics at `/telemetry`: the backend on 8080, the frontend on 9464, the beacon
service on 3100, reachable from a scraper you attach to the `basicrum_proxy` or
`basicrum_internal` network, never through Traefik. ClickHouse can expose its
own metrics on 9363 with one more file in `clickhouse-config/`, mounted into
`config.d/` like the shipped `system-logs.xml`:

```xml
<clickhouse><prometheus><endpoint>/metrics</endpoint><port>9363</port>
<metrics>true</metrics><events>true</events><asynchronous_metrics>true</asynchronous_metrics><errors>true</errors>
</prometheus></clickhouse>
```

## Security notes

- Only Traefik's ports are published. ClickHouse and Postgres are on an
  externally isolated Docker network with no host port mappings and are
  explicitly disabled in Traefik. Keep the server's firewall at 80 and 443
  (plus SSH). For database maintenance, use `docker compose exec` rather than
  opening database ports on the host. Existing `.env` values for
  `CLICKHOUSE_HTTP_PORT` and `CLICKHOUSE_NATIVE_PORT` are ignored.
- `.env` is created with mode 600 and holds every secret. Keep it private.
- Traefik reads the Docker socket (read-only mount) to discover the routed
  containers; that is the Docker provider's standard requirement and gives
  the Traefik container wide access to the Docker daemon.
- All three application containers run as unprivileged users; the beacon
  overrides are off; the first account registers openly and every later one
  needs an invite code.

## Troubleshooting

- **The installer stops at "the stack did not come up healthy"**: `docker compose
  ps` shows which container is unhealthy, `docker compose logs --tail=100
  <service>` why. The backend logs its migrations; the beacon service needs
  ClickHouse; the frontend answers `/auth/login` once Next.js is up.
- **"address already in use"**: something on the host holds port 80 or 443.
  Change `HTTP_PORT` or `HTTPS_PORT`, or stop the other service.
- **Traefik answers 404**: the request's `Host` header is not `DOMAIN`. Check
  with `curl -sI -H "Host: rum.example.com" http://127.0.0.1/auth/login`.
- **No certificate / browser warning in letsencrypt mode**: `docker compose
  logs traefik | grep -i acme`. DNS not pointing here, port 80 blocked, an
  AAAA record to a host without IPv6, or the rate limit after many attempts
  (use `--acme-staging` to rehearse).
- **Sign-in fails or loops, the dashboard shows "server unreachable"**:
  `PUBLIC_URL` does not match what the browser uses. Fix it in `.env` (or
  pass `--public-url`) and rerun the installer.
- **Traefik answers 404 for everything** and `docker compose logs traefik`
  repeats "Failed to retrieve information of the docker client and server
  host": the Traefik version is older than 3.6 on a Docker Engine 29 daemon,
  whose API floor refuses the API 1.24 those versions pin. Set
  `TRAEFIK_VERSION=v3.7.16` (or newer) in `.env` and rerun the installer.
- **"AMD64 backend image cannot execute"**: the Docker daemon cannot execute
  the application's AMD64 image. Configure AMD64 emulation or use an AMD64 host.
- **"ClickHouse image cannot execute"**: check the CPU requirements for the
  selected ClickHouse image and confirm the image is cached when using `--no-pull`.
- **"Public HTTPS dashboard did not become ready"**: check public DNS, inbound
  ports 80/443, and `docker compose logs traefik` for certificate issuance errors.
- **"Cannot create user without an organization"** on the register page: the
  backend has not finished its first start yet; wait for
  `docker compose ps` to show it healthy.
- **The backend's very first start logs "Error fetching and storing verified
  hostnames on app start … relation "sites" does not exist"**: it pre-loads
  its hostname cache before its own migrations have created the table. Harmless
  and once only; the lookup falls back to the database.

## How this relates to the Monarch render

For maintainers who know the Monarch control plane: this bundle is the demo
environment's render (`demo-basicrum`, server `demo-01`) made generic. The
deliberate differences:

- image tags come from `BASICRUM_VERSION` instead of digest pins; data lives
  in named volumes instead of absolute host directories;
- the demo-only values are gone: demo mode and its account, the timestamp
  override, telemetry exposure, and `NEXTAUTH_SECRET` on the backend, which
  the backend never reads;
- Traefik is v3.7.16 instead of the demo's v3.3.4: on Docker Engine 29 the
  3.3, 3.4 and 3.5 lines cannot talk to the daemon at all (they pin Docker
  API 1.24, below the new floor), which is worth knowing before the fleet's
  hosts move to Docker 29;
- Traefik's static configuration is a file written per TLS mode rather than
  command-line flags, with the three modes above; port 443 rides
  `compose.https.yml`; the dynamic directory is mounted whole, as in Monarch;
- one router per service: the frontend's extra `/_next, /basicrum, /api/auth`
  router is folded into its catch-all, which it duplicated;
- the beacon service also waits for the backend to be healthy, so a fresh
  install does not start it before the ClickHouse dimension tables exist;
- `z_prometheus.xml` (ClickHouse metrics) is not mounted; log rotation and
  ClickHouse's `nofile` limit are additions;
- the ClickHouse tuning keeps the demo's system-log settings and expresses
  the memory cap as a ratio of the host's RAM instead of a fixed byte count.
