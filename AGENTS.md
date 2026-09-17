# AGENTS.md — decdn-devops

Guidance for AI coding agents (Claude Code, Codex, Cursor, …) working in the deCDN
DevOps repo.

## What this repo is

The official DevOps project for deploying a **deCDN node**: infrastructure, deployment,
and operational tooling. There are two deploy paths: **Ansible** (`ansible/`, VMs/bare
metal, the primary path) and a **Helm chart** (`charts/decdn-node/`, Kubernetes).

This repo is **infrastructure only**. It is *not* a source of truth for protocol or
economic claims — those trace to the deCDN ADRs. If something here states a protocol fact
(chain-id, token address, fee split), it must trace back to an ADR, not invent one.

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
  playbooks/            # site.yml (decdn node)
  roles/                # baseline, decdn_node, grafana_alloy
  inventory/ galaxy/ molecule/    # see ansible/README.md
charts/
  decdn-node/           # Helm chart for the node on Kubernetes (see its README.md)
    ci/                 # CI values files (mirror molecule/schema's three plays)
    tests/render-test.sh  # positive/negative render tests (`make lint-helm`)
```

## Current services

- **`ansible/`** — the declarative deployment project. **The public deCDN node**
  (`playbooks/site.yml` → baseline + `decdn-node`), installed from a pinned GitHub release
  tarball — verified against the release's GPG-signed `SHA256SUMS` — or, while upstream
  has no release tag cut (the current default), from locally-built binaries; under a hardened
  systemd unit; public QUIC udp/4433, loopback metrics/admin, operator-provisioned eth
  keystore, operator-provisionable secret env file, and required chain knobs (no baked
  protocol facts — sourced from ADRs), over a shared DevSec-hardened `baseline`.
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
  so Grafana Cloud's prebuilt Linux Server dashboards work unmodified. Only the API token
  is host-provisioned (`0600 /etc/grafana-alloy.env`, read via `sys.env` — Alloy has no
  `--config.expand-env`); the non-secret endpoints/instance IDs are inventory variables
  that fall back to their `GC_…` env key when empty, and preflight refuses a token in any
  of them. Two hardening relaxations are conditional on the signals being on
  (`ProtectHome=read-only` for correct filesystem metrics, `SupplementaryGroups=
  systemd-journal adm` for journal access — without which collection is silently empty);
  teardown is gated on the managed-by marker in the unit, so a foreign Alloy is never
  touched. **`make lint-alloy` is the gate that matters** — the molecule stub exits 0 for
  everything, so only the real pinned binary proves the rendered config loads. See
  `ansible/roles/grafana_alloy/README.md`.

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
  `DECDN_CLI=… make lint-helm` locally when bumping the decdn version.

## Commands

Two Makefiles: the **root** is the hygiene/security/CI mirror; **`ansible/`** drives
deploys (its targets must run from `ansible/`). `make help` lists root targets.

```bash
# Root — lint & security (mirror CI)
make hooks            # one-time: install pre-commit git hook (pip install pre-commit first)
make lint             # all pre-commit hooks on all files (hygiene, shellcheck, yamllint, markdown)
make lint-ansible     # vendor collections + full ansible-lint (production profile)
make molecule         # containerised converge/verify of the decdn_node role — all six
                      # scenarios in parallel (needs Docker); cap with JOBS=<n>
make molecule-serial  # the same suite one scenario at a time (readable failure output)
make lint-helm        # chart: helm lint + render tests + kubeconform + schema keys (needs helm, yq, Docker)
make lint-alloy       # grafana_alloy: render its templates + `alloy validate` them with the real
                      # pinned binary (the molecule stub exits 0 for everything and cannot)
make security         # = security-ansible + security-helm (KICS over the rendered chart; needs helm)

# Ansible deploys — run from ansible/ (see ansible/README.md for the full flow)
cd ansible
make deps             # vendor pinned Galaxy collections into ./collections
make check / deploy   # deCDN node (site.yml): dry-run / provision
                      # fleet-wide by default; LIMIT=<host> scopes, ANSIBLE_ARGS='…' passes through
make build / galaxy-check       # stage + build the decdn.node collection, then validate it
```

**Galaxy collection (`decdn.node`).** The two roles (`baseline` + `decdn_node`) ship as a
distributable collection. The overlay lives in `ansible/galaxy/` and is staged into a clean
collection tree by `galaxy/build.sh` — there is **no** `galaxy.yml` at the `ansible/` root
(that would make ansible-lint treat the deploy project as a collection). Build/validate with
`make build` / `make galaxy-check`; **publishing is a manual step**
(`ansible-galaxy collection publish`), not automated.

**Gotcha — pre-commit is local-only.** Hygiene/shellcheck/yamllint/markdown run via
`make hooks`/`make lint` on your machine, **not** in CI. CI (`.github/workflows/`) is the
blocking gate and runs `ansible-lint` + `galaxy-build` (on `ansible/**`), `helm` (`make lint-helm`,
on `charts/**`, the shared schema checker/inventory, `Makefile` or `ci.yml`), KICS (on either) +
`actionlint`. `ansible-lint`
is **not** a per-commit hook (it needs collections vendored) — run `make lint-ansible`.
A separate `molecule.yml` workflow runs the containerised converge/verify in CI too, so
`make molecule` is not purely local.
