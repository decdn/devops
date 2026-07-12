# roles/decdn_node

Provisions a **public deCDN node** (`decdn-node` daemon) under a hardened systemd
unit. Two install methods (`decdn_node_install_method`): the default `release`
pulls a pinned GitHub Release tarball, and `manual` copies locally-built binaries
from the Ansible control machine — the pre-release path for when no release exists
yet. This is the repo's deployment (`playbooks/site.yml`).

## What this role does (and does not)

Per the deCDN node-onboarding ADR (019), a node only serves paid traffic after
**on-chain stake + registration**. That split maps onto this role as:

- **Ansible (this role): Phase 1 host prep + Phase 3 startup** — install binaries,
  create the `decdn` user + dirs, render `node.toml` + a hardened unit, open the
  public QUIC port, start the daemon, and run a best-effort `/metrics` readiness
  probe (see [Readiness](#readiness)).
- **Operator (manual, NOT automated here):** Phase 1 **key material** (generate the
  node + eth keys) and Phase 2 **on-chain** (fund + stake the wallet, register the
  node). See "register the node" below — there is no turnkey CLI for it yet.

## Prerequisites

1. **The binaries.** Pick an install method with `decdn_node_install_method`:

   - **`release`** (default) — the role downloads
     `decdn-node-<ver>-<target>.tar.gz` (and the `decdn` CLI) from
     `decdn_node_release_base` (default
     `https://github.com/decdn/decdn/releases/download`). Set `decdn_node_version` to a real
     `v<version>` release, which must be **publicly reachable** from the target host;
     override `decdn_node_release_base` to fetch from a mirror. *(No release exists yet —
     either cut one with the upstream `release.yml` workflow, or use `manual` below in the
     meantime.)*
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
   keystore on the host, as the `decdn` user, directly into the data dir. `key-gen`
   **reads** the password file — it does *not* create it — so make it first:

   ```bash
   # 1) create the keystore password file FIRST (key-gen reads it; never creates it)
   umask 077
   openssl rand -base64 32 | sudo -u decdn tee /etc/decdn/keystore.password >/dev/null
   sudo -u decdn chmod 600 /etc/decdn/keystore.password

   # 2) generate keys INTO the data dir. Pass --output-dir explicitly: a bare
   #    `decdn key-gen` writes to ~/.decdn and the node would NOT find its keys.
   sudo -u decdn decdn key-gen \
     --output-dir /var/lib/decdn \
     --password-file /etc/decdn/keystore.password
   # prints: node id: <NodeId>   eth address: <0x…>

   # 3) verify all three are present (the role locks them to 0600 on deploy)
   ls -l /var/lib/decdn/node.secret /var/lib/decdn/keystore.json \
         /etc/decdn/keystore.password
   ```

   This writes `/var/lib/decdn/node.secret` + `/var/lib/decdn/keystore.json`.
   **Fund + stake** the printed eth address, then **register** the node on-chain —
   the `CapacityBond.bond` / `declareMbps` / `registerNode` transactions of ADR 019
   §2.2–2.3. There is **no turnkey `decdn` subcommand** for registration yet (the
   onboarding CLI is listed as *Deferred* in ADR 019); perform the txns out-of-band.

   The role **refuses to start** until the keystore, node identity (`node.secret`),
   and password file all exist — by default it never generates wallet material
   itself. Set
   `decdn_node_generate_keystore: true` to have the role run the `key-gen` above
   for you on first converge (it mints a random password file too, and never
   overwrites existing material) — but the wallet is still **unfunded + unstaked**,
   so the funding + registration steps below stay manual either way.

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
- `decdn_node_generate_keystore` (default `false`) — opt-in turnkey wallet. When `true`
  the role runs `decdn key-gen` on the host **only if the keystore is absent** (minting a
  random `0600` password file first, but only when the keystore is *also* absent) — it
  never overwrites an existing wallet, and it will not mint a password beside a
  pre-existing keystore (that password couldn't decrypt it; the gate fails loud instead so
  you supply the matching one). The generated wallet is still **unfunded + unstaked**
  (funding + on-chain staking/registration stay manual — see the eth-wallet step above).
  Leave `false` to keep the operator-provisioned posture (the fail-loud gate then requires
  you to provision the keystore, `node.secret`, and password yourself).
- `decdn_readiness_retries` (default `30`) + `decdn_readiness_delay` (default `2`, seconds)
  — bound the `/metrics` readiness probe window (`retries × delay`, so ~60 s at these
  defaults). A **timeout** only warns; it never fails the deploy — but a non-200 *answer*
  does. See [Readiness](#readiness).

Source contract addresses / chain-id from the deCDN contract deployment for your target
chain, or the relevant ADR — never guess. See `roles/decdn_node/defaults/main.yml` for the
full knob list and defaults.

## Network

| Port | Proto | Bind | Public? |
|------|-------|------|---------|
| `decdn_bind_port` (4433) | QUIC/UDP | 0.0.0.0 | **yes** — opened via `baseline_extra_inbound` |
| metrics (9090) | TCP | 127.0.0.1 | no |
| admin RPC (9191) | TCP | 127.0.0.1 | no |

## Readiness

After starting the daemon the role runs a bounded probe against
`http://127.0.0.1:<metrics_port>/metrics`, then a hard assert that the systemd
unit is in the `running` state.

The probe is **advisory** on timeout: exhausting the window logs a warning but
does **not** fail the deploy. The daemon can bind its loopback metrics/admin
listeners well after process start on an otherwise-healthy node — they come up
behind the startup PaymentChannel buyer bootstrap (an upstream startup-ordering
issue tracked in `decdn/decdn`, not here), which can take many minutes. A short
probe that hard-failed would therefore false-fail a healthy deploy, and
stretching it to cover the worst case would hang every deploy for that whole
window — neither is acceptable, so a timeout warns and moves on. A metrics
endpoint that *answers* with a non-200 error is treated differently: that is a
fault, not slow startup, so it **fails** the deploy loudly.

The follow-on assert that the `decdn-node.service` unit is `running` (via
`service_facts`) is a **backstop, not a full health check**. It catches a daemon
that exited/failed or a fast crash-loop that tripped systemd's start limit — but
the unit is `Type=simple`, so a wedged-but-alive or slow-crash-looping process
still reports `running`. A *persistent* probe timeout is therefore **not provably
benign**: confirm the node out-of-band before trusting it. Tune the probe window
with `decdn_readiness_retries` × `decdn_readiness_delay` (see
`defaults/main.yml`). When the probe times out, confirm readiness once the node
has settled:

```bash
curl -s http://127.0.0.1:9090/metrics     # loopback metrics (once bound)
journalctl -u decdn-node -e               # look for "node runtime ready"
```

Note that neither check proves the node is serving **paid** traffic — that
additionally requires on-chain stake + registration (ADR 019 Phase 2, manual);
verify with `decdn node health`.

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
