# decdn-devops

[![CI](https://github.com/decdn/devops/actions/workflows/ci.yml/badge.svg)](https://github.com/decdn/devops/actions/workflows/ci.yml)
[![Ansible](https://img.shields.io/badge/Ansible-%E2%89%A5%202.15-1A1918?logo=ansible&logoColor=white)](https://docs.ansible.com/)
[![ansible-lint: production](https://img.shields.io/badge/ansible--lint-production-blue)](https://ansible.readthedocs.io/projects/lint/)
[![IaC scan: KICS](https://img.shields.io/badge/IaC%20scan-KICS-7B61FF)](https://kics.io/)
[![hardened: DevSec](https://img.shields.io/badge/hardened-DevSec-green)](https://dev-sec.io/)
[![shellcheck](https://img.shields.io/badge/shellcheck-passing-brightgreen)](https://www.shellcheck.net/)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://www.conventionalcommits.org)

The official **DevOps repo** for running a deCDN node: infrastructure, deployment and
day-2 tooling for operators anywhere. Three ways to deploy the same node:

| Path | For | Start here |
|------|-----|------------|
| **Ansible** (`ansible/`) | VMs and bare metal, one node or a fleet. Hardens the host too (firewall, SSH, patching). Also published as the `decdn.node` Galaxy collection. | [`ansible/README.md`](ansible/README.md) |
| **Docker Compose** (`compose/`) | One host that already runs Docker. | [`compose/README.md`](compose/README.md) |
| **Helm** (`charts/decdn-node/`) | Kubernetes, one release per node. | [`charts/decdn-node/README.md`](charts/decdn-node/README.md) |

Supported hosts: Debian 12/13 and Ubuntu 24.04/26.04 on x86_64 or aarch64. Network,
disk and platform requirements, and how to choose a path:
[`docs/requirements.md`](docs/requirements.md).

This repo is **infrastructure only**. It is *not* a source of truth for protocol or
economic facts (chain-id, token addresses, fee splits): those trace to the deCDN ADRs
and upstream's deployment manifests. Where this repo carries one (the contract addresses
behind `decdn_network`), it is a generated mirror with its upstream commit recorded.

## What every path gives you

- **The node, hardened.** `decdn-node` as a non-root service with a minimal privilege
  set: a hardened systemd unit, a locked-down container, or a restricted pod.
- **One public port.** QUIC on **udp/4433**. Metrics (9090) and the admin RPC (9191)
  stay on loopback (on Kubernetes, behind a ClusterIP Service and a NetworkPolicy).
- **The right chain config.** Contract addresses come from upstream's deployment
  manifest: `decdn_network: arbitrum-sepolia` on Ansible, `decdn config init --chain`
  for Compose and Helm. Nothing is hand-copied.
- **Signed installs.** Ansible verifies release tarballs against the GPG-signed
  `SHA256SUMS`; Compose and Helm pin the image by digest.
- **Monitoring.** Upstream's Grafana dashboards and alert rules, with the labels they
  expect: opt-in Grafana Cloud shipping via `grafana_alloy` on Ansible, a
  `ServiceMonitor` + `PrometheusRule` + dashboard ConfigMaps on Helm
  ([`charts/decdn-node/files/monitoring/`](charts/decdn-node/files/monitoring/README.md)).
- **Day 2.** Encrypted backups, restore and host migration, and a guarded
  decommission: [`docs/lifecycle.md`](docs/lifecycle.md).

On-chain stake and registration (ADR 019 Phase 2) is an **operator step** on every
path: the node serves paid traffic only after it. Upstream's `decdn setup` walks it
end to end (with `--dry-run`); this repo stops at host prep and startup.

## Quickstart (Ansible)

```bash
cd ansible
make deps                                          # vendor pinned Galaxy collections
cp inventory/hosts.yml.example inventory/hosts.yml
$EDITOR inventory/hosts.yml                         # your hosts in decdn_nodes
$EDITOR inventory/host_vars/decdn-node-1/main.yml   # binaries, region, origin; chain via decdn_network
# RPC URL: provision 0600 /etc/decdn/decdn.env on the host (preferred), or secret.yml
make check  LIMIT=decdn-node-1 ANSIBLE_ARGS='-u root'   # dry run; -u root only until the first converge
make deploy LIMIT=decdn-node-1 ANSIBLE_ARGS='-u root'   # first converge creates your admin account
make deploy LIMIT=decdn-node-1                          # every run after that
```

The full flow (bootstrap user, keystore, secrets, fleets in a private inventory) is in
[`ansible/README.md`](ansible/README.md). Compose and Helm have their own quickstarts.

## Security model

This is the canonical statement; the per-path READMEs add only what is specific to them.

- **Nothing secret is committed.** The eth keystore and the RPC URL (which may embed an
  API key) are **generated on, or operator-provisioned to, the target** and live in
  `0600` files readable only by whoever must read them: the service account for the
  keystore and its password; the service account (Ansible) or root (Compose, where
  Docker reads it before starting the container) for the RPC env file. On Kubernetes
  they are operator-created Secrets the chart only references. The repo ships `*.example` templates for secret files only;
  non-secret config such as `host_vars/<node>/main.yml` is committed. The `.gitignore`
  is a backstop, not the mechanism. Backups are encrypted on the host to public keys
  you choose.
- **Localhost-only by default.** Backends bind `127.0.0.1`. A service that must accept
  public traffic declares its port explicitly, and the node declares exactly one:
  udp/4433. On Kubernetes, metrics bind `0.0.0.0` in the pod only behind a ClusterIP
  Service and a NetworkPolicy.
- **Default-deny inbound** (Ansible's `baseline`, nftables). SSH is the only
  universally open port; extra public ports are declared via `baseline_extra_inbound`.
- **DevSec host hardening** (`os_hardening` + `ssh_hardening`: key-only SSH, no root
  login, kernel/sysctl/PAM hardening), applied last, after the admin key is in place, so
  you can't lock yourself out.
- **Pinned supply chain.** Release tarballs are GPG-verified; images, CI actions and
  scanners are pinned by digest or commit SHA ([`SECURITY.md`](SECURITY.md),
  [`CONTRIBUTING.md`](CONTRIBUTING.md#supply-chain--pinning-rules)).

## Repository layout

| Path | What it is |
|------|------------|
| [`ansible/`](ansible/README.md) | The Ansible project: `inventory/`, `playbooks/` (`site.yml`, `backup.yml`, `decommission.yml`), `roles/` (`baseline`, `decdn_node`, `grafana_alloy`), `galaxy/` (the `decdn.node` collection), `molecule/`. |
| [`compose/`](compose/README.md) | The Docker Compose deploy path. |
| [`charts/decdn-node/`](charts/decdn-node/README.md) | The Helm chart, with vendored dashboards and alert rules in `files/monitoring/`. |
| [`docs/`](docs/requirements.md) | Cross-path operator docs: requirements, lifecycle. |
| `scripts/` | Generators for the upstream mirrors (network profiles, monitoring) and the release gate. |
| `Makefile` | Lint, test and security targets; CI runs the same ones. `make help` lists them. |
| `.github/workflows/` | CI (`ci.yml`, `molecule.yml`), releases (`release.yml`), the weekly upstream drift check. |

## Contributing and releases

- [`CONTRIBUTING.md`](CONTRIBUTING.md): local checks, every `make` target, what CI runs,
  and the pinning rules.
- [`RELEASING.md`](RELEASING.md): how a `vX.Y.Z` tag publishes the collection and the chart.
- [`AGENTS.md`](AGENTS.md): the repo's hard rules (for humans and AI agents).
- [`SECURITY.md`](SECURITY.md): reporting a vulnerability, verifying releases.

Conventions: commits follow Conventional Commits. The deCDN ADRs are the only source
of truth for protocol facts (payments ADR 003, node onboarding ADR 019, tokenomics
ADR 026); if a doc here contradicts an ADR, fix the doc.
