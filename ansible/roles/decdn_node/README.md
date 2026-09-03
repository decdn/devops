# roles/decdn_node

Provisions a **public deCDN node** (`decdn-node` daemon) under a hardened systemd
unit. Two install methods (`decdn_node_install_method`): `release` pulls a pinned
GitHub Release tarball and verifies it against the GPG-signed `SHA256SUMS`
manifest, and `manual` copies locally-built binaries from the Ansible control
machine. This is the repo's deployment (`playbooks/site.yml`).

> **The default is `manual`, because upstream has cut no release yet.**
> `decdn/decdn`'s `release.yml` fires on a `v[0-9]*` tag push and
> `git ls-remote --tags` is empty, so there is nothing for `release` mode to
> download. Build the two binaries from a checkout until that changes.

**Schema tracking.** This role renders `node.toml` against the config schema of
`decdn/decdn` @ `d306cc5c` (crate version 0.1.1). Upstream marks every config
section `#[serde(deny_unknown_fields)]` and defines **no** serde aliases, so a key
this role emits that your binary does not know is a startup crash-loop, not a
warning. The role runs `decdn config validate` against the installed binary after
templating, so a mismatch fails the deploy with the daemon's own error message
instead. The `molecule/schema` scenario guards the same thing in CI.

## What this role does (and does not)

Per the deCDN node-onboarding ADR (019), a node only serves paid traffic after
**on-chain stake + registration**. That split maps onto this role as:

- **Ansible (this role): Phase 1 host prep + Phase 3 startup** — install binaries,
  create the `decdn` user + dirs, render `node.toml` + a hardened unit, open the
  public QUIC port, start the daemon, and run a best-effort `/metrics` readiness
  probe (see [Readiness](#readiness)).
- **Operator (manual, NOT automated here):** Phase 1 **key material** (generate the
  node + eth keys) and Phase 2 **on-chain** (fund + stake the wallet, register the
  node). These are no longer raw contract calls — upstream shipped a guided
  onboarding CLI, `decdn setup`, over the `decdn node bond` / `register`
  primitives (`unbond` / `deregister` are the exit path, which setup never calls).
  See [On-chain onboarding](#on-chain-onboarding).

## Prerequisites

1. **The binaries.** Pick an install method with `decdn_node_install_method`:

   - **`release`** — the role downloads `decdn-node-<ver>-<target>.tar.gz` (and the
     `decdn` CLI) from `decdn_node_release_base` (default
     `https://github.com/decdn/decdn/releases/download`), then **verifies both**:
     it fetches the release's `SHA256SUMS` and `SHA256SUMS.asc`, checks the
     detached signature against the maintainer keyring vendored at
     `files/decdn-release-KEYS.asc` (a byte copy of `decdn/KEYS`; upstream's rule
     is that a good signature from *any* key in that file is authentic), and only
     then checks the tarballs against the manifest. `gnupg` is installed on the
     target for this. Set `decdn_release_keyring` to pin your own export, or
     `decdn_verify_release_signature: false` for an air-gapped mirror that strips
     the signature — that takes the tarballs on trust.

     Set `decdn_node_version` to a real `v<version>` release, publicly reachable
     from the target host; override `decdn_node_release_base` for a mirror.
     **No upstream release exists yet**, so this mode currently has nothing to
     fetch — the role's assert says so rather than surfacing a bare 404.
   - **`manual`** (current default) — the role copies the two binaries **verbatim** from the paths
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
   **Fund** the printed eth address, then bond + register it — see
   [On-chain onboarding](#on-chain-onboarding).

   The role **refuses to start** until the keystore, node identity (`node.secret`),
   and password file all exist — by default it never generates wallet material
   itself. Set
   `decdn_node_generate_keystore: true` to have the role run the `key-gen` above
   for you on first converge (it mints a random password file too, and never
   overwrites existing material) — but the wallet is still **unfunded + unstaked**,
   so the funding + registration steps below stay manual either way.

## Required variables (set in `host_vars/<node>/`)

`decdn_node_version` (`release` mode only) **or** `decdn_node_manual_bin_src` +
`decdn_cli_manual_bin_src` (`manual` mode), an RPC endpoint (sensitive — may embed an
API key; provision it on the host or set `decdn_rpc_url` in the git-ignored
`secret.yml` — see [Secrets](#secrets)), `decdn_region` (ISO 3166-1 alpha-2), and
**four** contract addresses (all `0x`+40-hex, none the zero address):

| Variable | Contract | Why required |
|---|---|---|
| `decdn_payment_pool_address` | PaymentPool | Settlement. Renamed from `decdn_payment_channel_address` — pairwise channels were replaced by a shared payment pool. |
| `decdn_capacity_bond_address` | CapacityBond | Stake + registration. |
| `decdn_slash_judge_address` | SlashJudge | EIP-712 `verifyingContract` (ADR 014). |
| `decdn_content_blacklist_address` | ContentBlacklist | **Newly required.** Upstream refuses to resolve a config without it: an absent or zero address is a fail-open compliance trap, and serving a blacklisted hash past its window is slashable (ADR 011/031). |

Contract addresses and chain-id are protocol facts. Copy them from the upstream
deployment manifest `decdn/contracts/deployments/<chainId>.json` — the same file
`decdn config init --chain arbitrum-sepolia` bakes in — and never guess. Upstream
redeploys wholesale, so re-sync the whole set rather than patching lines.

Optional (omitted from `node.toml` unless set):

- `decdn_slash_appeal_address` — SlashAppeal (ADR 028); only `decdn appeal slash`
  uses it. The daemon accepts the key but never resolves or reads it.
- `decdn_origin_assignment_address` and `decdn_publisher_registry_address` — the
  ADR 022 chain-backed origin directory. **Independently optional** (the old "both
  or neither" rule went away with the whole-directory mirror): the daemon reads
  OriginAssignment for cache-miss pull-through fallback, and only validates
  PublisherRegistry, which `decdn publish` consumes.
- `decdn_usdc_address` and the `decdn_swap_*` knobs — CLI-only `[blockchain]` keys.
  The daemon accepts but never parses them — only `decdn setup` reads them, to
  swap USDC into the deCDN TOKEN and bond that (the bond is always TOKEN; native
  ETH is only ever gas). They live in `node.toml` because the section is
  `deny_unknown_fields` and the CLI shares the file, which also means nothing
  downstream catches a malformed value — hence the role's own shape asserts.
- `decdn_cache_origin_kind` (`http`|`fs`|`s3`) + that kind's fields — the
  pull-through origin the node fetches on a cache miss. **A serving node needs
  one:** unset ⇒ no `[cache.origin]` and cache misses fail `NoOrigin`. For an
  ordered fallback chain use `decdn_cache_origins` (a list of the same per-kind
  dicts) instead — the two forms are mutually exclusive upstream and the role
  fails loud if both are set.
- `decdn_extra_env` — extra `KEY: value` pairs appended to the 0600
  `/etc/decdn/decdn.env` **when the role authors that file** (i.e. `decdn_rpc_url`
  is set). With a host-provisioned env file the role rejects it rather than
  silently dropping it — put those lines in the host file instead. See
  [Secrets](#secrets) and [S3 credentials](#s3-credentials).
- `decdn_node_generate_keystore` (default `false`) — opt-in turnkey wallet. When `true`
  the role runs `decdn key-gen` on the host **only if the keystore is absent** (minting a
  random `0600` password file first, but only when the keystore is *also* absent) — it
  never overwrites an existing wallet, and it will not mint a password beside a
  pre-existing keystore (that password couldn't decrypt it; the gate fails loud instead so
  you supply the matching one). The generated wallet is still **unfunded + unstaked**.
  Leave `false` to keep the operator-provisioned posture.
- `decdn_readiness_retries` (default `30`) + `decdn_readiness_delay` (default `2`, seconds)
  — bound the `/metrics` readiness probe window (`retries × delay`, so ~60 s at these
  defaults). A **timeout** only warns; it never fails the deploy — but a non-200 *answer*
  does. See [Readiness](#readiness).

### Optional tuning knobs

These expose daemon config fields that most operators never touch. Each defaults to
`""` (or `[]`/`{}`), meaning **omit the key and use the daemon's own default** — set one
only to override; an explicit `0`/`false` **is** emitted (`0` is meaningful — e.g.
`decdn_gc_interval_sec: 0` disables the GC sweep). A malformed or out-of-range value
fails loud at deploy time, and `decdn config validate` catches anything the role's own
asserts miss. See `defaults/main.yml` for every knob's upstream default, unit and range.

- **Payment / credit** — `decdn_rate_per_mb`, `decdn_delivery_floor`,
  `decdn_credit_max` (bare-integer bytes), `decdn_credit_ramp_divisor`,
  `decdn_frame_target_bytes` (`1..=1048576`), `decdn_voucher_commit_interval_ms`.
  Note `delivery_floor` is a **pre-chain seed only**: the daemon overwrites it from
  `PaymentPool.getRateBounds()` at startup, so the on-chain value is authoritative.
  There is no companion ceiling knob any more.
- **Settlement / payment pool** — `decdn_redeem_threshold_micro_usdc`,
  `decdn_redeem_max_vouchers_per_tx`, `decdn_redeem_interval_secs`,
  `decdn_buyer_working_deposit_micro_usdc`, `decdn_buyer_max_approve` (bool),
  `decdn_pool_min_remaining_deposit_micro_usdc`, and the per-signer floor pair
  `decdn_pool_floor_signer_share_bps` (`1..=10000`) /
  `decdn_pool_floor_signer_max_windows`. All µUSDC unless noted.
- **Cache sizing + eviction** — `decdn_cache_size_mb`, `decdn_max_blob_size_mb`
  (defaults to `cache_size_mb` upstream; must be `<=` it), `decdn_max_rate_per_mb`
  (buyer-side rate ceiling), `decdn_gc_interval_sec`, `decdn_fs_rescan_interval_sec`,
  `decdn_max_probe_holds`, `decdn_stake_lane_reserved_holds`, `decdn_pinned_hashes`
  (64-char **lowercase-hex** BLAKE3), `decdn_cache_user_agent`, the
  `decdn_eviction_*` family, and the `decdn_origin_probe_*` TTLs (which must satisfy
  `negative <= fault <= positive`). **The eviction hysteresis gap is structural:**
  `decdn_eviction_target_pct` must be at least **5** below
  `decdn_eviction_high_water_pct`, not merely below it.
- **Admission / eviction policy (ADR 040)** — `decdn_eviction_policy`
  (`lru`|`tinylfu`), `decdn_admission_policy` (`always`|`tinylfu`) and the
  `decdn_tinylfu_*` knobs. `decdn_tinylfu_sketch_bytes` has a **hard floor of
  16384**, and the floor applies even on the stock `lru`/`always` policies because
  the default serve-economics policy builds the same sketch.
- **Refuse-to-serve economics (ADR 041)** — `decdn_serve_economics_policy`
  (`off`|`margin`), `decdn_serve_economics_discount` (a **float** in `(0.0, 1.0]`,
  not basis points), `decdn_serve_economics_n_max`, and the warming budget/refill pair.
- **Node-to-node pull-through (#29)** — `decdn_node_to_node_pull_through_enabled`
  (bool) gates all serve-time origin pull from upstream nodes;
  `decdn_node_pull_probe_fanout`, `decdn_node_pull_timeout_sec`,
  `decdn_node_pull_stall_window_sec` and `decdn_node_pull_min_throughput_bps` tune it.
  The last two replaced a single stall timeout: a leg is now abandoned when it
  delivers under the throughput floor across the window, not merely when it goes
  quiet. `decdn_relay_foreign_namespaces` (origin-only node policy) has a
  **role-derived** default — `false` when an origin backend is configured, `true`
  when none — so leave it unset unless you mean to pin it.
- **Origin retry + circuit breaker** — the `decdn_origin_retry_*` and
  `decdn_circuit_breaker_*` families.
- **Blockchain watchers** — `decdn_rpc_watchdog_interval_sec` (`0` or `>= 10`),
  `decdn_event_poll_interval_ms` (`>= 250`), `decdn_content_blacklist_poll_interval_sec`
  (`>= 1`), `decdn_rate_bounds_poll_interval_sec`, `decdn_fee_shares_poll_interval_sec`,
  and the `decdn_origin_directory_*` cache knobs.
- **Network** — `decdn_relay_urls` (list; the singular `relay_url` config key no
  longer exists). Operator-run address discovery (#818) via
  `decdn_discovery_pkarr_url` (publishes this node's record — **requires**
  `decdn_discovery_dns_origin`, which resolves peers) and/or `decdn_discovery_dns_origin`
  **on its own**, a resolve-only node that never publishes; and/or
  `decdn_discovery_peers` (a map of 64-char lowercase-hex NodeId to
  `{relay_url, addrs}`). Setting either mechanism drops the n0 discovery leg.
- **Abuse limits + load shedding** — the `decdn_security_*` family,
  `decdn_load_shed_*` (`policy` is `resource-pressure`|`always-admit`; the low-water
  serve mark must be `<=` the high), and the `decdn_dht_rate_limit` /
  `decdn_probe_rate_limit` **dicts** (any subset of eight keys; rate keys are floats,
  the rest integers — an unknown key is rejected at deploy time, because the template
  would otherwise silently drop it).
- **Receipts + local denylist** — `decdn_receipts_max_file_bytes`,
  `decdn_receipts_retained_files`, and `decdn_content_denied_hashes` /
  `decdn_content_denied_origins` (node-local, independent of the on-chain blacklist).
- **Observability** — `decdn_otlp_endpoint` (OTLP span export; needs the node built
  `--features otlp`).

## Secrets

Every secret this role needs ends up in exactly one place on the host: `0600`
files under `/etc/decdn` and `/var/lib/decdn`, owned by the `decdn` user. The
wallet material (`keystore.json`, `node.secret`, `keystore.password`) is
provisioned — or, with `decdn_node_generate_keystore`, minted — **on the host**,
and never touches the control machine. The one
operator-supplied secret — the chain RPC URL, which may embed a provider API key,
plus anything else the daemon reads from its environment — has two authoring
paths:

| | Host-provisioned (preferred) | Inventory-carried |
|---|---|---|
| Set | `decdn_rpc_url: ""` (the default) | `decdn_rpc_url` in `host_vars/<node>/secret.yml` |
| Who writes `/etc/decdn/decdn.env` | you, on the target | the role, on every converge |
| Secret on the control machine | never | plaintext, git-ignored |
| Extra env vars | further `KEY=value` lines in that file | `decdn_extra_env` |

On the host path the role never reads the file's contents back — that would put
the secret on the control machine, defeating the point. It reads only a **sha256**
of the file (which does cross to the control machine, to be compared and written
back as the record below), and on that path it confines itself to:

- enforcing `0600 decdn:decdn` on the file, content untouched, after refusing to
  touch it at all unless it is a regular file (a symlink would have root apply
  that ownership to whatever it points at);
- grepping for a `DECDN_RPC_URL=` line with a non-whitespace value, failing loud
  if there is none.

**Provisioning it.** Do this on the target as **root** — on a host that has never
been converged the `decdn` account does not exist yet (this role creates it, and
chowns the file on the next run), so `install -o decdn` / `chown decdn:decdn`
would fail. The full template, including the S3 credential block, is
[`files/decdn.env.example`](files/decdn.env.example):

```bash
(umask 077; sudo mkdir -p /etc/decdn)
echo 'DECDN_RPC_URL=https://your-endpoint.example/rpc' | sudo tee /etc/decdn/decdn.env >/dev/null
sudo chmod 600 /etc/decdn/decdn.env
```

systemd's `EnvironmentFile` parser is shell-*like* but not a shell: one `KEY=value`
per line, no `export`, no expansion — and it **skips** a line it cannot parse,
logging a warning to `journalctl -u decdn-node` that is easy to miss, so the
variable is simply absent at runtime. Single-quote any value containing a space,
quote, backslash, `$` or backtick. (`decdn config validate` sources this file with
bash, which *would* expand `$VAR` and execute `$(…)`; quoting avoids both.) On the
inventory path the role applies that escaping to `decdn_extra_env` values for you —
but **not** to `decdn_rpc_url` itself, which is rendered raw.

### The provenance record

`/etc/decdn/.decdn.env.sha256` (`0600 root`, `decdn_env_checksum_file`) holds the
env file's sha256 as of the last converge that got the daemon running. It is
written on **both** paths, and it is what lets the role tell the two apart — a
bare `stat` cannot, since a file the role wrote last week exists exactly as much
as an operator-provisioned one. From it the role gets three behaviours:

- **Restart on an out-of-band edit.** Record ≠ file on the host path ⇒ the unit is
  restarted so the daemon picks up the new values. The record is written *after*
  the restart, so a run that aborts in between leaves the old value in place and
  the next converge re-detects — the signal is never burned by a failed deploy.
- **"`secret.yml` went missing" ≠ "the host owns this now."** An empty
  `decdn_rpc_url` against a file the role itself wrote is treated as a lost
  inventory value and fails loud, instead of silently deploying a stale endpoint.
  To migrate a node to the host path deliberately, `sudo rm` the record once.
- **No silent clobbering.** An inventory `decdn_rpc_url` against a file the record
  says someone else wrote fails loud rather than discarding those lines; set
  `decdn_env_overwrite_host_file: true` to confirm. With **no** record (a host
  that predates this) the role cannot tell, so it warns and starts tracking.

If neither authoring path is satisfied the role fails before touching the host,
with the provisioning commands above in the failure message.

### S3 credentials

The role deliberately **never** writes static AWS keys into `node.toml`: that file
is `0640` and diffable, and committing credentials to it would break this repo's
no-secrets rule. Only `source = "default-chain"` is templated. Set
`decdn_cache_origin_s3_use_default_chain: true` (plus an optional
`decdn_cache_origin_s3_profile`) and supply the keys through the `0600` env file.
On the host, as further lines in `/etc/decdn/decdn.env`:

```ini
AWS_ACCESS_KEY_ID=AKIA...
AWS_SECRET_ACCESS_KEY=...
AWS_SESSION_TOKEN=...          # assume-role / SSO only
```

…or, if you are carrying the RPC URL in inventory anyway, through `decdn_extra_env`
(the role then renders both into the same file):

```yaml
# host_vars/<node>/secret.yml (git-ignored)
decdn_extra_env:
  AWS_ACCESS_KEY_ID: "AKIA..."
  AWS_SECRET_ACCESS_KEY: "..."
  AWS_SESSION_TOKEN: "..."     # assume-role / SSO only
```

`default-chain` is the full AWS credential chain — those environment variables
first, then a `~/.aws/credentials` profile, then an IAM role or instance profile —
so an S3, R2, B2 or MinIO origin works with no secret in a tracked file, and an
instance profile needs no credentials at all, just the toggle. Note the region is
**not** taken from `AWS_REGION`: it comes from `[cache.origin].region`
(`decdn_cache_origin_s3_region`).

## Config reload

SIGHUP (and `decdn node reload`, which shares its mutex) re-reads the config file
and applies **five** sections: `observability.log_level`, `cache.pinned_hashes`,
all of `[security]`, all of `[content]`, and all of `[load_shed]`. Everything else
logs "requires restart" and keeps its running value — notably `payment.rate_per_mb`,
which upstream demoted to restart-required.

The unit exposes `ExecReload`, and the role ships a `Reload decdn-node` handler,
but the `node.toml` task still notifies a **restart**: a template diff carries no
information about which sections changed, so choosing reload is an operator's
deliberate call.

See `roles/decdn_node/defaults/main.yml` for the full knob list, defaults and units.

## On-chain onboarding

The role stops at ADR 019 Phase 1 (host prep) and Phase 3 (startup). Phase 2 — fund,
bond, register — is the operator's, but it is **no longer a set of raw contract
calls**: upstream ships a guided CLI. Every one of these takes `--dry-run`.

```bash
# Guided path: pre-flight checks (clock skew, gas, balances), key generation,
# bond and registration, ending in a readiness summary. Thin orchestration over
# `key-gen` / `node bond` / `node register` — it submits no transaction they do
# not. (The exit path below is NOT part of setup.)
decdn setup --mbps 100 --region US \
  --multiaddr /ip4/<public-ip>/udp/4433/quic-v1 --yes --accept-terms

# Or drive the primitives directly:
decdn node bond --mbps 100     # CapacityBond.bond + declareMbps (idempotent:
                               # tops up only the shortfall, so a re-run after a
                               # partial failure converges rather than over-bonding)
decdn node register --region US \
  --multiaddr /ip4/<public-ip>/udp/4433/quic-v1 \
  --accept-terms               # CapacityBond.registerNode — builds the EIP-712
                               # binding + ed25519 ownership signatures locally.
                               # --region is REQUIRED (no default).
```

Exiting is the reverse, in order: `decdn node deregister` (leaves the active set
and clears the declared tier — the bond stays deposited and **fully slashable**),
then `decdn node unbond --all` (starts the unbonding window; the node is INACTIVE
for its whole duration, and a second call withdraws once it matures).

`decdn node rotate-key --key iroh` rotates the node's iroh identity. `--key` is
required and has no default; `--key eth` is a different, much heavier operation —
it moves the whole Ethereum identity, which means deregister, a full unbond window,
and re-bonding (resetting `firstBondedAt`).

**Running these from a playbook:** `decdn setup` and `decdn node register` prompt
for terms acceptance and abort in any non-TTY context, so both need
`--accept-terms`; `setup` additionally needs `--yes` to skip its bond-amount
confirmation. All of them read the same `node.toml` this role renders, so the
contract addresses only have to be right once.

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
behind the startup PaymentPool buyer bootstrap (an upstream startup-ordering
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
additionally requires on-chain stake + registration (see
[On-chain onboarding](#on-chain-onboarding)); verify with `decdn node health`.

## Files on the host

- `/usr/local/bin/decdn-node`, `/usr/local/bin/decdn` — daemon + CLI
- `/etc/decdn/node.toml` (`0640 decdn`) — rendered config; non-secret (no `rpc_url`), so it stays `--check`-diffable
- `/etc/decdn/decdn.env` (`0600 decdn`) — the one operator-supplied secret, `DECDN_RPC_URL` (+ any extra env vars), read by the unit via `EnvironmentFile`; role-authored or host-provisioned ([Secrets](#secrets))
- `/etc/decdn/.decdn.env.sha256` (`0600 root`) — role-managed hash of the above: provenance marker, and the trigger for a restart after an out-of-band edit. Not a secret store
- `/etc/decdn/keystore.password` (`0600 decdn`) — operator-provisioned
- `/var/lib/decdn/` (`0700 decdn`) — `node.secret`, `keystore.json`, `cache/`, state
- `/etc/systemd/system/decdn-node.service` — hardened unit

## Day-2

```bash
systemctl status decdn-node
journalctl -u decdn-node -e
# Admin RPC (127.0.0.1:9191). All of these accept --json and --timeout-ms, and
# honour DECDN_ADMIN_URL; `node top` scrapes /metrics and honours DECDN_METRICS_URL.
decdn node health        # identity + process uptime
decdn node status        # DHT health: routing-table fill, active stakers, republish depth
decdn node lanes         # per-lane accrued claim, voucher age, redemption-threshold state
decdn node slashes       # slashes detected against this operator, with appeal deadlines
decdn node top           # live activity: streams, cache hit rate, bytes returned
decdn node evict <HASH>  # force a blob out of the local cache (takedown, corruption)
decdn node reload        # re-read node.toml, apply the five hot-reloadable sections
decdn node drain --wait  # graceful shutdown. Without --wait it is fire-and-forget
                         # (the response means "asked to stop", not "stopped");
                         # --wait polls to completion (--wait-timeout-secs 30).

# Read-only chain query, not admin RPC: lists active registered nodes and maps
# node-ids/regions to operator addresses. Loads no keystore and spends nothing.
decdn node lookup --region US --probe

# If this node is slashed (surfaced by `decdn node slashes` / admin_v1_slashes),
# file an appeal within the ADR 028 window. Needs decdn_slash_appeal_address set in
# node.toml (else pass --slash-appeal-address / DECDN_SLASH_APPEAL_ADDRESS):
decdn appeal slash <SLASH_ID> <EVIDENCE_BUNDLE_HASH>
```

Upgrades (`release` mode): bump `decdn_node_version` and re-deploy — the version stamp triggers re-install + restart; the persistent
`node.secret` and `keystore.json` are untouched.

Upgrades (`manual` mode): there is **no** version stamp — rebuild the binaries
locally and re-deploy. `copy` compares checksums and re-pushes (and restarts) only
when the control-machine binary actually changed.

Switching methods: a `manual` deploy clears the release version stamp on the host,
so returning to `release` afterwards always re-fetches and re-installs the official
tarball — even when `decdn_node_version` is unchanged. (This is separate from the
`--version` backstop: a `decdn_node_version` left set in `manual` mode is still
enforced against the local build — see the `manual` prerequisite above.)
