# AGENTS.md — decdn-devops

Guidance for AI coding agents (Claude Code, Codex, Cursor, …) working in the deCDN
DevOps repo.

## What this repo is

The official Ansible project for deploying a **deCDN node**: infrastructure, deployment,
and operational tooling. The whole repo is **Ansible-driven** — `ansible/` is the
deployment project.

This repo is **infrastructure only**. It is *not* a source of truth for protocol or
economic claims — those trace to the deCDN ADRs. If something here states a protocol fact
(chain-id, token address, fee split), it must trace back to an ADR, not invent one.

## Hard rules

1. **Never commit secrets.** No passwords, private keys, API tokens, or keystores in any
   tracked file. Secrets are *generated on — or operator-provisioned to — the target host*
   (e.g. the node's eth keystore, or `rpc_url` which may embed an API key) and stored under
   `/etc/<svc>/` with `chmod 600` and a dedicated owner. The repo ships `*.example`
   templates for secret files only (non-secret config may be committed directly). The root
   `.gitignore` is a backstop — do not rely on it; keep secrets out by design.
2. **Localhost-only by default.** Service daemons bind `127.0.0.1` (e.g. the node's metrics
   and admin RPC). A service that must accept public traffic declares exactly one hole (the
   node's QUIC udp/4433) via `baseline_extra_inbound`; if a service ever needs an HTTP-facing
   public path, front it with an explicit reverse proxy that terminates auth + TLS. Never
   bind a *backend* to `0.0.0.0` or expose its raw port.
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
  roles/                # baseline, decdn_node
  inventory/ galaxy/ molecule/    # see ansible/README.md
```

## Current services

- **`ansible/`** — the declarative deployment project. **The public deCDN node**
  (`playbooks/site.yml` → baseline + `decdn-node`), installed from a pinned GitHub release
  tarball — verified against the release's GPG-signed `SHA256SUMS` — or, while upstream
  has no release tag cut (the current default), from locally-built binaries; under a hardened
  systemd unit; public QUIC udp/4433, loopback metrics/admin, operator-provisioned eth
  keystore, required chain knobs (no baked protocol facts — sourced from ADRs), over a
  shared DevSec-hardened `baseline`. See `ansible/README.md`. (On-chain node
  stake/registration, ADR 019 Phase 2, is a manual operator step, driven by `decdn setup`.)

  **Config-schema coupling.** `roles/decdn_node/templates/node.toml.j2` renders against
  `decdn/crates/common/src/config/types.rs`, where every section is
  `#[serde(deny_unknown_fields)]` with **no** serde aliases — a key the role emits that
  the installed binary does not know is a startup crash-loop. Two guards: the role runs
  `decdn config validate` against the real binary after templating, and the
  `molecule/schema` scenario checks the rendered key set against a committed inventory of
  upstream field names. Re-sync both when bumping the pinned decdn version.

## Commands

Two Makefiles: the **root** is the hygiene/security/CI mirror; **`ansible/`** drives
deploys (its targets must run from `ansible/`). `make help` lists root targets.

```bash
# Root — lint & security (mirror CI)
make hooks            # one-time: install pre-commit git hook (pip install pre-commit first)
make lint             # all pre-commit hooks on all files (hygiene, shellcheck, yamllint, markdown)
make lint-ansible     # vendor collections + full ansible-lint (production profile)
make security         # KICS IaC scan of ansible/ (pinned engine image)
make molecule         # containerised converge/verify of the decdn_node role (needs Docker)

# Ansible deploys — run from ansible/ (see ansible/README.md for the full flow)
cd ansible
make deps             # vendor pinned Galaxy collections into ./collections
make check / deploy   # deCDN node (site.yml): dry-run / provision
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
blocking gate and runs `ansible-lint` + KICS + `galaxy-build` (on `ansible/**`) + `actionlint`. `ansible-lint`
is **not** a per-commit hook (it needs collections vendored) — run `make lint-ansible`.
A separate `molecule.yml` workflow runs the containerised converge/verify in CI too, so
`make molecule` is not purely local.
