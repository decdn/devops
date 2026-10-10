# deCDN services with Docker Compose

The same services the Ansible roles deploy, on one host, without Ansible: the upstream
images (amd64 and arm64) under Compose, with the same host paths, the same start
commands and the same hardening as the roles' systemd units.

| Profile | Service | Image | Ansible equivalent |
|---------|---------|-------|--------------------|
| `node` | `decdn-node`, a deCDN cache node (node operators) | `ghcr.io/decdn/decdn-node` | `decdn_node` |
| `origin` | the same `decdn-node`, run as a publisher's origin ([below](#run-it-as-an-origin-publishers)) | `ghcr.io/decdn/decdn-node` | `decdn_node` with an origin backend (`decdn_cache_origin_kind`) |
| `sponsord` | `sponsord`, the onboarding sponsor: treasury signer and PaymentPool keeper | `ghcr.io/decdn/sponsord` | `sponsord` |
| `onramp` | `sponsord-onramp`, its public side (Turnstile gate, installers); also starts `sponsord` | `ghcr.io/decdn/sponsord-onramp` | `sponsord_onramp` |
| `caddy` | Caddy, TLS in front of the onramp; leave it out to bring your own proxy | `caddy` (official) | `sponsord_onramp_proxy: caddy` |

Pick the profiles with `COMPOSE_PROFILES` in `.env`. A **node operator** runs `node`.
A **publisher** runs `origin` for an origin node, `onramp,caddy` for a sponsor, or
`origin,onramp,caddy` for both on one host. The sponsor is independent of the node.
`node` and `origin` start the same service, so a host runs one or the other.

Pick this path for a single machine you already run Docker on. For a fleet, or a host
you want hardened from scratch (firewall, SSH, auto-patching), use the
[Ansible project](../ansible/README.md); on Kubernetes, the
[Helm chart](../charts/decdn-node/README.md). [`docs/requirements.md`](../docs/requirements.md)
compares the paths.

`compose.yaml` takes every image by digest. `.env.example` carries the digests of
the releases the Ansible roles pin (decdn/decdn v0.0.1, decdn/sponsord v0.0.2),
each copied from that release's signed digest file; the node's
[Operate](#operate) section says how to take a newer one.

**Upgrading from a node-only `compose.yaml`?** Every service now sits behind a
profile, so add `COMPOSE_PROFILES=node` to your `.env`. Without it,
`sudo docker compose -f compose/compose.yaml up -d` selects no service.

**Running a cache node from an earlier setup?** Its `/etc/decdn/node.toml` predates
step 4's pull-through line, and the daemon's default is off, so the node cannot fill a
miss from other nodes. Add `node_to_node_pull_through_enabled = true` under `[cache]`
(the same `sed` as step 4), check it (step 6), and restart the node. An origin needs no
change.

## The node

### How it is laid out

| Host path | In the container | Holds |
|-----------|------------------|-------|
| `/etc/decdn/node.toml` | same, read-only | node config, no secrets |
| `/etc/decdn/keystore.password` | same, read-only | keystore password (`decdn`, `0600`) |
| `/etc/decdn/decdn.env` | read by Docker, injected as env | `DECDN_RPC_URL` (`root`, `0600`) |
| `/var/lib/decdn/` | same, read-write | `node.secret`, `keystore.json`, state, cache |

The layout matches the Ansible role, so the host `decdn` CLI, backups and restores
([`docs/lifecycle.md`](../docs/lifecycle.md)) work the same way on both.

**Networking.** Every container uses the host network. The node's metrics
(`127.0.0.1:9090`) and admin RPC (`127.0.0.1:9191`, hard-wired upstream) stay on the
host's loopback, and Docker publishes no ports, so its iptables rules never open
anything past your firewall. The node's only public port is QUIC **udp/4433**.

### Set up

1. **A system account and directories:**

   ```bash
   sudo useradd --system --home-dir /var/lib/decdn --shell /usr/sbin/nologin decdn
   sudo install -d -m 0700 -o decdn -g decdn /var/lib/decdn
   sudo install -d -m 0750 -o decdn -g decdn /etc/decdn
   ```

2. **The `decdn` CLI on the host.** The image is daemon-only. Install the CLI from the
   release tarball, checking it against the GPG-signed `SHA256SUMS` first (the
   maintainer keys are in `decdn/decdn`'s `KEYS`; their fingerprints are in
   [SECURITY.md](../SECURITY.md#release-verification)). It is also on crates.io
   (`cargo install --locked decdn-cli@<version>`), which carries no maintainer
   signature.

3. **Keys.** Create the password file first (`key-gen` reads it, never creates it),
   then generate the node key and eth keystore into the data dir:

   ```bash
   umask 077
   openssl rand -base64 32 | sudo -u decdn tee /etc/decdn/keystore.password >/dev/null
   sudo -u decdn decdn key-gen --output-dir /var/lib/decdn \
     --keystore-password-file /etc/decdn/keystore.password
   ```

   Back them up now ([`docs/lifecycle.md`](../docs/lifecycle.md#backup-make-backup)).

4. **Config.** Let the CLI write it with the chain's contract addresses already filled
   in, then point it at `/var/lib/decdn` and set the node's region (ISO 3166-1
   alpha-2). A cache node has no origin backend and fills a miss from other nodes,
   which the daemon does only with `node_to_node_pull_through_enabled = true` in
   `[cache]` (its default is off; the Ansible role turns it on for a node without an
   origin). An origin has a backend instead ([below](#run-it-as-an-origin-publishers)):
   leave that line out for one.

   ```bash
   sudo -u decdn decdn config init --chain arbitrum-sepolia --output /etc/decdn/node.toml
   sudo -u decdn sed -i \
     -e 's|^# data_dir = .*|data_dir = "/var/lib/decdn"|' \
     -e '0,/^# region = /s|^# region = .*|region = "DE"|' \
     -e '/^\[cache\]$/a node_to_node_pull_through_enabled = true' /etc/decdn/node.toml
   ```

5. **The RPC endpoint**, which may embed an API key, goes in a root-only env file:

   ```bash
   sudo install -m 0600 -o root -g root compose/decdn.env.example /etc/decdn/decdn.env
   sudoedit /etc/decdn/decdn.env        # DECDN_RPC_URL=https://…
   ```

6. **Check the config** against the CLI, with the same environment the daemon gets:

   ```bash
   sudo systemd-run --pty --wait --collect -p User=decdn -p EnvironmentFile=/etc/decdn/decdn.env \
     /usr/local/bin/decdn config validate --config /etc/decdn/node.toml \
     --keystore-password-file /etc/decdn/keystore.password
   ```

7. **Firewall.** Allow inbound **udp/4433** on the host firewall *and* in your cloud
   provider's security group. Nothing else needs to be open.

8. **Start it:**

   ```bash
   cp compose/.env.example compose/.env
   $EDITOR compose/.env                  # COMPOSE_PROFILES=node; DECDN_UID/GID = `id -u decdn` / `id -g decdn`
   sudo docker compose -f compose/compose.yaml up -d
   curl -s 127.0.0.1:9090/metrics | head   # once "node runtime ready" is in the logs
   decdn node health                      # admin RPC, from the host
   ```

9. **Stake and register** (on-chain onboarding, ADR 019 Phase 2) with `decdn setup`,
   described in
   [`roles/decdn_node/README.md` § On-chain onboarding](../ansible/roles/decdn_node/README.md#on-chain-onboarding).
   The CLI does not read `DECDN_RPC_URL`, and `node.toml` still names the public RPC
   `config init` wrote, so run it through the `decdn_chain` helper in
   [`docs/lifecycle.md` § Running on-chain commands](../docs/lifecycle.md#running-on-chain-commands),
   which passes your endpoint as `--rpc-url`. The node serves paid traffic only after
   that.

### Operate

Run these from the repository root with `sudo`, like the set-up steps: Compose reads
the root-only env files whenever it creates a container.

- **Logs:** `sudo docker compose -f compose/compose.yaml logs -f decdn-node`. To send
  them to the journal like the systemd unit, switch the `x-logging` driver
  (commented in `compose.yaml`).
- **Stop:** `sudo docker compose -f compose/compose.yaml stop decdn-node`. It sends
  SIGTERM, the daemon's graceful drain, and waits up to 300 s. Do not use
  `decdn node drain` here: `restart: unless-stopped` starts the drained container
  again.
- **Upgrade:** download the new release's `decdn-node-image-digest.txt` and its `.asc`
  from `decdn/decdn`'s releases (v0.0.1 named them `image-digest.txt`), `gpg --verify`
  against the keys in [SECURITY.md](../SECURITY.md#release-verification), set the
  digest after its `@` as `DECDN_IMAGE_DIGEST` in `.env`, then
  `sudo docker compose -f compose/compose.yaml up -d`. sponsord's release carries
  `sponsord-image-digest.txt` and `sponsord-onramp-image-digest.txt` the same way.
- **Config change:** edit `/etc/decdn/node.toml`, then
  `sudo docker compose -f compose/compose.yaml restart decdn-node` (or
  `decdn node reload` for the hot-reloadable sections).
- **Health:** there is no container healthcheck. The image has no HTTP client, and the
  metrics listener serves only `/metrics`. Probe `http://127.0.0.1:9090/metrics` from
  the host, or ship metrics with Grafana Alloy / Prometheus. Dashboards and alert rules
  are in [`monitoring/`](../monitoring/README.md).

### Run it as an origin (publishers)

An origin is the same node with an origin backend: the canonical source of a
publisher's namespace. Set `COMPOSE_PROFILES=origin` and give `node.toml` the
backend. For an HTTP store, add `--origin <url>` to step 4's `config init`; for S3
(and R2, B2, MinIO) or a local or NFS path, write the `[cache.origin]` table by hand.
The [`decdn_node` role's README](../ansible/roles/decdn_node/README.md) lists the
keys, and `decdn config validate` (step 6) checks them. Static S3 keys go in
`/etc/decdn/decdn.env` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), never in
`node.toml`.

A path backend must be visible inside the container. `compose.yaml` mounts only
`/etc/decdn` and `/var/lib/decdn`, and `make lint-compose` holds it to exactly those,
so add the content root in a `compose.override.yaml` of your own beside it, read-only:

```yaml
services:
  decdn-node:
    volumes:
      - /srv/content:/srv/content:ro   # [cache.origin] path = "/srv/content"
```

With a backend set, the node serves only what its backend holds and declines the rest,
even a blob already in its cache (`relay_foreign_namespaces` defaults to false;
[ADR 002 § Retrieval by namespace](https://github.com/decdn/decdn/blob/main/adr/002-content-addressing.md#retrieval-by-namespace)),
and fills misses from the backend, not from other nodes. The chain recognises it as an origin
only once the namespace's publisher seats its operator with
`OriginAssignment.addOrigin`
([ADR 011](https://github.com/decdn/decdn/blob/main/adr/011-content-takedown.md#origin-assignment-authority)).

## sponsord and its onramp

`sponsord` holds the treasury wallet: it signs capped spending capabilities for new
users and keeps the treasury's PaymentPool pool topped up. `sponsord-onramp` is its
public side: the Turnstile gate, the `decdn.sh` / `decdn.ps1` installers and the API
the `decdn-sponsored` CLI polls. The onramp calls the daemon on loopback with the
daemon's own API token, so the two run on the same host (the `onramp` profile starts
both). The [`sponsord`](../ansible/roles/sponsord/README.md) and
[`sponsord_onramp`](../ansible/roles/sponsord_onramp/README.md) role READMEs explain
what each setting does; this section covers the Compose side.

### How it is laid out

| Host path | Owner, mode | Reaches | As |
|-----------|-------------|---------|----|
| `/etc/sponsord/secret.env` | `root`, `0600` | sponsord | env, read by `sudo docker compose`: `SPONSORD_RPC_URL` only |
| `/etc/sponsord/sponsord.env` | `root`, `0644` | sponsord | env: chain, PaymentPool, pool id, limits |
| `/etc/sponsord/sponsord-onramp.env` | `root`, `0644` | onramp | env: public settings |
| `/etc/sponsord/api-token` | `sponsord`, `0600` | both | read-only file in `/run/secrets/` |
| `/etc/sponsord/treasury-keystore.json` | `sponsord`, `0600` | sponsord | read-only file in `/run/secrets/` |
| `/etc/sponsord/treasury-password` | `sponsord`, `0600` | sponsord | read-only file in `/run/secrets/` |
| `/etc/sponsord/turnstile-secret` | `sponsord`, `0600` | onramp | read-only file in `/run/secrets/` |
| `/etc/sponsord/onramp-gate/` | `root`, `0755` | onramp | read-only directory, same path: an optional custom gate page |
| `/var/lib/caddy/` | `caddy`, `0700` | Caddy | `/data`: certificates, ACME account |

The paths match the Ansible roles, with one difference: the credential files belong
to a `sponsord` account instead of root. Under systemd, root hands them to the
service; here they are bind-mounted, which keeps the host file's owner and mode, and
sponsord refuses a treasury keystore that anyone but its owner can read. Both daemons
run as that account, and each container sees only the files it needs. A host moved
from the Ansible path needs a `chown` of those four files, and running the Ansible
`sponsord` role on the host again chowns them back to root, which stops this path.

`compose.yaml` sets both listeners (`127.0.0.1:8090` for sponsord, `127.0.0.1:8080`
for the onramp), the onramp's daemon URL and every secret file path in
`environment:`, which wins over the env files, so no env file can change them; the
release images default both listeners to `0.0.0.0`. No container publishes a port:
sponsord is reachable only from the host, and from outside, the onramp only through
the proxy.

### Set up

1. **System accounts and directories:**

   ```bash
   sudo useradd --system --no-create-home --shell /usr/sbin/nologin sponsord
   sudo install -d -m 0755 -o root -g root /etc/sponsord
   # with the caddy profile:
   sudo useradd --system --no-create-home --shell /usr/sbin/nologin caddy
   sudo install -d -m 0700 -o caddy -g caddy /var/lib/caddy
   ```

2. **The treasury wallet.** Create it with the decdn CLI (`decdn key-gen`, which
   writes `keystore.json`), fund it with USDC plus gas, then open its pool from it
   (`decdn pool open`, which prints the pool id). It is a hot key: hold only a few
   top-ups' worth. Then copy the keystore and its password onto the host:

   ```bash
   sudo install -m 0600 -o sponsord -g sponsord keystore.json /etc/sponsord/treasury-keystore.json
   sudo install -m 0600 -o sponsord -g sponsord treasury-password      /etc/sponsord/treasury-password
   ```

3. **The API token**, generated on the host and never replaced (the onramp presents
   the same token):

   ```bash
   openssl rand -hex 32 | sudo install -m 0600 -o sponsord -g sponsord /dev/stdin /etc/sponsord/api-token
   ```

4. **sponsord's settings.** The RPC URL may embed an API key, so it gets its own
   root-only file; the rest is not secret. Take the chain id and PaymentPool address
   from the deployment this repo mirrors,
   [`roles/sponsord/vars/main/networks.yml`](../ansible/roles/sponsord/vars/main/networks.yml).

   ```bash
   sudo install -m 0600 -o root -g root compose/sponsord-secret.env.example /etc/sponsord/secret.env
   sudoedit /etc/sponsord/secret.env        # SPONSORD_RPC_URL='https://…'
   sudo install -m 0644 -o root -g root compose/sponsord.env.example /etc/sponsord/sponsord.env
   sudoedit /etc/sponsord/sponsord.env      # SPONSORD_CHAIN_ID, SPONSORD_PAYMENT_POOL_ADDR, SPONSORD_POOL_ID
   ```

5. **The onramp** (`onramp` profile). Create a Cloudflare Turnstile widget for the
   onramp's domain, then store its secret and fill in the public settings. The
   CapacityBond address is in
   [`roles/sponsord_onramp/vars/main/networks.yml`](../ansible/roles/sponsord_onramp/vars/main/networks.yml).

   ```bash
   sudo install -m 0600 -o sponsord -g sponsord /dev/null /etc/sponsord/turnstile-secret
   sudoedit /etc/sponsord/turnstile-secret  # the widget's secret key
   sudo install -m 0644 -o root -g root compose/sponsord-onramp.env.example /etc/sponsord/sponsord-onramp.env
   sudoedit /etc/sponsord/sponsord-onramp.env
   ```

   `sudoedit` writes the file back with its existing owner and mode.

   **Your own gate page** (optional; upstream `docs/operator.md`, "Your own gate
   page", lists its placeholders): put the HTML in `/etc/sponsord/onramp-gate/`, the
   one directory the onramp mounts for it (created empty when absent), and point
   `ONRAMP_GATE_TEMPLATE` at it in `sponsord-onramp.env`:

   ```bash
   sudo install -D -m 0644 -o root -g root gate.html /etc/sponsord/onramp-gate/gate.html
   # in sponsord-onramp.env: ONRAMP_GATE_TEMPLATE=/etc/sponsord/onramp-gate/gate.html
   ```

   The onramp serves whatever file `ONRAMP_GATE_TEMPLATE` names, to anyone, and its
   container also holds the API token and the Turnstile secret. So `compose.yaml`
   starts it through a check: unless the path resolves (symlinks followed) to a file
   in `/etc/sponsord/onramp-gate/`, the onramp exits at start and its log says why.

6. **TLS in front of the onramp.** Either:
   - **Caddy** (`caddy` profile): point the domain's DNS at this host and open
     **tcp/80** and **tcp/443** in the host firewall and the cloud security group.
     Caddy gets the certificate from Let's Encrypt, redirects http to https and
     proxies to `127.0.0.1:8080`. Its config is [`Caddyfile`](Caddyfile): no admin
     API, no HTTP/3 (so no udp/443), and an optional ACME contact email. Uncomment
     `ONRAMP_CLIENT_IP_HEADER=X-Forwarded-For` in `sponsord-onramp.env`, so the onramp
     rate limits each client instead of Caddy as a whole.
   - **Your own proxy**: leave `caddy` out of `COMPOSE_PROFILES` and proxy the domain
     to `127.0.0.1:8080`. Then decide on `ONRAMP_CLIENT_IP_HEADER` in
     `sponsord-onramp.env`. The onramp rate limits by that header's right-most
     address, so set it only if your proxy is the **only** way in and overwrites
     that header (e.g. `CF-Connecting-IP` behind Cloudflare). Unset, the onramp
     limits by the TCP peer, which behind a proxy is the proxy itself.

7. **Start it:**

   ```bash
   cp compose/.env.example compose/.env      # unless the node already uses one
   $EDITOR compose/.env    # COMPOSE_PROFILES=onramp,caddy; SPONSORD_*_IMAGE_DIGEST;
                           # SPONSORD_UID/GID, CADDY_UID/GID (`id -u sponsord` …);
                           # SPONSORD_ONRAMP_DOMAIN
   sudo docker compose -f compose/compose.yaml up -d
   curl -s 127.0.0.1:8090/healthz             # {"ok":true}
   curl -s 127.0.0.1:8080/healthz             # {"ok":true}
   curl -s https://<domain>/healthz           # through Caddy
   ```

   sponsord binds only after it has decrypted the keystore and confirmed on-chain
   that the treasury owns `SPONSORD_POOL_ID`. Until then it exits and restarts, and
   its log says why. The onramp exits while the daemon is unreachable, so it restarts
   until sponsord is up.

### Operate

As for the node, run these from the repository root with `sudo`.

**Before anything that restarts or stops sponsord** (a restart, a stop, an `up -d`
that recreates it, a treasury rotation), check that it holds no unconfirmed pool
top-up:

```bash
curl -fsS 127.0.0.1:8090/metrics | grep '^sponsord_pool_topup_unconfirmed_since_unix'
```

`… 0` means no hold. An error or no output means the state is unknown: do not
restart until you know. Anything else is a held top-up: the keeper broadcast one and could not read its
receipt, so it sends no other until that transaction mines or provably never can. A
restart forgets the hold, and the pool can then be refilled twice. Wait for it to
clear; if the transaction was dropped, send 0-value transactions from the treasury to
itself until it does (the error log line names the transaction and how many). The
Ansible role refuses such a restart on its own; Compose cannot, so this check is
yours. The `SponsordTopupHeld` alert (below) flags it.

- **Logs:** `sudo docker compose -f compose/compose.yaml logs -f sponsord sponsord-onramp caddy`.
- **Stop:** `sudo docker compose -f compose/compose.yaml stop caddy sponsord-onramp sponsord`
  (leave out `caddy` without that profile). On SIGTERM sponsord waits for a pool
  top-up it already sent, up to 120 s. Stopping sponsord alone leaves the onramp
  running, and stopping both leaves Caddy on tcp/80 and tcp/443 answering with
  errors.
- **Restart:** `sudo docker compose -f compose/compose.yaml restart sponsord` restarts
  the onramp too, because the onramp reads the daemon's limits only at start.
- **Config change:** edit the env file, then
  `sudo docker compose -f compose/compose.yaml up -d`, which recreates a container
  whose env changed. A changed credential file needs
  `sudo docker compose -f compose/compose.yaml restart sponsord` (the onramp restarts
  with it), or `restart sponsord-onramp` for the Turnstile secret alone.
- **Caddyfile change:** `sudo docker compose -f compose/compose.yaml restart caddy`.
  The admin API is off, so there is no live reload.
- **Rotate the treasury:** replace the keystore and password files (same owner and
  mode), then `sudo docker compose -f compose/compose.yaml restart sponsord`. The new
  wallet must own `SPONSORD_POOL_ID`, or sponsord exits at start.
- **Health:** no container healthchecks, as for the node. Probe the two `/healthz`
  endpoints above from the host. sponsord also serves `/metrics` on the same port, and
  logs errors only unless `RUST_LOG=info` is set in `sponsord.env`. The onramp logs
  at info; its `RUST_LOG` takes a level or `target=level` pairs only (a span or
  field filter makes it log nothing).
- **Dashboard and alerts:** a sponsord dashboard and alert rules (pool balance, keeper
  failures, a held top-up) are in
  [`monitoring/sponsord/`](../monitoring/README.md#sponsord).
- **Backup:** the treasury keystore and password are the only copy of the key that
  owns the pool and its funds. Copy them off the host encrypted, with the same
  files the Ansible path's `make backup` takes
  ([`docs/lifecycle.md`](../docs/lifecycle.md)):

  ```bash
  set -o pipefail
  sudo tar -C / --numeric-owner -czf - etc/sponsord/treasury-keystore.json \
      etc/sponsord/treasury-password etc/sponsord/api-token etc/sponsord/turnstile-secret \
    | age -r age1… -o sponsord.tar.age
  ```

## A local image

To run an unreleased build, build the daemon image from a `decdn/decdn` checkout (its `Dockerfile` header shows
how) and push it to a registry on the host's loopback, which gives it a digest:

```bash
sudo docker run -d --name registry --restart unless-stopped -p 127.0.0.1:5000:5000 registry:2
sudo docker build -t 127.0.0.1:5000/decdn-node:dev <decdn-checkout>     # after staging dist/<arch>/
sudo docker push 127.0.0.1:5000/decdn-node:dev    # prints "dev: digest: sha256:… size: …"
```

Then in `.env`:

```bash
DECDN_IMAGE_REPO=127.0.0.1:5000/decdn-node
DECDN_IMAGE_DIGEST=sha256:…                       # from the push output
```

The upstream image is based on Debian bookworm (glibc 2.36). A `decdn-node` built
natively on a newer distribution will not start in it; build with `cross`, as the
upstream release does, or on bookworm.

The sponsord images work the same way. `decdn/sponsord`'s `deploy/Dockerfile` builds
either one from source:

```bash
sudo docker build -f <sponsord-checkout>/deploy/Dockerfile --build-arg BIN=sponsord \
  -t 127.0.0.1:5000/sponsord:dev <sponsord-checkout>
sudo docker build -f <sponsord-checkout>/deploy/Dockerfile --build-arg BIN=sponsord-onramp \
  -t 127.0.0.1:5000/sponsord-onramp:dev <sponsord-checkout>
sudo docker push 127.0.0.1:5000/sponsord:dev && sudo docker push 127.0.0.1:5000/sponsord-onramp:dev
```

Then set `SPONSORD_IMAGE_REPO` / `SPONSORD_IMAGE_DIGEST` and
`SPONSORD_ONRAMP_IMAGE_REPO` / `SPONSORD_ONRAMP_IMAGE_DIGEST` in `.env`.

## Security notes

- Every container runs as a dedicated host account (`decdn`, `sponsord`, `caddy`) with
  a read-only root filesystem, every capability dropped and `no-new-privileges`.
  Caddy keeps `NET_BIND_SERVICE` and nothing else, for tcp/80 and tcp/443.
- Secret files are mounted read-only and one by one, so a container sees only its
  own. The secrets that are environment variables (`DECDN_RPC_URL`,
  `SPONSORD_RPC_URL`) live in root-only files on disk; Compose copies them into the
  container's config when it creates it.
- The remaining KICS findings are the design, not an oversight: host networking
  (loopback-only backends, no Docker-published ports), no healthchecks (see above),
  Caddy's one added capability, and the API token both sponsord containers mount.
  The "Volume Has Sensitive Host Directory" query, which flags every host-path mount
  (the roles' host layout), is excluded for the reason given in the root `Makefile`.
- Every image is referenced by digest: `compose.yaml` builds `REPO@DIGEST` itself,
  so no `.env` value can turn it into a mutable tag.
- Compose cannot require a variable without breaking the profiles that do not use
  it, so an unset one renders a value its service refuses: an invalid image
  reference, an unknown user, an onramp domain with a non-numeric port. That service
  fails to start; the others are unaffected.
- No secret is written in this file: each service may set only its listener,
  secret-file paths and public URL inline, and everything else (`DECDN_RPC_URL`,
  `SPONSORD_RPC_URL`, …) comes from its env file on the host.
- `make lint-compose` (CI job `compose`) renders this file with every profile on:
  with the example `.env`, without the env files, and with an empty `.env`. It fails
  if any of those properties regress ([`tests/invariants.jq`](tests/invariants.jq),
  [`tests/inline-env.jq`](tests/inline-env.jq),
  [`tests/fail-closed.jq`](tests/fail-closed.jq)); `make test-scripts` checks it
  rejects broken variants.
