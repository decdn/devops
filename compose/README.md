# deCDN services with Docker Compose

The same services the Ansible roles deploy, on one host, without Ansible: the upstream
images (amd64 and arm64) under Compose, with the same host paths, the same start
commands and the same hardening as the roles' systemd units. A small wrapper,
[`decdn-compose`](decdn-compose), prepares the host and runs Compose with the checks
Compose cannot make by itself.

| Profile | Service | Image | Ansible equivalent |
|---------|---------|-------|--------------------|
| `node` | `decdn-node`, a deCDN cache node (node operators) | `ghcr.io/decdn/decdn-node` | `decdn_node` on `decdn_nodes` outside `decdn_origin_nodes` ([`playbooks/node.yml`](../ansible/playbooks/node.yml)) |
| `origin` | the same `decdn-node`, run as a publisher's origin ([below](#run-it-as-an-origin-publishers)) | `ghcr.io/decdn/decdn-node` | `decdn_node` on `decdn_origin_nodes`, with an origin backend ([`playbooks/origin.yml`](../ansible/playbooks/origin.yml)) |
| `sponsord` | `sponsord`, the onboarding sponsor: treasury signer and PaymentPool keeper | `ghcr.io/decdn/sponsord` | `sponsord` |
| `onramp` | `sponsord-onramp`, its public side (Turnstile gate, installers); also starts `sponsord` | `ghcr.io/decdn/sponsord-onramp` | `sponsord_onramp` |
| `caddy` | Caddy, TLS in front of the onramp; leave it out to bring your own proxy | `caddy` (official) | `sponsord_onramp_proxy: caddy` |
| `relay` | `iroh-relay`, a self-hosted iroh relay ([below](#an-iroh-relay-publishers)) | `n0computer/iroh-relay` (official) | `iroh_relay` ([`playbooks/iroh_relay.yml`](../ansible/playbooks/iroh_relay.yml)) |
| `dns` | `iroh-dns-server`, a self-hosted iroh DNS server ([below](#an-iroh-dns-server-publishers)) | `n0computer/iroh-dns-server` (official) | `iroh_dns_server` ([`playbooks/iroh_dns_server.yml`](../ansible/playbooks/iroh_dns_server.yml)) |

A **node operator** runs `node`. A **publisher** runs `origin` for an origin node,
`onramp caddy` for a sponsor, or all three on one host, and `relay` and `dns` on hosts
of their own. The sponsor is independent of the node. `node` and `origin` start the
same service, so a host runs one or the other; `relay` and `dns` cannot share a host
with each other, `onramp` or `caddy`, which want the same ports.

Pick this path for a single machine you already run Docker on. For a fleet, or a host
you want hardened from scratch (firewall, SSH, auto-patching), use the
[Ansible project](../ansible/README.md); on Kubernetes, the
[Helm chart](../charts/decdn-node/README.md). [`docs/requirements.md`](../docs/requirements.md)
compares the paths.

## Requirements

- Linux with systemd: the containers log to the host journal, like the systemd
  units. Without journald, see [Logs](#logs).
- Docker Engine with Compose v2.24 or later, and Python 3.11 or later for the wrapper
  (Debian 12 and Ubuntu 24.04 ship it). `ss` (iproute2) for the port check, and
  [`age`](https://github.com/FiloSottile/age) for backups.
- This repository, checked out on the host: the wrapper reads `compose/` and the
  contract addresses this repo mirrors from upstream.

Every command below runs from the checkout's root, as root: Compose reads the
root-only env files whenever it creates a container, and `init` creates system
accounts and secrets.

## The wrapper

`decdn-compose` is a thin layer. Every service command is plain `docker compose`
against [`compose.yaml`](compose.yaml), plus `compose.override.yaml` when you have one
(a bare `docker compose -f compose.yaml` silently drops it). On top of that:

| Command | Does |
|---------|------|
| `init <profile>…` | creates the system accounts and directories, writes `.env` with their real uids, installs the env-file templates to `/etc`, fills in the chain's contract addresses from this repo's [generated mirror](../ansible/roles/sponsord/vars/main/networks.yml), and generates every secret that is generated on the host. It never replaces a secret, and ends with the list of what you still have to provide. Re-run it any time. |
| `check` | the preflight `up` also runs: every file present, owned and moded as the services need, the settings filled in, `decdn config validate` against the pinned image, the relay's and DNS server's configs, and no other process on the ports the stopped services bind |
| `up [svc…]` | `check`, then `docker compose up -d` |
| `stop`, `restart`, `down` | `docker compose …`, but refused while sponsord holds an unconfirmed pool top-up ([below](#the-top-up-hold)) |
| `health` | probes every running service: the node's admin RPC and metrics, each `/healthz`, sponsord's hold, the onramp's certificate through Caddy, the relay's metrics and certificate, the DNS server's version, SOA answers and certificate |
| `cli <args>` | the `decdn` CLI from the node image, with the node's config and keys and your RPC endpoint from `decdn.env`: `cli whoami`, `cli node status`, `cli setup` |
| `backup -r <age recipient>` | an age-encrypted archive of the active profiles' keys and secrets |
| `config` | `docker compose config`, with every value that came from an env file shown as `<redacted>` (the plain command prints `DECDN_RPC_URL` and the rest in clear) |
| `logs`, `ps`, `pull`, `exec` | plain `docker compose …` |

`.env` (beside `compose.yaml`, not committed) holds `COMPOSE_PROFILES`, the image
digests, the accounts' uids, the env files' paths, an fs origin's directory and the
onramp's domain. Nothing in it is secret. It is the only place Compose's inputs come
from: the wrapper always names the project (`decdn`) and refuses to run while the
shell sets a `COMPOSE_*` variable or one `compose.yaml` reads, which Compose would
otherwise take over `.env`, so its checks see what Compose runs. `init`
starts it from `.env.example`, which carries the digests of the releases the Ansible
roles pin (decdn/decdn v0.0.2, decdn/sponsord v0.0.2), each copied from that
release's signed digest file; [Operate](#operate) says how to take a newer one.

## The node

### Set up

1. **Prepare the host:**

   ```bash
   sudo compose/decdn-compose init node --region DE     # ISO 3166-1 alpha-2
   ```

   This creates the `decdn` system account, `/etc/decdn` and `/var/lib/decdn`, then
   uses the node image's `decdn` CLI to generate the keystore password, the node key
   and the eth keystore (`decdn key-gen`) and the config (`decdn config init --chain
   arbitrum-sepolia`, with the data dir and region set and, for a cache node,
   `node_to_node_pull_through_enabled = true` so it fills a miss from other nodes; the
   daemon's default is off). **Back up the keys now:**
   `sudo compose/decdn-compose backup -r age1…`.

2. **The RPC endpoint**, which may embed an API key, goes in the root-only env file
   `init` installed:

   ```bash
   sudoedit /etc/decdn/decdn.env        # DECDN_RPC_URL=https://…
   ```

3. **Firewall.** Allow inbound **udp/4433** on the host firewall *and* in your cloud
   provider's security group. Nothing else needs to be open.

4. **Start it:**

   ```bash
   sudo compose/decdn-compose up
   sudo compose/decdn-compose health
   ```

5. **Stake and register** (on-chain onboarding, ADR 019 Phase 2) with `decdn setup`,
   described in
   [`roles/decdn_node/README.md` § On-chain onboarding](../ansible/roles/decdn_node/README.md#on-chain-onboarding).
   Run `sudo compose/decdn-compose cli setup`. `node.toml` still names the public RPC
   `config init` wrote, so `cli` hands the CLI a copy whose `rpc_url` reads your
   endpoint from `decdn.env` (`"${DECDN_RPC_URL}"`, which the config loader
   expands): it never appears on a command line, in a sudo log or in shell history.
   The node serves paid traffic only after that.

### How it is laid out

| Host path | In the container | Holds |
|-----------|------------------|-------|
| `/etc/decdn/node.toml` | same, read-only | node config, no secrets |
| `/etc/decdn/keystore.password` | same, read-only | keystore password (`decdn`, `0600`) |
| `/etc/decdn/decdn.env` | read by Docker, injected as env | `DECDN_RPC_URL` (`root`, `0600`) |
| `/var/lib/decdn/` | same, read-write | `node.secret`, `keystore.json`, state, cache |
| `DECDN_ORIGIN_DIR` (an fs origin only) | `/srv/decdn-origin`, read-only | the origin's content |

The layout matches the Ansible role, so backups and restores
([`docs/lifecycle.md`](../docs/lifecycle.md)) work the same way on both, and a host
moves between the two paths without touching its keys.

**Networking.** Every container uses the host network. The node's metrics
(`127.0.0.1:9090`) and admin RPC (`127.0.0.1:9191`, hard-wired upstream) stay on the
host's loopback, and Docker publishes no ports, so its iptables rules never open
anything past your firewall. The node's only public port is QUIC **udp/4433**.

**Health.** The container's healthcheck is `decdn node health` against the admin RPC,
so `docker compose ps` shows a wedged runtime as unhealthy, not just a live process.
Dashboards and alert rules are in [`monitoring/`](../monitoring/README.md).

### Operate

- **Logs:** `sudo compose/decdn-compose logs -f decdn-node`, or
  `journalctl CONTAINER_NAME=decdn-decdn-node-1`.
- **Stop:** `sudo compose/decdn-compose stop decdn-node`. It sends SIGTERM, the
  daemon's graceful drain, and waits up to 300 s. Do not use `decdn node drain` here:
  `restart: unless-stopped` starts the drained container again.
- **Upgrade:** download the new release's `decdn-node-image-digest.txt` and its `.asc`
  from `decdn/decdn`'s releases, `gpg --verify` against the keys in
  [SECURITY.md](../SECURITY.md#release-verification), set the digest after its `@`
  as `DECDN_IMAGE_DIGEST` in `compose/.env`, then `sudo compose/decdn-compose up`.
  sponsord's release carries `sponsord-image-digest.txt` and
  `sponsord-onramp-image-digest.txt` the same way.
- **Config change:** edit `/etc/decdn/node.toml`, then
  `sudo compose/decdn-compose restart decdn-node` (or
  `sudo compose/decdn-compose cli node reload` for the hot-reloadable sections).
- **Coming from an earlier setup** whose `node.toml` predates the pull-through line:
  add `node_to_node_pull_through_enabled = true` under `[cache]` for a cache node
  (not an origin), then `restart decdn-node`.

### Run it as an origin (publishers)

An origin is the same node with an origin backend: the canonical source of a
publisher's namespace. `init origin` writes the backend into `node.toml`:

```bash
sudo compose/decdn-compose init origin --region DE --origin https://store.example.org/bucket
sudo compose/decdn-compose init origin --region DE --origin s3://my-bucket
sudo compose/decdn-compose init origin --region DE --origin file:///srv/content
```

- **HTTP store:** nothing else to do.
- **S3** (and R2, B2, MinIO): `config init` writes `region = "us-east-1"` for you to
  confirm and leaves `endpoint_url` commented. Static keys go in
  `/etc/decdn/decdn.env` (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`), never in
  `node.toml`.
- **A local or NFS path:** `init` records it as `DECDN_ORIGIN_DIR` in `.env`, and the
  node sees it read-only as `/srv/decdn-origin`, which is the path `node.toml` names.

Or write the `[cache.origin]` table by hand: the
[`decdn_node` role's README](../ansible/roles/decdn_node/README.md) lists the keys,
and `check` validates them.

With a backend set, the node serves only what its backend holds and declines the rest,
even a blob already in its cache (`relay_foreign_namespaces` defaults to false;
[ADR 002 § Retrieval by namespace](https://github.com/decdn/decdn/blob/main/adr/002-content-addressing.md#retrieval-by-namespace)),
and fills misses from the backend, not from other nodes. The chain recognises it as an
origin only once the namespace's publisher seats its operator with
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

### Set up

1. **Prepare the host:**

   ```bash
   sudo compose/decdn-compose init onramp caddy --domain onramp.example.org --generate-treasury
   ```

   This creates the `sponsord` and `caddy` accounts, `/etc/sponsord` and
   `/var/lib/caddy`, the API token, and the env files, with the chain id and the
   PaymentPool, CapacityBond and SlashJudge addresses filled in from this repo's
   mirror of upstream's deployment manifest. Leave out `caddy` to bring your own
   proxy, and `onramp` (use `sponsord`) for the daemon alone.

   `--generate-treasury` creates the treasury wallet on the host. Without it, copy
   your own keystore and its password in, owned by `sponsord`, `0600`:
   `/etc/sponsord/treasury-keystore.json` and `/etc/sponsord/treasury-password`.
   Either way, fund it with USDC plus gas, then open its pool from it
   (`decdn pool open`, which prints the pool id). It is a hot key: hold only a few
   top-ups' worth. Back it up now.

2. **The rest of the settings** (`init` lists exactly which):

   ```bash
   sudoedit /etc/sponsord/secret.env           # SPONSORD_RPC_URL='https://…' (may embed an API key)
   sudoedit /etc/sponsord/sponsord.env         # SPONSORD_POOL_ID
   sudoedit /etc/sponsord/sponsord-onramp.env  # ONRAMP_RPC_URL (public), ONRAMP_TURNSTILE_SITEKEY
   sudo install -m 0600 -o sponsord -g sponsord /dev/null /etc/sponsord/turnstile-secret
   sudoedit /etc/sponsord/turnstile-secret     # the Turnstile widget's secret key
   ```

   `sudoedit` writes a file back with its existing owner and mode.

3. **TLS in front of the onramp.** Either:
   - **Caddy** (`caddy` profile): point the domain's DNS at this host and open
     **tcp/80** and **tcp/443** in the host firewall and the cloud security group.
     Caddy gets the certificate from Let's Encrypt, redirects http to https and
     proxies to `127.0.0.1:8080`. Its config is [`Caddyfile`](Caddyfile): no admin
     API, no HTTP/3 (so no udp/443), and an optional ACME contact email. `init` set
     `ONRAMP_CLIENT_IP_HEADER=X-Forwarded-For` in `sponsord-onramp.env`, so the onramp
     rate limits each client instead of Caddy as a whole.
   - **Your own proxy**: leave `caddy` out and proxy the domain to `127.0.0.1:8080`.
     Then decide on `ONRAMP_CLIENT_IP_HEADER` in `sponsord-onramp.env`. The onramp
     rate limits by that header's right-most address, so set it only if your proxy is
     the **only** way in and overwrites that header (e.g. `CF-Connecting-IP` behind
     Cloudflare). Unset, the onramp limits by the TCP peer, which behind a proxy is
     the proxy itself.

4. **Start it:**

   ```bash
   sudo compose/decdn-compose up
   sudo compose/decdn-compose health
   ```

   sponsord binds only after it has decrypted the keystore and confirmed on-chain
   that the treasury owns `SPONSORD_POOL_ID`. Until then it exits and restarts, and
   its log says why. The onramp exits while the daemon is unreachable, so it restarts
   until sponsord is up.

**Your own gate page** (optional; upstream `docs/operator.md`, "Your own gate page",
lists its placeholders): put the HTML in `/etc/sponsord/onramp-gate/`, the one
directory the onramp mounts for it, and point `ONRAMP_GATE_TEMPLATE` at it in
`sponsord-onramp.env`:

```bash
sudo install -D -m 0644 -o root -g root gate.html /etc/sponsord/onramp-gate/gate.html
# in sponsord-onramp.env: ONRAMP_GATE_TEMPLATE=/etc/sponsord/onramp-gate/gate.html
```

The onramp serves whatever file `ONRAMP_GATE_TEMPLATE` names, to anyone, and its
container also holds the API token and the Turnstile secret. So `compose.yaml` starts
it through a check: unless the path resolves (symlinks followed) to a file in
`/etc/sponsord/onramp-gate/`, the onramp exits at start and its log says why.

### How it is laid out

| Host path | Owner, mode | Reaches | As |
|-----------|-------------|---------|----|
| `/etc/sponsord/secret.env` | `root`, `0600` | sponsord | env, read by Compose: `SPONSORD_RPC_URL` only |
| `/etc/sponsord/sponsord.env` | `root`, `0644` | sponsord | env: chain, PaymentPool, pool id, limits |
| `/etc/sponsord/sponsord-onramp.env` | `root`, `0644` | onramp | env: public settings |
| `/etc/sponsord/api-token` | `sponsord`, `0600` | both | Compose secret, `/run/secrets/api-token` |
| `/etc/sponsord/treasury-keystore.json` | `sponsord`, `0600` | sponsord | Compose secret |
| `/etc/sponsord/treasury-password` | `sponsord`, `0600` | sponsord | Compose secret |
| `/etc/sponsord/turnstile-secret` | `sponsord`, `0600` | onramp | Compose secret |
| `/etc/sponsord/onramp-gate/` | `root`, `0755` | onramp | read-only directory, same path: an optional custom gate page |
| `/var/lib/caddy/` | `caddy`, `0700` | Caddy | `/data`: certificates, ACME account |

The paths match the Ansible roles, with one difference: the credential files belong
to a `sponsord` account instead of root. Under systemd, root hands them to the
service; here a Compose secret is a read-only bind mount, which keeps the host file's
owner and mode, and sponsord refuses a treasury keystore that anyone but its owner can
read. Both daemons run as that account, and each container sees only the files it
needs. A host moved from the Ansible path needs a `chown` of those four files, and
running the Ansible `sponsord` role on the host again chowns them back to root, which
stops this path.

`compose.yaml` sets both listeners (`127.0.0.1:8090` for sponsord, `127.0.0.1:8080`
for the onramp), the onramp's daemon URL and every secret file path in
`environment:`, which wins over the env files, so no env file can change them; the
release images default both listeners to `0.0.0.0`. No container publishes a port:
sponsord is reachable only from the host, and from outside, the onramp only through
the proxy.

### Operate

#### The top-up hold

A stop or a restart of sponsord forgets a held, unconfirmed pool top-up: the keeper
broadcast one and could not read its receipt, so it sends no other until that
transaction mines or provably never can. Forget the hold and the pool can be refilled
twice. So `stop`, `restart`, `down`, and an `up` that would recreate sponsord (a
changed image, env file or setting), first read sponsord's
`sponsord_pool_topup_unconfirmed_since_unix` from `127.0.0.1:8090/metrics`, and refuse
while it is not 0 or cannot be read, as the Ansible role does. Wait for it to clear;
if the transaction was dropped, send 0-value transactions from the treasury to itself
until it does (the error log line names the transaction and how many). The
`SponsordTopupHeld` alert flags it. `--ignore-topup-hold` (before the command)
overrides the check. A plain `docker compose` command does not check: use the
wrapper.

- **Logs:** `sudo compose/decdn-compose logs -f sponsord sponsord-onramp caddy`.
- **Stop:** `sudo compose/decdn-compose stop caddy sponsord-onramp sponsord`. On
  SIGTERM sponsord waits for a pool top-up it already sent, up to 120 s. Stopping
  sponsord alone leaves the onramp running, and stopping both leaves Caddy on tcp/80
  and tcp/443 answering with errors.
- **Restart:** `sudo compose/decdn-compose restart sponsord` restarts the onramp too,
  because the onramp reads the daemon's limits only at start.
- **Config change:** edit the env file, then `sudo compose/decdn-compose up`, which
  recreates a container whose env changed. A changed credential file needs
  `restart sponsord` (the onramp restarts with it), or `restart sponsord-onramp` for
  the Turnstile secret alone.
- **Caddyfile change:** `sudo compose/decdn-compose restart caddy`. The admin API is
  off, so there is no live reload.
- **Rotate the treasury:** replace the keystore and password files (same owner and
  mode), then `restart sponsord`. The new wallet must own `SPONSORD_POOL_ID`, or
  sponsord exits at start.
- **Health:** `health` probes both `/healthz` endpoints and the hold. sponsord logs
  errors only unless `RUST_LOG=info` is set in `sponsord.env`. The onramp logs at
  info; its `RUST_LOG` takes a level or `target=level` pairs only (a span or field
  filter makes it log nothing).
- **Dashboard and alerts:** a sponsord dashboard and alert rules (pool balance, keeper
  failures, a held top-up) are in
  [`monitoring/sponsord/`](../monitoring/README.md#sponsord).
- **Backup:** the treasury keystore and password are the only copy of the key that
  owns the pool and its funds: `sudo compose/decdn-compose backup -r age1…` takes them
  with the API token, the Turnstile secret and the env files.

## An iroh relay (publishers)

`iroh-relay` is n0's relay server for iroh: when two peers cannot hole-punch, their
end-to-end encrypted QUIC traffic falls back to a relay, and its QUIC address
discovery (QAD, udp/7842) helps them hole-punch in the first place. Nodes use n0's
public relays unless their `relay_urls` names others; the ADRs expect production to
self-host relays as operational infrastructure, not an incentivized role
([Architecture § Trust Assumptions](https://github.com/decdn/decdn/blob/main/adr/architecture.md#trust-assumptions)).
The [`iroh_relay` role's README](../ansible/roles/iroh_relay/README.md) explains the
relay in depth; this section covers the Compose side.

The relay is public by design and terminates its own TLS: it gets a Let's Encrypt
certificate itself (TLS-ALPN-01 on tcp/443), and QAD needs that certificate
in-process, so no proxy can stand in front of it. It binds tcp/80, tcp/443 and
udp/7842 itself, so it cannot share a host with `onramp`, `caddy` or `dns`.

### Set up

1. **A DNS name.** Point an A record (and an AAAA record, if the host has IPv6) at
   the host.

2. **Prepare the host:**

   ```bash
   sudo compose/decdn-compose init relay --hostname relay1.example.org --contact you@your-domain
   ```

   This writes [`iroh-relay.toml.example`](iroh-relay.toml.example) to
   `/etc/iroh-relay/iroh-relay.toml` with your hostname and contact (Let's Encrypt
   mails expiry warnings there, and refuses an `example.*` address), and creates
   `/var/lib/iroh-relay` for the ACME account and certificates. It never replaces an
   existing config: edit that file instead. `--staging` uses Let's Encrypt's staging
   CA for a trial that leaves the production rate limits alone; its certificates are
   never trusted, so nodes cannot use the relay until you set `prod_tls = true`.

3. **Who may use it.** `--access` picks the mode (`allowlist`, the default, or
   `everyone`; a denylist is a hand edit, see the config's comments).
   - **`allowlist`** admits only the listed endpoint IDs. Run
     `sudo compose/decdn-compose cli whoami` on each of your nodes (the Ansible path:
     `decdn whoami` as the node's user) and add each `node id` to `access` in the
     config. `check` refuses an empty list, which would admit nobody. Update every
     relay after adding a node or rotating its key, then `restart iroh-relay`.
   - **What it costs:** decdn clients (`decdn fetch`, onramp users) use a fresh key
     per fetch, so they can never be listed, and iroh hole-punches over a connection
     it already has. A client therefore reaches a node homed on an allowlisted relay
     only if the node is directly reachable. A node behind NAT that serves clients
     needs its relays in `everyone` mode.

4. **Firewall.** Open **tcp/80** (iroh's captive-portal probe), **tcp/443** (the
   relay, and Let's Encrypt's challenge) and **udp/7842** (QAD) in the host firewall
   and the cloud security group, from anywhere.

5. **Start it:**

   ```bash
   sudo compose/decdn-compose up
   sudo compose/decdn-compose health
   ```

   `health` reads the relay's loopback `/metrics`, then fetches
   `https://<hostname>/healthz` from it against the host's trust store. Until Let's
   Encrypt has issued the first certificate (DNS and tcp/443 from the internet must
   work first), that second check fails; with `prod_tls = false` it only warns.

6. **Point the nodes at it.** In each node's `node.toml` (the Ansible path:
   `decdn_relay_urls`), then `restart decdn-node`:

   ```toml
   [network]
   relay_urls = ["https://relay1.example.org", "https://relay2.example.org"]
   ```

   `relay_urls` **replaces** n0's relays; it does not add to them. Deploy **at least
   two** relays, preferably in different regions, before switching nodes over.

### How it is laid out

| Host path | Owner, mode | In the container | Holds |
|-----------|-------------|------------------|-------|
| `/etc/iroh-relay/iroh-relay.toml` | `root`, `0644` | same, read-only | the config; nothing secret |
| `/var/lib/iroh-relay/` | `root`, `0700` | same, read-write | `acme/`: the Let's Encrypt account key and the certificate with its private key |

iroh-relay ignores keys it does not know, and without its config runs on built-in
defaults (metrics on a public port, no TLS). So the config is a single read-only file
that must exist (Docker never creates it), every key is written out, and `check`
refuses what the relay would ignore or run unsafely with: a key iroh-relay 1.3.0 does
not define, metrics off or off loopback, a `cert_dir` outside the mounted state
directory (the certificate would be lost on every restart), a non-Let's Encrypt
`cert_mode`, a placeholder or malformed hostname or contact, an empty allowlist,
ports other than 80/443/7842, and `[::]` on a host with `net.ipv6.bindv6only=1`
(where it serves no IPv4 peer; use `0.0.0.0`). Before `up` it also refuses ports
another process holds.

The image is n0's own `n0computer/iroh-relay`, the release the Ansible role pins
(`iroh_relay_version`, the iroh version decdn builds against), referenced by its
multi-arch digest in `compose.yaml`. Upstream signs neither the image nor the
release tarballs, so that digest is all that vouches for it, as the role's sha256
pin is on the Ansible path. It is upstream's musl build on Alpine; the role installs
the gnu build, whose glibc allocator serves a busy relay better. To change it, set
`IROH_RELAY_IMAGE_REPO` and `IROH_RELAY_IMAGE_DIGEST` in `.env`.

### Operate

- **Logs:** `sudo compose/decdn-compose logs -f iroh-relay`, at `RUST_LOG=info` (it
  logs only errors without it). An ACME failure (DNS, firewall, a refused contact)
  shows here; the relay keeps serving meanwhile.
- **Stop:** `sudo compose/decdn-compose stop iroh-relay` sends SIGINT, the only
  signal it shuts down gracefully on. As the container's PID 1 it ignores SIGTERM
  altogether, so a plain `docker stop` would wait out the grace period and kill it.
- **Config change:** edit `/etc/iroh-relay/iroh-relay.toml`, then
  `sudo compose/decdn-compose restart iroh-relay`, which checks the file first
  (iroh-relay ignores a mistyped key and falls back to its defaults, public metrics
  included) and refuses to restart on a problem. A restart drops the connections
  relayed through it.
- **Backup:** `backup` takes the config only. The relay creates its ACME account and
  certificate itself and gets new ones on a new host.
- **Dashboard and alerts:** in
  [`monitoring/iroh-relay/`](../monitoring/README.md#iroh-relay). Its scrape is your
  own on this path: `127.0.0.1:9092/metrics`, `job="iroh-relay"`.

## An iroh DNS server (publishers)

`iroh-dns-server` is n0's pkarr relay and DNS server for iroh: a deCDN node `PUT`s its
signed address record to `https://<hostname>/pkarr`, and peers resolve it as the TXT
record `_iroh.<z32 node id>.<origin>`, in place of n0's `dns.iroh.link`
([ADR 001 § Node Discovery](https://github.com/decdn/decdn/blob/main/adr/001-network.md#node-discovery-registry)).
The [`iroh_dns_server` role's README](../ansible/roles/iroh_dns_server/README.md)
explains it in depth; this section covers the Compose side.

It is public by design and terminates its own TLS (Let's Encrypt over TLS-ALPN-01 on
tcp/443), and it is authoritative for its zone on udp/53 and tcp/53. It cannot share a
host with `relay`, `onramp` or `caddy`, which want tcp/443 too. Run **one server per
origin**: upstream does not replicate, so two instances would be two independent
stores.

### Set up

1. **Delegate a zone to the host.** The server is authoritative for its hostname
   (say `dns.example.org`), which is also its https name. At the parent zone
   (`example.org`), add an NS record and a glue record:

   ```text
   dns.example.org.  NS  dns.example.org.
   dns.example.org.  A   203.0.113.10        ; glue: the host's public IPv4
   ```

   The server answers the matching NS, A and SOA records itself. Let's Encrypt
   resolves the hostname through this delegation, so the certificate comes only once
   it works: `dig +trace A dns.example.org` must end at this host.

2. **Prepare the host:**

   ```bash
   sudo compose/decdn-compose init dns --hostname dns.example.org --contact you@your-domain
   ```

   This writes [`iroh-dns-server.toml.example`](iroh-dns-server.toml.example) to
   `/etc/iroh-dns-server/config.toml` and creates `/var/lib/iroh-dns-server` (the
   record store and the ACME account and certificates). DNS binds **one** address,
   for udp and tcp: by default the host's default-route IPv4 (`--dns-bind` picks
   another), so systemd-resolved's stub on `127.0.0.53:53` keeps resolving for the
   host. The apex A record (`rr_a`) is that address when it is public; behind 1:1
   NAT (most clouds), pass the public one, the glue's, with `--public-ipv4`, and
   leave the bind on the private address the provider forwards port 53 to.
   `--staging` uses Let's Encrypt's staging CA for a trial; nodes cannot publish to
   it until you set `letsencrypt_prod = true`. It never replaces an existing config:
   edit that file instead.

3. **Firewall.** Open **tcp/443** (record `PUT`s, DNS-over-HTTPS and Let's Encrypt's
   challenge), **udp/53** and **tcp/53** in the host firewall and the cloud security
   group, from anywhere.

4. **Start it:**

   ```bash
   sudo compose/decdn-compose up
   sudo compose/decdn-compose health
   ```

   `health` reads the version from the loopback `/healthz` (the binary has no
   `--version`), asks each origin's SOA over udp and tcp at the bind address (with
   `dig`, when installed: `apt install bind9-dnsutils`), then fetches
   `https://<hostname>/healthz` against the host's trust store (only a warning with
   `letsencrypt_prod = false`).

5. **Point the nodes at it.** In each node's `node.toml` (the Ansible path:
   `decdn_discovery_pkarr_url` and `decdn_discovery_dns_origin`), then
   `restart decdn-node`:

   ```toml
   [network.discovery]
   pkarr_url = "https://dns.example.org/pkarr"
   dns_origin = "dns.example.org"
   ```

   Either setting **drops the node's n0 leg**: it publishes here only. A client on
   defaults resolves through `dns.iroh.link` and cannot find those nodes by pkarr
   (dials still work through the registry's multiaddrs), so **clients need the same
   `dns_origin`** in their `[network.discovery]`.

### How it is laid out

| Host path | Owner, mode | In the container | Holds |
|-----------|-------------|------------------|-------|
| `/etc/iroh-dns-server/config.toml` | `root`, `0644` | same, read-only | the config; nothing secret |
| `/var/lib/iroh-dns-server/` | `root`, `0700` | same, read-write | `signed-packets-1.db` (the records), `cert_cache/` (the ACME account key and the certificate with its private key) |

It runs as uid 0 holding `NET_BIND_SERVICE` alone, for the relay's reason
([Security notes](#security-notes)). iroh-dns-server ignores keys it does not know,
so `check` refuses: a key 1.3.0 does not define, an origin without its trailing dot
(1.3.0 then answers SOA but no record at the apex), a missing `"."` origin (it refuses
to start), origins that do not cover the hostname, `pkarr_put_rate_limit = "smart"`
(it reads `X-Forwarded-For`, which a client can forge with no proxy in front), the
loopback `/healthz` and metrics listeners off loopback, a `data_dir` outside the
mount, a non-Let's Encrypt `cert_mode`, placeholders, a private or missing `rr_a`
while the server answers its own hostname, and `::` under `net.ipv6.bindv6only=1`.
Before `up` it refuses port 53 held on the DNS bind address (or anywhere, for a
wildcard bind, naming `DNSStubListener=no` when systemd-resolved's stub is the
holder), and tcp/443 and the loopback ports held by anything.

The image is n0's `n0computer/iroh-dns-server`, the release the role pins
(`iroh_dns_server_version`), by its multi-arch digest in `compose.yaml`: unsigned
upstream and a musl build on Alpine, as the relay's. `IROH_DNS_SERVER_IMAGE_REPO` /
`_DIGEST` in `.env` change it (then `health` no longer insists on the pinned version).

### Operate

- **Logs:** `sudo compose/decdn-compose logs -f iroh-dns-server`, at `RUST_LOG=info`,
  which logs every query.
- **Stop:** `sudo compose/decdn-compose stop iroh-dns-server` sends SIGINT, the only
  signal it shuts down gracefully on, flushing its record writes; as PID 1 it ignores
  SIGTERM.
- **Config change:** edit `/etc/iroh-dns-server/config.toml`, then
  `sudo compose/decdn-compose restart iroh-dns-server`, which checks the file first
  (iroh-dns-server ignores a mistyped key) and refuses to restart on a problem.
- **Backup:** `backup` takes the config only. Nodes republish their records every 5
  minutes, and the server gets a new certificate on a new host.
- **Monitoring:** no dashboard or alert rules yet. Its metrics are on
  `127.0.0.1:9117/metrics`.

## Logs

Every container logs to the host journal (Compose's `journald` driver), like the
systemd units: `journalctl CONTAINER_NAME=decdn-sponsord-1`, or
`decdn-compose logs`. On a host without journald, `check` refuses to start; set
another driver per service in a `compose.override.yaml` beside `compose.yaml`, which
the wrapper always includes:

```yaml
services:
  decdn-node:
    logging: {driver: local}
```

## Backups

`sudo compose/decdn-compose backup -r age1… [-r age1…] [-o file.tar.age]` writes, in
the current directory, one archive of the active profiles' keys, secrets and env
files, encrypted on the host to the age recipients (nothing readable touches the
disk). It covers what the Ansible path's `make backup` takes for the identity, plus
`node.toml` and the env files, and refuses to write an archive while any of them is
missing;
restore with `age -d -i <key> <file> | sudo tar -C / -xzp --numeric-owner`, as in
[`docs/lifecycle.md`](../docs/lifecycle.md#restore-and-host-migration).

## A local image

To run an unreleased build, build the daemon image from a `decdn/decdn` checkout (its
`Dockerfile` header shows how) and push it to a registry on the host's loopback, which
gives it a digest:

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

The upstream image is based on Debian; a `decdn-node` built natively on a newer
distribution than the image's may not start in it. Build with `cross`, as the upstream
release does. The image must carry the `decdn` CLI too: the wrapper and the node's
healthcheck use it.

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

## Without the wrapper

`compose.yaml` is plain Compose, and every wrapper command maps onto one:
`sudo docker compose --project-directory compose up -d` (from the checkout's root),
`… stop decdn-node`, and so on. What you give up: the preflight, and the top-up hold
check, which you must then make yourself before anything that stops or recreates
sponsord:

```bash
curl -fsS 127.0.0.1:8090/metrics | grep '^sponsord_pool_topup_unconfirmed_since_unix'
```

`… 0` means no hold; an error or no output means the state is unknown. With a
`compose.override.yaml`, `--project-directory compose` picks it up only when no `-f`
is given.

## Security notes

- Every container runs as a dedicated host account (`decdn`, `sponsord`, `caddy`) with
  a read-only root filesystem, every capability dropped and `no-new-privileges`, from
  one shared block (`x-hardened`). Caddy keeps `NET_BIND_SERVICE` and nothing else,
  for tcp/80 and tcp/443.
- **The exception is the iroh services, the relay and the DNS server, which run as
  uid 0** holding `NET_BIND_SERVICE` and nothing else. Each must bind its public
  ports itself (the relay tcp/80, tcp/443 and udp/7842, the DNS server tcp/443 and
  udp+tcp/53; each terminates its own TLS, and the relay's QUIC address discovery
  needs the certificate in-process, so no proxy can take the ports), and on the host
  network Docker cannot give a non-root process that capability: Docker sets no
  ambient capabilities, the images' binaries carry no file capability (Caddy's
  does), and the `net.ipv4.ip_unprivileged_port_start` sysctl cannot be set on a
  host-network container. The rest of the hardening stays: read-only root
  filesystem, `no-new-privileges`, every other capability dropped (the effective set
  is `0x400`, `CAP_NET_BIND_SERVICE` alone, so root's file-permission and other
  overrides are gone), and the only writable mount is the service's own state
  directory. [`tests/invariants.jq`](tests/invariants.jq) allows uid 0 for these two
  services only, and only with `cap_add` exactly `[NET_BIND_SERVICE]`.
- Secret files reach the sponsor's containers as Compose secrets: read-only, one file
  each, from a host file only (never an environment source), so a container sees only
  its own. A missing secret file fails the start; Docker never creates one in its
  place. The secrets that are environment variables (`DECDN_RPC_URL`,
  `SPONSORD_RPC_URL`) live in root-only files on disk; Compose copies them into the
  container's config when it creates it.
- The wrapper never prints a secret: a failed `config validate` is shown with every
  URL cut to its scheme and host.
- The remaining KICS findings are the design, not an oversight: host networking
  (loopback-only backends, no Docker-published ports), no healthchecks on the sponsor's
  images (they have no HTTP client), the one added capability of Caddy and the iroh
  services, the iroh services running as root (above), and the API token both
  sponsord containers mount. The "Volume Has Sensitive Host Directory" query,
  which flags every host-path mount (the roles' host layout), is excluded for the
  reason given in the root `Makefile`.
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
  rejects broken variants and runs the wrapper's unit tests
  ([`tests/test_decdn_compose.py`](tests/test_decdn_compose.py)).
