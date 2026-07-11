# roles/baseline

Hardened **Debian/Ubuntu host baseline** for the deCDN node deployment
(`playbooks/site.yml`). Run it first; it prepares the host and then locks it down.

## What this role does

In order — the ordering matters:

1. **Base packages** — `curl`, `git`, `jq`, `openssl`, `nftables`, `fail2ban`,
   `unattended-upgrades`, `chrony`, … (override `baseline_packages`).
2. **Admin sudo user** — creates `ssh_admin_user` and installs its key(s)
   **before** SSH is hardened, so you keep a way in. Both resolve from the control
   machine when left empty: the user falls back to the local `$USER`, and the key is
   autodetected from `~/.ssh` (`id_ed25519` > `id_ecdsa` > `id_rsa`). Extra operator keys
   come from `ssh_admin_extra_pubkeys`. Explicit values always win. By default the
   account is **key-only**: it gets a NOPASSWD sudoers drop-in and its password is
   locked (`ssh_admin_passwordless_sudo`), so sudo / `make deploy` needs no become
   password and no password can authenticate. Set the knob `false` for classic
   password sudo (you must then set a password on the account yourself).
   Additional **named** operator accounts come from `baseline_sudo_users` — each a
   distinct login (own username, home, and key), created key-only exactly like the
   admin (member of `sudo`, NOPASSWD drop-in, locked password). Use this to give
   teammates their own accounts rather than sharing keys on the admin via
   `ssh_admin_extra_pubkeys`.
3. **Firewall** — nftables **default-deny inbound**; SSH is the only universally-open
   port. Extra public listeners are declared explicitly via `baseline_extra_inbound`.
4. **Auto-patching** — `unattended-upgrades` for security updates.
5. **fail2ban** — aggressive `sshd` jail.
6. **Time sync** — `chrony`.
7. **DevSec hardening (LAST)** — `devsec.hardening.os_hardening` +
   `devsec.hardening.ssh_hardening` (key-only SSH, no root login, kernel/sysctl/PAM
   hardening). Applied last so the admin key is already in place.

## Lockout guard

`ssh_hardening` disables root and password auth. The role runs an **unconditional
assert** before any account creation or hardening that aborts the play unless a
**non-root** admin user *and* at least one key resolve. By default these come from
the control machine (local `$USER` + `~/.ssh` key), so a stock interactive run "just
works". The assert fires — by design, so you can fix it rather than lock yourself
out — when any of these hold:

- **No key resolves**: no `~/.ssh/id_ed25519|ecdsa|rsa.pub` and no explicit
  `ssh_admin_pubkey`/`ssh_admin_extra_pubkeys` (the most common real-world trigger).
- **The user is unresolvable**: `ssh_admin_user` empty *and* `$USER` unset (cron, CI,
  or `sudo` with `env_reset`).
- **The user resolves to `root`**: hardening forbids root login, so this would be a
  guaranteed lockout — set `ssh_admin_user` to a non-root account.

Because resolution reads the **control node's** `$USER`/`$HOME` of whoever invokes
`ansible-playbook`, a `sudo`/CI run can autodetect a different user/key than you
expect — set both explicitly in that case.

## Key variables

| Var | Default | Notes |
|-----|---------|-------|
| `ssh_admin_user` | `""` | Admin sudo account; created before SSH hardening. Empty = the control machine's local `$USER`. |
| `ssh_admin_pubkey` | `""` | Admin key. Empty = autodetected from `~/.ssh` (`id_ed25519`/`ecdsa`/`rsa`). Set to override. |
| `ssh_admin_pubkey_autodetect` | `true` | When `ssh_admin_pubkey` is empty, read the operator's default local public key. |
| `ssh_admin_extra_pubkeys` | `[]` | Additional authorized keys (full pubkey strings) on the **shared** admin account — e.g. other operators. |
| `baseline_sudo_users` | `[]` | **Distinct** named sudo accounts, created key-only like the admin. Each item `{name, keys: [...]}` (pubkeys only). |
| `ssh_admin_passwordless_sudo` | `true` | Give the admin user NOPASSWD sudo and lock its password (key-only). Set `false` for classic password sudo. |
| `ssh_allow_cidrs` | `[]` | Optional inbound-SSH source allowlist (CIDRs). Empty = any source. |
| `baseline_extra_inbound` | `[]` | Extra public inbound ports. Each item `{proto, port, comment}`. Loopback services need nothing here; the deCDN node opens udp/4433. |
| `baseline_packages` | see `defaults/main.yml` | Base package set. |

## Dependencies

- Collection: [`devsec.hardening`](https://galaxy.ansible.com/ui/repo/published/devsec/hardening/)
  (`>=10.0.0`) and [`ansible.posix`](https://galaxy.ansible.com/ui/repo/published/ansible/posix/)
  (`>=1.5.0`, for `authorized_key`).

## Platforms

Debian (bookworm), Ubuntu (jammy, noble).
