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

```
services/<name>/
  README.md          # runbook for that service
  .env.example       # consumer-facing env template (if applicable)
  etc/               # files that install under /etc (filesystem-mirrored)
  bin/               # install / bootstrap / operational scripts (source bin/lib.sh)
  contracts/         # (devnet) Foundry project + deploy scripts, if relevant
```

## Current services

- **`services/anvil-devnet/`** — shared Foundry/Anvil EVM devnet behind Caddy basic-auth
  and a Cloudflare Tunnel (`https://rpc-dev.decdn.org`). Persistent state, fixed
  chain-id 31337, shared mnemonic, deterministic (CREATE2) contract addresses. See its
  README for the full architecture and runbook.
