# Ansible Collection — `decdn.publisher`

What a **[deCDN](https://decdn.org) publisher** runs beside its origin nodes. A
publisher owns a namespace in the `PublisherRegistry` contract and seats the operators
that serve it as origins ([ADR 002](https://github.com/decdn/decdn/blob/main/adr/002-content-addressing.md)).
An origin is a `decdn-node` with an origin backend, deployed with
[`decdn.node`](https://github.com/decdn/devops/tree/main/ansible/galaxy/node)'s
`decdn_node` role; this collection holds the publisher's other services. It is part of
the public, reusable slice of the [`decdn/devops`](https://github.com/decdn/devops)
repository: four roles, and the playbooks that deploy a whole publisher fleet with
them and `decdn.node`'s (see [Usage](#usage)):

| Role | Purpose |
|------|---------|
| `decdn.publisher.sponsord` | The `sponsord` onboarding sponsor (treasury signer + PaymentPool keeper), standalone or beside a node — local binary, a host-side source build or a GPG-verified decdn/sponsord `v*` release (pinned to 0.0.4), `DynamicUser` unit with the API token and treasury wallet as systemd credentials, loopback-only API, `/healthz` deploy gate. `sponsord_network` sets the chain and PaymentPool from upstream's manifest. Restarts refuse while a pool top-up is held; `tasks_from: backup` / `decommission` for day 2. |
| `decdn.publisher.sponsord_onramp` | `sponsord-onramp`, sponsord's public side (Turnstile gate, installers, capability API), on the daemon's host — local binary, a host-side source build or a GPG-verified decdn/sponsord `v*` release (pinned to 0.0.4), `DynamicUser` unit with the daemon token and Turnstile secret as systemd credentials, loopback listener behind Caddy (distro package, ACME TLS, admin API off; or your own proxy), `/healthz` deploy gate; `tasks_from: decommission`. |
| `decdn.publisher.iroh_relay` | A self-hosted [iroh relay](https://github.com/n0-computer/iroh) (`iroh-relay`) for deCDN peers that cannot hole-punch — sha256-pinned upstream release (or a local binary), its own Let's Encrypt TLS, QUIC address discovery, `DynamicUser` unit holding only `CAP_NET_BIND_SERVICE`, loopback metrics, a deploy gate on every listener, a refusal of ports another process holds; access limited to an allowlist of endpoint IDs by default (`iroh_relay_access`; `tasks_from: node-ids` reads nodes' IDs); `tasks_from: decommission`. Point nodes at it with `decdn_relay_urls`. |
| `decdn.publisher.iroh_dns_server` | A self-hosted [iroh DNS server](https://github.com/n0-computer/iroh) (`iroh-dns-server`): the pkarr relay deCDN nodes publish their address records to and the DNS server peers resolve them through, in place of n0's `dns.iroh.link` — sha256-pinned upstream release (or a local binary), its own Let's Encrypt TLS, DNS on one bind address (clear of systemd-resolved's stub), `DynamicUser` unit holding only `CAP_NET_BIND_SERVICE`, loopback metrics, a deploy gate on every listener, `/healthz`'s version and an SOA answer over udp and tcp, a refusal of ports another process holds; `tasks_from: decommission`. Point nodes at it with `decdn_discovery_pkarr_url` and `decdn_discovery_dns_origin`. |

## Requirements

- **ansible-core ≥ 2.15** on the control machine.
- Target: **Debian 12/13** or **Ubuntu 24.04/26.04**, x86_64 or aarch64, over SSH with a
  sudo user. Facts must be gathered (each role derives its release target from the
  host architecture).
- Collection dependencies (installed automatically with this collection):
  `decdn.node (>=0.2.0)`, for the host baseline, observability and the origin and
  cache nodes. None of this collection's roles calls into it: its playbooks do.

## Install

From [Ansible Galaxy](https://galaxy.ansible.com/ui/repo/published/decdn/publisher/),
which also installs `decdn.node`:

```bash
ansible-galaxy collection install decdn.publisher
```

Or pin it in a `requirements.yml`:

```yaml
collections:
  - name: decdn.publisher
    version: ">=0.2.0"     # the first release with the playbooks
```

Each release is listed in the
[CHANGELOG](https://github.com/decdn/devops/blob/main/ansible/galaxy/publisher/CHANGELOG.md)
and as a `publisher-collection-vX.Y.Z`
[GitHub Release](https://github.com/decdn/devops/releases) with the tarball and its
`SHA256SUMS`. To run changes not released yet, build both collections from a checkout
and install the node collection first. The builds carry the last releases' versions
until the next ones, so `--force` replaces installed releases:

```bash
git clone https://github.com/decdn/devops && cd devops/ansible
make build
ansible-galaxy collection install --force build/decdn-node-*.tar.gz
ansible-galaxy collection install --force build/decdn-publisher-*.tar.gz
```

## Usage

### The shipped playbooks

The collection ships the playbooks `decdn/devops` deploys its own fleets with
([`ansible/playbooks/`](https://github.com/decdn/devops/tree/main/ansible/playbooks)),
roles qualified. Each play targets an inventory group and matches nothing unless the
inventory defines it, so `site` deploys whatever the inventory holds:

| Playbook | Runs |
|----------|------|
| `decdn.publisher.site` | `node`, then `publisher`: everything in the inventory |
| `decdn.publisher.publisher` | `origin`, `sponsord`, `iroh_relay`, `iroh_dns_server`, in that order |
| `decdn.publisher.node` | cache nodes: `decdn_nodes` outside `decdn_origin_nodes` (the same playbook as `decdn.node.node`) |
| `decdn.publisher.origin` | origin nodes: `decdn_origin_nodes`, a child group of `decdn_nodes`; refuses one without an origin backend |
| `decdn.publisher.sponsord` | `sponsord_hosts`, then the onramp on `sponsord_onramp_hosts` (which must be `sponsord_hosts` too) |
| `decdn.publisher.iroh_relay` | `iroh_relay_hosts`, one at a time; in allowlist mode (the default) it first reads every node's endpoint ID for the allowlist |
| `decdn.publisher.iroh_dns_server` | `iroh_dns_server_hosts`, one at a time |
| `decdn.publisher.backup` | encrypted backups of the nodes' identities (or full state) and sponsord's credentials |
| `decdn.publisher.decommission` | stops and removes every service on the run's hosts (the onramp's Caddy is stopped and disabled, not removed), then the Alloy agent, after one typed confirmation of the hosts; keeps the keys, never touches the chain |

```bash
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/hosts.yml decdn.publisher.site --check --diff
ansible-playbook -i inventory/hosts.yml decdn.publisher.site
ansible-playbook -i inventory/hosts.yml decdn.publisher.decommission -l <host>
```

Start the inventory from
[`hosts-publisher.yml.example`](https://github.com/decdn/devops/blob/main/ansible/inventory/hosts-publisher.yml.example)
and the `group_vars/` and `host_vars/` beside it. Beyond the roles, the playbooks
bring:

- **the firewall holes**, from the groups a host is in: the node's udp/4433, Caddy's
  tcp/80 + tcp/443 on an onramp host, the relay's tcp/80 + tcp/443 + udp/7842 and the
  DNS server's tcp/443 + udp/53 + tcp/53, one list per host whatever the play, so a
  co-located host renders one firewall. They and the Grafana Alloy per-daemon toggles
  live in the playbooks' own `group_vars/`, which ship beside them;
- **the placement checks** the roles leave out: an origin must be a `decdn_nodes` host
  too and have an origin backend, an onramp a `sponsord_hosts` one, a relay may not
  share a host with an onramp (both want tcp/80 and tcp/443), and a DNS server with
  neither (all want tcp/443);
- **the lifecycle guards**: `decommission` refuses more hosts than
  `decdn_decommission_max_hosts` (default 1) and refuses while sponsord holds an
  unconfirmed pool top-up.

- **Overrides.** The playbooks' `group_vars/<group>.yml` set `baseline_extra_inbound`,
  and playbook group vars beat every inventory group var: change it per host, in
  `host_vars` (or with `-e`). The Alloy toggles come from their `group_vars/all.yml`,
  which beats the inventory's `group_vars/all.yml` and group vars written inline in
  `hosts.yml`, but not its `group_vars/<group>.yml` or `host_vars`, where you can
  override them. Importing a shipped playbook from one of your own changes none of
  this: its plays read the collection's `group_vars/`, not those beside your playbook.
- **Backups.** `decdn.publisher.backup` fetches the nodes' identity archives and
  sponsord's credentials to `backups/` beside your project's `ansible.cfg` (never into
  the installed collection). Without a project `ansible.cfg`, set
  `decdn_backup_local_dir` and `sponsord_backup_local_dir`.
- **Scope.** The repository's Makefile guards (a `LIMIT` preflight, a required `LIMIT`
  for decommission) do not ship: scope a run with `-l` yourself.

### Your own playbook

To compose the roles yourself, a minimal sponsor playbook — `decdn.node`'s baseline
first (so the admin key lands before SSH hardening), then the daemon, then its public
onramp:

```yaml
- name: Provision sponsord and its onramp
  hosts: sponsors
  become: true
  roles:
    - role: decdn.node.baseline
      vars:
        baseline_sudo_users:                               # REQUIRED — lockout guard
          - name: deploy
            keys: ["ssh-ed25519 AAAA... you@host"]
        baseline_sudo_autodetect_runner: false             # provision only the explicit admin above
        baseline_extra_inbound:                            # the onramp's Caddy
          - { proto: tcp, port: 80, comment: "ACME + redirect" }
          - { proto: tcp, port: 443, comment: "sponsord-onramp" }
    - role: decdn.publisher.sponsord
      vars:
        sponsord_network: arbitrum-sepolia   # chain_id + PaymentPool, from upstream's manifest
      # Also REQUIRED per host: sponsord_pool_id, the treasury keystore and password
      # (host-provisioned, or sponsord_generate_treasury_wallet), and the RPC URL
      # (host-provisioned /etc/sponsord/secret.env, or sponsord_rpc_url in a
      # git-ignored secret.yml).
    - role: decdn.publisher.sponsord_onramp
      vars:
        sponsord_onramp_domain: downloads.example.org      # Caddy's ACME name
      # Also REQUIRED: sponsord_onramp_rpc_url (public, served to every user), the
      # Turnstile sitekey, and the Turnstile secret (host-provisioned
      # /etc/sponsord/turnstile-secret, or sponsord_onramp_turnstile_secret in a
      # git-ignored secret.yml).
```

Of the shipped playbooks' placement checks, three concern this collection's roles,
which do not check them, so a playbook of your own must keep them: `sponsord_onramp` runs on a
`sponsord` host (it reads the daemon's API token and calls it on loopback); an iroh
relay does not share a host with the onramp (both want tcp/80 and tcp/443); an iroh
DNS server shares a host with neither (all want tcp/443). The relay and DNS server
roles also refuse ports another process holds; the onramp's Caddy does not check. See each role's README for the full variable list and
day-2 ops:

- [`roles/sponsord`](https://github.com/decdn/devops/tree/main/ansible/roles/sponsord)
- [`roles/sponsord_onramp`](https://github.com/decdn/devops/tree/main/ansible/roles/sponsord_onramp)
- [`roles/iroh_relay`](https://github.com/decdn/devops/tree/main/ansible/roles/iroh_relay)
- [`roles/iroh_dns_server`](https://github.com/decdn/devops/tree/main/ansible/roles/iroh_dns_server)

## Security model

Backends bind `127.0.0.1`. `sponsord` has no public listener. `sponsord_onramp`
listens on loopback too: Caddy is its public side, so a host that runs it opens
tcp/80 and tcp/443 for Caddy in `baseline_extra_inbound` (the shipped playbooks
derive that from `sponsord_onramp_hosts`; from your own playbook, add them yourself).
`iroh_relay` is public by design and terminates its own TLS: it binds tcp/80, tcp/443
and udp/7842 on every address (its metrics stay on loopback), so a relay host opens
those three. `iroh_dns_server` is public by design too: it terminates its own TLS on
tcp/443 and answers DNS on udp/53 and tcp/53 at one address (its metrics and health
listener stay on loopback), so a DNS server host opens those three. No secrets ship
in the collection or are committed: the treasury keystore, the RPC URL and the
Turnstile secret are host-provisioned or rendered to `0600` files. The keystore, its
password, the API token and the Turnstile secret reach the daemons as systemd
credentials; the RPC URL, as an `EnvironmentFile`.

## License

MIT © deCDN Contributors. Protocol facts trace to the deCDN ADRs, never invented here.
