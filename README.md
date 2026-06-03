# decdn-devops

The deCDN team's **DevOps monorepo** — infrastructure, deployment, and operational
tooling for the deCDN project.

This repo holds **infrastructure only**. Protocol-level technical and economic claims
remain sourced from `decdn/adr/` (see the workspace `CLAUDE.md`); nothing here is a
source of truth for the protocol itself.

## Layout

| Path | What it is |
|------|------------|
| [`ansible/`](ansible/README.md) | The team's **declarative deployment project**. Two deployments on one hardened host baseline: **`site.yml`** (primary) provisions the public **deCDN node** (the product) under a hardened systemd unit, public QUIC udp/4433; **`anvil.yml`** (internal) provisions our shared **Anvil EVM devnet** behind Caddy basic-auth, loopback-only. |
| `services/` | Convention for self-contained **imperative bash + systemd** units — one subdirectory per service, each with its own README, `*.example` templates, and `bin/` install scripts. Currently empty: the former `anvil-devnet` service has been superseded by `ansible/` (the `anvil.yml` path). |

## Conventions

- **Nothing secret is committed.** Secrets (mnemonics, credentials, eth keystores) are
  generated on — or operator-provisioned to — the target host, never the repo. Ansible
  roles render them on the host (`no_log`, `0600`); bash services generate them in their
  `bin/bootstrap.sh`. The repo ships `*.example` templates only, and the root
  `.gitignore` enforces this as a backstop.
- **Localhost-only by default.** Backends bind `127.0.0.1`; the only sanctioned public
  path is an explicit reverse proxy / tunnel with auth in front. The node host opens one
  extra hole (udp/4433 QUIC); everything else stays loopback behind nftables default-deny.
- **Filesystem-mirrored config (bash services).** A file at `services/<svc>/etc/foo`
  installs to `/etc/foo`. For Ansible-managed services this doesn't apply — role
  **templates** render directly to their target paths.

## Getting started

```bash
cd ansible
less README.md      # full setup, security model, and deploy steps
```
