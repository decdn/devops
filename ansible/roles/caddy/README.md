# roles/caddy

Puts a **per-dev HTTP basic-auth reverse proxy** in front of the loopback anvil
RPC. The internal anvil devnet (`playbooks/anvil.yml`) runs `baseline → anvil →
caddy`; Caddy is the only thing that faces the internet, and only after auth over
TLS. Internal tooling — **not** part of the public `decdn.node` collection.

## What this role does

1. **Installs Caddy** and ensures `/etc/caddy` (group `caddy`, `0750`).
2. **Mints basic-auth users** on the host into a TSV registry
   (`caddy_users_tsv`), bcrypt-hashed via `caddy hash-password`, and renders the
   `basic_auth` import block (`caddy_basicauth_file`). Credentials are generated
   on the host — never in the repo. `caddy_initial_user` (`dev`) always exists;
   `make add-dev USER_NAME=…` mints more.
3. **Renders the Caddyfile** (validated with `caddy validate`) in one of two
   shapes:
   - `caddy_public: true` (default) — public **HTTPS on `rpc_hostname:443`** with
     auto-TLS (Let's Encrypt). Requires inbound tcp/80+443 (open via
     `baseline_extra_inbound`).
   - `caddy_public: false` — loopback plain-HTTP on `caddy_bind_port` (dev/CI, or
     TLS terminated upstream by a tunnel).
4. **JSON access log** to `caddy_access_log` (self-rolling, 10 MiB × 5), recording
   who hit the RPC. (Access logs move from the journal to this file — query it for
   requests; Caddy's runtime/process logs still go to `journalctl -u caddy`.)
5. **fail2ban `caddy-rpc` jail** — *public listener only*. Watches the access log
   and bans, via nftables, any IP that repeatedly fails basic auth (HTTP 401).
   See below.

## fail2ban: RPC basic-auth brute-force protection

A public RPC behind basic auth invites credential-stuffing. When
`caddy_public: true` and `caddy_fail2ban: true` (both default), the role installs:

- `/etc/fail2ban/filter.d/caddy-rpc.conf` — matches a `401` for the access logger
  in the JSON log and captures the connecting `remote_ip`.
- `/etc/fail2ban/jail.d/caddy-rpc.local` — the `caddy-rpc` jail
  (`banaction = nftables-multiport`, bans on 80+443).

fail2ban itself comes from `baseline` (always run before `caddy` in `anvil.yml`).
On the loopback/CI listener the jail is **skipped** — there's no public attack
surface, and Molecule runs `caddy` without `baseline` (fail2ban absent). Lenient
defaults: **5 failures within 10m → 1h ban**.

Because Molecule never exercises this path, the role self-checks at deploy: it
**asserts fail2ban is installed** before writing the jail (actionable error if you
ran `caddy` standalone without `baseline`), and **verifies the jail loaded**
(`fail2ban-client status caddy-rpc`) after the restart — so a malformed filter
fails loud instead of silently never banning.

Inspect / unban on the host:

```bash
sudo fail2ban-client status caddy-rpc
sudo fail2ban-client set caddy-rpc unbanip <IP>
```

> **Note:** baseline's nftables ruleset uses `flush ruleset`; a baseline nftables
> *reload* (only on template change) clears fail2ban's `f2b-table` until the next
> fail2ban restart. Pre-existing for the `sshd` jail too.

## Key variables

| Var | Default | Notes |
|-----|---------|-------|
| `caddy_public` | `true` | `true` = public HTTPS on `rpc_hostname`; `false` = loopback HTTP on `caddy_bind_port`. |
| `caddy_acme_email` | `""` | Let's Encrypt account contact; empty = anonymous ACME. |
| `caddy_bind_port` | `8080` | Loopback listener port (only when `caddy_public: false`). |
| `rpc_hostname` | `rpc-dev.decdn.org` | Public HTTPS host; printed in `ETH_RPC_URL`. |
| `anvil_host` / `anvil_port` | `127.0.0.1` / `8545` | Upstream RPC to proxy to. |
| `caddy_users_tsv` / `caddy_basicauth_file` | `/etc/caddy/…` | On-host credential registry + generated import. |
| `caddy_initial_user` | `dev` | Always-present basic-auth user. |
| `caddy_access_log` | `/var/log/caddy/rpc-access.log` | JSON access log; the log the fail2ban jail watches. |
| `caddy_fail2ban` | `true` | Enable the `caddy-rpc` jail (public listener only). |
| `caddy_fail2ban_maxretry` | `5` | Failed auths before a ban. |
| `caddy_fail2ban_findtime` | `10m` | Window the failures must fall within. |
| `caddy_fail2ban_bantime` | `1h` | Ban duration. |

## Platforms

Debian (bookworm), Ubuntu (jammy, noble).
