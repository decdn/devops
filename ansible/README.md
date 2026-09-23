# ansible — deCDN deployment

Declarative Ansible project for deploying deCDN nodes, one or a fleet, over a
hardened host baseline. The roles also ship as the `decdn.node` Galaxy collection.

| Playbook | Purpose | Make target |
|----------|---------|-------------|
| **`site.yml`** | Harden the host and deploy the public **deCDN node** (`decdn-node`). | `make check` / `make deploy` |
| `backup.yml` | Encrypted backup of a node's identity or full state. | `make backup` |
| `decommission.yml` | Stop a node and remove its service (keeps the identity; no on-chain steps). | `make decommission` |

```
baseline        host hardening: DevSec os/ssh, nftables default-deny inbound,
   │            fail2ban, unattended-upgrades, chrony, an admin sudo user
   ├─ grafana_alloy   opt-in Grafana Cloud agent (metrics, journald, traces), loopback-only
   └─ decdn_node      public QUIC udp/4433; metrics + admin loopback; signed-tarball or
                      local-build install; hardened systemd unit; backup/decommission
```

## Security model

The repo-wide model is in the [root README](../README.md#security-model). What is
specific to this path:

- **nftables is the firewall.** SSH plus the node's **udp/4433** (via
  `baseline_extra_inbound`) are the only holes; metrics 9090 and the admin RPC 9191 stay
  loopback. Baseline turns off `os_hardening`'s ufw config template
  (`ufw_manage_defaults: false`) so a misleading DROP-policy `/etc/default/ufw` is never
  written. Do not install or enable ufw: it would replace the nftables ruleset and drop
  QUIC and SSH.
- **Two homes for the RPC URL**: a `0600 /etc/decdn/decdn.env` written on the host
  (preferred; the role gates on it but never reads it back), or a git-ignored
  `host_vars/<node>/secret.yml` the role renders into that same file. Details:
  [`roles/decdn_node/README.md` § Secrets](roles/decdn_node/README.md#secrets).
- **DevSec hardening can't sever the node.** Baseline overrides a few `os_hardening` sysctls so hardening can't sever node
  connectivity: it preserves IPv6 RA/autoconf (`baseline_preserve_ipv6_autoconf`, so
  SLAAC-assigned addresses survive) and can loosen reverse-path filtering for multi-homed
  hosts (`baseline_rp_filter_loose`).

## Requirements

- Control machine: **Ansible ≥ 2.15**, `ansible-lint`, `yamllint`.
- Target: **Debian 12 (bookworm) / 13 (trixie)** or **Ubuntu 24.04 (noble) / 26.04
  (resolute)** host(s), x86_64 or aarch64, reachable over SSH with a sudo-capable user.
  `make molecule` converges the node roles on all four; `baseline` is verified on real
  hosts (see `roles/baseline/README.md` § Platforms).
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

`inventory/hosts.yml` is git-ignored. This repo is public, and real host IPs never belong in
it.

### Private fleet inventory

To track a real fleet, keep its inventory in a **private overlay** outside this repo and
point the deploy targets at it:

```bash
cp -r inventory/fleet.example ../../decdn-fleet     # into a PRIVATE repo/dir, then fill it in
make check  INVENTORY=../../decdn-fleet/hosts.yml LIMIT=<host>
make deploy INVENTORY=../../decdn-fleet/hosts.yml LIMIT=<host>
```

Ansible loads `group_vars/` and `host_vars/` from beside whichever `hosts.yml` you pass, so
the overlay carries its own copies. The template's own `.gitignore` comes along too, so the
private repo never tracks a `host_vars/*/secret.yml`. The public `inventory/group_vars/` and
`inventory/host_vars/` are **not** loaded for it. Settings every node needs regardless of
inventory, currently only the udp/4433 QUIC firewall hole, live in
`playbooks/group_vars/decdn_nodes.yml`, so an overlay can't drop them. Override that per node
in `host_vars` if you have to. Playbook group_vars beat inventory group_vars.

[`inventory/fleet.example/`](inventory/fleet.example/hosts.yml) is the overlay
template: every host in `decdn_nodes`, the chain from `decdn_network`, and the cache
sizing knobs to fill per disk. Add child groups of your own when hosts differ by group
(an origin, an egress cap on metered bandwidth); the template's header shows how.

By default baseline **deploys you as yourself**: the runner (your control-machine `$USER` +
its autodetected `~/.ssh` key, `id_ed25519` > `ecdsa` > `rsa`) is prepended as the head of
the one operator list, `baseline_sudo_users`. Add other admins there — list yourself (same
name) to override the auto-detected head with explicit keys. Set
`baseline_sudo_autodetect_runner: false` to skip the runner and provision only the explicit
list (e.g. from CI). baseline **asserts a non-root account with a key resolves** before
`ssh_hardening` disables root + password login, so you can't lock yourself out.

The inventory template sets **no `ansible_user`**, so Ansible connects as your local `$USER`
— the same account baseline creates. That account doesn't exist yet on a fresh box, so
bootstrap each new host once as a sudo-capable user (root, or the image's default user such
as `ubuntu`):

```bash
make deploy LIMIT=decdn-node-1 ANSIBLE_ARGS='-u root'   # first converge only; swap root for your image's bootstrap user
make deploy LIMIT=decdn-node-1                          # every run after that first converge succeeds
```

Set a per-host `ansible_user` only when the admin account's name differs from your `$USER`
(you listed a different name in `baseline_sudo_users`) or you set
`baseline_sudo_autodetect_runner: false`. Never set it to the bootstrap user: an inventory
`ansible_user` beats `-u`, and root login is gone after the first converge. For the same
reason, add a per-host `ansible_user` only after that host's bootstrap run, or `-u` is
ignored on the first converge.

---

## Deploy the deCDN node (primary)

**Prerequisites** (see `roles/decdn_node/README.md` for the full flow):

1. **Binaries.** Upstream has not tagged a release yet, so the default install method
   is **`manual`**: build `decdn-node` and `decdn` from a `decdn/decdn` checkout and point
   the role at them (`decdn_release_target_dir`, or both `decdn_node_manual_bin_src` and
   `decdn_cli_manual_bin_src`). Cross-compile for aarch64 hosts; the role derives each
   host's target from its architecture and checks the ELF before shipping. Once a
   `v<version>` release exists, switch to `decdn_node_install_method: release` +
   `decdn_node_version`; the role then downloads the tarballs from
   `decdn_node_release_base` and verifies them against the GPG-signed `SHA256SUMS`.
2. **Per-node config** in `inventory/host_vars/<node>/main.yml` (committed): the binary
   sources, `decdn_region`, the cache origin, and the chain, as
   `decdn_network: arbitrum-sepolia`. The network profile supplies `chain_id` and every
   contract address from the role's mirror of upstream's deployment manifest
   ([`roles/decdn_node/README.md` § Network profiles](roles/decdn_node/README.md#network-profiles-decdn_network)),
   so nothing is hand-copied. Plus the one secret, the RPC URL: provisioned as
   `/etc/decdn/decdn.env` on the host (preferred, see [Setup](#setup)) or in a sibling
   git-ignored `secret.yml` (copy the shipped `host_vars/decdn-node-1/secret.yml.example`).
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

Use `LIMIT` when **bringing up a new node**: that host's first converge connects as the
bootstrap user (`ANSIBLE_ARGS='-u root'`, see [Setup](#setup) above), creates the operator
account and then lets `ssh_hardening` disable root + password login. Every later run
connects as your `$USER` with no flag. You do not want that bootstrap play — or its `-u root`
— reaching nodes already serving paid traffic. Same when re-running a single node after a config change, a failed play, or a
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

### Grafana Cloud observability (opt-in)

The play's third role, `grafana_alloy`, installs a loopback-only
[Grafana Alloy](https://grafana.com/docs/alloy/) agent that ships the node's metrics, the
machine's own metrics, journald, the agent's health and the daemon's OTLP traces to your
Grafana Cloud org. One mirrored inventory flag drives both roles:

```yaml
decdn_grafana_cloud_enabled: true   # group_vars or host_vars
```

Only the API token is secret. It lives on each host in `0600 /etc/grafana-alloy.env`, or
in the git-ignored `secret.yml` as `grafana_alloy_api_token`. The endpoints and instance
IDs are ordinary inventory variables. Setup, token handling, upgrade notes, cost
guardrails and rollback: [`roles/grafana_alloy/README.md`](roles/grafana_alloy/README.md).
To import upstream's decdn dashboards and alert rules into that stack, see
[`charts/decdn-node/files/monitoring/`](../charts/decdn-node/files/monitoring/README.md).

### Backup and decommission

```bash
make backup LIMIT=<host>                                           # encrypted identity backup
make backup LIMIT=<host> ANSIBLE_ARGS='-e decdn_backup_scope=full'  # full state (stops the node briefly)
make decommission LIMIT=<host>                                     # typed confirmation; keeps the identity
```

Backups need `decdn_backup_age_recipients` (public keys). Restore, host migration and
the on-chain exit: [`docs/lifecycle.md`](../docs/lifecycle.md).

---

## Testing

```bash
make lint           # yamllint + ansible-lint (production profile)
for pb in playbooks/*.yml; do ansible-playbook "$pb" --syntax-check -i localhost,; done
make molecule       # every molecule scenario, in parallel (needs Docker)
make molecule JOBS=2   # …capped to two at a time on a small machine
make molecule-serial   # …one at a time, when a failure needs readable output

# from the repo ROOT — the only test that uses a real Grafana Alloy binary
make lint-alloy     # render grafana_alloy's templates, then `alloy validate` them
```

`make molecule` runs every scenario under `molecule/`: **`default`** (described below),
`schema` (config key-set drift against the upstream field list), `validation` (bad knobs,
for both roles, must be rejected by their own asserts), `generate-keystore` (opt-in
host-side wallet), `host-env` (host-provisioned `/etc/decdn/decdn.env`),
`slow-readiness` (advisory `/metrics` probe timeout), `grafana-cloud` (the opt-in
observability wiring — see [Grafana Cloud observability](#grafana-cloud-observability-opt-in))
`grafana-cloud-token` (the same wiring with the API token carried through
git-ignored inventory instead: role-authored env file + provenance record),
`os-matrix` (default's plays on Debian 13, Ubuntu 24.04 and Ubuntu 26.04; `default`
itself is Debian 12) and `lifecycle` (a `decdn_network` profile with an override, both
backup scopes decrypted and checked, a rejected and a real decommission).
They are independent, so they run concurrently, and each line of output is prefixed with its scenario name
because the runs interleave. `make molecule-serial` is the escape hatch when that
interleaving gets in the way of reading a failure.

`grafana-cloud` runs against a *stub* Alloy that exits 0 for every subcommand, so it
proves the role's plumbing but cannot prove the rendered `config.alloy` is loadable.
That gap is closed by `make lint-alloy` (repo root; CI job `alloy-config`), which renders
the templates in eight variable combinations — including one with every observability
sub-knob off, which must reproduce the pre-machine-monitoring pipeline exactly — and runs
the **real**, digest-pinned Alloy
binary's `alloy validate` over them plus a check that every `ExecStart` flag actually
exists in `alloy run --help`. Re-run it when bumping `grafana_alloy_version`. See
[`tests/alloy-config/`](tests/alloy-config/).

The `default` scenario converges the **`decdn_node`** role in a privileged systemd
container against a stub daemon: it installs via the `manual` method (no
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
| `decdn_node_install_method` | `manual` | `manual` (local build) until upstream tags a release, then `release` with `decdn_node_version`. |
| `decdn_node_target` | from the host | The release target triple, derived from the host architecture (x86_64 or aarch64). |
| `decdn_network` | `""` | `arbitrum-sepolia` sets `chain_id` and every contract address from the role's manifest mirror; inventory values still win. `""` = set them yourself. |
| `decdn_rpc_url` | `""` | **required** per node, from a host-provisioned `0600 /etc/decdn/decdn.env` (preferred) *or* `host_vars/<node>/secret.yml`. |
| `decdn_region` / `decdn_bind_port` / `decdn_rate_per_mb` | `""` / `4433` / `10` | node identity, QUIC port, USDC base units/MB. |
| `decdn_env_checksum_file` / `decdn_env_overwrite_host_file` | `/etc/decdn/.decdn.env.sha256` / `false` | Provenance record for the secret env file (`0600 root`), and the opt-in that lets an inventory `decdn_rpc_url` overwrite a host-edited one. |
| `decdn_grafana_cloud_enabled` | `false` | ONE mirrored knob (identical default in both roles) wiring on Grafana Cloud observability: installs + configures `grafana_alloy` — node metrics, machine metrics, journald, agent health — AND injects `otlp_endpoint` into `node.toml`. Only the API token is provisioned per host *or* carried by `grafana_alloy_api_token` in git-ignored inventory; the rest are inventory variables. Label/cost guardrails in the role README. |
| `grafana_alloy_api_token` / `_env_checksum_file` / `_overwrite_host_file` | `""` / `/etc/grafana-alloy.env.sha256` / `false` | The dual-homed Grafana Cloud token and its provenance machinery (`#39` parity with the row above); the record path is fixed to `<secret-file>.sha256` and survives disable with the secret. See [`roles/grafana_alloy/README.md`](roles/grafana_alloy/README.md). |
| `decdn_backup_age_recipients` / `decdn_backup_scope` | `[]` / `identity` | Public keys backups are encrypted to (required for `make backup`), and `identity` or `full`. See [`docs/lifecycle.md`](../docs/lifecycle.md). |

---

## Packaging as a Galaxy collection (`decdn.node`)

The three roles (`baseline`, `decdn_node`, `grafana_alloy`) are also packaged as the
distributable **`decdn.node`** collection, for operators who bring their own playbooks.

The collection overlay lives in [`galaxy/`](galaxy/) (`galaxy.yml`, the collection
`README.md`/`CHANGELOG.md`, `meta/runtime.yml`, `build.sh`). It is deliberately **not**
a `galaxy.yml` at the project root: `galaxy/build.sh` stages only the three roles into a
clean `ansible_collections/decdn/node/` tree and builds the artifact, so this project
stays a plain Ansible project (the `make deploy`/`lint` flow is unchanged).

```bash
make build          # stage + build -> build/decdn-node-<version>.tar.gz
make galaxy-check   # build + validate with galaxy-importer (the checks Galaxy runs)
```

CI's `galaxy-build` job builds and validates the collection on every `ansible/**` change.
Publishing happens from a `vX.Y.Z` tag through `.github/workflows/release.yml`, together
with the Helm chart at the same version: see [RELEASING.md](../RELEASING.md). Record every
change under `[Unreleased]` in `galaxy/CHANGELOG.md`.
