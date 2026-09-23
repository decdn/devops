# AGENTS.md — decdn-devops

Guidance for AI coding agents (Claude Code, Codex, Cursor, …) working in the deCDN
DevOps repo.

## What this repo is

The official DevOps project for deploying a **deCDN node**: infrastructure, deployment,
and operational tooling, for node operators anywhere. There are three deploy paths:
**Ansible** (`ansible/`, VMs/bare metal, the primary path, also the `decdn.node` Galaxy
collection), **Docker Compose** (`compose/`, a single Docker host) and a **Helm chart**
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
   and admin RPC). A service that must accept public traffic declares exactly one hole (the
   node's QUIC udp/4433) via `baseline_extra_inbound`; if a service ever needs an HTTP-facing
   public path, front it with an explicit reverse proxy that terminates auth + TLS. Never
   bind a *backend* to `0.0.0.0` or expose its raw port.
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
  playbooks/            # site.yml (decdn node), backup.yml, decommission.yml
  roles/                # baseline, decdn_node, grafana_alloy
  inventory/ galaxy/ molecule/    # see ansible/README.md
compose/                # Docker Compose deploy path for a single host (see its README.md)
charts/
  decdn-node/           # Helm chart for the node on Kubernetes (see its README.md)
    ci/                 # CI values files (mirror molecule/schema's three plays)
    files/monitoring/   # GENERATED: upstream dashboards + alert rules (scripts/sync-monitoring.sh)
    tests/render-test.sh  # positive/negative render tests (`make lint-helm`)
docs/                   # cross-path operator docs: requirements.md, lifecycle.md
scripts/                # upstream-mirror generators + the release gate
```

**Generated mirrors of upstream — regenerate, never hand-edit:**
`ansible/roles/decdn_node/vars/main/networks.yml` (`scripts/sync-network-profiles.py`),
`charts/decdn-node/files/monitoring/` (`scripts/sync-monitoring.sh`) and
`ansible/molecule/schema/files/schema-keys.txt` (`gen-schema-keys.py`). The weekly
`upstream-drift` workflow flags staleness. These are the only protocol facts (contract
addresses) the repo carries, and they carry their upstream commit.

## Current services

- **`ansible/`** — the declarative deployment project. **The public deCDN node**
  (`playbooks/site.yml` → baseline + `decdn-node`), installed from a pinned GitHub release
  tarball — verified against the release's GPG-signed `SHA256SUMS` — or, while upstream
  has no release tag cut (the current default), from locally-built binaries; under a hardened
  systemd unit; public QUIC udp/4433, loopback metrics/admin, operator-provisioned eth
  keystore, operator-provisionable secret env file, over a shared DevSec-hardened
  `baseline`. The release target triple is derived from the host's architecture
  (x86_64/aarch64). The chain comes from `decdn_network` (the generated manifest mirror
  above; explicit inventory addresses still win) or from explicit variables.
  `playbooks/backup.yml` / `decommission.yml` (`make backup` / `make decommission`) are
  role entry points (`tasks_from: backup|decommission`): backups are encrypted on the host
  to operator public keys; decommission needs `LIMIT` + typed confirmation, keeps the
  identity and never touches the chain.
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
  so Grafana Cloud's prebuilt Linux Server dashboards work unmodified. The API token is the
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

- **`compose/`** — the same node under Docker Compose on one host: the upstream image by
  digest, the role's host layout (`/etc/decdn` read-only, `/var/lib/decdn`), host
  networking (so loopback metrics/admin stay loopback and Docker publishes no ports),
  read-only rootfs, no capabilities, 300 s SIGTERM grace. `make lint-compose` asserts
  those invariants; `make security` scans it.

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
  `PrometheusRule` + dashboard ConfigMaps render the vendored `files/monitoring/` (never
  through `tpl`: the alert annotations carry Prometheus templates).

## Commands

Two Makefiles: the **root** is the check driver CI calls (`make help`); **`ansible/`**
drives deploys (its targets must run from `ansible/`). The full target list is in
[CONTRIBUTING.md](CONTRIBUTING.md#make-targets).

```bash
# Root — the gates (CI runs the same)
make lint             # every pre-commit hook, every file (also the CI `pre-commit` job)
make lint-ansible     # vendor collections + ansible-lint (production profile)
make molecule         # every ansible/molecule/*/ scenario in parallel (Docker; JOBS=<n>)
make lint-helm        # chart: lint + render tests + kubeconform + schema keys
make lint-alloy       # grafana_alloy config against the real pinned Alloy binary
make lint-compose     # compose/ invariants
make security         # KICS over ansible/, the rendered chart and compose/

# Ansible — run from ansible/
make deps                          # vendor pinned Galaxy collections
make check / deploy                # site.yml; fleet-wide unless LIMIT=<host>; INVENTORY=<overlay>
make backup / decommission LIMIT=… # lifecycle playbooks (decommission requires LIMIT)
make build / galaxy-check          # the decdn.node collection
```

**Inventory is private; the firewall hole is not.** This repo is public, so
`ansible/inventory/hosts.yml` is git-ignored and a real fleet lives in a private overlay
(template: `ansible/inventory/fleet.example/`). Inventory-adjacent group_vars do not load for an
overlay, so anything every node needs regardless of inventory (today only the udp/4433
`baseline_extra_inbound` hole) lives in `ansible/playbooks/group_vars/decdn_nodes.yml`.
Don't move it back under `inventory/`.

**Galaxy collection (`decdn.node`).** The three roles (`baseline` + `decdn_node` +
`grafana_alloy`) ship as a
distributable collection. The overlay lives in `ansible/galaxy/` and is staged into a clean
collection tree by `galaxy/build.sh` — there is **no** `galaxy.yml` at the `ansible/` root
(that would make ansible-lint treat the deploy project as a collection). Build/validate with
`make build` / `make galaxy-check`. **Publishing** is `release.yml` on a `vX.Y.Z` tag,
together with the chart at the same version, and only while the `PUBLISH_ENABLED`
repository variable is `true` (RELEASING.md). Log changes under `[Unreleased]` in
`ansible/galaxy/CHANGELOG.md` and `charts/decdn-node/CHANGELOG.md`.

**CI.** `ci.yml` is the blocking gate: `pre-commit` and `actionlint` on every PR, the
Ansible, chart and compose jobs path-filtered, KICS on any of them; `molecule.yml` runs the
molecule suite on `ansible/**`. `ansible-lint` is **not** a per-commit hook (it needs
collections vendored): run `make lint-ansible`.
