# decdn-devops

[![CI](https://github.com/decdn/devops/actions/workflows/ci.yml/badge.svg)](https://github.com/decdn/devops/actions/workflows/ci.yml)
[![Ansible](https://img.shields.io/badge/Ansible-%E2%89%A5%202.15-1A1918?logo=ansible&logoColor=white)](https://docs.ansible.com/)
[![ansible-lint: production](https://img.shields.io/badge/ansible--lint-production-blue)](https://ansible.readthedocs.io/projects/lint/)
[![IaC scan: KICS](https://img.shields.io/badge/IaC%20scan-KICS-7B61FF)](https://kics.io/)
[![hardened: DevSec](https://img.shields.io/badge/hardened-DevSec-green)](https://dev-sec.io/)
[![shellcheck](https://img.shields.io/badge/shellcheck-passing-brightgreen)](https://www.shellcheck.net/)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-yellow.svg)](https://www.conventionalcommits.org)

The official **DevOps repo** for running deCDN: infrastructure, deployment and day-2
tooling for operators anywhere. It serves both kinds of operator:

| You are | You run | Start here |
|---------|---------|------------|
| a **node operator** | deCDN cache nodes: bond, serve, get paid per megabyte | [`docs/node-operators.md`](docs/node-operators.md) |
| a **publisher** | origin nodes for your namespaces, and optionally the services around them (`sponsord` and its onramp, iroh relays, an iroh DNS server) | [`docs/publishers.md`](docs/publishers.md) |

Four ways to deploy the node, cache or origin:

| Path | For | Start here |
|------|-----|------------|
| **Ansible** (`ansible/`) | VMs and bare metal, one node or a fleet. Hardens the host too (firewall, SSH, patching). Also published as the `decdn.node` and `decdn.publisher` Galaxy collections. | [`ansible/README.md`](ansible/README.md) |
| **cloud-init** (`cloud-init/`) | One VM, no control machine: paste the user-data into your provider's "create server" form. It runs the Ansible playbook on the host itself, hardening included. One template per kind of operator: a cache node, or a publisher's origin with the onboarding sponsor (`sponsord` + its onramp). | [`cloud-init/README.md`](cloud-init/README.md) |
| **Docker Compose** (`compose/`) | One host that already runs Docker. Profiles for a cache node or an origin, the onboarding sponsor (`sponsord` + its onramp) and an iroh relay, driven by the `decdn-compose` wrapper (set-up, preflight, guarded restarts). | [`compose/README.md`](compose/README.md) |
| **Helm** (`charts/decdn-node/`) | Kubernetes, one release per node, cache or origin. | [`charts/decdn-node/README.md`](charts/decdn-node/README.md) |

The iroh relay a publisher may run deploys with Ansible or Compose; the iroh DNS server with Ansible only.

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
  `SHA256SUMS`; Compose only takes the image by digest; Helm takes a digest
  (recommended) or a tag.
- **Monitoring.** The deCDN Grafana dashboards and alert rules, with the labels they
  expect: opt-in Grafana Cloud shipping via `grafana_alloy` on Ansible, a
  `ServiceMonitor` + `PrometheusRule` + dashboard ConfigMaps on Helm
  ([`monitoring/`](monitoring/README.md)).
- **Day 2.** Encrypted backups, restore and host migration, and a guarded
  decommission: [`docs/lifecycle.md`](docs/lifecycle.md).

On-chain stake and registration (ADR 019 Phase 2) is an **operator step** on every
path: the node serves paid traffic only after it. Upstream's `decdn setup` walks it
end to end (with `--dry-run`); this repo stops at host prep and startup.

## Quickstart (Ansible)

```bash
cd ansible
make deps                                          # vendor pinned Galaxy collections
cp inventory/hosts-node.yml.example inventory/hosts.yml   # node operators; its host is decdn-node-1
# publishers instead: cp inventory/hosts-publisher.yml.example inventory/hosts.yml  (host origin-1)
HOST=decdn-node-1                                   # or origin-1
$EDITOR inventory/hosts.yml                         # your hosts
$EDITOR inventory/host_vars/$HOST/main.yml          # binaries, region (an origin: its backend); chain via decdn_network
# RPC URL: provision 0600 /etc/decdn/decdn.env on the host (preferred), or secret.yml
make check  LIMIT=$HOST ANSIBLE_ARGS='-u root'      # dry run; -u root only until the first converge
make deploy LIMIT=$HOST ANSIBLE_ARGS='-u root'      # first converge creates your admin account
make deploy LIMIT=$HOST                             # every run after that
```

The full flow (bootstrap user, keystore, secrets, fleets in a private inventory) is in
[`ansible/README.md`](ansible/README.md). cloud-init, Compose and Helm have their own quickstarts.

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
  udp/4433. The sponsor's public onramp (Ansible and Compose) stays on loopback too,
  behind Caddy on tcp/80 + tcp/443 (the default on Ansible, the `caddy` profile on
  Compose; otherwise you bring the proxy and open its ports). A self-hosted iroh relay
  (Ansible and Compose) is public by design: it terminates its own TLS on tcp/80 + tcp/443 and serves
  QUIC address discovery on udp/7842, with its metrics on loopback. So is a self-hosted
  iroh DNS server (Ansible): its own TLS on tcp/443 and DNS on udp/53 + tcp/53, with its
  metrics on loopback. On Kubernetes, metrics bind `0.0.0.0` in the pod only behind a ClusterIP
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
| [`ansible/`](ansible/README.md) | The Ansible project: `inventory/`, `playbooks/` (`site.yml`, `node.yml` for node operators, `publisher.yml` for publishers with `origin.yml`, `sponsord.yml`, `iroh_relay.yml` and `iroh_dns_server.yml`, `backup.yml`, `decommission.yml`), `roles/` (`baseline`, `decdn_node`, `grafana_alloy`, `sponsord`, `sponsord_onramp`, `iroh_relay`, `iroh_dns_server`), `galaxy/` (the `decdn.node` and `decdn.publisher` collections), `molecule/`. |
| [`cloud-init/`](cloud-init/README.md) | The cloud-init deploy path: `user-data-node.yaml` (node operators: a cache node), `user-data-publisher.yaml` (publishers: an origin node, sponsord and its onramp), the on-host `bootstrap.sh`, and the pinned ansible-core and collections it installs. |
| [`compose/`](compose/README.md) | The Docker Compose deploy path: the node, `sponsord`, `sponsord-onramp`, Caddy and an iroh relay, one profile each, and the `decdn-compose` wrapper. |
| [`charts/decdn-node/`](charts/decdn-node/README.md) | The Helm chart; it renders the node's dashboards and alert rules from `monitoring/`. |
| [`monitoring/`](monitoring/README.md) | The deCDN Grafana dashboards and Prometheus alert rules, for the node (`decdn-node/`, every deploy path), sponsord (`sponsord/`, Ansible and Compose) and the iroh relay (`iroh-relay/`, Ansible and Compose). |
| [`docs/`](docs/requirements.md) | Cross-path operator docs: the two front doors ([node operators](docs/node-operators.md), [publishers](docs/publishers.md)), requirements, lifecycle. |
| `scripts/` | Generators for the upstream mirrors (network profiles) and the release gate. |
| `Makefile` | Lint, test and security targets; CI runs the same ones. `make help` lists them. |
| `.github/workflows/` | CI (`ci.yml`, `molecule.yml`), releases (`release-collection.yml`, `release-chart.yml`), the weekly upstream drift check. |

## Contributing and releases

- [`CONTRIBUTING.md`](CONTRIBUTING.md): local checks, every `make` target, what CI runs,
  and the pinning rules.
- [`RELEASING.md`](RELEASING.md): how `scripts/release.sh` cuts a release, and how a
  `node-collection-vX.Y.Z` or `publisher-collection-vX.Y.Z` tag publishes a collection
  and a `decdn-node-X.Y.Z` tag the chart.
- [`AGENTS.md`](AGENTS.md): the repo's hard rules (for humans and AI agents).
- [`SECURITY.md`](SECURITY.md): reporting a vulnerability, verifying releases.

Conventions: commits follow Conventional Commits. The deCDN ADRs are the only source
of truth for protocol facts (payments ADR 003, node onboarding ADR 019, tokenomics
ADR 026); if a doc here contradicts an ADR, fix the doc.
