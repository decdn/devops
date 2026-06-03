# decdn-devops

The deCDN team's **DevOps monorepo** — infrastructure, deployment, and operational
tooling for the deCDN project. One repo per concern lives under `services/`, each
self-contained (its own README, config templates, and install/run scripts).

This repo holds **infrastructure only**. Protocol-level technical and economic claims
remain sourced from `decdn/adr/` (see the workspace `CLAUDE.md`); nothing here is a
source of truth for the protocol itself.

## Services

| Path | What it is |
|------|------------|
| [`services/anvil-devnet/`](services/anvil-devnet/README.md) | Shared **Anvil (Foundry) EVM devnet** — the common settlement-layer test chain every dev points their tooling at. Persistent state, fixed chain-id/accounts, deterministic contract addresses, fronted by Caddy basic-auth and a Cloudflare Tunnel at `https://rpc-dev.decdn.org`. |

## Conventions

- **Nothing secret is committed.** Secrets (mnemonics, credentials, tunnel keys) are
  generated on the target host by the service's `bin/bootstrap.sh` and stored under
  `/etc` with tight permissions. The repo ships `*.example` templates only. The root
  `.gitignore` enforces this as a backstop.
- **`etc/` directories mirror the target filesystem.** A file at
  `services/<svc>/etc/caddy/Caddyfile` installs to `/etc/caddy/Caddyfile`, so the
  install destination is always obvious.
- **Scripts are idempotent and root-aware.** Installers can be re-run safely; they
  refuse to clobber existing secrets and print clear next steps.

## Getting started

Pick a service and read its README. For the devnet:

```bash
cd services/anvil-devnet
less README.md
```
