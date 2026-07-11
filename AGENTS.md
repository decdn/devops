# AGENTS.md — decdn-devops

Guidance for AI coding agents (Claude Code, Codex, Cursor, …) working in the deCDN
DevOps monorepo.

## What this repo is

This is the deCDN team's **DevOps monorepo**: infrastructure, deployment, and
operational tooling. It is one of the independent git repositories inside the
`/home/thiras/dev/decdn/` workspace (see the workspace-level `CLAUDE.md`). Today the
whole repo is **Ansible-driven**: `ansible/` is the deployment project. `services/` is a
reserved convention for future imperative bash + systemd units and is currently empty.

This repo is **infrastructure only**. It is *not* a source of truth for protocol or
economic claims — those live in `decdn/adr/`. If something here states a protocol fact
(chain-id, token address, fee split), it must trace back to an ADR, not invent one.

## Hard rules

1. **Never commit secrets.** No mnemonics, passwords, bcrypt hashes, private keys, API
   tokens, or tunnel credentials in any tracked file. Secrets are *generated on the
   target host* by the role tasks (e.g. basic-auth creds) and stored under `/etc/<svc>/` with `chmod 600`
   and a dedicated owner. The repo ships `*.example` templates for secret files only
   (non-secret config may be committed directly). The root `.gitignore` is a backstop —
   do not rely on it; keep secrets out by design.
2. **Localhost-only by default.** Service daemons (anvil, etc.) bind `127.0.0.1`. The
   *only* sanctioned public path is an explicit reverse proxy with auth + TLS in front
   (e.g. the anvil devnet's public-HTTPS Caddy, or that same proxy behind an outbound
   tunnel). Never bind a *backend* to `0.0.0.0` or expose its raw port — only the
   auth-terminating proxy faces the internet.
3. **`etc/` mirrors the target filesystem** (the `services/` convention, currently unused —
   see Layout). Put a config where it installs:
   `services/<svc>/etc/systemd/system/foo.service` → `/etc/systemd/system/foo.service`.
4. **Scripts are idempotent and fail loud.** `set -euo pipefail`, re-runnable, refuse to
   overwrite existing secrets, and require typed confirmation before destructive ops
   (e.g. wiping chain state).
5. **Show before installing.** When building or changing infra, present the files; the
   playbook run on the target (`make deploy` / `deploy-anvil`) is what mutates a host — it
   runs there, not here.

## Layout

The repo's one active unit is the Ansible project; `services/` is a reserved convention:

```
ansible/                # the deployment project (DevSec-hardened, lean roles)
  playbooks/            # site.yml (decdn node), anvil.yml (devnet), add-dev-user.yml
  roles/                # baseline, decdn_node, anvil, caddy, contracts(stub)
  inventory/ molecule/ galaxy/   # see ansible/README.md

services/<name>/        # reserved: future imperative bash + systemd units (currently empty)
  README.md  bin/  etc/ (filesystem-mirrored)  contracts/
```

For Ansible-managed services the `etc/`-mirror convention (hard-rule #3) does not apply —
role **templates** render to their target paths instead. Hard-rules #1 (no committed
secrets; generated on host) and #2 (localhost-only by default) hold for both conventions.

## Current services

- **`ansible/`** — the team's declarative deployment project. **Primary: the public deCDN
  node** (`playbooks/site.yml` → baseline + `decdn-node`), installed from a pinned GitHub
  release tarball under a hardened systemd unit; public QUIC udp/4433, loopback
  metrics/admin, operator-provisioned eth keystore, required chain knobs (no baked protocol
  facts — sourced from ADRs). **Internal: the anvil devnet** (`playbooks/anvil.yml` →
  baseline + anvil + Caddy basic-auth; anvil stays loopback while Caddy fronts it on public
  https/443 with auto-TLS — `caddy_public: true`, default; flip to loopback-only for a tunnel;
  repeated basic-auth failures are fail2ban-banned via the public-only `caddy-rpc` jail)
  — team tooling, not the product. Shared
  DevSec-hardened `baseline`. See `ansible/README.md`. (On-chain node stake/registration,
  ADR 019 Phase 2, is an operator step, not automated.)
- **`contracts` role** — intentional **stub**, out of scope for v1, not wired into any
  playbook. CREATE2 deploys will plug in after the `anvil` role; until then it's a no-op.

The original bash + systemd `services/anvil-devnet/` devnet has been **removed** —
superseded by `ansible/` (the `anvil.yml` path). `services/` remains the documented
convention for any future imperative bash + systemd unit, but currently holds none.

## Commands

Two Makefiles: the **root** is the hygiene/security/CI mirror; **`ansible/`** drives
deploys (its targets must run from `ansible/`). `make help` lists root targets.

```bash
# Root — lint & security (mirror CI)
make hooks            # one-time: install pre-commit git hook (pip install pre-commit first)
make lint             # all pre-commit hooks on all files (hygiene, shellcheck, yamllint, markdown)
make lint-ansible     # vendor collections + full ansible-lint (production profile)
make security         # KICS IaC scan of ansible/ (pinned engine image)
make molecule         # containerised converge/verify of the anvil stack (needs Docker)

# Ansible deploys — run from ansible/ (see ansible/README.md for the full flow)
cd ansible
make deps             # vendor pinned Galaxy collections into ./collections
make check / deploy             # deCDN node (site.yml): dry-run / provision
make check-anvil / deploy-anvil # anvil devnet (anvil.yml)
make add-dev USER_NAME=alice    # mint + reveal an anvil basic-auth dev user
make build / galaxy-check       # stage + build the decdn.node collection, then validate it
```

**Galaxy collection (`decdn.node`).** The public roles (`baseline` + `decdn_node`) ship as
a distributable collection; the internal anvil tooling does not. The overlay lives in
`ansible/galaxy/` and is staged into a clean collection tree by `galaxy/build.sh` — there is
**no** `galaxy.yml` at the `ansible/` root (that would make ansible-lint/molecule treat the
deploy project as a collection). Build/validate with `make build` / `make galaxy-check`;
**publishing is a manual step** (`ansible-galaxy collection publish`), not automated.

**Gotcha — pre-commit is local-only.** Hygiene/shellcheck/yamllint/markdown run via
`make hooks`/`make lint` on your machine, **not** in CI. CI (`.github/workflows/`) is the
blocking gate and runs `ansible-lint` + KICS + `galaxy-build` (on `ansible/**`) + `actionlint`. `ansible-lint`
is **not** a per-commit hook (it needs collections vendored) — run `make lint-ansible`.
A separate `molecule.yml` workflow runs the containerised converge/verify in CI too, so
`make molecule` is not purely local.
