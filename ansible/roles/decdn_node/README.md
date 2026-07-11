# roles/decdn_node

Provisions a **public deCDN node** (`decdn-node` daemon) from a pinned GitHub
Release tarball, under a hardened systemd unit. This is the repo's deployment
(`playbooks/site.yml`).

## What this role does (and does not)

Per `decdn/adr/019-node-onboarding.md`, a node only serves paid traffic after
**on-chain stake + registration**. That split maps onto this role as:

- **Ansible (this role): Phase 1 host prep + Phase 3 startup** — install binaries,
  create the `decdn` user + dirs, render `node.toml` + a hardened unit, open the
  public QUIC port, start the daemon, wait for `/metrics`.
- **Operator (manual, NOT automated here):** Phase 1 **key material** (generate the
  node + eth keys) and Phase 2 **on-chain** (fund + stake the wallet, register the
  node). See "register the node" below — there is no turnkey CLI for it yet.

## Prerequisites

1. **A published release.** The role downloads
   `decdn-node-<ver>-<target>.tar.gz` (and the `decdn` CLI) from
   `github.com/decdn/decdn/releases`. Set `decdn_node_version` to a real
   `v<version>` release. *(No release exists yet — cut one with the upstream
   `release.yml` workflow first.)*

2. **Eth wallet (operator-provisioned).** Generate the node identity + eth
   keystore on the host, as the `decdn` user, into the data dir:

   ```bash
   # create the password file first (0600), then:
   sudo -u decdn decdn key-gen \
     --output-dir /var/lib/decdn \
     --password-file /etc/decdn/keystore.password
   # prints: node id: <NodeId>   eth address: <0x…>
   ```

   This writes `/var/lib/decdn/node.secret` + `/var/lib/decdn/keystore.json`.
   **Fund + stake** the printed eth address, then **register** the node on-chain —
   the `CapacityBond.bond` / `declareMbps` / `registerNode` transactions of ADR 019
   §2.2–2.3. There is **no turnkey `decdn` subcommand** for registration yet (the
   onboarding CLI is listed as *Deferred* in ADR 019); perform the txns out-of-band.

   The role **refuses to start** until the keystore + password file exist — it
   never generates wallet material itself.

## Required variables (set in `host_vars/<node>/`)

`decdn_node_version`, `decdn_rpc_url` (sensitive — may embed an API key; goes in the
git-ignored `secret.yml`, everything else in the committed `main.yml`),
`decdn_payment_channel_address`, `decdn_capacity_bond_address`,
`decdn_slash_judge_address` (all `0x`+40-hex; SlashJudge non-zero),
`decdn_region` (ISO 3166-1 alpha-2). Contract addresses/chain-id are protocol
facts — source them from the deployment / an ADR, never guess.

Optional (omitted from `node.toml` unless set):

- `decdn_slash_appeal_address` — SlashAppeal contract (ADR 028); only needed to file
  appeals with `decdn appeal slash`, and `decdn_slash_judge_from_block` — SlashJudge
  deploy block; bounds the slash-detection watcher's per-restart chain rescan.
- `decdn_origin_assignment_address` + `decdn_publisher_registry_address` — the ADR 022
  chain-backed origin directory that gates DHT prefetch. **Set both or neither** (either
  alone fails the deploy-time assert); `decdn_origin_directory_from_block` bounds its
  per-restart log replay.
- `decdn_content_blacklist_address` — the ADR 011/031 compliance watcher (evicts
  blacklisted blobs in your region scope); `decdn_content_blacklist_from_block` bounds
  its per-restart log replay. Unset ⇒ no watcher (serving a blacklisted hash past its
  compliance window is then slashable with no local protection).
- `decdn_cache_origin_kind` (`http`|`fs`|`s3`) + that kind's fields — the pull-through
  origin the node fetches on a cache miss. **A serving node needs one:** unset ⇒ no
  `[cache.origin]` and cache misses fail `NoOrigin` (the node can only serve blobs it
  already holds).

Source contract addresses / chain-id from the deployment
(`contracts/deployments/<chainId>.json`) or an ADR — never guess. See
`roles/decdn_node/defaults/main.yml` for the full knob list and defaults.

## Network

| Port | Proto | Bind | Public? |
|------|-------|------|---------|
| `decdn_bind_port` (4433) | QUIC/UDP | 0.0.0.0 | **yes** — opened via `baseline_extra_inbound` |
| metrics (9090) | TCP | 127.0.0.1 | no |
| admin RPC (9191) | TCP | 127.0.0.1 | no |

## Files on the host

- `/usr/local/bin/decdn-node`, `/usr/local/bin/decdn` — daemon + CLI
- `/etc/decdn/node.toml` (`0640 decdn`) — rendered config; non-secret (no `rpc_url`), so it stays `--check`-diffable
- `/etc/decdn/decdn.env` (`0600 decdn`) — the one sensitive value, `DECDN_RPC_URL`, read by the unit via `EnvironmentFile`
- `/etc/decdn/keystore.password` (`0600 decdn`) — operator-provisioned
- `/var/lib/decdn/` (`0700 decdn`) — `node.secret`, `keystore.json`, `cache/`, state
- `/etc/systemd/system/decdn-node.service` — hardened unit

## Day-2

```bash
systemctl status decdn-node
journalctl -u decdn-node -e
decdn node health        # admin RPC (127.0.0.1:9191)
decdn node peers

# If this node is slashed (surfaced via the admin RPC — admin_v1_slashes), file an
# appeal within the ADR 028 window. Needs decdn_slash_appeal_address set in node.toml
# (else pass --slash-appeal-address / DECDN_SLASH_APPEAL_ADDRESS):
decdn appeal slash <SLASH_ID> <EVIDENCE_BUNDLE_HASH>
```

Upgrades: bump `decdn_node_version` (+ `decdn_node_sha256`) and re-deploy — the
version stamp triggers re-install + restart; the persistent `node.secret` and
`keystore.json` are untouched.
