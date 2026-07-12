# roles/baseline

Hardened **Debian/Ubuntu host baseline** for the deCDN node deployment
(`playbooks/site.yml`). Run it first; it prepares the host and then locks it down.

## What this role does

In order — the ordering matters:

1. **Base packages** — `curl`, `git`, `jq`, `openssl`, `nftables`, `fail2ban`,
   `unattended-upgrades`, `chrony`, … (override `baseline_packages`).
2. **Sudo operators** — one list, `baseline_sudo_users`, installed **before** SSH is
   hardened so you keep a way in. There is no separate admin knob: the **runner** (this
   control box's `$USER` + its `~/.ssh` key, autodetected `id_ed25519` > `id_ecdsa` >
   `id_rsa`) is prepended as the lockout-critical **head**, so the person running
   `make deploy` is provisioned without being committed anywhere. Set
   `baseline_sudo_autodetect_runner: false` to skip that and provision only the explicit
   list (e.g. CI). Add other admins to `baseline_sudo_users` — each a distinct login (own
   username, home, key(s)); listing yourself there (same name) **overrides** the
   auto-detected head with explicit keys. Every operator is created **key-only**: member
   of `sudo`, a NOPASSWD sudoers drop-in, and a locked password, so sudo / `make deploy`
   needs no become password and no password can authenticate. `baseline_sudo_passwordless`
   (default `true`) is the role-wide default; set it (or a per-entry `passwordless: false`)
   `false` for classic password sudo (you must then set a password on the account
   yourself). The head and every listed operator are rendered by a single primitive
   (`tasks/sudo_account.yml`), so the sudoers.d sanitize / password-lock / check-mode
   logic lives in exactly one place.
3. **Firewall** — nftables **default-deny inbound**; SSH is the only universally-open
   port. Extra public listeners are declared explicitly via `baseline_extra_inbound`.
4. **Auto-patching** — `unattended-upgrades` for security updates.
5. **fail2ban** — aggressive `sshd` jail.
6. **Time sync** — `chrony`.
7. **DevSec hardening (LAST)** — `devsec.hardening.os_hardening` +
   `devsec.hardening.ssh_hardening` (key-only SSH, no root login, kernel/sysctl/PAM
   hardening). Applied last so the admin key is already in place. baseline overrides a
   few `os_hardening` defaults so the CIS baseline can't sever node connectivity: it
   re-enables IPv6 RA/autoconf (`baseline_preserve_ipv6_autoconf`, so SLAAC-assigned
   addresses survive), optionally loosens reverse-path filtering for multi-homed hosts
   (`baseline_rp_filter_loose`), and disables `os_hardening`'s ufw template
   (`ufw_manage_defaults: false`) so no misleading DROP-policy `/etc/default/ufw` is
   written — **nftables is the firewall; do not install or enable ufw, which would
   replace the ruleset and drop QUIC/SSH.**

## Lockout guard

`ssh_hardening` disables root and password auth. The role runs an **unconditional
assert** before any account creation or hardening that aborts the play unless the
resolved operator set (auto-detected runner head + `baseline_sudo_users`) contains at
least one **non-root** account **with a key**. By default the head comes from the
control machine (local `$USER` + `~/.ssh` key), so a stock interactive run "just works".
The assert fires — by design, so you can fix it rather than lock yourself out — when
the whole set has no viable admin, e.g.:

- **No runner head resolves** (no `~/.ssh/id_ed25519|ecdsa|rsa.pub`, `$USER` unset/`root`
  under cron/CI/`sudo`, or `baseline_sudo_autodetect_runner: false`) **and**
  `baseline_sudo_users` is empty — nothing to log in as.
- The only entries resolve to **`root`** (hardening forbids root login) or are
  **keyless** — add a non-root, keyed entry to `baseline_sudo_users`.

Because the head reads the **control node's** `$USER`/`$HOME` of whoever invokes
`ansible-playbook`, a `sudo`/CI run can autodetect a different user/key than you expect —
set `baseline_sudo_autodetect_runner: false` and list admins explicitly in that case.

## Key variables

| Var | Default | Notes |
|-----|---------|-------|
| `baseline_sudo_users` | `[]` | The one operator list. Each item `{name, keys: [...], passwordless?}` (pubkeys only), created key-only. The auto-detected runner head is prepended; a same-name entry here overrides it. |
| `baseline_sudo_autodetect_runner` | `true` | Auto-detect the runner (`$USER` + `~/.ssh` `id_ed25519`/`ecdsa`/`rsa`) and prepend it as the head. `false` = provision only the explicit list (e.g. CI). |
| `baseline_sudo_passwordless` | `true` | Role-wide default sudo mode: NOPASSWD drop-in + locked password (key-only). Per-entry `passwordless: false` overrides; `false` = classic password sudo. |
| `ssh_allow_cidrs` | `[]` | Optional inbound-SSH source allowlist (CIDRs). Empty = any source. |
| `baseline_extra_inbound` | `[]` | Extra public inbound ports. Each item `{proto, port, comment}`. Loopback services need nothing here; the deCDN node opens udp/4433. |
| `baseline_preserve_ipv6_autoconf` | `true` | Re-enable IPv6 RA/autoconf under `os_hardening` (which disables it, breaking SLAAC addresses). Set `false` for statically-addressed IPv6 hosts to keep full CIS IPv6 hardening. |
| `baseline_rp_filter_loose` | `false` | `true` sets loose reverse-path filtering (`rp_filter=2`) for multi-homed/policy-routed nodes; default keeps strict (`1`). |
| `baseline_packages` | see `defaults/main.yml` | Base package set. |

## Dependencies

- Collection: [`devsec.hardening`](https://galaxy.ansible.com/ui/repo/published/devsec/hardening/)
  (`>=10.0.0`) and [`ansible.posix`](https://galaxy.ansible.com/ui/repo/published/ansible/posix/)
  (`>=1.5.0`, for `authorized_key`).

## Platforms

Debian (bookworm), Ubuntu (jammy, noble).
