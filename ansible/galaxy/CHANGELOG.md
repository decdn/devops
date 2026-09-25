# Changelog — `decdn.node`

All notable changes to the `decdn.node` Ansible collection are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
collection adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `decdn_network` (default `""`): set it to `arbitrum-sepolia` and `decdn_chain_id`
  plus every contract address default to upstream's deployment manifest, mirrored
  into `roles/decdn_node/vars/main/networks.yml` by `scripts/sync-network-profiles.py`.
  Inventory addresses still win (the role reports them); an unknown network or a
  `decdn_chain_id` that disagrees with the profile fails the play.
- arm64: `decdn_node_target` now derives from the host's architecture
  (`x86_64-unknown-linux-gnu` or `aarch64-unknown-linux-gnu`), so aarch64 hosts get
  the right release tarball and ELF check with no inventory change. An unsupported or
  mismatching triple fails loud.
- `tasks_from: backup` (`decdn_backup_*`): tars the node's identity (hot) or its full
  state minus the cache plus the keystore wherever it lives (stopping the node for the
  copy and restarting it if it was up, even when the archive step fails), encrypts it
  on the host to `decdn_backup_age_recipients` (age or SSH public keys, required), and
  fetches the ciphertext of identity archives only (a full one would be read into
  memory; the run prints a streaming copy command instead).
- `tasks_from: decommission` (`decdn_decommission_*`): typed confirmation that fails
  closed after `decdn_decommission_prompt_seconds`, one host by default, stops the
  node with systemctl and removes its unit, optionally purges the cache, keeps the
  identity, prints the on-chain exit steps.
- Both lifecycle entry points refuse a `decdn_cache_dir` that equals or encloses the
  identity and a `decdn_backup_dir` inside or around the node's directories.
- `decdn_node` is tested on Debian 13 and Ubuntu 24.04/26.04 (molecule `os-matrix`)
  as well as Debian 12; `grafana_alloy`'s install path still runs on Debian 12 only.

- `grafana_alloy_api_token`: the Grafana Cloud API token may now come from a
  git-ignored `host_vars/<node>/secret.yml` instead of only being operator-
  provisioned on the host, the same dual-home pattern `decdn_rpc_url` uses. Set, the
  role authors `/etc/grafana-alloy.env` itself as a **token-only** file at
  `root:root 0600`; left empty (the default), behaviour is unchanged. Because the
  authored file is token-only, every other connection setting must then come from
  inventory — preflight demands them before any mutation.
- `grafana_alloy_env_checksum_file` (default `/etc/grafana-alloy.env.sha256`): a
  root-owned `0600` provenance record, `<source> <sha256>`, written after the agent
  is running on that content. It lets a later converge tell an operator-owned file
  from a role-authored one, and drives two fail-loud guards — refusing to adopt a
  role-authored file as host-provisioned when the token goes missing from the
  control machine, and refusing to clobber a file this role did not write. Must
  remain exactly `<grafana_alloy_secret_file>.sha256`.
- `grafana_alloy_overwrite_host_file` (default `false`): explicit opt-in to rewrite
  an env file of foreign or unknown provenance. Required for one converge when
  migrating an existing host onto the inventory path; set it back to `false`
  afterwards or the guard stays disabled on that host.
- `baseline_packages` now includes `acl`. `decdn_node` runs two tasks as the
  unprivileged `decdn` user (`decdn key-gen`, and the `decdn config validate` gate),
  and on Debian Ansible needs ACL support to hand the temp module file to that user.
  Without it both fail without an `rc`, which the role can only report after the fact
  ("becoming the unprivileged decdn user needs the `acl` package on this host").

### Removed

- Ubuntu jammy from the roles' supported platforms: it was never tested.

- `decdn_delivery_floor` and `decdn_rate_bounds_poll_interval_sec`: upstream
  (decdn/decdn @ d3bc7da7) removed `payment.delivery_floor` and
  `blockchain.rate_bounds_poll_interval_sec`, so emitting either is a startup
  failure. The floor is redemption-time contract state that the node reads for no
  wire decision (ADR 003 §Rate-floor enforcement, ADR 005 §Rate bounds), so there
  is nothing left for either knob to tune.

### Changed

- `grafana_alloy` fails loud on an architecture Alloy has no package for, instead of
  a 404 at download time.

- `decdn_otlp_endpoint` must be `http://host:port`, matching upstream: `https://`,
  a missing port, a path/query/fragment and userinfo are rejected at deploy time.
  OTLP export is always compiled in; no `--features otlp` build is needed.

### Fixed

- A `release` install no longer fails intermittently at "Remove the download
  staging directory" with `rmtree failed: [Errno 2] No such file or directory:
  'S.gpg-agent.extra'`. Signature verification auto-started a `gpg-agent`
  whose sockets lived in the staging `GNUPGHOME`, and the agent removed them
  itself while the cleanup was deleting the directory. `gpg` now runs with
  `--no-autostart`, since importing and verifying need no agent.
- A changed `decdn-node` or `alloy` unit now takes effect on the converge that
  writes it. The restart handlers relied on a separate `Reload systemd`
  handler running first, but `devsec.hardening.os_hardening` (loaded by
  `baseline` through `include_role`) defines a handler of the same name. Being
  loaded last, it shadows the roles' own and runs after the restarts, so
  systemd restarted the service from its cached unit: a new `WatchdogSec` was
  on disk while the running node had no watchdog until the next restart. The
  restart handlers now `daemon_reload` themselves.
- The OTLP gateway is authenticated with its own instance ID. The role reused
  the Prometheus one, so a Grafana Cloud org whose stack ID differs 401s every
  trace while metrics and logs keep flowing. New `grafana_alloy_otlp_username` /
  `GC_OTLP_USERNAME`; when both are empty the rendered config still resolves the
  Prometheus value, so an org where the IDs coincide is unaffected. The optional
  host key is shape-checked whenever it is present, so a malformed value cannot
  quietly outrank that fallback.
- Grafana Alloy credentials now default to root-controlled
  `/etc/grafana-alloy.env`; preflight also rejects a non-root-owned or writable
  parent directory and a root service identity. Teardown requires the managed
  stamp on the unit's first line, and destructive paths reject both `.` and `..`
  segments.
- `decdn config validate` no longer bash-sources `/etc/decdn/decdn.env`. It
  loads the role-supported one-line EnvironmentFile assignment forms with a
  non-expanding host-side parser, so `$VAR` / `$(...)` in an inventory-rendered
  (`to_json`) RPC URL stay literal for both the gate and the daemon.
- Manual dir-mode's read-only ELF probe runs under `--check` instead of being
  skipped and feeding empty output into the architecture assertion.

## [0.1.0] — unreleased

Initial packaging of the public deCDN node roles as a distributable collection.
Not yet published to Galaxy (pre-1.0; the published shape may still change).

### Added

- `decdn.node.baseline` — Debian/Ubuntu host baseline: nftables default-deny
  inbound, fail2ban, unattended-upgrades, chrony, an admin sudo account, and DevSec
  OS + SSH hardening applied last.
- `decdn.node.decdn_node` — the `decdn-node` daemon under a hardened systemd unit,
  from locally built binaries (`manual`, the default until upstream tags a release)
  or a GPG-verified GitHub Release tarball (`release`); public QUIC udp/4433,
  loopback metrics + admin RPC.
- Release-integrity verification: `release` mode fetches the release's `SHA256SUMS`
  and `SHA256SUMS.asc`, verifies the detached signature against the maintainer
  keyring vendored at `roles/decdn_node/files/decdn-release-KEYS.asc`, then checks
  the tarballs against the manifest. Replaces the hand-pasted `decdn_node_sha256` /
  `decdn_cli_sha256` pins, which are removed. `decdn_verify_release_signature`
  (default `true`) and `decdn_release_keyring` control it.
- `decdn config validate` now runs against the installed binary after `node.toml` is
  templated, so a config-schema mismatch fails the deploy with the daemon's own
  error rather than crash-looping the service.
- `decdn_extra_env` — extra `KEY: value` pairs appended to the `0600` env file. The
  supported home for environment-borne secrets, notably the AWS credentials behind
  an S3 cache origin (which are deliberately never written to the `0640` `node.toml`).
- **Host-provisioned secrets.** `decdn_rpc_url` may now be left empty when the
  operator has written a `0600 /etc/decdn/decdn.env` on the target host: the role
  then leaves that file's *content* alone (it never reads it back to the control
  machine), enforcing only `0600 decdn:decdn` and checking that a non-empty
  `DECDN_RPC_URL=` line is present. Setting `decdn_rpc_url` keeps the previous
  behaviour and overwrites the host file from inventory. The role fails loud, with
  the provisioning commands, when neither is present — and rejects
  `decdn_extra_env` against a host-provisioned file rather than silently dropping
  it. A template for the host file ships at
  `roles/decdn_node/files/decdn.env.example`.
- `decdn_env_checksum_file` (default `/etc/decdn/.decdn.env.sha256`, `0600 root`) —
  a role-managed `<source> <sha256>` record for the env file, written on both
  authoring paths after the daemon is running. It restarts the unit when an **out-of-band** edit of
  a host-provisioned `decdn.env` is detected (instead of leaving the daemon on stale
  values behind a green deploy), and doubles as the file's provenance marker: an
  empty `decdn_rpc_url` against a file the role itself wrote fails loud (a missing
  `secret.yml` is not the same as handing the file to the host), and an inventory
  `decdn_rpc_url` against a file someone else wrote fails loud rather than
  discarding it — override with `decdn_env_overwrite_host_file: true`.
  **Upgrade note:** hosts deployed before this have no record, so the first
  converge seeds one. That first run deliberately does *not* restart the daemon,
  and the role warns rather than fails if it rewrites an untracked file.
- `ExecReload` on the unit plus a `Reload decdn-node` handler, for the five
  hot-reloadable config sections.
- Full config-schema parity with `decdn/decdn` @ `d306cc5c`: `[network.discovery]`,
  `[cache.tinylfu]`, `[cache.serve_economics]`, `[cache.origin_retry]`,
  `[cache.circuit_breaker]`, `[[cache.origins]]`, `[security]`, `[load_shed]`,
  `[dht.rate_limit]`, `[probe.rate_limit]`, `[receipts]` and `[content]` are now
  rendered, along with the new `[blockchain]` and `[cache]` scalars.

- `decdn_node_generate_keystore` (default `false`) — opt-in host-side wallet
  generation: when `true` the `decdn_node` role runs `decdn key-gen` only if the
  keystore is absent (minting a random `0600` password file first, but only when the
  keystore is also absent), never overwriting an existing wallet. Funding + on-chain
  staking/registration remain a manual step.

### Fixed

- **`decdn_extra_env` values were escaped incorrectly** in the `0600` env file, and
  `DECDN_RPC_URL` was not escaped at all. Inside a YAML literal block Jinja reads
  `'\\'` as *two* literal backslashes, so the role's hand-rolled
  `replace('\\', '\\\\') | replace('"', '\\"')` chain never matched a lone backslash
  and rendered a double quote as `\\"` — an escaped backslash followed by a
  *closing* quote. Any value containing a quote was truncated there and any
  backslash was passed through unescaped; systemd then skipped the line it could
  not parse and the variable was simply **absent** at runtime (an S3 origin whose
  secret key contained a quote or backslash would 403 with nothing to show why).
  Both are now rendered with `to_json(ensure_ascii=false)`, which emits exactly the
  double-quoted, C-escaped form `EnvironmentFile=` expects. Values containing a
  space, `#`, quote, backslash or non-ASCII character now survive intact.
  **Upgrade note:** this changes the rendered file (`DECDN_RPC_URL` gains quotes),
  so the first converge on the inventory path rewrites it and restarts the daemon
  once.

### Changed (BREAKING)

The collection has never been published, so this is not a break against any
released version — but it *is* a break against the shape earlier commits on `main`
had, and against any inventory written for it.

- `decdn_payment_channel_address` → **`decdn_payment_pool_address`**. Upstream
  replaced pairwise payment channels with a shared payment pool.
- `decdn_buyer_deposit_micro_usdc` → **`decdn_buyer_working_deposit_micro_usdc`**.
  The split initial/working buyer deposits were merged into one.
- `decdn_content_blacklist_address` is now **REQUIRED**, not optional. Upstream
  refuses to resolve a config without it (ADR 011/031): an absent or zero address is
  a fail-open compliance trap.
- `decdn_origin_assignment_address` and `decdn_publisher_registry_address` are now
  **independently** optional; the old "set both or neither" assert is gone.
- The `arbitrum-sepolia` contract addresses in `host_vars/decdn-node-1/main.yml` are
  re-synced to deployBlock 11613778. Upstream redeployed all fourteen contracts, so
  every previous address is dead.
- The default `decdn_node_install_method` is now `manual`, because upstream has cut
  no release tag yet and `release` mode has nothing to download.

### Removed

Config keys upstream deleted. Every config section is `deny_unknown_fields` with no
serde aliases, so leaving any of these set would refuse the daemon's startup:

- `decdn_relay_url` (singular — use the `decdn_relay_urls` list) and
  `decdn_enable_0rtt`.
- `decdn_slash_judge_from_block`, `decdn_origin_directory_from_block`,
  `decdn_content_blacklist_from_block` — the watchers no longer take a scan floor.
- `decdn_delivery_ceiling` (on-chain `PaymentPool.getRateBounds()` is authoritative;
  `DECDN_DELIVERY_CEILING` is a retired env var upstream) and
  `decdn_voucher_interval_mb` (voucher-interval negotiation was deleted).
- `decdn_settlement_auto_threshold_micro_usdc` and
  `decdn_settlement_auto_by_voucher_nonce_span` — auto-`closeChannel` went away with
  the channels.
- `decdn_pull_ahead_bytes`, `decdn_max_unrecouped_leech_bytes`,
  `decdn_pull_share_ratio_percent`, `decdn_pull_through_require_authorized_origin` —
  the speculative-pull accounting was replaced by
  `decdn_node_pull_stall_window_sec` + `decdn_node_pull_min_throughput_bps`.
- `decdn_region_accounting_interval_sec`.
- `decdn_node_sha256` / `decdn_cli_sha256` — superseded by signed `SHA256SUMS`.

<!-- No release tags exist yet; these resolve today. Switch to compare/tag links
     (compare/v0.1.0...HEAD and releases/tag/v0.1.0) once v0.1.0 is cut. -->
[Unreleased]: https://github.com/decdn/devops/commits/main
[0.1.0]: https://github.com/decdn/devops/releases
