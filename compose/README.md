# deCDN node with Docker Compose

The same node the Ansible role deploys, on one host, without Ansible: the upstream
image (`ghcr.io/decdn/decdn-node`, amd64 and arm64) under Compose, with the same host
paths, the same start command and the same hardening as the role's systemd unit.

Pick this path for a single machine you already run Docker on. For a fleet, or a host
you want hardened from scratch (firewall, SSH, auto-patching), use the
[Ansible project](../ansible/README.md); on Kubernetes, the
[Helm chart](../charts/decdn-node/README.md). [`docs/requirements.md`](../docs/requirements.md)
compares the three.

> **Upstream has not published a release yet**, so there is no signed image to pin.
> Until there is, build one from a `decdn/decdn` checkout (its `Dockerfile` header
> shows how) and set `DECDN_IMAGE` to that local image's digest.

## How it is laid out

| Host path | In the container | Holds |
|-----------|------------------|-------|
| `/etc/decdn/node.toml` | same, read-only | node config, no secrets |
| `/etc/decdn/keystore.password` | same, read-only | keystore password (`decdn`, `0600`) |
| `/etc/decdn/decdn.env` | read by Docker, injected as env | `DECDN_RPC_URL` (`root`, `0600`) |
| `/var/lib/decdn/` | same, read-write | `node.secret`, `keystore.json`, state, cache |

The layout matches the Ansible role, so the host `decdn` CLI, backups and restores
([`docs/lifecycle.md`](../docs/lifecycle.md)) work the same way on both.

**Networking.** The container uses the host network. The daemon's metrics
(`127.0.0.1:9090`) and admin RPC (`127.0.0.1:9191`, hard-wired upstream) stay on the
host's loopback, and Docker publishes no ports, so its iptables rules never open
anything past your firewall. The only public port is QUIC **udp/4433**.

## Set up

1. **A system account and directories:**

   ```bash
   sudo useradd --system --home-dir /var/lib/decdn --shell /usr/sbin/nologin decdn
   sudo install -d -m 0700 -o decdn -g decdn /var/lib/decdn
   sudo install -d -m 0750 -o decdn -g decdn /etc/decdn
   ```

2. **The `decdn` CLI on the host.** The image is daemon-only. Install the CLI from the
   release tarball, checking it against the GPG-signed `SHA256SUMS` first (the
   maintainer key is in `decdn/decdn`'s `KEYS`; its fingerprint is in
   [SECURITY.md](../SECURITY.md#release-verification)). Until a release exists, build it:
   `cargo build --release -p decdn-cli`.

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
   alpha-2). Add `--origin <url>` to `config init` if this node has a backing origin.

   ```bash
   sudo -u decdn decdn config init --chain arbitrum-sepolia --output /etc/decdn/node.toml
   sudo -u decdn sed -i \
     -e 's|^# data_dir = .*|data_dir = "/var/lib/decdn"|' \
     -e '0,/^# region = /s|^# region = .*|region = "DE"|' /etc/decdn/node.toml
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
   $EDITOR compose/.env                  # DECDN_IMAGE digest; DECDN_UID/GID = `id -u decdn` / `id -g decdn`
   sudo docker compose -f compose/compose.yaml up -d
   curl -s 127.0.0.1:9090/metrics | head   # once "node runtime ready" is in the logs
   decdn node health                      # admin RPC, from the host
   ```

9. **Stake and register** (on-chain onboarding, ADR 019 Phase 2): `decdn setup`, as in
   [`roles/decdn_node/README.md` § On-chain onboarding](../ansible/roles/decdn_node/README.md#on-chain-onboarding).
   The node serves paid traffic only after that.

## Operate

- **Logs:** `sudo docker compose -f compose/compose.yaml logs -f`. To send them to the
  journal like the systemd unit, switch the `logging` driver (commented in
  `compose.yaml`).
- **Stop:** `docker compose stop`. It sends SIGTERM, the daemon's graceful drain, and
  waits up to 300 s. Do not use `decdn node drain` here: `restart: unless-stopped`
  starts the drained container again.
- **Upgrade:** set the new release's digest in `.env`, then `docker compose up -d`.
- **Config change:** edit `/etc/decdn/node.toml`, then `docker compose restart`
  (or `decdn node reload` for the hot-reloadable sections).
- **Health:** there is no container healthcheck. The image has no HTTP client, and the
  metrics listener serves only `/metrics`. Probe `http://127.0.0.1:9090/metrics` from
  the host, or ship metrics with Grafana Alloy / Prometheus. Dashboards and alert rules
  are in [`charts/decdn-node/files/monitoring/`](../charts/decdn-node/files/monitoring/README.md).

## Security notes

- The container runs as the host's `decdn` account with a read-only root filesystem,
  every capability dropped and `no-new-privileges`.
- The two remaining KICS findings are the design, not an oversight: host networking
  (loopback-only metrics and admin, no Docker-published ports) and no healthcheck (see
  above). The read-only `/etc/decdn` mount is excluded from the scan for the reason
  given in the root `Makefile`.
- `make lint-compose` (CI job `compose`) renders this file and fails if any of those
  properties regress.
