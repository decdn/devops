# ansible — deCDN deployment

Declarative Ansible project for deploying a deCDN node. One deployment over a shared host
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
  (node metrics 9090, admin RPC 9191) stays **loopback** with no hole. **nftables is the
  firewall** — baseline turns off `os_hardening`'s ufw config template (`ufw_manage_defaults:
  false`) so a misleading DROP-policy `/etc/default/ufw` is never written; and, separately,
  operators must not install or enable ufw, which would replace the nftables ruleset and
  drop QUIC/SSH.
- **No secrets in the repo.** The node's eth keystore is **operator-provisioned** and never
  generated here; its `rpc_url` (which may embed an API key) is provisioned the same way —
  a `0600 /etc/decdn/decdn.env` written on the target host, which the role gates on but
  never reads back — or, if you prefer, carried in a git-ignored
  `host_vars/<node>/secret.yml` (the rest of `host_vars` is committed, non-secret config)
  and rendered to that same `0600` file.
- **Host hardening via DevSec** (`os_hardening` + `ssh_hardening`): key-only SSH, no root
  login, kernel/sysctl/PAM hardening — applied last, after the admin key is in place.
  baseline overrides a few `os_hardening` sysctls so hardening can't sever node
  connectivity: it preserves IPv6 RA/autoconf (`baseline_preserve_ipv6_autoconf`, so
  SLAAC-assigned addresses survive) and can loosen reverse-path filtering for multi-homed
  hosts (`baseline_rp_filter_loose`).

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
```

The per-node **secret** (`decdn_rpc_url`, which may embed a provider API key, plus any
environment-borne secrets like AWS keys for an S3 origin) has two homes — pick one.
**Preferred:** provision a `0600 /etc/decdn/decdn.env` on the target host and leave
`decdn_rpc_url` empty, so nothing sensitive is stored on or transits this machine. The role
then leaves that file's contents alone, enforcing only `0600 decdn:decdn`. Full commands and
the file format are in
[`roles/decdn_node/README.md` § Secrets](roles/decdn_node/README.md#secrets) — the single
canonical copy; don't duplicate them here.

**Or** carry it in inventory, and the role authors `decdn.env` from those values on every run:

```bash
cp inventory/host_vars/decdn-node-1/secret.yml.example inventory/host_vars/decdn-node-1/secret.yml
$EDITOR inventory/host_vars/decdn-node-1/secret.yml   # set decdn_rpc_url
```

The role fails loud when neither exists, and — once it has recorded a checksum for the file —
when the two would collide: an inventory value that would discard a host-side edit, or an
empty `decdn_rpc_url` that turns out to mean "`secret.yml` went missing" rather than "the host
owns this file".

Your `hosts.yml` is no longer force-ignored — commit it in your fork if you want, or keep
it local.

By default baseline **deploys you as yourself**: the runner (your control-machine `$USER` +
its autodetected `~/.ssh` key, `id_ed25519` > `ecdsa` > `rsa`) is prepended as the head of
the one operator list, `baseline_sudo_users`. Add other admins there — list yourself (same
name) to override the auto-detected head with explicit keys. Set
`baseline_sudo_autodetect_runner: false` to skip the runner and provision only the explicit
list (e.g. from CI). baseline **asserts a non-root account with a key resolves** before
`ssh_hardening` disables root + password login, so you can't lock yourself out. After the
first deploy, switch each host's `ansible_user` to that admin account (your local username
unless you listed one).

---

## Deploy the deCDN node (primary)

**Prerequisites** (see `roles/decdn_node/README.md` for the full flow):

1. A published **`v<version>` release** exists and is **publicly downloadable** — the role
   fetches the release tarball from `decdn_node_release_base`
   (default `https://github.com/decdn/decdn/releases/download`). To install from a mirror,
   override `decdn_node_release_base`; to deploy a locally-built binary with no release at
   all, use the **`manual`** install method (`decdn_node_install_method: manual` +
   `decdn_node_manual_bin_src` / `decdn_cli_manual_bin_src`).
2. Per-node config in `inventory/host_vars/<node>/main.yml` (committed) —
   the install method + binary sources, the **four** required contract addresses,
   `decdn_region`, cache origin, … — plus the one secret, `decdn_rpc_url`, either
   provisioned as `/etc/decdn/decdn.env` on the host (preferred — see
   [Setup](#setup)) or in a sibling git-ignored `secret.yml` (copy the shipped
   `host_vars/decdn-node-1/secret.yml.example`).
   The committed `main.yml` already carries the current Arbitrum Sepolia addresses; edit
   `decdn_region`, the binary paths and the cache origin for your node. Contract addresses
   are protocol facts — copy them from the upstream deployment manifest
   `decdn/contracts/deployments/<chainId>.json`, never guess.
3. The **eth keystore + password file** provisioned on the host (operator step — the wallet
   must be funded + staked per the deCDN node-onboarding ADR, 019). As the `decdn` user,
   create the password file FIRST (`key-gen` reads it, never creates it), then generate the
   keys into the data dir — pass `--output-dir` explicitly (a bare `decdn key-gen` writes to
   `~/.decdn`, which the node won't read). Full copy-pasteable sequence: see
   [`roles/decdn_node/README.md`](roles/decdn_node/README.md) step 2. Or set
   `decdn_node_generate_keystore: true` to have the role do all of that on first converge
   (never overwriting existing material); funding + staking stay manual regardless.

```bash
make check          # dry run (--check --diff); asserts fire if required knobs are missing
make deploy         # provision + start the node
```

Both targets are **fleet-wide by default** — every host in `decdn_nodes`. Scope a run with
`LIMIT`:

```bash
make check  LIMIT=decdn-node-1                    # dry-run one host
make deploy LIMIT=decdn-node-1                    # converge one host
make deploy LIMIT='decdn-node-1,decdn-node-2'     # a list
make deploy LIMIT='!decdn-node-2'                 # any ansible host pattern
```

Quote the pattern at your own prompt — your shell runs before make does, and eats a bare
`!decdn-node-2` (history expansion) or `decdn-node-*` (globbing).

Use `LIMIT` when **bringing up a new node**: that host's first converge creates the
operator account and then lets `ssh_hardening` disable root + password login — after which
you switch its `ansible_user` by hand (see [Setup](#setup) above; the converge does not
edit your inventory). You do not want that play re-converging nodes already serving
paid traffic. Same when re-running a single node after a config change, a failed play, or a
binary bump.

`make check`/`make deploy` refuse to run if `LIMIT` or `ANSIBLE_ARGS` reaches them from an
exported shell variable, or if `LIMIT` expands empty — both are ways a run looks scoped but
is silently fleet-wide.

`ANSIBLE_ARGS` passes anything else straight through. Quote the whole value at your prompt,
or make will read the extra words as its own goals and flags (a bare `-vv` is make's `-v`);
the recipe's shell then splits it back into separate flags, so inner quoting works. Write a
literal `$` as `$$`:

```bash
make deploy LIMIT=decdn-node-1 ANSIBLE_ARGS='--tags decdn_node -vv'
make deploy LIMIT=decdn-node-1 ANSIBLE_ARGS='--start-at-task="Install the decdn binaries"'
```

> **Watch the PLAY RECAP.** A *well-formed* argument that selects nothing is not an error:
> `--tags decdn-node` (hyphen, vs the real `decdn_node`) runs zero tasks and still exits 0,
> as does a `--limit` matching a host outside `decdn_nodes`. A malformed flag fails loudly;
> these do not. Confirm the recap lists the hosts you expected.

Then confirm:

```bash
systemctl status decdn-node
ss -lun | grep 4433            # public QUIC listener
ss -ltn | grep -E '9090|9191'  # metrics + admin — 127.0.0.1 ONLY
curl -s 127.0.0.1:9090/metrics # 200 once up
decdn node health              # admin RPC; full readiness needs on-chain registration
decdn config validate --config /etc/decdn/node.toml   # the role runs this too, on every deploy
```

The node serves paid traffic only **after** on-chain stake + registration (ADR 019
§2.2–2.3) — an operator action, not automated here, but no longer a raw contract call:
`decdn setup` walks the whole of Phase 2, and `decdn node bond` / `register` are the
primitives underneath it. All take `--dry-run`. See
[`roles/decdn_node/README.md`](roles/decdn_node/README.md#on-chain-onboarding).

---

## Testing

```bash
make lint           # yamllint + ansible-lint (production profile)
ansible-playbook playbooks/site.yml --syntax-check
make molecule       # containerised converge + idempotence + verify (needs Docker)
```

`make molecule` converges the **`decdn_node`** role in a privileged systemd container
against a stub daemon (`molecule/default/`): it installs via the `manual` method (no
published release needed), stages a placeholder keystore, renders `node.toml` + the
hardened unit, starts the service, and passes the role's own `/metrics` readiness probe;
`verify.yml` then asserts the node user, valid TOML, a valid systemd unit, loopback-only
metrics binding, and the `0600` secret env file. It does **not** exercise real node logic
or a live chain — full paid-traffic readiness still needs on-chain registration and a real
release. `baseline` is not exercised in a container — the scenario connects over Docker
(not SSH), and baseline's host-level hardening (nftables default-deny, DevSec os/ssh
hardening, fail2ban) isn't meaningful in a throwaway container; `make check` covers it as
a non-mutating dry run.

## Configuration

Defaults live in each role (`roles/*/defaults/main.yml`); override in `group_vars`
(shared) or `host_vars` (per node; `main.yml` committed config, `secret.yml` git-ignored for
the RPC URL when it is not provisioned on the host instead). Highlights:

| Var | Default | Notes |
|-----|---------|-------|
| `baseline_sudo_users` | `[]` | The one operator list (`{name, keys, passwordless?}`); the auto-detected runner head (`$USER` + `~/.ssh` key) is prepended, all created before SSH hardening. |
| `baseline_sudo_autodetect_runner` / `baseline_sudo_passwordless` | `true` / `true` | Prepend the runner as head (`false` = explicit list only); key-only NOPASSWD + locked-password default. |
| `baseline_extra_inbound` | `[]` | public inbound ports; `decdn_nodes` opens udp/4433. |
| `baseline_preserve_ipv6_autoconf` | `true` | Keep IPv6 RA/autoconf under hardening; set `false` for static-IPv6 hosts. |
| `baseline_rp_filter_loose` | `false` | `true` loosens reverse-path filtering (`rp_filter=2`) for multi-homed nodes. |
| `decdn_node_version` | `""` | **required**; a `v<version>` release must exist. |
| `decdn_rpc_url` + 3 contract addresses | `""` | **required** per node — `rpc_url` from a host-provisioned `0600 /etc/decdn/decdn.env` (preferred) *or* `host_vars/<node>/secret.yml`, addresses in `main.yml`; sourced from an ADR/deployment. |
| `decdn_region` / `decdn_bind_port` / `decdn_rate_per_mb` | `""` / `4433` / `10` | node identity, QUIC port, USDC base units/MB. |
| `decdn_env_checksum_file` / `decdn_env_overwrite_host_file` | `/etc/decdn/.decdn.env.sha256` / `false` | Provenance record for the secret env file (`0600 root`), and the opt-in that lets an inventory `decdn_rpc_url` overwrite a host-edited one. |

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
