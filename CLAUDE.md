# CLAUDE.md — decdn-devops

Guidance for Claude Code when working in the deCDN DevOps monorepo.

## What this repo is

This is the deCDN team's **DevOps monorepo**: infrastructure, deployment, and
operational tooling. It is one of the independent git repositories inside the
`/home/thiras/dev/decdn/` workspace (see the workspace-level `CLAUDE.md`). It has no
shared application build — each subdirectory under `services/` is a self-contained
unit with its own README, config templates, and scripts.

This repo is **infrastructure only**. It is *not* a source of truth for protocol or
economic claims — those live in `decdn/adr/`. If something here states a protocol fact
(chain-id, token address, fee split), it must trace back to an ADR, not invent one.

## Hard rules

1. **Never commit secrets.** No mnemonics, passwords, bcrypt hashes, private keys, API
   tokens, or tunnel credentials in any tracked file. Secrets are *generated on the
   target host* by `bin/bootstrap.sh` and stored under `/etc/<svc>/` with `chmod 600`
   and a dedicated owner. The repo ships `*.example` templates only. The root
   `.gitignore` is a backstop — do not rely on it; keep secrets out by design.
2. **Localhost-only by default.** Service daemons (anvil, etc.) bind `127.0.0.1`. The
   *only* sanctioned public path is an explicit reverse proxy + tunnel with auth in
   front. Never bind a backend to `0.0.0.0` or expose its raw port.
3. **`etc/` mirrors the target filesystem.** Put a config where it installs:
   `services/<svc>/etc/systemd/system/foo.service` → `/etc/systemd/system/foo.service`.
4. **Scripts are idempotent and fail loud.** `set -euo pipefail`, re-runnable, refuse to
   overwrite existing secrets, and require typed confirmation before destructive ops
   (e.g. wiping chain state).
5. **Show before installing.** When building or changing infra, present the files; the
   `bin/install.sh` of a service is what actually mutates a host, and it runs there, not
   here.

## Layout

Two top-level units, two conventions:

```
services/<name>/        # imperative bash + systemd services
  README.md             # runbook for that service
  .env.example          # consumer-facing env template (if applicable)
  etc/                  # files that install under /etc (filesystem-mirrored)
  bin/                  # install / bootstrap / operational scripts (source bin/lib.sh)
  contracts/            # (devnet) Foundry project + deploy scripts, if relevant

ansible/                # declarative Ansible project (lean roles + DevSec hardening)
  inventory/ playbooks/ roles/ molecule/   # see ansible/README.md
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
  baseline + anvil + Caddy basic-auth, loopback) — team tooling, not the product. Shared
  DevSec-hardened `baseline`. See `ansible/README.md`. (On-chain node stake/registration,
  ADR 019 Phase 2, is an operator step, not automated.)

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
```

**Gotcha — pre-commit is local-only.** Hygiene/shellcheck/yamllint/markdown run via
`make hooks`/`make lint` on your machine, **not** in CI. CI (`.github/workflows/`) is the
blocking gate and runs `ansible-lint` + KICS (on `ansible/**`) + `actionlint`. `ansible-lint`
is **not** a per-commit hook (it needs collections vendored) — run `make lint-ansible`.
