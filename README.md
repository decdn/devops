# decdn-devops

[![CI](https://github.com/decdn/devops/actions/workflows/ci.yml/badge.svg)](https://github.com/decdn/devops/actions/workflows/ci.yml)
[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/decdn-node)](https://artifacthub.io/packages/search?repo=decdn-node)
[![decdn.node on Galaxy](https://img.shields.io/ansible/collection/v/decdn/node?label=decdn.node)](https://galaxy.ansible.com/ui/repo/published/decdn/node/)
[![decdn.publisher on Galaxy](https://img.shields.io/ansible/collection/v/decdn/publisher?label=decdn.publisher)](https://galaxy.ansible.com/ui/repo/published/decdn/publisher/)
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
| **Docker Compose** (`compose/`), recommended | One host that already runs Docker. The quickest start, [below](#quickstart-docker-compose). Profiles for a cache node or an origin, the onboarding sponsor (`sponsord` + its onramp), an iroh relay, an iroh DNS server and Grafana Alloy, driven by the `decdn-compose` wrapper (set-up, preflight, guarded restarts). | [`compose/README.md`](compose/README.md) |
| **Ansible** (`ansible/`) | VMs and bare metal, one node or a fleet. Hardens the host too (firewall, SSH, patching). Also published on Ansible Galaxy as the [`decdn.node`](https://galaxy.ansible.com/ui/repo/published/decdn/node/) and [`decdn.publisher`](https://galaxy.ansible.com/ui/repo/published/decdn/publisher/) collections, roles and playbooks, so a fleet needs only an inventory of its own: the [quickstart below](#quickstart-ansible-from-galaxy). | [`ansible/README.md`](ansible/README.md) |
| **cloud-init** (`cloud-init/`) | One VM, no control machine: paste the user-data into your provider's "create server" form. It runs the Ansible playbook on the host itself, hardening included. One template per kind of operator: a cache node, or a publisher's origin with the onboarding sponsor (`sponsord` + its onramp). | [`cloud-init/README.md`](cloud-init/README.md) |
| **Helm** (`charts/decdn-node/`) | Kubernetes, one release per node, cache or origin. Published to `oci://ghcr.io/decdn/charts/decdn-node`, signed, and listed on [Artifact Hub](https://artifacthub.io/packages/helm/decdn-node/decdn-node). | [`charts/decdn-node/README.md`](charts/decdn-node/README.md) |

The iroh relay and DNS server a publisher may run deploy with Ansible or Compose.

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
  expect: opt-in Grafana Cloud shipping via `grafana_alloy` on Ansible or Compose's
  `alloy` profile, a
  `ServiceMonitor` + `PrometheusRule` + dashboard ConfigMaps on Helm
  ([`monitoring/`](monitoring/README.md)).
- **Day 2.** Encrypted backups, restore and host migration, and a guarded
  decommission: [`docs/lifecycle.md`](docs/lifecycle.md).

On-chain stake and registration (ADR 019 Phase 2) is an **operator step** on every
path: the node serves paid traffic only after it. Upstream's `decdn setup` walks it
end to end (with `--dry-run`); this repo stops at host prep and startup.

## Quickstart (Docker Compose)

On the host (a systemd distro with Docker, Compose v2.24+, Python 3.11+ and
[`age`](https://github.com/FiloSottile/age)), from an account with sudo:

```bash
git clone https://github.com/decdn/devops.git && cd devops
sudo compose/decdn-compose init node --region DE      # ISO 3166-1 alpha-2; account, keys, node.toml, decdn.env
# publishers: sudo compose/decdn-compose init origin --region DE --origin https://store.example.org/bucket
sudo compose/decdn-compose backup -r age1…            # a key from age-keygen off the host; copy the .tar.age off too
sudoedit /etc/decdn/decdn.env                         # DECDN_RPC_URL=https://…
# open udp/4433 inbound: host firewall and your provider's security group
sudo compose/decdn-compose up                         # preflight, then docker compose up -d
sudo compose/decdn-compose health
sudo compose/decdn-compose cli whoami                 # the node's wallet: fund it before setup
MA=/ip4/<public-ip>/udp/4433/quic-v1                  # behind 1:1 NAT too; dual-stack: add --multiaddr /ip6/…
sudo compose/decdn-compose cli setup --mbps 100 --region DE --multiaddr "$MA" --dry-run
sudo compose/decdn-compose cli setup --mbps 100 --region DE --multiaddr "$MA"   # stake and register (ADR 019 Phase 2)
```

Compose installs the node, not the host around it: firewall, SSH and patching stay
yours. The full flow (origins, the sponsor, relays, DNS, Alloy, upgrades) is in
[`compose/README.md`](compose/README.md). For a fleet, or a host you want hardened from
scratch, use [Ansible](#quickstart-ansible-from-galaxy) (or [cloud-init](cloud-init/README.md) for
one VM); on Kubernetes, the [Helm chart](charts/decdn-node/README.md).

## Quickstart (Ansible, from Galaxy)

From your workstation (ansible-core ≥ 2.15, e.g. `pipx install ansible-core`) with an
SSH key in `~/.ssh/`, and a fresh Debian or Ubuntu host. The collections bring the roles
and playbooks; you clone this repository once, only to copy the example project (its
inventory templates included) into a private repository of your own:

```bash
git clone --depth 1 https://github.com/decdn/devops.git
cp -R devops/examples/collection-fleet my-fleet && cd my-fleet     # make this your private repo
ansible-galaxy collection install -r requirements.yml -p collections
cp inventory/hosts-node.yml.example inventory/hosts.yml
cp inventory/host_vars/decdn-node-1/secret.yml.example inventory/host_vars/decdn-node-1/secret.yml
$EDITOR inventory/hosts.yml                          # ansible_host: the node's IP
$EDITOR inventory/host_vars/decdn-node-1/main.yml    # decdn_region; add decdn_node_generate_keystore: true (the node makes its wallet)
$EDITOR inventory/host_vars/decdn-node-1/secret.yml  # decdn_rpc_url (git-ignored)
```

Then deploy. The first run connects as root, or as your image's sudo user (`-u ubuntu`
on Ubuntu cloud images): it creates an admin account named after your local `$USER`,
keyed with your `~/.ssh/id_*` key, and then turns root and password login off. Every
later run connects as that account, so drop `-u`:

```bash
ssh root@<node-ip> true                                   # accept the host key once (or ubuntu@…)
ansible-playbook decdn.node.node -l decdn-node-1 -u root  # first run only
ansible-playbook decdn.node.node -l decdn-node-1 --check --diff   # later changes: dry run,
ansible-playbook decdn.node.node -l decdn-node-1                  # then apply
```

The play opens udp/4433 in the host firewall; open it in your provider's security
group too. Then fund the node's wallet and stake and register it with `decdn setup`
([`docs/lifecycle.md` § Running on-chain commands](docs/lifecycle.md#running-on-chain-commands)).
Publishers start from `hosts-publisher.yml.example`, uncomment the groups they run and
deploy with `decdn.publisher.publisher` ([`docs/publishers.md`](docs/publishers.md)). Backups, decommission and every other
`make` target in the docs:
[From `make` to `ansible-playbook`](examples/collection-fleet/README.md#from-make-to-ansible-playbook).

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
  behind nginx on tcp/80 + tcp/443 (the default on Ansible; on Compose, and with
  `sponsord_onramp_proxy: none`, you bring the proxy and open its ports). A self-hosted iroh relay
  (Ansible and Compose) is public by design: it terminates its own TLS on tcp/80 + tcp/443 and serves
  QUIC address discovery on udp/7842, with its metrics on loopback. So is a self-hosted
  iroh DNS server (Ansible and Compose): its own TLS on tcp/443 and DNS on udp/53 + tcp/53, with its
  metrics on loopback. On Kubernetes, metrics bind `0.0.0.0` in the pod only behind a ClusterIP
  Service and a NetworkPolicy.
- **Default-deny inbound** (Ansible's `baseline`, nftables; on Compose, your own firewall). SSH is the only
  universally open port; extra public ports are declared via `baseline_extra_inbound`.
- **DevSec host hardening** (Ansible and cloud-init; `os_hardening` + `ssh_hardening`: key-only SSH, no root
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
| [`compose/`](compose/README.md) | The Docker Compose deploy path: the node, `sponsord`, `sponsord-onramp`, an iroh relay, an iroh DNS server, a public gateway and Grafana Alloy, one profile each, and the `decdn-compose` wrapper. |
| [`charts/decdn-node/`](charts/decdn-node/README.md) | The Helm chart; it renders the node's dashboards and alert rules from `monitoring/`. |
| [`monitoring/`](monitoring/README.md) | The deCDN Grafana dashboards and Prometheus alert rules, for the node (`decdn-node/`, every deploy path), sponsord (`sponsord/`, Ansible and Compose), the iroh relay (`iroh-relay/`, Ansible and Compose), the iroh DNS server (`iroh-dns-server/`, Ansible and Compose) and the public gateway (`decdn-gateway/`, Ansible). |
| [`docs/`](docs/requirements.md) | Cross-path operator docs: the two front doors ([node operators](docs/node-operators.md), [publishers](docs/publishers.md)), requirements, lifecycle. |
| [`examples/collection-fleet/`](examples/collection-fleet/README.md) | A starting point for a private repository that deploys from the Galaxy collections alone, with only its own inventory. |
| `scripts/` | Generators for the upstream mirrors (network profiles) and Compose's Alloy config (`render-compose-alloy.sh`), and the release gate. |
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
