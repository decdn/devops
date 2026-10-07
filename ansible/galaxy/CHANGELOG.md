# Changelog — `decdn.node`

All notable changes to the `decdn.node` Ansible collection are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
collection adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `decdn_node`, `sponsord`, `sponsord_onramp`: a `source` install method that
  clones `*_source_repo` (the upstream GitHub repo by default) at `*_source_ref`
  (any tag, branch or SHA) on the target and builds it there with `cargo build
  --release --locked`. The build runs as an unprivileged `decdn-build` system user
  (`decdn_build_user`, `decdn_build_home`) with a sha256-pinned rustup-init
  (`decdn_rustup_version`, `decdn_rustup_sha256`) and the toolchain the commit's
  `rust-toolchain.toml` pins (root installs both). Every new commit builds in a fresh
  environment so no build can poison a later one: root owns the build home, the
  toolchain and the git clone, the commit is exported into a per-build work
  directory (own `CARGO_HOME`, `TMPDIR`, `HOME`) deleted after install, cargo runs
  in a sandboxed transient systemd unit (read-only filesystem but the work
  directory, private tmp, `/dev/shm` and IPC, its cgroup killed when it ends),
  cron and at are denied to the build user, and its processes, crontab and at
  jobs are removed (and a build home root does not own deleted) before the layout
  is touched. Root never
  acts by name inside the build user's tree: the outputs are installed by
  `files/install-build-output.py`, which refuses symlinks and files the build user
  does not own. The build runs async (`*_source_build_timeout`),
  `*_source_build_jobs` sets `CARGO_BUILD_JOBS`, and a `<repo>@<commit>` stamp
  skips rebuilding an unchanged commit. The repo URL may not carry a secret
  (password, user on http(s), query), and is checked before anything prints it; an
  ssh deploy-key URL (root's key) is fine. Every method now clears the other
  methods' stamps.
- `decdn_node`: the daemon binary's sha256 is recorded after the start
  (`decdn_bin_checksum_file`), and a mismatch restarts the daemon, so a binary
  installed by a run that failed before its restart handler ran is not left
  unused behind a green deploy. A host with no record yet has it initialised from
  the binary in place before anything is installed, so the first run on this
  version is covered without restarting an unchanged daemon.
- Source mode never runs a source-built binary as root: the `--version` backstop
  of all three roles runs it in a throwaway sandboxed unit (`DynamicUser`, no
  network, read-only filesystem).

- `sponsord`: opt-in treasury wallet generation (`sponsord_generate_treasury_wallet`,
  `sponsord_decdn_cli_bin_src`). With the keystore absent, the role runs `decdn
  key-gen` on the host, writes a random password beside the keystore and records
  the address in `/etc/sponsord/treasury-address`; an existing keystore is never
  replaced. An empty `sponsord_pool_id` is accepted on that run, which stops before
  the daemon with the address and the `decdn pool open` command to run on the host.
- `sponsord_onramp`: the Turnstile secret can come from inventory
  (`sponsord_onramp_turnstile_secret`, git-ignored `secret.yml`); the role then
  writes `/etc/sponsord/turnstile-secret` (root 0600). The same provenance record
  and guards as `sponsord`'s `secret.env`: a host-written file is replaced only
  with `sponsord_onramp_turnstile_secret_overwrite_host_file: true`, and an emptied
  value never adopts the role's own file. A host-provisioned file keeps working
  unchanged.

- `sponsord_onramp` role: deploys `sponsord-onramp` (decdn/sponsord), the public
  side of the sponsor: the Cloudflare Turnstile gate, the `decdn.sh` / `decdn.ps1`
  installers and the API the `decdn-sponsored` CLI polls. It runs on the daemon's
  host (the token gate and `/healthz` fail without the daemon) and reads the daemon's own
  `/etc/sponsord/api-token`.
  - Install: a local binary (`sponsord_onramp_install_method: manual`, the default
    until upstream tags a release; `sponsord_onramp_release_target_dir` follows
    `sponsord_release_target_dir`) or a `sponsord-onramp-v<version>` release
    verified against its GPG-signed `SHA256SUMS`, with the keys vendored in the
    `sponsord` role.
  - Unit: `DynamicUser`, the daemon token and the host-provisioned Turnstile secret
    (`0600 /etc/sponsord/turnstile-secret`, never handled by the role) as
    `LoadCredential=` credentials, `PartOf=sponsord.service` so it re-reads the
    daemon's limits when the daemon restarts.
  - Inputs: `sponsord_onramp_rpc_url` is published to every user, so the role
    refuses credentials, a query or any character the installers cannot quote.
    The release pins (`sponsord_onramp_decdn_release` / `_cli_release` and their
    `SHA256SUMS` digests) and the Turnstile sitekey are checked against upstream's
    shapes. CapacityBond and SlashJudge come from
    `roles/sponsord_onramp/vars/main/networks.yml`, generated by
    `scripts/sync-network-profiles.py`, through `sponsord_onramp_network` (which
    follows `sponsord_network` and must agree with it).
  - Listener: loopback only (asserted). The deploy fails unless `/healthz` answers
    from a listener owned by the running unit. A restart-input record restarts the
    onramp after an out-of-band rotation of the token or the Turnstile secret.
  - TLS front: `sponsord_onramp_proxy: caddy` (default) installs the distro's Caddy
    and owns `/etc/caddy/Caddyfile` (validated before it lands, admin API off,
    `tls internal` for staging). A Caddyfile without the role's marker on a host
    that already had Caddy is refused unless
    `sponsord_onramp_caddy_overwrite_config: true`. The client address is the
    right-most `X-Forwarded-For` Caddy sets. `none` leaves the proxy, the public
    URL and its ports to you.
- `grafana_alloy_sponsord_onramp_enabled` (default `false`): label the onramp's
  journald stream with `service_name="sponsord-onramp"` and a `level` parsed from
  each line, as for sponsord. It has no `/metrics`, so there is no scrape. The
  systemd collector's default unit list now includes `sponsord-onramp.service` and
  `caddy.service`, which changes `config.alloy` once on every Grafana-enabled host.

- `sponsord` role: deploys the deCDN onboarding sponsor (decdn/sponsord) on its own
  host or beside a node. It installs a local binary (`sponsord_install_method: manual`,
  the default until upstream tags a release) or a `sponsord-v<version>` release
  verified against its GPG-signed `SHA256SUMS`. The unit uses `DynamicUser`, and the
  API token, treasury keystore and password reach it as `LoadCredential=`
  credentials. Newer systemd (255 on Ubuntu 24.04) writes credentials `0440` and sponsord refuses a
  group-readable keystore, so the keystore is re-copied `0600` into the unit's
  `RuntimeDirectory` at start. The API token is generated on the host and never
  replaced. The RPC
  URL comes from `sponsord_rpc_url` or a host-provisioned `0600
  /etc/sponsord/secret.env`, with the same provenance guards as `decdn_rpc_url`. A
  host-provisioned file may carry `SPONSORD_RPC_URL` only, because an
  `EnvironmentFile` would override every validated setting.
- The listener is loopback only. The deploy fails unless `/healthz` answers
  `{"ok":true}` from a listener owned by the running unit.
- A hash record of every restart input (credentials, env files, unit, binary)
  restarts the daemon after a rotation, an out-of-band edit, or an earlier failed
  run.
- In release mode, the version stamp is written only after an exact `--version`
  match.
  `sponsord_network` takes the chain and PaymentPool from
  `roles/sponsord/vars/main/networks.yml`, generated by
  `scripts/sync-network-profiles.py`.
- `grafana_alloy_sponsord_enabled` (default `false`): scrape sponsord's `/metrics`
  as `job="sponsord"` with its own `service_name`. Its journald stream gets the
  same `service_name`, and a `level` label parsed from each line, because journald
  files all of a daemon's stdout as info. Like decdn-node, it is exempt from the
  journald-priority guardrail and judged by that parsed level instead.
- `grafana_alloy_node_enabled` (default `true`) turns the decdn-node scrape off on
  a host without a node. The repo's playbooks derive both settings from
  `sponsord_hosts` / `decdn_nodes`.
- The systemd collector's default unit list now includes `sponsord.service`. That
  changes `config.alloy` once on every Grafana-enabled host, so expect one Alloy
  restart on the next deploy.

- `decdn_get_logs_max_block_span` (default `""`, daemon default 10000, `>= 1`): the
  ceiling on one chain-watcher `eth_getLogs` block span, rendered as
  `blockchain.get_logs_max_block_span` (decdn/decdn @ 3ebf5f17). The poller halves
  its window on a provider range rejection and grows it back toward this ceiling;
  if rejections keep coming, set it to the lowest span reached while they do, not
  the provider's quoted limit. A binary built without that commit rejects the key
  and the role's `decdn config validate` gate fails the deploy, so leave it unset
  there.

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

- **Breaking:** `decdn_node_install_method`, `sponsord_install_method` and
  `sponsord_onramp_install_method` now default to `release` (was `manual`). An
  inventory that relied on the old default must set `manual` explicitly. Upstream
  has cut no release yet, so `release` needs a pinned version and a mirror until
  it does; the version assert now names the alternatives.
- `decdn_node`, `sponsord`, `sponsord_onramp`: every install method clears both
  install stamps (release and source) before it replaces the first binary, and
  writes its own only after the `--version` backstop passes (`decdn_node` used to
  write the release stamp before the backstop), so an install interrupted half way
  (a method switch included) is redone, a release that installs a broken binary is
  downloaded again next run, and pinning back to the previous version reinstalls
  it.

- The role now tracks the config schema of decdn/decdn @ 3ebf5f17 (was
  d3bc7da7).

- `grafana_alloy` fails loud on an architecture Alloy has no package for, instead of
  a 404 at download time.

- `decdn_otlp_endpoint` must be `http://host:port`, matching upstream: `https://`,
  a missing port, a path/query/fragment and userinfo are rejected at deploy time.
  OTLP export is always compiled in; no `--features otlp` build is needed.

- `sponsord_onramp` checks for Caddy and curl with one `dpkg-query` instead of
  `package_facts`, and skips the apt install (and its cache refresh) when both are
  installed. A re-run no longer loads the whole package database or refreshes the apt
  lists. It no longer sets `ansible_facts.packages`.

### Fixed

- On a host in both `decdn_nodes` and `sponsord_hosts`, the sponsord play's
  baseline could not render the node's udp/4433 hole: it read `decdn_bind_port`, a
  `decdn_node` default that play does not load. The public holes are now built
  from the host's groups in `playbooks/group_vars/all.yml`, so every play renders
  the same firewall. With `sponsord_onramp_hosts` they include tcp/80 and tcp/443
  for Caddy.

- `grafana_alloy` no longer ships URL credentials in journald lines to Grafana
  Cloud Loki (#84). Every line was forwarded verbatim, so a daemon error that
  quoted the RPC URL (sponsord's `error sending request for url (…)`) put its
  provider API key in Loki. A new `loki.process "redact_urls"` stage now runs on
  every unit's line ahead of the level stages. It replaces the userinfo with
  `<redacted>` and everything after the host with `/<redacted>`, keeping the
  scheme and host. That holds for passwords with unencoded `/ ? # @`, and for
  URLs inside JSON that escapes them (`https:\/\/…`, `\u0026`, one level of
  nesting). A URL with an `@` in its path loses its host. A line with no URL, or
  with a URL that has no userinfo and nothing after its host, is unchanged. OTLP
  logs and spans are not redacted (#86). The rendered `config.alloy` changes on
  every host with Grafana Cloud logs on, so the next deploy restarts Alloy once.
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
