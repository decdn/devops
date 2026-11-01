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
| `onramp` | `sponsord-onramp`, its public side (Turnstile gate, installers), on loopback behind your own TLS proxy ([below](#sponsord-and-its-onramp)); also starts `sponsord` | `ghcr.io/decdn/sponsord-onramp` | `sponsord_onramp`, which also installs nginx and its certificate |
| `relay` | `iroh-relay`, a self-hosted iroh relay ([below](#an-iroh-relay-publishers)) | `n0computer/iroh-relay` (official) | `iroh_relay` ([`playbooks/iroh_relay.yml`](../ansible/playbooks/iroh_relay.yml)) |
| `dns` | `iroh-dns-server`, a self-hosted iroh DNS server ([below](#an-iroh-dns-server-publishers)) | `n0computer/iroh-dns-server` (official) | `iroh_dns_server` ([`playbooks/iroh_dns_server.yml`](../ansible/playbooks/iroh_dns_server.yml)) |
| `gateway` | `decdn-gateway`, a public deCDN gateway on loopback, behind your own TLS proxy ([below](#a-public-gateway-publishers)) | `ghcr.io/decdn/decdn-node` (its `decdn` CLI) | `decdn_gateway` ([`playbooks/decdn_gateway.yml`](../ansible/playbooks/decdn_gateway.yml)), which also installs nginx and its certificate |
| `alloy` | Grafana Alloy: this host's metrics and logs to Grafana Cloud ([below](#grafana-cloud-alloy)) | `grafana/alloy` (official) | `grafana_alloy` (`decdn_grafana_cloud_enabled`) |

A **node operator** runs `node`. A **publisher** runs `origin` for an origin node,
`onramp` for a sponsor, or both on one host, `relay` and `dns` on hosts of their
own, and `gateway` for a public gateway. The sponsor is independent of the node.
`node` and `origin` start the same service, so a host runs one or the other; `relay`
and `dns` cannot share a host with each other or with `onramp`, whose TLS proxy wants
the same ports. Any host adds `alloy` to ship its metrics and logs to Grafana Cloud.

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
| `health` | probes every running service: the node's admin RPC and metrics, each `/healthz`, sponsord's hold, the relay's metrics and certificate, the DNS server's version, SOA answers and certificate, Alloy's readiness and components |
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
starts it from `.env.example`, which carries the three digests of the newest release
of the line the Ansible roles pin (`decdn_node_version` = `sponsord_version`: one
decdn/decdn release ships every image), each copied from that release's signed digest
file. Compose pins by digest only, so it
names one release where the roles follow the line; [Operate](#operate) says how to
take a newer one.

## The node

### Set up

1. **Prepare the host:**

   ```bash
   sudo compose/decdn-compose init node --region DE     # ISO 3166-1 alpha-2
   ```

   This creates the `decdn` system account, `/etc/decdn` and `/var/lib/decdn`, then
   uses the node image's `decdn` CLI to generate the keystore password, the node key
   and the eth keystore (`decdn key-gen`) and the config (`decdn config init --chain
   arbitrum-sepolia`, with the data dir and region set; the daemon turns
   `node_to_node_pull_through_enabled` on for a cache node, so it fills a miss from other
   nodes). **Back up the keys now:**
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
   Find the node's wallet with `sudo compose/decdn-compose cli whoami` and fund it, then
   run `sudo compose/decdn-compose cli setup --mbps 100 --region DE --multiaddr
   /ip4/<public-ip>/udp/4433/quic-v1 --dry-run`, and again without `--dry-run`
   (`--mbps` and `--region` are required). Pass the public address even on a cloud VM
   behind 1:1 NAT: left out, `setup` registers only a public address on the default
   route, so such a host registers none. On a dual-stack host, add
   `--multiaddr /ip6/<public-ipv6>/udp/4433/quic-v1` as well. `node.toml` still
   names the public RPC `config init` wrote, so `cli` hands the CLI a copy whose
   `rpc_url` reads your endpoint from `decdn.env` (`"${DECDN_RPC_URL}"`, which the config loader
   expands): it never appears on a command line, in a sudo log or in shell history.
   The node serves paid traffic only after that. The CLI's daily "a newer release
   exists, run `decdn self-update`" notice (decdn v0.2) is off in the `node.toml`
   that `init` writes and under `cli`: the image's binary is read-only, and the pin
   moves with `DECDN_IMAGE_DIGEST` ([Operate](#operate)).

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
the installers poll for their capability. The onramp calls the daemon on loopback with the
daemon's own API token, so the two run on the same host (the `onramp` profile starts
both). The [`sponsord`](../ansible/roles/sponsord/README.md) and
[`sponsord_onramp`](../ansible/roles/sponsord_onramp/README.md) role READMEs explain
what each setting does; this section covers the Compose side.

### Set up

1. **Prepare the host:**

   ```bash
   sudo compose/decdn-compose init onramp --domain onramp.example.org --generate-treasury
   ```

   This creates the `sponsord` account, `/etc/sponsord`, the API token, and the env
   files, with the chain id and the PaymentPool, CapacityBond and SlashJudge addresses
   filled in from this repo's mirror of upstream's deployment manifest. Use
   `sponsord` instead of `onramp` for the daemon alone.

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

3. **Your TLS proxy.** The onramp listens on `127.0.0.1:8080` only. Point the
   domain's DNS at a proxy of your own that terminates TLS for it and forwards to
   `http://127.0.0.1:8080`, and open its ports (tcp/80 and tcp/443 when it runs on
   this host). The Ansible role puts the distro's nginx in front with a Let's Encrypt
   certificate, but stock nginx cannot bind tcp/80 and tcp/443 as a non-root account
   on the host network, and this file runs no service as root but the iroh ones
   ([Security notes](#security-notes)). A minimal nginx site, with the certificate
   from any ACME client. The `/.well-known/acme-challenge/` location serves an
   HTTP-01 webroot, as the role's
   [certificate unit](../ansible/roles/sponsord_onramp/templates/sponsord-onramp-certs.service.j2)
   uses with lego (`--http --http.webroot /var/www/acme`):

   ```nginx
   server {
       listen 80;
       listen [::]:80;
       server_name onramp.example.org;
       location ^~ /.well-known/acme-challenge/ {
           root /var/www/acme;
       }
       location / {
           return 301 https://$host$request_uri;
       }
   }

   server {
       # nginx 1.25.1 and later: `listen 443 ssl;` plus `http2 on;`.
       listen 443 ssl http2;
       listen [::]:443 ssl http2;
       server_name onramp.example.org;
       ssl_certificate     /etc/ssl/onramp/fullchain.pem;
       ssl_certificate_key /etc/ssl/onramp/privkey.pem;

       location / {
           proxy_pass http://127.0.0.1:8080;
           proxy_set_header Host $host;
           # The client's address, replacing whatever the client sent.
           proxy_set_header X-Forwarded-For $remote_addr;
       }
   }
   ```

   Then decide on `ONRAMP_CLIENT_IP_HEADER` in `sponsord-onramp.env`; `init` leaves it
   unset. The onramp rate limits by that header's right-most address, so set it
   (`X-Forwarded-For` for the site above) only if your proxy is the **only** way in
   and puts the client's address there (`CF-Connecting-IP` behind Cloudflare).
   Unset, the onramp limits by the TCP peer, which behind a proxy is the proxy
   itself, so every user shares one limit.

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

- **Logs:** `sudo compose/decdn-compose logs -f sponsord sponsord-onramp`.
- **Stop:** `sudo compose/decdn-compose stop sponsord-onramp sponsord`. On SIGTERM
  sponsord waits for a pool top-up it already sent, up to 120 s. Stopping sponsord
  alone leaves the onramp running, and stopping both leaves your proxy answering
  with errors.
- **Restart:** `sudo compose/decdn-compose restart sponsord` restarts the onramp too,
  because the onramp reads the daemon's limits only at start.
- **Config change:** edit the env file, then `sudo compose/decdn-compose up`, which
  recreates a container whose env changed. A changed credential file needs
  `restart sponsord` (the onramp restarts with it), or `restart sponsord-onramp` for
  the Turnstile secret alone.
- **Moving off the old `caddy` profile:** this file no longer has one, and `check`
  and `up` refuse a `COMPOSE_PROFILES` that still names it. Drop `caddy` from it in
  `.env` (and the `CADDY_*` lines), then
  `sudo compose/decdn-compose up --remove-orphans`, which removes the Caddy container
  and frees tcp/80 and tcp/443 for your own proxy ([Set up](#set-up-1), step 3).
  `check` and a plain `up` refuse while that container still runs. Afterwards,
  `sudo rm -r /var/lib/caddy` and `sudo userdel caddy` remove its old certificates
  and account. The old `init` set `ONRAMP_CLIENT_IP_HEADER=X-Forwarded-For` in
  `sponsord-onramp.env`, which was safe only because Caddy overwrote that header:
  keep it only if your proxy is the only way in and sets the header itself (step 3),
  otherwise remove it, or clients choose the address the rate limits key on.
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
udp/7842 itself, so it cannot share a host with `dns`, or with `onramp`, whose TLS
proxy wants tcp/80 and tcp/443.

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
   - **What it costs:** decdn clients (`decdn get`, onramp users) use a fresh key
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
  [`monitoring/iroh-relay/`](../monitoring/README.md#iroh-relay). The
  [`alloy` profile](#grafana-cloud-alloy) on the same host scrapes
  `127.0.0.1:9092/metrics` as `job="iroh-relay"`; otherwise the scrape is your own.

## An iroh DNS server (publishers)

`iroh-dns-server` is n0's pkarr relay and DNS server for iroh: a deCDN node `PUT`s its
signed address record to `https://<hostname>/pkarr`, and peers resolve it as the TXT
record `_iroh.<z32 node id>.<origin>`, in place of n0's `dns.iroh.link`
([ADR 001 § Node Discovery](https://github.com/decdn/decdn/blob/main/adr/001-network.md#node-discovery-registry)).
The [`iroh_dns_server` role's README](../ansible/roles/iroh_dns_server/README.md)
explains it in depth; this section covers the Compose side.

It is public by design and terminates its own TLS (Let's Encrypt over TLS-ALPN-01 on
tcp/443), and it is authoritative for its zone on udp/53 and tcp/53. It cannot share a
host with `relay`, or with `onramp`, whose TLS proxy wants tcp/443 too. Run **one server per
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
`_DIGEST` in `.env` change it (with another `IROH_DNS_SERVER_IMAGE_DIGEST`, `health`
no longer insists on the pinned version).

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
- **Dashboard and alerts:** in
  [`monitoring/iroh-dns-server/`](../monitoring/README.md#iroh-dns-server). The
  [`alloy` profile](#grafana-cloud-alloy) on the same host scrapes
  `127.0.0.1:9117/metrics` as `job="iroh-dns-server"`; otherwise the scrape is your own.

## A public gateway (publishers)

`decdn gateway --public-url` serves `decdn:` content to any browser on a domain of your
own: `https://<domain>/<hash>`, a bundle as a website at `https://<hash32>.<domain>/`,
and a namespace's at `https://<ns>.<domain>/` once its owner points it there. It pays
for every request from a pool its own wallet funds, within a daily allowance
([`adr/appendix-gateway.md`](https://github.com/decdn/decdn/blob/main/adr/appendix-gateway.md)).
The [`decdn_gateway` role's README](../ansible/roles/decdn_gateway/README.md) explains
it in depth; this section covers the Compose side.

The profile runs **the gateway only**, on loopback (`127.0.0.1:8484`, metrics on
`127.0.0.1:9094`). TLS is your own proxy's: the Ansible role puts the distro's nginx in
front with a wildcard certificate, but stock nginx cannot bind tcp/80 and tcp/443 as a
non-root account on the host network, and this file runs no service as root but the
iroh ones ([Security notes](#security-notes)).

### Set up

1. **Prepare the host:**

   ```bash
   sudo compose/decdn-compose init gateway --gateway-domain gateway.example.org
   ```

   This creates the `decdn-gateway` account, `/var/lib/decdn-gateway` and
   `/etc/decdn-gateway`, generates the wallet's password and **the gateway's own
   wallet** (`decdn key-gen`, from the node image; it prints the eth address), writes
   `/etc/decdn-gateway/gateway.toml` with the chain's contract addresses
   (`--chain`, from this repo's
   [generated mirror](../ansible/roles/decdn_gateway/vars/main/networks.yml)), and
   installs [`decdn-gateway.env.example`](decdn-gateway.env.example) to
   `/etc/decdn-gateway/gateway.env`. The gateway runs on the node image's `decdn`, so
   `.env` needs `DECDN_IMAGE_DIGEST` even on a host without a node.

2. **The RPC URL and the wallet.** Set `DECDN_GATEWAY_RPC_URL` in
   `/etc/decdn-gateway/gateway.env` (`sudoedit`); `gateway.toml` reads it as
   `${DECDN_GATEWAY_RPC_URL}`, so the URL stays in the root-only file. Fund the
   wallet's address with USDC (at least the working deposit, 10 USDC) and ETH for
   gas. Set `DECDN_GATEWAY_ALLOWANCE_BYTES_PER_DAY` in `.env` to what you will pay
   for.

3. **Your TLS proxy.** Point `<domain>` and `*.<domain>` at the host, and terminate
   TLS for both in a proxy of your own that forwards to `http://127.0.0.1:8484`. It
   must:
   - pass `Host` through unchanged: the gateway routes by it;
   - add no CORS headers: the gateway sets its own, and a second
     `Access-Control-Allow-Origin` makes browsers refuse the answer;
   - stream: no response buffering;
   - limit `PUT /_pointer` per client address: the gateway budgets owner lookups
     globally and reads no `X-Forwarded-*` header.

   The Ansible role's
   [nginx site](../ansible/roles/decdn_gateway/templates/decdn-gateway.nginx.j2) is
   a complete example, and its
   [certificate unit](../ansible/roles/decdn_gateway/templates/decdn-gateway-certs.service.j2)
   shows the lego command for the wildcard over ACME DNS-01. A wildcard covers one
   label, so the `?ns=` redirect's `<ns>.<hash32>.<domain>` has no certificate
   (decdn/decdn#2784).

4. **Start it:**

   ```bash
   sudo compose/decdn-compose up
   sudo compose/decdn-compose health
   ```

   `health` asks the gateway's loopback listener for `/` and its metrics listener for
   `/metrics`.

### How it is laid out

| Host path | Owner, mode | In the container | Holds |
|-----------|-------------|------------------|-------|
| `/etc/decdn-gateway/` | `decdn-gateway`, `0750` | same, read-only | `keystore.password` (`0600`) and `gateway.toml` (`0644`, nothing secret) |
| `/etc/decdn-gateway/gateway.env` | `root`, `0600` | its environment | `DECDN_GATEWAY_RPC_URL`, `RUST_LOG` |
| `/var/lib/decdn-gateway/` | `decdn-gateway`, `0700` | same, read-write | `keystore.json` (the wallet), `gateway/store/` (the pool and its lanes), `gateway/pointers/` (namespace pointers) |

`check` refuses a missing or readable wallet or password, an unset RPC URL, the
example domain, and the gateway's loopback ports held by anything else.

### Operate

- **Logs:** `sudo compose/decdn-compose logs -f decdn-gateway`.
- **Stop:** `stop decdn-gateway` sends SIGINT, the only signal it shuts down
  gracefully on: it settles the pulls in flight. A restart forgives the day's
  allowance (the counters live in memory).
- **Per-namespace allowances** (`--allowance <ns>=<bytes>`): add them to the
  service's `command` in a `compose.override.yaml`.
- **Backup:** `backup` takes the wallet, its password, `gateway.toml`, the env file
  and the namespace pointers. Leave the pool store: the gateway adopts its live pool
  from the chain again.
- **Monitoring:** the [`alloy` profile](#grafana-cloud-alloy) on the same host scrapes
  `127.0.0.1:9094/metrics` as `job="decdn-gateway"`; the dashboard and alert rules are
  in [`monitoring/decdn-gateway/`](../monitoring/decdn-gateway/).

## Grafana Cloud (alloy)

The `alloy` profile runs [Grafana Alloy](https://grafana.com/docs/alloy/), the agent
the Ansible [`grafana_alloy`](../ansible/roles/grafana_alloy/README.md) role installs,
with the same pipeline: its configuration,
[`alloy/config.alloy`](alloy/config.alloy), is generated from the role's own
template (`scripts/render-compose-alloy.sh`; never edit it by hand, and
`make test-scripts` fails while it differs from a fresh render). It is opt-in, like
`decdn_grafana_cloud_enabled` on the Ansible path.

```bash
sudo compose/decdn-compose init alloy           # the alloy account, /var/lib/alloy, the env file
sudoedit /etc/grafana-alloy.env                 # the token and endpoints (below)
sudo compose/decdn-compose up && sudo compose/decdn-compose health
```

`init alloy` adds `alloy` to `COMPOSE_PROFILES` and writes the account's uid/gid, the
host's `systemd-journal` gid, the instance name (the host name) and the region (the
node's, or `--region`) to `.env`.

**Credentials.** `/etc/grafana-alloy.env` (`root`, `0600`) holds the Grafana Cloud
access-policy token (`GC_API_TOKEN`, with metrics, logs and traces write) and the
endpoints and instance IDs: `GC_PROM_REMOTE_WRITE_URL` / `GC_PROM_USERNAME`,
`GC_LOKI_URL` / `GC_LOKI_USERNAME`, `GC_OTLP_ENDPOINT` (and `GC_OTLP_USERNAME` when
your stack's OTLP instance ID is not the Prometheus one). It is the file, at the path,
the Ansible role reads, so a host moving between the paths keeps it; Compose has no
inventory, so every endpoint goes in it
([`grafana-alloy.env.example`](grafana-alloy.env.example)). Compose reads it when it
creates the container; it is never in `compose.yaml` or `.env`, and
`decdn-compose config` prints its values as `<redacted>`.

| Host path | In the container | Holds |
|-----------|------------------|-------|
| `/etc/grafana-alloy.env` | read by Docker, injected as env | the token and endpoints (`root`, `0600`) |
| `compose/alloy/config.alloy` | `/etc/alloy/config.alloy`, read-only | the generated configuration |
| `/var/lib/alloy/` | same, read-write | the WAL, the journal positions, the send queue (`alloy`, `0700`) |
| `/proc`, `/sys`, `/` | `/host/proc`, `/host/sys`, `/host/root` (`rslave`), read-only | what the host metrics read |
| `/var/log/journal`, `/run/log/journal`, `/etc/machine-id` | same, read-only | the host journal |

**What it collects**, labelled as on the Ansible path (`instance` = `ALLOY_INSTANCE_ID`,
plus `region` and `deployment_environment` from `.env`):

- the node's `/metrics` (`job="decdn-node"`), only while `COMPOSE_PROFILES` has `node`
  or `origin`; sponsord's (`job="sponsord"`), only with `sponsord` or `onramp`; the
  relay's (`127.0.0.1:9092`, `job="iroh-relay"`) with `relay`, and the DNS server's
  (`127.0.0.1:9117`, `job="iroh-dns-server"`) with `dns`. A host without the daemon
  has no target, so no `up == 0` for `DecdnNodeDown` (or `SponsordDown`,
  `IrohRelayDown`, `IrohDnsServerDown`) to fire on. Compose passes `COMPOSE_PROFILES` in as `DECDN_COMPOSE_PROFILES`, so a profile
  change recreates the container with the new targets (a profile chosen with
  `--profile` on the command line instead is not seen);
- the host: Alloy's in-process node_exporter (CPU, memory, disks, filesystems,
  network, load, pressure), `job="integrations/node_exporter"`, reading the host's
  `/proc`, `/sys` and `/` through the read-only mounts. The `systemd` collector is
  off (it would need the host's D-Bus socket);
- Alloy's own health (`job="integrations/alloy"`);
- the host journal to Loki, every unit's and every container's lines. The
  containers' lines arrive as `docker.service` with a `container` label; this
  project's get their role's unit (`decdn-decdn-node-1` becomes
  `unit="decdn-node.service"`, likewise `sponsord`, `sponsord-onramp`,
  `iroh-relay`, `iroh-dns-server` and `alloy`), so the level parsing, the debug/trace guardrail and the dashboards' log
  panels work as on the Ansible path;
- OTLP on `127.0.0.1:4317` (gRPC) and `:4318` (HTTP), sampled and forwarded.

**URL redaction.** Every journal line passes the role's `redact_urls` stage before
any level stage: a URL keeps its scheme and host and loses its userinfo, path, query
and fragment, so an RPC URL a daemon quotes in an error ships without its API key.
`make lint-alloy` runs these stages, and a container's line through them, in the real
Alloy.

**Hardening.** The shared `x-hardened` block, as the account `alloy` with the
`systemd-journal` group added and no capability: what that account cannot read on the
host (the `0600` key files, `/root`), Alloy does not collect, as under the role's
unit. Its UI and API (`/-/ready`, the component graph) listen on `127.0.0.1:12345`
only. `health` checks `/-/ready` and that every component is healthy; a Grafana
Cloud rejection (a wrong token or instance ID) shows in `decdn-compose logs alloy`
instead.

**In Grafana Cloud**, install the *Linux Server* integration (Connections → Linux
Server): its dashboards and alerts select `job="integrations/node_exporter"` and
`instance`, which these series and log lines carry. The deCDN dashboards and alert
rules are in [`monitoring/`](../monitoring/README.md).

The persistent journal must exist (`/var/log/journal`): `check` refuses without it,
and `compose.yaml` never lets Docker create it, which would switch journald to
persistent storage behind your back.

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

The sponsord images work the same way: they are the `sponsord` and `sponsord-onramp`
stages of decdn/decdn's root `Dockerfile`, built from the same release archives as the
node image (`docker build --target sponsord`; upstream's `RELEASING.md` has the
`dist/<arch>/` layout the stages copy from). Push both to the local registry, then set
`SPONSORD_IMAGE_REPO` / `SPONSORD_IMAGE_DIGEST` and `SPONSORD_ONRAMP_IMAGE_REPO` /
`SPONSORD_ONRAMP_IMAGE_DIGEST` in `.env`.

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

- Every container runs as a dedicated host account (`decdn`, `sponsord`,
  `decdn-gateway`, `alloy`) with a read-only root filesystem, every capability dropped and
  `no-new-privileges`, from one shared block (`x-hardened`). Alloy gets the host's
  `systemd-journal` group and read-only views of the host (`/proc`, `/sys`, `/`, the
  journal): no other container mounts any of them. "Read-only" holds for what is
  mounted at start (submounts too only on Docker 25+ with kernel 5.12+); a
  filesystem the host mounts later keeps its own flags, which Alloy, as a non-root
  account with no capability, can still only read as file modes allow.
- **The exception is the iroh services, the relay and the DNS server, which run as
  uid 0** holding `NET_BIND_SERVICE` and nothing else. Each must bind its public
  ports itself (the relay tcp/80, tcp/443 and udp/7842, the DNS server tcp/443 and
  udp+tcp/53; each terminates its own TLS, and the relay's QUIC address discovery
  needs the certificate in-process, so no proxy can take the ports), and on the host
  network Docker cannot give a non-root process that capability: Docker sets no
  ambient capabilities, the images' binaries carry no file capability, and the `net.ipv4.ip_unprivileged_port_start` sysctl cannot be set on a
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
  `SPONSORD_RPC_URL`, `DECDN_GATEWAY_RPC_URL`) live in root-only files on disk; Compose copies them into the
  container's config when it creates it.
- The wrapper never prints a secret: a failed `config validate` is shown with every
  URL cut to its scheme and host.
- The remaining KICS findings are the design, not an oversight: host networking
  (loopback-only backends, no Docker-published ports), no healthchecks on the sponsor's
  images, Alloy's (they have no HTTP client) and the iroh services'
  (`decdn-compose health` probes them all from the host), the one added capability of
  the iroh services, the iroh services running as root (above), and the API
  token both sponsord containers mount. The "Volume Has Sensitive Host Directory"
  query, which flags every host-path mount (the roles' host layout, and Alloy's view
  of the host), and "Volume Mounted In Multiple Containers", which flags the `rslave`
  propagation of Alloy's read-only host root, are excluded for the reasons given in
  the root `Makefile`; `make lint-compose` pins every mount instead, and refuses
  propagation on any other.
- Every image is referenced by digest: `compose.yaml` builds `REPO@DIGEST` itself,
  so no `.env` value can turn it into a mutable tag.
- Compose cannot require a variable without breaking the profiles that do not use
  it, so an unset one renders a value its service refuses: an invalid image
  reference, an unknown user, an onramp domain with a non-numeric port. That service
  fails to start; the others are unaffected.
- No secret is written in this file: each service may set inline only the keys
  [`tests/inline-env.jq`](tests/inline-env.jq) allows (listeners, secret-file
  paths, URLs, log settings and, for Alloy, the identity and active profiles), and
  everything else
  (`DECDN_RPC_URL`, `SPONSORD_RPC_URL`, `GC_API_TOKEN`, …) comes from its env file on
  the host.
- `make lint-compose` (CI job `compose`) reads this file as written, for every bind
  mount's `create_host_path` ([`tests/bind-sources.jq`](tests/bind-sources.jq):
  Compose releases render and default that flag differently, so each mount sets it),
  then renders it with every profile on: with the example `.env`, without the env
  files, and with an empty `.env`. It fails if any of those properties regress
  ([`tests/invariants.jq`](tests/invariants.jq),
  [`tests/inline-env.jq`](tests/inline-env.jq),
  [`tests/fail-closed.jq`](tests/fail-closed.jq)); `make test-scripts` checks it
  rejects broken variants and runs the wrapper's unit tests
  ([`tests/test_decdn_compose.py`](tests/test_decdn_compose.py)).
