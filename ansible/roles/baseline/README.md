# roles/baseline

Hardened **Debian/Ubuntu host baseline**, shared by every deCDN deployment in this
repo (the public node via `playbooks/site.yml`, the internal anvil devnet via
`playbooks/anvil.yml`). Run it first; it prepares the host and then locks it down.

## What this role does

In order — the ordering matters:

1. **Base packages** — `curl`, `git`, `jq`, `openssl`, `nftables`, `fail2ban`,
   `unattended-upgrades`, `chrony`, … (override `baseline_packages`).
2. **Admin sudo user** — creates `ssh_admin_user` and installs `ssh_admin_pubkey`
   **before** SSH is hardened, so you keep a way in.
3. **Firewall** — nftables **default-deny inbound**; SSH is the only universally-open
   port. Extra public listeners are declared explicitly via `baseline_extra_inbound`.
4. **Auto-patching** — `unattended-upgrades` for security updates.
5. **fail2ban** — aggressive `sshd` jail.
6. **Time sync** — `chrony`.
7. **DevSec hardening (LAST)** — `devsec.hardening.os_hardening` +
   `devsec.hardening.ssh_hardening` (key-only SSH, no root login, kernel/sysctl/PAM
   hardening). Applied last so the admin key is already in place.

## Lockout guard

`ssh_hardening` disables root and password auth. The role **asserts** that
`ssh_admin_user` and `ssh_admin_pubkey` are set before it runs — set both for any
real deploy, or you will lock yourself out. (Set `ssh_admin_user: ""` to skip the
admin account + SSH hardening entirely, as the Molecule container does.)

## Key variables

| Var | Default | Notes |
|-----|---------|-------|
| `ssh_admin_user` | `deploy` | Admin sudo account; created before SSH hardening. `""` skips it. |
| `ssh_admin_pubkey` | `""` | **Required** for a real deploy — the lockout guard asserts it. |
| `ssh_allow_cidrs` | `[]` | Optional inbound-SSH source allowlist (CIDRs). Empty = any source. |
| `baseline_extra_inbound` | `[]` | Extra public inbound ports. Each item `{proto, port, comment}`. Loopback services need nothing here; the deCDN node opens udp/4433. |
| `baseline_packages` | see `defaults/main.yml` | Base package set. |

## Dependencies

- Collection: [`devsec.hardening`](https://galaxy.ansible.com/ui/repo/published/devsec/hardening/)
  (`>=10.0.0`) and [`ansible.posix`](https://galaxy.ansible.com/ui/repo/published/ansible/posix/)
  (`>=1.5.0`, for `authorized_key`).

## Platforms

Debian (bookworm), Ubuntu (jammy, noble).
