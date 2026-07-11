# ansible — deCDN deployment

Declarative Ansible project for the deCDN team. One deployment over a shared host
baseline:

| Playbook | Purpose | Exposure |
|----------|---------|----------|
| **`site.yml`** | A public **deCDN node** (`decdn-node`) — the product. | Public QUIC udp/4433 |

```
baseline   host hardening — DevSec os/ssh, nftables default-deny inbound,
           fail2ban, unattended-upgrades, chrony, an admin sudo user
   │
   └─ site.yml  → decdn-node   public QUIC udp/4433; metrics+admin loopback;
                               release-tarball install; hardened systemd unit
```

## Security model

- **Default-deny inbound (nftables).** SSH is the only universally-open port. The node host
  additionally opens **udp/4433** (QUIC) via `baseline_extra_inbound`. Everything else
  (node metrics 9090, admin RPC 9191) stays **loopback** with no hole.
- **No secrets in the repo.** The node's eth keystore is **operator-provisioned** and never
  generated here; its `rpc_url` (which may embed an API key) lives in a git-ignored
  `host_vars/<node>/secret.yml` (the rest of `host_vars` is committed, non-secret config) and
  is rendered to a `0600` config.
- **Host hardening via DevSec** (`os_hardening` + `ssh_hardening`): key-only SSH, no root
  login, kernel/sysctl/PAM hardening — applied last, after the admin key is in place.

## Requirements

- Control machine: **Ansible ≥ 2.15**, `ansible-lint`, `yamllint`.
- Target: **Debian (bookworm)** host(s) reachable over SSH with a sudo-capable user.
  - **Ubuntu sudo-rs note:** 25.10+ (and 26.04) ship `sudo-rs` as the default `sudo`,
    which doesn't honor the custom `-p` become prompt Ansible relies on — so
    `--ask-become-pass` hangs with "Timeout waiting for privilege escalation prompt". On
    an affected host uncomment `ansible_become_exe: /usr/bin/sudo.ws` for that host in
    `hosts.yml` (see the note in `inventory/hosts.yml.example`) to route become through
    classic sudo.

## Setup

```bash
cd ansible
make deps                                    # vendor pinned collections into ./collections
cp inventory/hosts.yml.example inventory/hosts.yml
$EDITOR inventory/hosts.yml                   # set hosts for decdn_nodes
$EDITOR inventory/group_vars/all.yml          # optional: override admin user/keys, allowlists
# Per-node RPC secret (the rest of host_vars/<node>/main.yml is committed config):
cp inventory/host_vars/decdn-node-1/secret.yml.example inventory/host_vars/decdn-node-1/secret.yml
$EDITOR inventory/host_vars/decdn-node-1/secret.yml   # set decdn_rpc_url
```

Your `hosts.yml` is no longer force-ignored — commit it in your fork if you want, or keep
it local.

By default baseline **deploys you as yourself**: an empty `ssh_admin_user` resolves to your
control-machine `$USER`, and an empty `ssh_admin_pubkey` is autodetected from `~/.ssh`
(`id_ed25519` > `ecdsa` > `rsa`). Add teammates' keys via `ssh_admin_extra_pubkeys`. Set
`ssh_admin_user`/`ssh_admin_pubkey` explicitly to override (e.g. a shared `deploy` account,
or when deploying from CI). baseline **asserts a key resolves** before `ssh_hardening`
disables root + password login, so you can't lock yourself out. After the first deploy,
switch each host's `ansible_user` to that admin account (your local username unless you set
one).

---

## Deploy the deCDN node (primary)

**Prerequisites** (see `roles/decdn_node/README.md` for the full flow):

1. A published **`v<version>` release** exists (the role downloads the release tarball).
2. Per-node config in `inventory/host_vars/<node>/main.yml` (committed) —
   `decdn_node_version`, the three contract addresses, `decdn_region`, cache origin, … — plus
   the one secret, `decdn_rpc_url`, in a sibling git-ignored `secret.yml` (copy the shipped
   `host_vars/decdn-node-1/secret.yml.example`). The committed `main.yml` already carries the
   Arbitrum Sepolia genesis contract addresses; edit `decdn_region` + cache origin for your
   node. Contract addresses are protocol facts — source them from the deployment / an ADR,
   never guess.
3. The **eth keystore + password file** provisioned on the host (operator step — the wallet
   must be funded + staked per `decdn/adr/019`). Generate with, as the `decdn` user:
   `decdn key-gen --output-dir /var/lib/decdn --password-file /etc/decdn/keystore.password`.

```bash
make check          # dry run (--check --diff); asserts fire if required knobs are missing
make deploy         # provision + start the node
```

Then confirm:

```bash
systemctl status decdn-node
ss -lun | grep 4433            # public QUIC listener
ss -ltn | grep -E '9090|9191'  # metrics + admin — 127.0.0.1 ONLY
curl -s 127.0.0.1:9090/metrics # 200 once up
decdn node health              # admin RPC; full readiness needs on-chain registration
```

The node serves paid traffic only **after** on-chain stake + registration (the
`CapacityBond` txns of ADR 019 §2.2–2.3) — an operator action, not automated here, and
with no turnkey CLI yet (see `roles/decdn_node/README.md`).

---

## Testing

```bash
make lint           # yamllint + ansible-lint (production profile)
ansible-playbook playbooks/site.yml --syntax-check
```

The **node** role is verified statically pre-release (syntax-check, `systemd-analyze verify`
on the rendered unit, TOML validity, fail-loud asserts); a live deploy follows once a
`v<version>` release is published (no real chain runs in CI). `baseline` is not exercised in
a container (its `ssh_hardening` would sever the connection); `make check` covers it as a
non-mutating dry run.

## Configuration

Defaults live in each role (`roles/*/defaults/main.yml`); override in `group_vars`
(shared) or `host_vars` (per node; `main.yml` committed config, `secret.yml` git-ignored for
the RPC URL). Highlights:

| Var | Default | Notes |
|-----|---------|-------|
| `ssh_admin_user` / `ssh_admin_pubkey` | `""` / `""` | Empty = local `$USER` + autodetected `~/.ssh` key; admin created before SSH hardening. |
| `ssh_admin_extra_pubkeys` | `[]` | Extra authorized keys for the admin user (teammates). |
| `baseline_extra_inbound` | `[]` | public inbound ports; `decdn_nodes` opens udp/4433. |
| `decdn_node_version` | `""` | **required**; a `v<version>` release must exist. |
| `decdn_rpc_url` + 3 contract addresses | `""` | **required** per node — `rpc_url` in `host_vars/<node>/secret.yml`, addresses in `main.yml`; sourced from an ADR/deployment. |
| `decdn_region` / `decdn_bind_port` / `decdn_rate_per_mb` | `""` / `4433` / `10` | node identity, QUIC port, USDC base units/MB. |

---

## Packaging as a Galaxy collection (`decdn.node`)

The two roles (`baseline` + `decdn_node`) are also packaged as the distributable
**`decdn.node`** collection — deployment options for external node operators.

The collection overlay lives in [`galaxy/`](galaxy/) (`galaxy.yml`, the collection
`README.md`/`CHANGELOG.md`, `meta/runtime.yml`, `build.sh`). It is deliberately **not**
a `galaxy.yml` at the project root: `galaxy/build.sh` stages only the two roles into a
clean `ansible_collections/decdn/node/` tree and builds the artifact, so this project
stays a plain Ansible project (the internal `make deploy`/`lint` flow is unchanged).

```bash
make build          # stage + build -> build/decdn-node-<version>.tar.gz
make galaxy-check   # build + validate with galaxy-importer (the checks Galaxy runs)
```

Publishing is a **manual** step (no auto-publish workflow, no token in CI yet):

```bash
ansible-galaxy collection publish build/decdn-node-*.tar.gz --api-key "$GALAXY_TOKEN"
```

Bump `version:` in `galaxy/galaxy.yml` and add a `galaxy/CHANGELOG.md` entry per release.
CI's `galaxy-build` job builds + validates the collection on every `ansible/**` change but
never publishes.
