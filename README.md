# decdn-devops

[![CI](https://github.com/decdn/devops/actions/workflows/ci.yml/badge.svg)](https://github.com/decdn/devops/actions/workflows/ci.yml)
[![Molecule](https://github.com/decdn/devops/actions/workflows/molecule.yml/badge.svg)](https://github.com/decdn/devops/actions/workflows/molecule.yml)
[![Ansible](https://img.shields.io/badge/Ansible-%E2%89%A5%202.15-1A1918?logo=ansible&logoColor=white)](https://docs.ansible.com/)
[![ansible-lint: production](https://img.shields.io/badge/ansible--lint-production-blue)](https://ansible.readthedocs.io/projects/lint/)
[![IaC scan: KICS](https://img.shields.io/badge/IaC%20scan-KICS-7B61FF)](https://kics.io/)
[![hardened: DevSec](https://img.shields.io/badge/hardened-DevSec-green)](https://dev-sec.io/)
[![shellcheck](https://img.shields.io/badge/shellcheck-passing-brightgreen)](https://www.shellcheck.net/)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://www.conventionalcommits.org)

The deCDN team's **DevOps monorepo** — infrastructure, deployment, and operational
tooling for the deCDN project, driven by a single declarative [Ansible](ansible/README.md)
project.

This repo is **infrastructure only**. It is *not* a source of truth for protocol or
economic facts (chain-id, token addresses, fee splits) — those live in `decdn/adr/` (see
the workspace `CLAUDE.md`). Anything here that states a protocol fact traces back to an
ADR; nothing is invented in this repo.

## What it deploys

Two deployments share one hardened host baseline:

| Playbook | Deploys | Exposure |
|----------|---------|----------|
| **`site.yml`** (primary) | A public **deCDN node** (`decdn-node`) — the product. Installed from a pinned GitHub release tarball under a hardened systemd unit. | Public QUIC **udp/4433** |
| `anvil.yml` (internal) | The shared **Anvil EVM devnet** behind a Caddy basic-auth proxy — team tooling, not the product. | Loopback (+ out-of-band tunnel) |

## Architecture

```
baseline   host hardening — DevSec os/ssh, nftables default-deny inbound,
           fail2ban, unattended-upgrades, chrony, an admin sudo user
   │
   ├─ site.yml  → decdn-node      public QUIC udp/4433; metrics+admin loopback;
   │                              release-tarball install; hardened systemd unit
   │
   └─ anvil.yml → anvil + caddy   loopback EVM devnet + per-dev basic auth
```

On-chain node stake + registration (ADR 019 Phase 2) is an **operator step**, not
automated here — the node serves paid traffic only after it is staked and registered.

## Repository layout

| Path | What it is |
|------|------------|
| [`ansible/`](ansible/README.md) | The team's **declarative deployment project** — `inventory/`, `playbooks/`, `roles/` (baseline, decdn_node, anvil, caddy, contracts), and a Molecule scenario. The whole deploy surface lives here. |
| `Makefile` | Root hygiene/security/CI mirror — runs the same lint + IaC scans CI does. |
| `ansible/Makefile` | The deploy driver — `make deps/check/deploy/check-anvil/deploy-anvil/add-dev`. |
| `.github/workflows/` | The blocking CI gate (`ansible-lint` + KICS + `actionlint`) and the Molecule run. |

## Quickstart

```bash
cd ansible
make deps                                     # vendor pinned Galaxy collections into ./collections
cp inventory/hosts.yml.example inventory/hosts.yml
$EDITOR inventory/hosts.yml                    # set hosts for decdn_nodes and/or anvil_devnet
$EDITOR inventory/group_vars/all.yml           # set ssh_admin_pubkey (REQUIRED — prevents lockout)
make check                                     # dry run (--check --diff)
make deploy                                    # provision the deCDN node
```

See [`ansible/README.md`](ansible/README.md) for the full setup, the deCDN-node
prerequisites (release tarball, per-node `host_vars`, operator-provisioned eth keystore),
and the anvil devnet flow.

## Security model

- **Nothing secret is committed.** Mnemonics, basic-auth credentials, and eth keystores
  are **generated on — or operator-provisioned to — the target host**, never the repo.
  Ansible roles render them on the host (`no_log`, `0600`); the repo ships `*.example`
  templates only, with the root `.gitignore` as a backstop.
- **Localhost-only by default.** Backends bind `127.0.0.1`; the only sanctioned public
  path is an explicit reverse proxy / tunnel with auth in front. The node host opens one
  extra hole (udp/4433 QUIC); everything else (anvil 8545, caddy 8080, node metrics 9090,
  admin RPC 9191) stays loopback.
- **Default-deny inbound (nftables).** SSH is the only universally-open port; extra public
  ports are declared explicitly via `baseline_extra_inbound`.
- **DevSec host hardening.** `os_hardening` + `ssh_hardening` (key-only SSH, no root login,
  kernel/sysctl/PAM hardening) — applied last, after the admin key is in place, so you
  can't lock yourself out.

## Commands

Two Makefiles, two jobs. The **root** Makefile mirrors CI's hygiene/security gates; the
**`ansible/`** Makefile drives deploys (run its targets from `ansible/`).

```bash
# Root — lint & security (mirror CI)
make hooks            # one-time: install the pre-commit git hook (pip install pre-commit first)
make lint             # all pre-commit hooks on all files (hygiene, shellcheck, yamllint, markdown)
make lint-ansible     # vendor collections + full ansible-lint (production profile)
make security         # KICS IaC scan of ansible/ (pinned engine image)
make molecule         # containerised converge/verify of the anvil stack (needs Docker)

# Ansible deploys — run from ansible/
cd ansible
make deps                         # vendor pinned Galaxy collections into ./collections
make check / deploy               # deCDN node (site.yml): dry-run / provision
make check-anvil / deploy-anvil   # anvil devnet (anvil.yml)
make add-dev USER_NAME=alice      # mint + reveal an anvil basic-auth dev user
```

**Gotcha — pre-commit is local-only.** Hygiene/shellcheck/yamllint/markdown run via
`make hooks`/`make lint` on your machine, **not** in CI. The blocking gate is
`.github/workflows/` (`ansible-lint` + KICS on `ansible/**` + `actionlint`). `ansible-lint`
is not a per-commit hook (it needs collections vendored) — run `make lint-ansible`.

## CI & quality gates

- **`ci.yml`** — path-filtered so heavy jobs skip unrelated PRs: `ansible-lint` (production
  profile + playbook syntax-check), **KICS** IaC scan (fail on HIGH), and `actionlint` on
  the workflows themselves. The KICS engine is pinned by digest and every third-party
  action by full commit SHA (a re-pointed tag can ship malicious code).
- **`molecule.yml`** — spins up the anvil + caddy stack in a container and asserts
  `eth_chainId`, loopback-only binding, a `401` on unauthenticated requests, and
  idempotence. The `baseline` role is not exercised in a container (its `ssh_hardening`
  would sever the connection); `make check` covers it as a non-mutating dry run.

## Conventions & source of truth

- **ADRs are the only source of truth for protocol facts.** They live in `decdn/adr/`
  (a separate repo in the workspace) — e.g. payments (ADR 003), node onboarding
  (ADR 019), tokenomics (ADR 026). If a doc here contradicts an ADR, fix the doc.
- **Role templates render to their target paths.** Ansible roles template config directly
  onto the host (e.g. `roles/anvil/templates/anvil.service.j2` → `/etc/systemd/system/`),
  with secrets generated on the host at `0600`.

## Further reading

- [`ansible/README.md`](ansible/README.md) — full setup, security model, and deploy steps
- [`ansible/roles/decdn_node/README.md`](ansible/roles/decdn_node/README.md) — the deCDN node role
- [`ansible/roles/contracts/README.md`](ansible/roles/contracts/README.md) — contracts deploy (stub)
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — the local + CI check workflow
- workspace `CLAUDE.md` — repo hard rules and the single-source-of-truth policy
