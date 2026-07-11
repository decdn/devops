# roles/decdn_node

Provisions a **public deCDN node** (`decdn-node` daemon) under a hardened systemd
unit. Two install methods (`decdn_node_install_method`): the default `release`
pulls a pinned GitHub Release tarball, and `manual` copies locally-built binaries
from the Ansible control machine — the pre-release path for when no release exists
yet. This is the repo's **primary** deployment (`playbooks/site.yml`); the anvil
devnet is separate internal tooling.

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

1. **The binaries.** Pick an install method with `decdn_node_install_method`:

   - **`release`** (default) — the role downloads
     `decdn-node-<ver>-<target>.tar.gz` (and the `decdn` CLI) from
     `github.com/decdn/decdn/releases`. Set `decdn_node_version` to a real
     `v<version>` release. *(No release exists yet — either cut one with the
     upstream `release.yml` workflow, or use `manual` below in the meantime.)*
   - **`manual`** — the role copies the two binaries **verbatim** from the paths
     you give it (`decdn_node_manual_bin_src` + `decdn_cli_manual_bin_src`) on the
     Ansible control machine; it does *not* consult `decdn_node_target`, so you are
     responsible for building for the host's architecture (the default target is
     `x86_64-unknown-linux-gnu`). Build both `decdn-node` and `decdn` from the
     upstream `decdn` repo, then set the two paths. `decdn_node_version` is **not**
     required in this mode — but if it is set (e.g. left over from a `release`
     deploy) the `--version` backstop still enforces it, so clear it when switching
     to `manual` unless you intend that binary to report that exact version.

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

`decdn_node_version` (`release` mode only) **or** `decdn_node_manual_bin_src` +
`decdn_cli_manual_bin_src` (`manual` mode), `decdn_rpc_url` (sensitive — may embed an
API key; goes in the git-ignored `secret.yml`, everything else in the committed
`main.yml`), `decdn_payment_channel_address`, `decdn_capacity_bond_address`,
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

Upgrades (`release` mode): bump `decdn_node_version` (+ `decdn_node_sha256`) and
re-deploy — the version stamp triggers re-install + restart; the persistent
`node.secret` and `keystore.json` are untouched.

Upgrades (`manual` mode): there is **no** version stamp — rebuild the binaries
locally and re-deploy. `copy` compares checksums and re-pushes (and restarts) only
when the control-machine binary actually changed.

Switching methods: a `manual` deploy clears the release version stamp on the host,
so returning to `release` afterwards always re-fetches and re-installs the official
tarball — even when `decdn_node_version` is unchanged. (This is separate from the
`--version` backstop: a `decdn_node_version` left set in `manual` mode is still
enforced against the local build — see the `manual` prerequisite above.)
