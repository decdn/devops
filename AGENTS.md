# AGENTS.md — decdn-devops

Guidance for AI coding agents (Claude Code, Codex, Cursor, …) working in the deCDN
DevOps repo.

## What this repo is

The official DevOps project for deploying deCDN: infrastructure, deployment, and
operational tooling. It serves **two kinds of operator**, and every entry point is
split along that line:

- **Node operators** run cache nodes (`decdn-node`, no origin backend): `node.yml` /
  `make deploy-node`, `cloud-init/user-data-node.yaml`, Compose's `node` profile, the
  chart, the `decdn.node` collection. Front door: `docs/node-operators.md`.
- **Publishers** own namespaces in `PublisherRegistry` and run **origin nodes** (the
  same daemon with an origin backend, seated on-chain via `OriginAssignment.addOrigin`,
  ADR 002/011), and optionally `sponsord` + its onramp, iroh relays and an iroh DNS
  server: `publisher.yml` / `make deploy-publisher` (`origin.yml` + the component
  playbooks), `cloud-init/user-data-publisher.yaml`, Compose's `origin`/`onramp`/`relay`/`dns`
  profiles, the chart (an origin node only), the `decdn.publisher` collection. Front
  door: `docs/publishers.md`.

There are four deploy paths:
**Ansible** (`ansible/`, VMs/bare metal, the primary path, also the `decdn.node` and
`decdn.publisher` Galaxy collections), **cloud-init**
(`cloud-init/`, one VM that runs the Ansible playbook on itself, no control machine),
**Docker Compose** (`compose/`, a single Docker host) and a **Helm chart**
(`charts/decdn-node/`, Kubernetes).

This repo is **infrastructure only**. It is *not* a source of truth for protocol or
economic claims — those trace to the deCDN ADRs. If something here states a protocol fact
(chain-id, token address, fee split), it must trace back to an ADR or upstream's
deployment manifest, not invent one; the contract addresses live only in the generated
mirror (`vars/main/networks.yml`), never hand-copied into inventory or docs.

## Hard rules

1. **Never commit secrets.** No passwords, private keys, API tokens, or keystores in any
   tracked file. Secrets are *generated on — or operator-provisioned to — the target host*
   (e.g. the node's eth keystore, or `rpc_url` which may embed an API key) and stored under
   `/etc/<svc>/` with `chmod 600` and a dedicated owner. The repo ships `*.example`
   templates for secret files only (non-secret config may be committed directly). The root
   `.gitignore` is a backstop — do not rely on it; keep secrets out by design. The Helm
   chart never creates a Secret: it references operator-provisioned ones
   (`existingSecret`), injects only named env keys (never `envFrom` — `DECDN_*` env
   overrides `node.toml`), keeps the keystore password off the PVC, and refuses
   secret-bearing keys in `config`.
2. **Localhost-only by default.** Service daemons bind `127.0.0.1` (e.g. the node's metrics
   and admin RPC). A service that must accept public traffic declares its holes explicitly
   via `baseline_extra_inbound` (today: the node's QUIC udp/4433, and tcp/80 + tcp/443 for
   the `sponsord_onramp` role's Caddy; on Compose, the `caddy` profile's same two ports,
   which the operator opens). An HTTP-facing service is fronted by an explicit
   reverse proxy that terminates TLS (and auth, where the service needs it), and the
   backend stays on loopback. Never bind a *backend* to `0.0.0.0` or expose its raw port.
   `sponsord-onramp` is public by design: its Turnstile gate guards the one action that
   spends (`POST /v1/fund`), and per-address rate limits cover the rest.
   **iroh relay exception (`iroh_relay` role):** `iroh-relay` is public by design and
   terminates its own TLS (Let's Encrypt over TLS-ALPN-01; QUIC address discovery needs
   the same certificate in-process), so it binds tcp/80, tcp/443 and udp/7842 on every
   address itself, with no proxy and no backend behind it. Its holes come from
   `iroh_relay_hosts`; its metrics are asserted onto loopback (`127.0.0.1:9092`). On
   Compose (the `relay` profile) the operator opens the same three ports, and
   `decdn-compose check` refuses metrics off loopback.
   **iroh DNS server exception (`iroh_dns_server` role):** `iroh-dns-server` is public
   by design and terminates its own TLS (Let's Encrypt over TLS-ALPN-01), so it binds
   tcp/443 (`::` by default) and udp/53 + tcp/53 on one address (the host's default
   IPv4 by default, clear of systemd-resolved's `127.0.0.53`) itself, with no proxy
   and no backend behind it. Its holes come from `iroh_dns_server_hosts`; its metrics
   (`127.0.0.1:9117`) and a plain-http health listener (`127.0.0.1:9118`) are
   asserted onto loopback. On Compose (the `dns` profile) the operator opens the same
   ports, and `decdn-compose check` refuses either listener off loopback.
   **Kubernetes exception (chart only):** the node's metrics bind `0.0.0.0` inside the pod
   so kubelet probes and Prometheus can reach them. That is allowed only behind a
   ClusterIP-only Service and the chart's NetworkPolicy (metrics ingress limited to
   `metrics.networkPolicy.from`); disabling the policy fails the render unless
   `networkPolicy.allowUnrestrictedMetrics=true` acknowledges it. Never front metrics with
   a LoadBalancer/NodePort/Ingress.
   **Compose exception (the iroh services only):** every Compose container runs as a
   non-root host account, except the iroh relay and DNS server, which run as uid 0
   holding `NET_BIND_SERVICE` and no other capability (read-only rootfs,
   `no-new-privileges`, everything else dropped). Each must bind its public ports
   itself, and on the host network Docker cannot give a non-root process that
   capability (no ambient capabilities, no file capability on the binaries, and the
   unprivileged-port sysctl is refused with host networking). `compose/tests/invariants.jq`
   allows uid 0 only for the services in its `root_allowed` list, and only with
   `cap_add` exactly `[NET_BIND_SERVICE]`; never add a service to that list for any
   other reason.
3. **Role templates render to their target paths.** Ansible roles template config directly
   onto the host (e.g. `roles/decdn_node/templates/decdn-node.service.j2` →
   `/etc/systemd/system/`), with secrets generated on the host at `0600`.
4. **Scripts are idempotent and fail loud.** `set -euo pipefail`, re-runnable, refuse to
   overwrite existing secrets, and require typed confirmation before destructive ops.
5. **Show before installing.** When building or changing infra, present the files; the
   playbook run on the target (`make deploy`) is what mutates a host — it runs there, not
   here.

## Layout

```
ansible/                # the deployment project (DevSec-hardened, lean roles)
  playbooks/            # site.yml = node.yml (node operators: cache nodes) + publisher.yml (publishers: origin.yml, sponsord.yml (+ onramp), iroh_relay.yml, iroh_dns_server.yml); backup.yml, decommission.yml
  roles/                # baseline, decdn_node, grafana_alloy, sponsord, sponsord_onramp, iroh_relay, iroh_dns_server
  inventory/ galaxy/ molecule/    # see ansible/README.md
cloud-init/             # user-data-{node,publisher}.yaml + on-host bootstrap.sh; pinned ansible-core/collections (see its README.md)
compose/                # Docker Compose deploy path for a single host (see its README.md)
  compose.yaml          # profiles: node / origin (one decdn-node), sponsord, onramp (+ sponsord), caddy, relay, dns, alloy
  alloy/config.alloy    # GENERATED from roles/grafana_alloy's config.alloy.j2 (scripts/render-compose-alloy.sh)
  decdn-compose         # the operator's wrapper: init, check, guarded up/stop/restart/down, health, cli, backup
  Caddyfile             # mirrors roles/sponsord_onramp/templates/Caddyfile.j2
  tests/*.jq            # lint-compose: invariants, inline-env, fail-closed
  tests/test_decdn_compose.py  # the wrapper's unit tests (make test-scripts)
charts/
  decdn-node/           # Helm chart for the node on Kubernetes (see its README.md)
    ci/                 # CI values files (mirror molecule/schema's three plays)
    files/monitoring    # symlink to ../../../monitoring/decdn-node (helm package dereferences it)
    tests/render-test.sh  # positive/negative render tests (`make lint-helm`)
    artifacthub-repo.yml  # Artifact Hub repository metadata (.helmignored, release-chart.yml pushes it)
monitoring/             # Grafana dashboards + Prometheus alert rules (maintained here)
  decdn-node/           # the node's (+ promtool unit tests, .helmignored), rendered by the chart
  sponsord/             # sponsord's (+ promtool unit tests), Ansible/Compose only
  iroh-relay/           # the relay's (+ promtool unit tests, exported-metrics.txt), Ansible and Compose
docs/                   # cross-path operator docs: node-operators.md + publishers.md (the front doors), requirements.md, lifecycle.md
scripts/                # upstream-mirror generators, the compose Alloy config generator (render-compose-alloy.sh), the release script (release.sh, git-cliff: ../cliff.toml) and its gate (+ its Artifact Hub changes generator), the molecule driver (molecule.sh), ansible/Makefile's LIMIT preflight (limit-guard.sh)
```

**Generated mirrors of upstream — regenerate, never hand-edit:**
`ansible/roles/decdn_node/vars/main/networks.yml` and its subsets
`ansible/roles/sponsord/vars/main/networks.yml` and
`ansible/roles/sponsord_onramp/vars/main/networks.yml` (all `scripts/sync-network-profiles.py`)
and `ansible/molecule/schema/files/schema-keys.txt` (`gen-schema-keys.py`), both
generated from the decdn/decdn tag `decdn_node_version` pins. The weekly
`upstream-drift` workflow flags staleness against that tag, and a newer upstream
release of either repo. These are the only protocol facts (contract addresses) the
repo carries, and `networks.yml` carries its upstream commit.

**Generated from this repo — regenerate, never hand-edit:** `compose/alloy/config.alloy`
is the `grafana_alloy` role's `templates/config.alloy.j2` rendered in its `compose`
runtime (`scripts/render-compose-alloy.sh`, which runs the `compose`-tagged task of
`ansible/tests/alloy-config/render.yml`). Change the template and regenerate; `make
test-scripts` fails while the committed file differs from a fresh render, and `make
lint-alloy` validates and runs it.

**Pinned upstream releases.** One decdn/decdn release (`decdn_node_version`, today
`0.0.2`) and one decdn/sponsord release (`sponsord_version` = `sponsord_onramp_version`,
today `0.0.2`; decdn/sponsord tags its whole workspace `vX.Y.Z`, there are no per-crate
tags) are pinned across every path: the role defaults, the onramp's installer pins
(`sponsord_onramp_{decdn,cli}_release` + `_sums_sha256`, copied into
`compose/sponsord-onramp.env.example`), `compose/.env.example`'s image digests, the
chart's `appVersion` and the generated mirrors. cloud-init takes the role defaults at
`DEVOPS_REF`. `make test-scripts` checks the pins agree with each other, the Compose
example, `appVersion` and the chart's `artifacthub.io/images` tag, and that both
vendored KEYS hold the keys SECURITY.md publishes; the weekly `upstream-drift` job checks the digests and the mirrors against
the releases and flags a newer upstream tag. The `--version` check compares the pin in
`release` mode only (exactly, on `<binary> <version>`). Bump everything together with
the checklists in `roles/decdn_node/README.md` and `roles/sponsord/README.md`. Both upstream repos are public and also publish their
binaries as crates (`decdn-node`, `decdn-cli`, `sponsord`, `sponsord-onramp`); the
roles do not install from crates.io (no maintainer signature).

**Monitoring assets are maintained here, by hand.** `monitoring/` holds the deCDN
Grafana dashboards and Prometheus alert rules for every deploy path; upstream ships none.
The chart renders `monitoring/decdn-node/` through its `files/monitoring` symlink
(`.Files` cannot read outside the chart; `render-test.sh` checks the link and that the
packaged chart carries those files and nothing else), so copy a chart tree with `cp -RL`. Every
`decdn_*` series a panel or rule names must be one `decdn-node` exports — check the
node's `/metrics` and upstream's `adr/appendix-observability.md` registry (a `planned`
row emits nothing). Nothing in CI checks the names, so a typo renders `(no data)` or a
rule that never fires. See `.claude/skills/grafana-dashboards/SKILL.md`. sponsord's pair
lives in `monitoring/sponsord/`, which the chart does not render; its `sponsord_*`
names must be ones upstream `decdn/sponsord` `crates/sponsord/src/metrics.rs` exports,
and its rules have promtool unit tests (`monitoring/sponsord/prometheus-alerts_test.yml`,
run by `make lint-helm`), as the node's `DecdnNodeDown` does
(`monitoring/decdn-node/prometheus-alerts_test.yml`, which the chart's `.helmignore`
keeps out of the package). The relay's pair lives in `monitoring/iroh-relay/`, also not
rendered by the chart, with its own promtool unit tests; there CI does check the names:
every `relayserver_*` series must appear in `exported-metrics.txt`, the `/metrics` of
the pinned `iroh-relay` (re-capture it when bumping `iroh_relay_version`).

## Current services

- **`ansible/`** — the declarative deployment project, with an entry point per persona:
  `playbooks/node.yml` (`make deploy-node`) for **node operators**, `playbooks/publisher.yml`
  (`make deploy-publisher`) for **publishers**, and `site.yml` (`make deploy`) for both.
  **Origin nodes** are `decdn_origin_nodes`, a child of `decdn_nodes` (so they inherit the
  node's firewall hole, backup, decommission, relay allowlist and Alloy scrape), deployed by
  `playbooks/origin.yml` with the same roles; node.yml's play is
  `decdn_nodes:!decdn_origin_nodes`, so each node runs once under site.yml. origin.yml's
  `pre_tasks` refuse an origin outside `decdn_nodes` or without an origin backend
  (`decdn_cache_origin_kind`/`decdn_cache_origins`); node.yml's warn about a backend outside
  `decdn_origin_nodes`. Those group checks live in the playbooks, never the role, as with
  sponsord's. A cache node has no origin backend: it fills misses from other nodes
  (node-to-node pull-through), and an origin-configured node serves only what its own
  backend holds (`relay_foreign_namespaces`, ADR 002 § Retrieval by namespace, ADR 037). Recognition as an origin is on-chain (`OriginAssignment.addOrigin`,
  the publisher's step). **The public deCDN node**
  (baseline + `decdn-node`), installed by `decdn_node_install_method`:
  `release` (the default) — a pinned GitHub release tarball verified against the
  release's GPG-signed `SHA256SUMS` (`decdn_node_version`, default `0.0.2`); `source` — a git ref (any tag/branch/SHA) cloned and `cargo build`-ed **on the
  node** as the unprivileged `decdn-build` user, sha256-pinned rustup, a `<repo>@<commit>`
  stamp (`tasks/source.yml`, copied into both sponsord roles, which share the user,
  home and toolchain). **No build can poison a later one:** root owns the home, the
  toolchain (it installs what the commit's `rust-toolchain.toml` pins) and the git
  clone; each new commit is `git archive`d into a fresh work directory (own
  `CARGO_HOME`/`TMPDIR`/`HOME`) that is deleted after install; cargo runs in a
  sandboxed `systemd-run` unit (read-only FS but the work dir, private
  tmp/dev/shm/IPC, cgroup killed at the end); cron/at are denied, and the build
  user's processes, crontab and at jobs are removed and a home root does not own is
  deleted before the layout is touched. Root never acts by name inside the build user's
  tree: outputs go through `files/install-build-output.py` (openat/O_NOFOLLOW walk,
  regular file owned by the build user), copied in decdn_node and sponsord and kept
  identical by `make test-scripts` with the shared `decdn_build_*`/`decdn_rustup_*`
  defaults. Validation checks the repo URL for secrets before any task prints it.
  Coverage is end to end on dependency-free fixture repos: `molecule/source-build`
  with `source-build-rollback` and `source-build-recovery` (decdn_node) and
  `molecule/sponsord-onramp-source` (both sponsord roles); or `manual` — binaries built on the control machine. Each method clears
  the others' stamps; a stamp is cleared before installing and written only after
  the `--version` backstop passes; the node records the running binary's sha256
  after the start and restarts on a mismatch. Under a hardened
  systemd unit; public QUIC udp/4433, loopback metrics/admin, operator-provisioned eth
  keystore, operator-provisionable secret env file, over a shared DevSec-hardened
  `baseline`. The release target triple is derived from the host's architecture
  (x86_64/aarch64). The chain comes from `decdn_network` (the generated manifest mirror
  above; explicit inventory addresses still win) or from explicit variables.
  `playbooks/backup.yml` / `decommission.yml` (`make backup` / `make decommission`) are
  role entry points (`tasks_from: backup|decommission`): backups are encrypted on the host
  to operator public keys; decommission needs `LIMIT` + typed confirmation, keeps the
  identity and never touches the chain. Both also cover `sponsord_hosts` (and the onramp),
  and decommission covers `iroh_relay_hosts` and `iroh_dns_server_hosts` too, with one
  confirmation per run, in the first play that reaches a host, whose prompt lists every
  service it covers (`_decdn_decommission_confirmed`; the `decdn_decommission_*` cap and
  timeout are copied into all five roles' defaults, `make test-scripts` checks).
  Leaving `decdn_rpc_url` empty means the operator wrote `0600 /etc/decdn/decdn.env`
  on the host and the role only gates on it, so no secret transits the control machine. See `ansible/README.md`. (On-chain node
  stake/registration, ADR 019 Phase 2, is a manual operator step, driven by `decdn setup`.)

  **Config-schema coupling.** `roles/decdn_node/templates/node.toml.j2` renders against
  `decdn/crates/common/src/config/types.rs`, where every section is
  `#[serde(deny_unknown_fields)]` with **no** serde aliases — a key the role emits that
  the installed binary does not know is a startup crash-loop. Two guards: the role runs
  `decdn config validate` against the real binary after templating, and the
  `molecule/schema` scenario checks the rendered key set against a committed inventory of
  upstream field names. Re-sync both when bumping the pinned decdn version.

- **`ansible/roles/grafana_alloy`** — opt-in Grafana Cloud observability for that node,
  one mirrored flag (`decdn_grafana_cloud_enabled`, `false` by default) driving a
  loopback-only Grafana Alloy agent: the node's `/metrics`, the **machine** itself
  (Alloy's in-process `node_exporter`, curated collector set, `systemd` collector scoped
  to the units that matter), **journald** → Grafana Cloud Loki, Alloy's own health, and
  the daemon's OTLP spans. Host metrics and logs carry `job="integrations/node_exporter"`
  so Grafana Cloud's prebuilt Linux Server dashboards work unmodified. Every journald line
  passes `loki.process "redact_urls"` ahead of the level stages (URL userinfo, path, query
  and fragment → `<redacted>`, scheme and host kept, no knob), so an RPC URL quoted in a
  daemon error ships without its API key; OTLP data is not redacted (#86). The API token is the
  only credential, and it has two homes: operator-provisioned on the host
  (`0600 /etc/grafana-alloy.env`) or carried by `grafana_alloy_api_token` from a git-ignored
  `host_vars/<node>/secret.yml`, in which case the role authors that file itself as a
  token-only `EnvironmentFile` and tracks who wrote it in `<secret-file>.sha256` (the same
  `decdn_rpc_url` dual-home pattern). Either way `config.alloy` reads it as
  `sys.env("GC_API_TOKEN")` — Alloy has no `--config.expand-env`. The non-secret endpoints
  and the three per-service instance IDs are inventory variables that fall back to their
  `GC_…` env key when empty, and preflight refuses a token in any of them; with an inventory
  token it also requires all of them, since the authored file is token-only. Two hardening relaxations are conditional on the signals being on
  (`ProtectHome=read-only` for correct filesystem metrics, `SupplementaryGroups=
  systemd-journal adm` for journal access — without which collection is silently empty);
  teardown is gated on the managed-by marker in the unit, so a foreign Alloy is never
  touched. **`make lint-alloy` is the gate that matters** — the molecule stub exits 0 for
  everything, so only the real pinned binary proves the rendered config loads. See
  `ansible/roles/grafana_alloy/README.md`.
  **One template, two runtimes.** `config.alloy.j2` also renders Compose's
  `compose/alloy/config.alloy` (the generated mirror above) when `_ga_runtime` is
  `compose` (an internal var the render playbook sets, never an operator knob): the
  host's identity becomes `sys.env("ALLOY_INSTANCE_ID"|"ALLOY_REGION"|
  "ALLOY_DEPLOYMENT_ENVIRONMENT")` (the `ga_str` macro renders values carrying a
  `sys.env:` prefix as lookups; OTTL statements are built with `string.format` and a
  `where` guard), every daemon's scrape (node, sponsord, relay, DNS server) goes through a `discovery.relabel` keep
  rule on `DECDN_COMPOSE_PROFILES` (Compose's `COMPOSE_PROFILES`), so a daemon is
  scraped only under the profiles that start it (`_ga_compose_profiles`; the wrapper's
  unit tests check they match `PROFILES`), the host exporter reads `/host/{proc,sys,root}`
  and drops `systemd`, and journal lines get `container` from `CONTAINER_NAME` and, for
  `decdn-<service>-<n>`, the unit the role installs (`_ga_compose_units`), so every
  `unit`-keyed rule (level, guardrail exemption, service_name) and the dashboards'
  log panels apply unchanged; `redact_urls` still runs ahead of every level stage.
  The systemd renders are unchanged by the compose branch: keep it that way (diff
  `render.yml`'s output before and after a template change). `make lint-alloy` runs
  the compose render's journal stages on container lines and runs the whole file in
  Alloy (every component healthy, the targets per profile), since `alloy validate`
  neither parses OTTL nor evaluates `sys.env`.

- **`ansible/roles/sponsord`** — the deCDN onboarding sponsor (`decdn/sponsord`): the
  treasury wallet's signer for capped capabilities plus the PaymentPool keeper. It is
  independent of the node, so `playbooks/sponsord.yml` (`make deploy-sponsord`, also
  imported by `publisher.yml`) targets its own `sponsord_hosts` group, standalone or
  co-located with a node.
  - **Install:** a GPG-verified `v*` decdn/sponsord release by default
    (`sponsord_version`, `0.0.2`), a host-side `source` build, or a manual binary.
    The `--version` backstop checks the version in `release` mode only (the version
    has a default, so other modes would fail against it), as in the other two roles.
  - **Unit:** `DynamicUser`; the API token (generated on the host, never replaced),
    treasury keystore and password (operator-provisioned, or generated on the host
    with `sponsord_generate_treasury_wallet`) are `LoadCredential=`
    credentials, never env. The keystore is re-copied at 0600 into the unit's
    `RuntimeDirectory` by `ExecStartPre`, because newer systemd (255) writes credentials 0440
    and upstream rejects a group-readable keystore. Debian 12's systemd 252 hides
    this (0400); the `molecule/sponsord` Ubuntu 24.04 platform catches it, because
    the stub enforces upstream's keystore mode check.
  - **RPC URL:** in `0600 /etc/sponsord/secret.env`, with the same dual-home and
    provenance guards as `decdn_rpc_url`. A host-provisioned file may carry
    `SPONSORD_RPC_URL` only (an EnvironmentFile overrides every other setting).
  - **Listener:** loopback only (asserted), no firewall hole.
  - **Config gate:** sponsord has no `config validate` and only env/flag config, so
    `/healthz` after start is the gate, and it is **fatal**. The daemon binds only
    after the keystore decrypts and the on-chain pool-owner check passes.
  - **Top-up hold guard:** a restart or stop forgets a held, unconfirmed pool top-up
    (`sponsord_pool_topup_unconfirmed_since_unix` > 0), and the pool can be refilled
    twice. `tasks/topup-hold.yml` reads `/metrics` (at the address the running
    process listens on) before the role queues a restart and before decommission
    stops the daemon, and fails while a hold is on or `/metrics` does not answer.
    **The restart-inputs comparison is the role's only restart trigger:** never add
    `notify: Restart sponsord` to another task; make the file a hashed input
    instead, or the restart skips the guard. `sponsord_restart_ignore_topup_hold`
    overrides it (pass it as JSON). On Compose, `decdn-compose` makes the same check
    (`hold_state`, probing the bind the running container was started with; stricter
    than the role: a missing or unparseable gauge, which every pinned image exports,
    is unknown, and any held series holds) before a stop, restart, down or recreating `up`.
  - **Alloy toggles:** `playbooks/group_vars/all.yml` derives
    `grafana_alloy_node_enabled` / `grafana_alloy_sponsord_enabled` from group
    membership. They are host-scoped so a co-located host's two plays render one
    config.
  - **Molecule:** under docker, `/` must be `--make-rshared` (see
    `molecule/sponsord/prepare.yml`) or every credential directory is empty.
  - **cloud-init:** `cloud-init/user-data-publisher.yaml` (with the onramp and an
    origin node), release mode only; see the `cloud-init/` bullet below.

- **`ansible/roles/sponsord_onramp`** — `sponsord-onramp`, sponsord's public side (the
  Turnstile gate, the installers, the `decdn-sponsored` CLI API), as a second play of
  `playbooks/sponsord.yml` on `sponsord_onramp_hosts` (which must also be in
  `sponsord_hosts`: it reads the daemon's `/etc/sponsord/api-token` and calls it on
  loopback). The playbook's first play enforces that membership (tested by
  `make test-scripts`); the role checks no group name, so collection users keep their
  own groups, and its token gate and `/healthz` fail without a daemon.
  - **Install / unit / gate:** the sponsord role's patterns, copied: a
    GPG-verified `v*` decdn/sponsord release (default), `source` or manual (the
    KEYS and the source installer are the sponsord role's files, via `role_path`), `DynamicUser` with the token and the Turnstile secret (inventory
    or operator, with `secret.env`'s provenance record and guards) as
    `LoadCredential=`, `PartOf=sponsord.service`, a restart-inputs
    record, and a fatal `/healthz` gate on a loopback listener.
  - **Public inputs:** `sponsord_onramp_rpc_url` is served to every user, so preflight
    refuses userinfo, a query and the characters upstream's installers cannot quote.
    CapacityBond/SlashJudge come from the generated `vars/main/networks.yml`.
  - **Caddy (default) or none:** the distro package, a role-owned `/etc/caddy/Caddyfile`
    (marker-gated: a foreign one needs `sponsord_onramp_caddy_overwrite_config`),
    `admin off`, so the handler restarts. tcp/80 + tcp/443 come from
    `playbooks/group_vars/all.yml`, which reads `sponsord_onramp_proxy` from inventory.
  - **Molecule:** `molecule/sponsord-onramp` runs the real Caddy with `tls internal`
    and checks the https chain and that a forged `X-Forwarded-For` cannot pick the
    client address; `molecule/sponsord-onramp-caddy` runs the proxy side effects
    (ACME, `none`, a foreign Caddyfile), the custom gate page and the inventory
    Turnstile secret on the same converge.

- **`ansible/roles/iroh_relay`** — a self-hosted iroh relay (`iroh-relay` from
  n0-computer/iroh), the fallback path for deCDN peers that cannot hole-punch and their
  QUIC address discovery. The ADRs make relays operator-run infrastructure, not an
  incentivized role (`decdn/adr/architecture.md`, Trust Assumptions); nodes use them
  through `decdn_relay_urls`, which REPLACES n0's relays (so deploy at least two).
  `playbooks/iroh_relay.yml` (`make deploy-relay`, also imported by `publisher.yml`) runs
  baseline → grafana_alloy → iroh_relay on `iroh_relay_hosts`, after a play refusing a
  host also in `sponsord_onramp_hosts` (both want 80/443; `make test-scripts` runs it).
  - **Access:** `iroh_relay_access` defaults to `allowlist`. A play before the
    relay's runs `tasks_from: node-ids`: `decdn whoami` on every `decdn_nodes` host
    (delegate_to, so `LIMIT=<relay>` still reads them all; as the node's
    `decdn_user` via systemd-run; fallbacks = decdn_node defaults, `make
    test-scripts` checks), merged with `iroh_relay_allowlist`, sorted. An unreadable
    node or an empty list fails the deploy, and a list set for another mode is
    refused; the role refuses to run when the inventory read is on but did not run.
    Relays deploy `serial: 1`. The cost, documented in the role README: decdn
    clients use a fresh iroh key per fetch (`decdn/crates/client/src/endpoint.rs`),
    so they can never be listed, and iroh hole-punches over an existing connection,
    so a client reaches a node homed on an allowlisted relay only if the node is
    directly reachable. NATed nodes that serve clients need `everyone`.
  - **Install:** the release tarball pinned to the iroh version decdn builds against
    (`iroh_relay_version`, now 1.3.0), verified against a per-target sha256 in defaults
    (upstream signs nothing; the gnu triples, glibc 2.34+), or `manual`. Bump the
    version and every digest together.
  - **Config traps (iroh-relay 1.3.0 `main.rs`):** unknown TOML keys are ignored and a
    missing config file means built-in defaults (metrics on public `[::]:9090`, no
    TLS), so the template writes every key and the unit has
    `AssertPathExists=`/`AssertFileNotEmpty=` on it; QAD (udp/7842) is off unless
    `enable_quic_addr_discovery = true`; without `RUST_LOG` it logs errors only; it
    shuts down gracefully on SIGINT only (`KillSignal=SIGINT`). The molecule stub
    refuses keys `main.rs` does not define, which is what catches a template typo.
  - **Unit:** `DynamicUser`, `CAP_NET_BIND_SERVICE` only (ambient + bounding),
    `StateDirectory=iroh-relay iroh-relay/acme` for the Let's Encrypt account and
    certificates, `LimitNOFILE`.
  - **Gates:** the bind address is parsed with Python's `ipaddress` on the control
    machine (no `ansible.utils`), and `::` is refused where `net.ipv6.bindv6only=1`.
    Before any change, ports 80/443/metrics (and udp/7842 with QAD on) held by any
    process outside the relay unit's cgroup (the whole path) are refused
    (`tasks/ports.yml`; not by a MainPID read beforehand, which is 0 while the unit
    waits to restart, #113). After start, a fatal gate wants loopback
    `/metrics` answering, every listener owned by `MainPID`, and the same process
    still up after `iroh_relay_readiness_settle` seconds (the relay binds before it has
    a certificate, and an ACME failure does not stop it). Then a separate certificate
    check (`iroh_relay_certificate_check` warn/fail/skip) curls
    `https://<hostname>/healthz` on the relay's address (loopback for a wildcard bind)
    against the host trust store; `warn` fails too once the PRODUCTION certificate
    for this hostname is cached in the ACME dir (tokio-rustls-acme names it after the
    domain and the ACME directory URL, `vars/main.yml`), never in staging mode, whose
    certificates are never trusted. Restarts come from the templates' and the binary
    install's notifies and the restart-inputs record (config, unit, binary). The
    release stamp is `<version> <target> <pinned archive sha256> <binary sha256>`, so a
    corrected pin or a binary replaced in place is downloaded and verified again.
  - **Molecule:** `molecule/iroh-relay` (a molecule CA in place of Let's Encrypt; the
    stub's markers break each part of the gate), `iroh-relay-certificate` (the
    certificate check), `iroh-relay-gate` (the other gate refusals, QAD, binds and
    access modes; two hosts), `iroh-relay-lifecycle` (decommission) and
    `iroh-relay-install` (release mode against a local mirror), all on the same
    inventory (`make test-scripts` checks), and `validation-iroh-relay`.
  - **Compose:** the `relay` profile runs the same release from n0's image (see the
    `compose/` bullet). A bump of `iroh_relay_version` also bumps the image digest in
    `compose/compose.yaml` and the version its comment names (`make test-scripts`
    checks the name), and a new key in the role's template or stub goes into
    `RELAY_KEYS` in `compose/decdn-compose` (its unit tests compare them with the
    stub's).

- **`ansible/roles/iroh_dns_server`** — a self-hosted iroh DNS server
  (`iroh-dns-server` from n0-computer/iroh): the pkarr relay nodes publish their
  signed address records to (`PUT https://<hostname>/pkarr/<z32>`) and the DNS
  server peers resolve them through (`_iroh.<z32>.<origin>` TXT), in place of n0's
  `dns.iroh.link` (ADR 001, Node Discovery). Nodes use it through
  `decdn_discovery_pkarr_url` + `decdn_discovery_dns_origin`, which DROP the n0 leg,
  so clients need the same `dns_origin`. `playbooks/iroh_dns_server.yml` (`make
  deploy-dns`, also imported by `publisher.yml`) runs baseline → grafana_alloy →
  iroh_dns_server on `iroh_dns_server_hosts`, after a play refusing a host also in
  `iroh_relay_hosts` or `sponsord_onramp_hosts` (all want tcp/443; `make
  test-scripts` runs it). One server per origin: upstream has no replication, and
  `[mainline]` (off) is a lookup-only fallback that finds nothing for decdn nodes,
  which never publish to the DHT. The parent zone delegates `iroh_dns_server_hostname`
  to the host (NS + glue); the server answers that apex's NS/SOA/A itself
  (`iroh_dns_server_rr_a` defaults to the DNS bind address only when it is public).
  - **Install:** as `iroh_relay` (release tarball + per-target sha256, or `manual`;
    `iroh_dns_server_version` tracks the iroh decdn pins, now 1.3.0), except that the
    binary has **no `--version`**: a `--help` smoke run, and the stamp is written
    only after the gate saw `/healthz` report the pinned version.
  - **Config traps (iroh-dns-server 1.3.0):** unknown keys are ignored (the stub
    refuses them); `"."` must be an origin or it refuses to start; an origin without
    its trailing dot answers SOA but not its apex A/AAAA/NS, so the role qualifies
    every origin; it shuts down gracefully on SIGINT only; `RUST_LOG` unset logs
    errors only; `pkarr_put_rate_limit = "smart"` (X-Forwarded-For) behaves as
    `simple` upstream and is refused here (no proxy, so the header is forgeable).
  - **Ports:** the DNS listener takes ONE `bind_addr` for udp and tcp. The port guard
    (`tasks/ports.yml`, the relay's cgroup test) refuses foreign holders of 443 and
    the loopback ports on any address, and of port 53 only on the bind address or a
    wildcard (or anywhere, for a wildcard bind, naming `DNSStubListener=no` when
    resolved's stub is the holder). The role never touches the host's resolver.
  - **Gate:** loopback `/healthz` (version in release mode), metrics, every listener
    owned by `MainPID`, each origin's SOA via `dig` over udp and tcp at the bind
    address (loopback for a wildcard bind), the settle wait; then the relay's
    certificate check.
  - **Molecule:** `molecule/iroh-dns-server` (stub; a molecule CA for Let's Encrypt),
    `iroh-dns-server-gate`, `-certificate`, `-install` and `-lifecycle` on the same
    inventory (`make test-scripts` checks), and `validation-iroh-dns-server`. The
    real binary's record round-trip (PUT, then `dig TXT`) is a manual check, listed
    in the role README. No `monitoring/` assets yet.
  - **Compose:** the `dns` profile runs the same release from n0's image (see the
    `compose/` bullet). A bump of `iroh_dns_server_version` also bumps the image
    digest in `compose/compose.yaml`, the version its comment names and
    `DNS_VERSION` in `compose/decdn-compose` (`make test-scripts` checks both), and
    a new key in the role's template or stub goes into `DNS_KEYS` there (its unit
    tests compare them with the stub's).

- **`cloud-init/`** — the Ansible path with no control machine. Two templates, one per
  persona: `user-data-node.yaml` (node operators: a cache node) and
  `user-data-publisher.yaml` (publishers: an origin node + sponsord + onramp, deletable
  group by group), share stage 1 and differ only in their inventory. They carry only public material (the lint
  refuses secret-looking keys, credentials in URLs and unknown `bootstrap.env` keys)
  and a stage-1 `decdn-bootstrap`. That script clones this repo at a pinned ref (a full
  SHA is verified after checkout) and execs `cloud-init/bootstrap.sh`, which:
  - installs ansible-core from the hash-locked `requirements.txt` into a venv (two pins
    split by Python marker: 2.19 for Debian 12's 3.11, 2.21 for 3.12 and later);
  - installs the exact collections from `collections.lock.yml`;
  - runs `site.yml` (which imports `node.yml` and `publisher.yml`) against localhost. The inventory
    must put localhost in `decdn_nodes` and/or `sponsord_hosts` (and in
    `decdn_nodes` whenever it is in `decdn_origin_nodes`, in `sponsord_hosts` whenever
    it is in `sponsord_onramp_hosts`), or the plays match nothing and the firewall
    holes never load. The template lists an origin in `decdn_nodes` and
    `decdn_origin_nodes` as siblings (the lint refuses `children:`), and the lint
    requires an origin backend in `decdn_origin_nodes.vars`.

  Each group needs its secrets on the host first, at the role-default paths (the lint
  forbids moving them): `/etc/decdn/decdn.env` for a node (an origin's too, with an S3
  backend's keys; `decdn_origin_nodes` has no `SECRETS` of its own, so no `case` arm);
  `secret.env`, the treasury
  keystore and password, and (onramp) `turnstile-secret` under `/etc/sponsord/`. While
  any is missing it runs `--tags baseline` only, lists them in
  `/var/lib/decdn-bootstrap/awaiting` and records `awaiting-secret`. The operator
  writes them over SSH and re-runs `decdn-bootstrap` for the full playbook. Every
  service is `release`-installed with signature verification (pinned by the lint, in
  its own group's `vars`), and the node's wallet is host-generated. The roles are used
  unchanged, so a role change reaches this path without edits here. A new secret file
  in a role means a new entry in `bootstrap.sh`'s `SECRETS` and the lint's
  `FORBIDDEN_VARS`, its instructions in the per-group `case` that prints the next
  steps at the end of `bootstrap.sh`, and the README's table. A new group also needs
  its own `case` arm and a place in both `HOST_GROUPS` and lint.py's `GROUPS`
  (`make test-scripts` checks all three). The baseline-only run trusts every
  node.yml/origin.yml/sponsord.yml play to run `baseline` tagged `baseline` (checked
  per play at boot by `cloud-init/baseline-plays.sh`, for `decdn_origin_nodes` in place
  of `decdn_nodes` on an origin, whose play is origin.yml's; and by `make
  test-scripts`). The lint
  allows only the templates' top-level modules and no YAML anchors, so what it reads
  is what cloud-init and Ansible read. When `ansible/requirements.yml` changes, re-sync the lock:
  `make lint-cloud-init` checks it covers the requirements. The molecule `cloud-init`
  and `cloud-init-publisher` scenarios boot the real templates through cloud-init
  (skipping `baseline`) against a locally signed release mirror, built from the shared
  `molecule/cloud-init/pack.yml` and `includes/`. They are the only coverage of the node's and the
  onramp's release download and verify path.

- **`compose/`** — the node, the sponsor, an iroh relay, an iroh DNS server and Grafana Alloy under Docker Compose on one host. The
  node: the upstream image, always by digest (`compose.yaml` builds
  `DECDN_IMAGE_REPO@DECDN_IMAGE_DIGEST`), the role's host layout (`/etc/decdn`
  read-only, `/var/lib/decdn`), host networking (so loopback metrics/admin stay
  loopback and Docker publishes no ports), read-only rootfs, no capabilities, 300 s
  SIGTERM grace. Every service sits behind a profile (`COMPOSE_PROFILES` in `.env`):
  `node` and `origin` (both start the one `decdn-node`: a node operator's cache node,
  or a publisher's origin, whose `node.toml` carries `[cache.origin]`), `sponsord`,
  `onramp` (also starts `sponsord`), `caddy`, `relay`, `dns` and `alloy` (`relay` and
  `dns` each refused with one another, `onramp` or `caddy`: all want 443). The shared hardening (host network,
  read-only rootfs, `cap_drop: [ALL]`, `no-new-privileges`, SIGTERM, journald logging)
  is one `x-hardened` anchor merged by `<<: *hardened`; the lint checks the rendered
  result, so a service-level override is caught like an inline one. An fs origin's
  content is `DECDN_ORIGIN_DIR`, mounted read-only at the fixed `/srv/decdn-origin`.
  The node's healthcheck is `decdn node health` (the image ships the CLI since decdn
  v0.0.2).
  - **`decdn-compose`** (Python ≥ 3.11, stdlib only): every service command is plain
    `docker compose --project-directory compose/ -p decdn -f compose.yaml [-f
    compose.override.yaml]`, and it refuses to run while `.env` sets a `COMPOSE_*` key
    other than `COMPOSE_PROFILES` or the shell sets one or a variable `compose.yaml`
    interpolates (Compose would take those over `.env`, which is all its checks
    read). Values are checked as Compose renders them (`rendered_environments`), with
    `parse_env` as the fallback. `init` creates the accounts, dirs and host-generated
    secrets (node keys and `config init` through the node image's CLI, the API
    token, optionally the treasury wallet) and fills chain values from the generated
    `networks.yml` mirrors (`network_profile`, which parses their fixed shape: keep
    it, or update the parser); it never replaces a secret. `check` (also run by
    `up`) is the preflight, including `decdn config validate` with every URL in a
    failure redacted. An env file's values reach a CLI container through a root-only
    0600 copy (`--env-file`), never argv or the docker client's own environment; `cli` points on-chain commands at
    `decdn.env`'s endpoint through a config copy with `rpc_url = "${DECDN_RPC_URL}"`;
    `config` redacts every env-file value; loopback probes bypass any proxy. The top-up guard asks Compose itself whether an `up` recreates
    sponsord (`--dry-run up`): `config --hash` differs from the container label on
    older Compose. Running containers are found by Compose's labels (project
    `decdn`), not `compose ps`, which loads disabled services' env files.
    `make test-scripts` runs its unit tests; no CI job runs it end to end, so try a
    change in a throwaway `docker:27-dind` (privileged) with a `compose.override.yaml`
    that sets a non-journald logging driver.
  - **sponsord / onramp:** the roles' `/etc/sponsord/` layout, except that the
    credential files belong to a host `sponsord` account (a Compose secret is a bind
    mount, which keeps owner and mode, and upstream rejects a group-readable
    keystore). They reach the containers as Compose `secrets:` (`file:` sources
    only, read-only, one each, in `/run/secrets/`; a missing file fails the start).
    Listeners and secret paths are set in `environment:`, which beats env files,
    because the release images default to `0.0.0.0`.
  - **Onramp entrypoint:** upstream serves whatever `ONRAMP_GATE_TEMPLATE` names, and
    the container also mounts the daemon token and the Turnstile secret, so the
    onramp starts through a `/bin/sh` check that the path resolves into
    `/etc/sponsord/onramp-gate/`, then a flagless `exec`. `invariants.jq` pins that
    script byte for byte (`onramp_entrypoint`): change both together.
  - **Caddy:** the official image by digest, non-root, keeping only
    `NET_BIND_SERVICE`. `compose/Caddyfile` is a hand-kept copy of the role's
    `Caddyfile.j2`: change one, change both.
  - **iroh relay (`relay`):** n0's `n0computer/iroh-relay` image (musl, Alpine;
    unsigned upstream) pinned in `compose.yaml` by its multi-arch index digest at
    the role's `iroh_relay_version`; uid 0 with `NET_BIND_SERVICE` only (hard rule
    2's Compose exception), `stop_signal: SIGINT` (as PID 1 it ignores SIGTERM
    outright), `ulimits.nofile`, the config a read-only single-file bind
    (`/etc/iroh-relay/iroh-relay.toml`, from `compose/iroh-relay.toml.example`,
    which writes every key the role's template does) and `/var/lib/iroh-relay` (ACME
    state) the only writable mount. iroh-relay ignores unknown keys and runs on
    public defaults without a config, so `check` parses it (`tomllib`) and refuses
    unknown keys (`RELAY_KEYS`), metrics off loopback, a `cert_dir` outside the
    mount, placeholders, a reserved-domain contact (Let's Encrypt refuses it), an
    empty allowlist and `[::]` under `bindv6only=1`. `health` is the role's gate
    (loopback `/metrics` with `relayserver_accepts_total`) plus its certificate
    check (warn-only with `prod_tls = false`).
  - **iroh DNS server (`dns`):** the relay's pattern with n0's
    `n0computer/iroh-dns-server` (`--config`, `/etc/iroh-dns-server/config.toml` from
    `compose/iroh-dns-server.toml.example`, `/var/lib/iroh-dns-server` as
    `data_dir`). `init dns` binds DNS to one address, the default route's IPv4
    (`--dns-bind`), so resolved's `127.0.0.53` stub keeps working, and writes `rr_a`
    from it only when public (`--public-ipv4` behind NAT). `check` refuses unknown
    keys (`DNS_KEYS`), an origin without its trailing dot or no `"."`, `"smart"`
    rate limiting, `[http]`/`[metrics]` off loopback and a missing or private
    `rr_a`; its port guard is address-aware for 53 (`dns_port_problems`, the
    role's `ports.yml`: a wildcard bind beside resolved's stub names
    `DNSStubListener=no`). `health`: loopback `/healthz` must report `DNS_VERSION`
    (unless `.env` overrides the digest), each origin's SOA via `dig` over udp and
    tcp (skipped with a warning without `dig`), then the certificate.
  - **Alloy (`alloy` profile):** `grafana/alloy` by its index digest (the comment
    names the tag; `make test-scripts` checks it is `grafana_alloy_version`), the
    role's command (UI on `127.0.0.1:12345`), as a host `alloy` account plus
    `group_add` of the host's `systemd-journal` gid, no capability. It mounts the host
    read-only (`/proc`, `/sys`, `/` at `/host/root` with `rslave`, the journal dirs,
    `/etc/machine-id`), the generated `alloy/config.alloy`, and `/var/lib/alloy`
    read-write. The token and endpoints come from the role's own
    `/etc/grafana-alloy.env` (`ALLOY_ENV_FILE`, an env file, so never inline: the
    `inline-env.jq` allow-list is the identity keys and `DECDN_COMPOSE_PROFILES:
    ${COMPOSE_PROFILES:-}`). `/var/log/journal` is never created (that would switch
    journald to persistent storage); the wrapper refuses without it. KICS flags the
    `rslave` propagation HIGH (query `baa452f0`, excluded with its reason in the
    root `Makefile`; `invariants.jq` refuses propagation on any other mount).
  - **No `${VAR:?}`:** Compose interpolates disabled services too, so a required
    variable would break other profiles. An unset variable renders a value its
    service refuses instead (invalid image reference, unknown user, a domain with a
    non-numeric port).
  - **Gates:** `make lint-compose` renders with `--profile '*'` under `env -i`, three
    times:
    - with the example `.env`, against `compose/tests/invariants.jq`: allowed keys
      and exact mounts per service, so `privileged`, `pid: host` or an extra mount
      fail;
    - with every service env file pointed at `/dev/null`, against
      `compose/tests/inline-env.jq`: an allow-list of inline env keys, so no RPC URL
      lands in the tracked file;
    - with an empty `.env`, against `compose/tests/fail-closed.jq`.

    All print `<service>: <invariant>` per violation; `make test-scripts` pins which
    one fires for each broken variant (`LINT_COMPOSE_FILE`, not Compose's own
    `COMPOSE_FILE`). `make security` scans it.
  - **The allow-lists are deliberate friction.** A new key, mount or inline env var
    in `compose.yaml` fails the lint until it is added to the matching list in
    `compose/tests/*.jq`, and the PR should say why. Env var names follow upstream
    `decdn/sponsord` (`crates/*/src/config.rs`); re-check them when bumping images.
  - **CI's Compose is older than a dev box's.** The runner's release mishandled
    `config --no-env-resolution` (v2.33 lacks it), which is why the inline-env render
    uses `/dev/null` env files instead. Before relying on a newer `config` flag, try
    it under an older release: `docker run --rm -v "$PWD:/w" -w /w docker:27-cli
    docker compose …`.

- **`charts/decdn-node/`** — the same node on Kubernetes: a one-replica StatefulSet (one
  release = one identity) on the upstream `decdn-node` image (`ghcr.io/decdn/decdn-node`,
  tag `appVersion` = the role's `decdn_node_version` unless `image.tag`/`image.digest`
  is set), PVC data dir, a `prepare` init
  container that installs the identity files from an `existingSecret` onto the PVC at
  `0600` (upstream rejects symlinked or group/world-readable key files) and the password
  into an in-memory volume, `DECDN_RPC_URL` via `secretKeyRef` (named keys only), public
  UDP Service (LoadBalancer/NodePort/ClusterIP) or `hostPort`, and metrics bound `0.0.0.0`
  behind a ClusterIP Service + NetworkPolicy. `values.config` mirrors `node.toml`; the
  chart injects the path/port keys and fails on collisions. **The config-schema coupling
  above applies here too:** `make lint-helm` runs the same `check-schema-keys.py` +
  `schema-keys.txt` on the rendered ConfigMap, so a re-sync covers both paths. Unlike the
  role, CI has no real-binary `decdn config validate` for the chart — run
  `DECDN_CLI=… make lint-helm` locally when bumping the decdn version. Optional
  `PrometheusRule` + dashboard ConfigMaps render `files/monitoring/`, the symlink to
  `monitoring/decdn-node/` (never through `tpl`:
  the alert annotations carry Prometheus templates).

## Commands

Two Makefiles: the **root** is the check driver CI calls (`make help`); **`ansible/`**
drives deploys (its targets must run from `ansible/`). The full target list is in
[CONTRIBUTING.md](CONTRIBUTING.md#make-targets).

```bash
# Root — the gates (CI runs the same)
make lint             # every pre-commit hook, every file (also the CI `pre-commit` job)
make lint-ansible     # vendor collections + ansible-lint (production profile)
make molecule         # every ansible/molecule/*/ scenario in parallel (Docker; JOBS=<n>, SCENARIOS='a b')
make lint-helm        # chart: lint + render tests + kubeconform + promtool + schema keys
make lint-alloy       # grafana_alloy config against the real pinned Alloy binary
make lint-compose     # compose/ invariants (three renders, compose/tests/*.jq)
make lint-cloud-init  # cloud-init/user-data*.yaml: schema + invariants (no secrets, release mode, lock)
make test-scripts     # Makefile/molecule-driver guards, release gate, lint-compose/lint-cloud-init negatives, decdn-compose unit tests
make security         # KICS over ansible/, the rendered chart and compose/

# Ansible — run from ansible/
make deps                          # vendor pinned Galaxy collections
make check / deploy                # site.yml; fleet-wide unless LIMIT=<host>; INVENTORY=<overlay>
make check-node / deploy-node      # node.yml only (node operators: cache nodes)
make check-publisher / deploy-publisher # publisher.yml only (origins, sponsord, relays, DNS)
make check-origin / deploy-origin  # origin.yml only (decdn_origin_nodes)
make check-sponsord / deploy-sponsord   # sponsord.yml only (sponsord_hosts)
make check-relay / deploy-relay         # iroh_relay.yml only (iroh_relay_hosts)
make check-dns / deploy-dns             # iroh_dns_server.yml only (iroh_dns_server_hosts)
make backup / decommission LIMIT=… # lifecycle playbooks (decommission requires LIMIT)
make build / galaxy-check          # both collections (build-node, galaxy-check-publisher, … for one)
```

**Inventory is private; the firewall hole is not.** This repo is public, so
`ansible/inventory/hosts.yml` is git-ignored and a real fleet lives in a private overlay.
Inventory-adjacent group_vars do not load for an overlay, so anything every host needs
regardless of inventory lives in `ansible/playbooks/group_vars/`. The public firewall holes
(`baseline_extra_inbound`, today the node's udp/4433 (an origin's too), plus tcp/80 + tcp/443 on
`sponsord_onramp_hosts` with `sponsord_onramp_proxy: caddy`, tcp/80 + tcp/443 + udp/7842
on `iroh_relay_hosts`, the last unless `iroh_relay_enable_quic_addr_discovery` is false,
and tcp/443 + udp/53 + tcp/53 on `iroh_dns_server_hosts`) are built from a host's groups in
`all.yml` (`_baseline_service_inbound`). `decdn_nodes.yml`, `decdn_origin_nodes.yml`,
`sponsord_hosts.yml`, `iroh_relay_hosts.yml` and `iroh_dns_server_hosts.yml` all set
`baseline_extra_inbound` to that list, so a co-located host renders one firewall in
every play.
`ansible/tests/firewall-holes/` (run by `make test-scripts`) pins the result per host shape.
The Alloy per-daemon toggles also live in `all.yml`. Don't move any of it back under
`inventory/`.

**Galaxy collections (`decdn.node`, `decdn.publisher`).** The seven roles ship as two
distributable collections, split by persona: `decdn.node` (`baseline` + `decdn_node` +
`grafana_alloy`, what a node operator runs and a publisher's origin nodes) and
`decdn.publisher` (`sponsord` + `sponsord_onramp` + `iroh_relay` + `iroh_dns_server`,
which depends on `decdn.node`). Each overlay lives in `ansible/galaxy/<collection>/`, with
`roles.txt` as the one role list (`galaxy/build.sh` and `scripts/release.sh` both read it;
`make test-scripts` checks every role ships in exactly one), and is staged into a clean
collection tree by `galaxy/build.sh <collection>` — there is **no** `galaxy.yml` at the
`ansible/` root (that would make ansible-lint treat the deploy project as a collection).
A new role goes in one `roles.txt`. Build/validate from `ansible/` with `make build` /
`make galaxy-check` (both; `-node`/`-publisher` suffixes for one; the root's
`galaxy-build`/`galaxy-check` run both). **Publishing** is per artifact, each on
its own version: `release-collection.yml` on a `node-collection-vX.Y.Z` or
`publisher-collection-vX.Y.Z` tag (the repo's Latest follows `decdn.node`; release.sh
refuses a publisher release until a node tag satisfies its `decdn.node` constraint), `release-chart.yml` on a
`decdn-node-X.Y.Z` tag (that file name and tag prefix are the chart's cosign identity:
never rename them), and only while the `PUBLISH_ENABLED` repository variable is `true`
(RELEASING.md). The chart's publish also pushes its
Artifact Hub metadata (`charts/decdn-node/artifacthub-repo.yml`, `.helmignore`d), and
the packaged `Chart.yaml` gets an `artifacthub.io/changes` annotation generated from the
release's chart CHANGELOG section (`scripts/chart-artifacthub-changes.py`): never write
that annotation by hand. **Releases are cut on `main` by `scripts/release.sh`** (a
git-cliff wrapper, dry run unless `--execute`; RELEASING.md): it bumps the manifest,
generates the dated section of `ansible/galaxy/<collection>/CHANGELOG.md` or
`charts/decdn-node/CHANGELOG.md` from the conventional commit subjects since the
artifact's tag (`cliff.toml`), and pushes a signed `chore(release)` commit and tag, with
no release PR. The repo squash-merges with the PR title as the subject, so the PR title
is the changelog entry (`pr-title.yml` checks it is conventional); release.sh refuses a
commit that touched the artifact and that git-cliff cannot parse as conventional, unless
`--allow-unconventional`. Until an artifact's first release, its manifest stays at
the `0.0.0` placeholder and its changelog changes are logged by hand under
`[Unreleased]`, which becomes the first release's section; after it, do not edit the
changelogs by hand.

**CI.** `ci.yml` is the blocking gate: `pre-commit`, `scripts` and `actionlint` on every PR, the
Ansible, chart, compose and cloud-init jobs path-filtered, KICS on the first three (KICS has
no cloud-init platform); `pr-title.yml` checks PR titles are Conventional Commits (they
become the changelog); `molecule.yml` runs the molecule suite on `ansible/**`,
`cloud-init/**` and `scripts/molecule.sh`, one runner per scenario (matrix from `make molecule-list`), with the
`molecule` job as the single aggregate check. `ansible-lint` is **not** a per-commit hook (it needs
collections vendored): run `make lint-ansible`.

**Molecule runs share the host's Docker daemon.** Scenario container names are
fixed, so `scripts/molecule.sh` (behind `make molecule`) takes a host-wide lock per
scenario: another agent running a *different* scenario does not block you, the
*same* one refuses to start (exit 75). Run what you changed with
`make molecule SCENARIOS='…'` rather than bare `molecule test -s`, which skips the
lock. A scenario that grows slow is split along its side effects into a sibling
that reuses its prepare/converge/verify by path, with an identical inventory
(`make test-scripts` checks the pairs); add the sibling to `SLOW_FIRST` in
`ansible/Makefile` when it is among the slowest.
