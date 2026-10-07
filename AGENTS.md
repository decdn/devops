# AGENTS.md — decdn-devops

Guidance for AI coding agents (Claude Code, Codex, Cursor, …) working in the deCDN
DevOps repo.

## What this repo is

The official DevOps project for deploying a **deCDN node**: infrastructure, deployment,
and operational tooling, for node operators anywhere. There are four deploy paths:
**Ansible** (`ansible/`, VMs/bare metal, the primary path, also the `decdn.node` Galaxy
collection), **cloud-init** (`cloud-init/`, one VM that runs the Ansible playbook on
itself, no control machine), **Docker Compose** (`compose/`, a single Docker host) and a
**Helm chart** (`charts/decdn-node/`, Kubernetes).

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
   **Kubernetes exception (chart only):** the node's metrics bind `0.0.0.0` inside the pod
   so kubelet probes and Prometheus can reach them. That is allowed only behind a
   ClusterIP-only Service and the chart's NetworkPolicy (metrics ingress limited to
   `metrics.networkPolicy.from`); disabling the policy fails the render unless
   `networkPolicy.allowUnrestrictedMetrics=true` acknowledges it. Never front metrics with
   a LoadBalancer/NodePort/Ingress.
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
  playbooks/            # site.yml (decdn node + sponsord), sponsord.yml (+ onramp), backup.yml, decommission.yml (node + sponsord)
  roles/                # baseline, decdn_node, grafana_alloy, sponsord, sponsord_onramp
  inventory/ galaxy/ molecule/    # see ansible/README.md
cloud-init/             # user-data{,-sponsord}.yaml + on-host bootstrap.sh; pinned ansible-core/collections (see its README.md)
compose/                # Docker Compose deploy path for a single host (see its README.md)
  compose.yaml          # profiles: node, sponsord, onramp (+ sponsord), caddy
  Caddyfile             # mirrors roles/sponsord_onramp/templates/Caddyfile.j2
  tests/*.jq            # lint-compose: invariants, inline-env, fail-closed
charts/
  decdn-node/           # Helm chart for the node on Kubernetes (see its README.md)
    ci/                 # CI values files (mirror molecule/schema's three plays)
    files/monitoring/   # Grafana dashboards + Prometheus alert rules (maintained here)
    tests/render-test.sh  # positive/negative render tests (`make lint-helm`)
docs/                   # cross-path operator docs: requirements.md, lifecycle.md
scripts/                # upstream-mirror generators, the release gate, the molecule driver (molecule.sh)
```

**Generated mirrors of upstream — regenerate, never hand-edit:**
`ansible/roles/decdn_node/vars/main/networks.yml` and its subsets
`ansible/roles/sponsord/vars/main/networks.yml` and
`ansible/roles/sponsord_onramp/vars/main/networks.yml` (all `scripts/sync-network-profiles.py`)
and `ansible/molecule/schema/files/schema-keys.txt` (`gen-schema-keys.py`). The weekly
`upstream-drift` workflow flags staleness. These are the only protocol facts (contract
addresses) the repo carries, and they carry their upstream commit.

**Monitoring assets are maintained here, by hand.** `charts/decdn-node/files/monitoring/`
holds the deCDN Grafana dashboards and Prometheus alert rules; upstream ships none. Every
`decdn_*` series a panel or rule names must be one `decdn-node` exports — check the
node's `/metrics` and upstream's `adr/appendix-observability.md` registry (a `planned`
row emits nothing). Nothing in CI checks the names, so a typo renders `(no data)` or a
rule that never fires. See `.claude/skills/grafana-dashboards/SKILL.md`. sponsord's pair
lives in its `sponsord/` subdirectory, which the chart does not render; its `sponsord_*`
names must be ones upstream `decdn/sponsord` `crates/sponsord/src/metrics.rs` exports,
and its rules have promtool unit tests (`charts/decdn-node/tests/sponsord-alerts_test.yml`).

## Current services

- **`ansible/`** — the declarative deployment project. **The public deCDN node**
  (`playbooks/site.yml` → baseline + `decdn-node`), installed by `decdn_node_install_method`:
  `release` (the default) — a pinned GitHub release tarball verified against the
  release's GPG-signed `SHA256SUMS` (upstream has cut no tag yet, so this needs a mirror
  for now); `source` — a git ref (any tag/branch/SHA) cloned and `cargo build`-ed **on the
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
  (decdn_node) and `molecule/sponsord-onramp-source` (both sponsord
  roles); or `manual` — binaries built on the control machine. Each method clears
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
  with one confirmation per run, in the first play that reaches a host, whose prompt
  lists every service it covers (`_decdn_decommission_confirmed`; the
  `decdn_decommission_*` cap and timeout are copied into all three roles' defaults,
  `make test-scripts` checks).
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

- **`ansible/roles/sponsord`** — the deCDN onboarding sponsor (`decdn/sponsord`): the
  treasury wallet's signer for capped capabilities plus the PaymentPool keeper. It is
  independent of the node, so `playbooks/sponsord.yml` (`make deploy-sponsord`, also
  imported by `site.yml`) targets its own `sponsord_hosts` group, standalone or
  co-located with a node.
  - **Install:** a GPG-verified `sponsord-v*` release by default (none cut yet), a
    host-side `source` build, or a manual binary.
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
    overrides it (pass it as JSON). Compose cannot guard itself; its README has the
    manual check.
  - **Alloy toggles:** `playbooks/group_vars/all.yml` derives
    `grafana_alloy_node_enabled` / `grafana_alloy_sponsord_enabled` from group
    membership. They are host-scoped so a co-located host's two plays render one
    config.
  - **Molecule:** under docker, `/` must be `--make-rshared` (see
    `molecule/sponsord/prepare.yml`) or every credential directory is empty.
  - **cloud-init:** `cloud-init/user-data-sponsord.yaml` (with the onramp), release
    mode only; see the `cloud-init/` bullet below.

- **`ansible/roles/sponsord_onramp`** — `sponsord-onramp`, sponsord's public side (the
  Turnstile gate, the installers, the `decdn-sponsored` CLI API), as a second play of
  `playbooks/sponsord.yml` on `sponsord_onramp_hosts` (which must also be in
  `sponsord_hosts`: it reads the daemon's `/etc/sponsord/api-token` and calls it on
  loopback). The playbook's first play enforces that membership (tested by
  `make test-scripts`); the role checks no group name, so collection users keep their
  own groups, and its token gate and `/healthz` fail without a daemon.
  - **Install / unit / gate:** the sponsord role's patterns, copied: a
    GPG-verified `sponsord-onramp-v*` release (default), `source` or manual (the
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
    (ACME, `none`, a foreign Caddyfile) on the same converge.

- **`cloud-init/`** — the Ansible path with no control machine. Two templates,
  `user-data.yaml` (a node) and `user-data-sponsord.yaml` (sponsord + onramp), share
  stage 1 and differ only in their inventory. They carry only public material (the lint
  refuses secret-looking keys, credentials in URLs and unknown `bootstrap.env` keys)
  and a stage-1 `decdn-bootstrap`. That script clones this repo at a pinned ref (a full
  SHA is verified after checkout) and execs `cloud-init/bootstrap.sh`, which:
  - installs ansible-core from the hash-locked `requirements.txt` into a venv (two pins
    split by Python marker: 2.19 for Debian 12's 3.11, 2.21 for 3.12 and later);
  - installs the exact collections from `collections.lock.yml`;
  - runs `site.yml` (which imports `sponsord.yml`) against localhost. The inventory
    must put localhost in `decdn_nodes` and/or `sponsord_hosts` (and in
    `sponsord_hosts` whenever it is in `sponsord_onramp_hosts`), or the plays match
    nothing and the firewall holes never load.

  Each group needs its secrets on the host first, at the role-default paths (the lint
  forbids moving them): `/etc/decdn/decdn.env` for a node; `secret.env`, the treasury
  keystore and password, and (onramp) `turnstile-secret` under `/etc/sponsord/`. While
  any is missing it runs `--tags baseline` only, lists them in
  `/var/lib/decdn-bootstrap/awaiting` and records `awaiting-secret`. The operator
  writes them over SSH and re-runs `decdn-bootstrap` for the full playbook. Every
  service is `release`-installed with signature verification (pinned by the lint, in
  its own group's `vars`), and the node's wallet is host-generated. The roles are used
  unchanged, so a role change reaches this path without edits here. A new secret file
  in a role means a new entry in `bootstrap.sh`'s `SECRETS` and the lint's
  `FORBIDDEN_VARS`. When `ansible/requirements.yml` changes, re-sync the lock:
  `make lint-cloud-init` checks it covers the requirements. The molecule `cloud-init`
  and `cloud-init-sponsord` scenarios boot the real templates through cloud-init
  (skipping `baseline`) against a locally signed release mirror, built from the shared
  `molecule/cloud-init/includes/`. They are the only coverage of the node's and the
  onramp's release download and verify path.

- **`compose/`** — the node and the sponsor under Docker Compose on one host. The
  node: the upstream image, always by digest (`compose.yaml` builds
  `DECDN_IMAGE_REPO@DECDN_IMAGE_DIGEST`), the role's host layout (`/etc/decdn`
  read-only, `/var/lib/decdn`), host networking (so loopback metrics/admin stay
  loopback and Docker publishes no ports), read-only rootfs, no capabilities, 300 s
  SIGTERM grace. Every service sits behind a profile (`COMPOSE_PROFILES` in `.env`):
  `node`, `sponsord`, `onramp` (also starts `sponsord`) and `caddy`.
  - **sponsord / onramp:** the roles' `/etc/sponsord/` layout, except that the
    credential files belong to a host `sponsord` account (bind mounts keep owner and
    mode, and upstream rejects a group-readable keystore). They are mounted
    read-only one by one into `/run/secrets/`. Listeners and secret paths are set in
    `environment:`, which beats env files, because the release images default to
    `0.0.0.0`.
  - **Onramp entrypoint:** upstream serves whatever `ONRAMP_GATE_TEMPLATE` names, and
    the container also mounts the daemon token and the Turnstile secret, so the
    onramp starts through a `/bin/sh` check that the path resolves into
    `/etc/sponsord/onramp-gate/`, then a flagless `exec`. `invariants.jq` pins that
    script byte for byte (`onramp_entrypoint`): change both together.
  - **Caddy:** the official image by digest, non-root, keeping only
    `NET_BIND_SERVICE`. `compose/Caddyfile` is a hand-kept copy of the role's
    `Caddyfile.j2`: change one, change both.
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
  release = one identity) on the upstream daemon-only image (`ghcr.io/decdn/decdn-node`;
  unpublished, so `image.tag`/`image.digest` is required), PVC data dir, a `prepare` init
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
  `PrometheusRule` + dashboard ConfigMaps render `files/monitoring/` (never through `tpl`:
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
make test-scripts     # Makefile/molecule-driver guards, release gate, lint-compose/lint-cloud-init negatives
make security         # KICS over ansible/, the rendered chart and compose/

# Ansible — run from ansible/
make deps                          # vendor pinned Galaxy collections
make check / deploy                # site.yml; fleet-wide unless LIMIT=<host>; INVENTORY=<overlay>
make check-sponsord / deploy-sponsord   # sponsord.yml only (sponsord_hosts)
make backup / decommission LIMIT=… # lifecycle playbooks (decommission requires LIMIT)
make build / galaxy-check          # the decdn.node collection
```

**Inventory is private; the firewall hole is not.** This repo is public, so
`ansible/inventory/hosts.yml` is git-ignored and a real fleet lives in a private overlay.
Inventory-adjacent group_vars do not load for an overlay, so anything every host needs
regardless of inventory lives in `ansible/playbooks/group_vars/`. The public firewall holes
(`baseline_extra_inbound`, today the node's udp/4433, plus tcp/80 + tcp/443 on
`sponsord_onramp_hosts` with `sponsord_onramp_proxy: caddy`) are built from a host's groups in
`all.yml` (`_baseline_service_inbound`). `decdn_nodes.yml` and `sponsord_hosts.yml` both set
`baseline_extra_inbound` to that list, so a co-located host renders one firewall in every play.
`ansible/tests/firewall-holes/` (run by `make test-scripts`) pins the result per host shape.
The Alloy per-daemon toggles also live in `all.yml`. Don't move any of it back under
`inventory/`.

**Galaxy collection (`decdn.node`).** The five roles (`baseline` + `decdn_node` +
`grafana_alloy` + `sponsord` + `sponsord_onramp`) ship as a
distributable collection. The overlay lives in `ansible/galaxy/` and is staged into a clean
collection tree by `galaxy/build.sh` — there is **no** `galaxy.yml` at the `ansible/` root
(that would make ansible-lint treat the deploy project as a collection). Build/validate with
`make build` / `make galaxy-check`. **Publishing** is `release.yml` on a `vX.Y.Z` tag,
together with the chart at the same version, and only while the `PUBLISH_ENABLED`
repository variable is `true` (RELEASING.md). Log changes under `[Unreleased]` in
`ansible/galaxy/CHANGELOG.md` and `charts/decdn-node/CHANGELOG.md`.

**CI.** `ci.yml` is the blocking gate: `pre-commit`, `scripts` and `actionlint` on every PR, the
Ansible, chart, compose and cloud-init jobs path-filtered, KICS on the first three (KICS has
no cloud-init platform); `molecule.yml` runs the molecule suite on `ansible/**`,
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
