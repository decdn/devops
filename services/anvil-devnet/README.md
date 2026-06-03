# anvil-devnet — shared deCDN settlement-layer devnet

> **⚠️ Superseded by [`../../ansible/`](../../ansible/README.md).** The canonical anvil
> deployment is now the declarative Ansible project at the repo root, which reproduces this
> service's hardening and adds a full host baseline. This bash + systemd version is kept
> only until the Ansible path is proven on the box, then it will be removed. Prefer
> `ansible/` for new deployments.

A single, persistent **Foundry Anvil** EVM chain that the whole team points their
tooling at. Fixed chain-id, a shared mnemonic (so everyone derives the same pre-funded
accounts), deterministic contract addresses, and state that survives reboots. Public
access is gated by per-dev HTTP basic auth (Caddy) and reached over a Cloudflare Tunnel
at **`https://rpc-dev.decdn.org`**. The anvil RPC itself is bound to `127.0.0.1` and is
never exposed directly.

## Architecture

```
   dev tooling (cast / forge / viem / ethers)
        │  ETH_RPC_URL=https://user:pass@rpc-dev.decdn.org
        ▼
   Cloudflare edge  (TLS for rpc-dev.decdn.org)
        │  outbound tunnel (no inbound ports opened on the VPS)
        ▼
   cloudflared        (systemd: cloudflared.service, user: cloudflared)
        │  http://127.0.0.1:8080
        ▼
   Caddy              (systemd: caddy.service)  ── per-dev basic_auth (bcrypt)
        │  http://127.0.0.1:8545
        ▼
   anvil              (systemd: anvil.service, user: anvil)
        chain-id 31337 · block-time 2s · --state /var/lib/anvil/state.json
        bound to 127.0.0.1:8545 ONLY
```

Three security layers in front of a loopback-only RPC: Cloudflare edge → tunnel (no
open inbound ports) → Caddy basic-auth. Binding anvil to `127.0.0.1` is a hard
requirement enforced in `anvil.service`.

## Files in this service

| Path | Installs to | Purpose |
|------|-------------|---------|
| `etc/systemd/system/anvil.service` | `/etc/systemd/system/` | anvil daemon (dedicated user, hardened, persistent state) |
| `etc/systemd/system/cloudflared.service` | `/etc/systemd/system/` | Cloudflare Tunnel daemon |
| `etc/caddy/Caddyfile` | `/etc/caddy/Caddyfile` | basic-auth + reverse proxy to anvil |
| `etc/caddy/rpc-dev.basicauth.example` | (generated) `/etc/caddy/rpc-dev.basicauth` | shows the credential block shape; real one is generated |
| `etc/cloudflared/config.yml.example` | `/etc/cloudflared/config.yml` | tunnel ingress (fill in tunnel id) |
| `bin/install.sh` | — | one-shot installer (run on the VPS) |
| `bin/bootstrap.sh` | — | generates mnemonic + initial `dev` user, prints once |
| `bin/caddy-add-user.sh` | — | add/update a per-dev basic-auth user |
| `bin/deploy.sh` | — | deterministic contract deploy (TODO: plug in contracts) |
| `bin/reset.sh` | — | wipe chain state + redeploy (typed confirmation) |
| `bin/lib.sh` | — | shared config/helpers sourced by the scripts |
| `contracts/` | — | Foundry project skeleton for the deCDN contracts (TODO) |
| `.env.example` | — | developer environment template |

No secrets are committed. The mnemonic, basic-auth hashes, and tunnel credentials are
all generated/placed on the VPS under `/etc` with tight permissions.

---

## Install (on the VPS, as root)

```bash
git clone <this-repo> /opt/decdn-devops
cd /opt/decdn-devops/services/anvil-devnet
sudo bin/install.sh
```

`install.sh` installs Foundry, Caddy, and cloudflared; creates the `anvil` and
`cloudflared` system users; lays down the units/config; runs `bootstrap.sh` (which
**prints the shared mnemonic and the `dev` password once** — save them to the team dev
docs); then starts anvil and Caddy. It does **not** start cloudflared — that needs the
tunnel credentials you create manually below.

### Cloudflare: manual steps

These require your Cloudflare account/browser and cannot be scripted:

1. **Authenticate** (opens a browser, writes `~/.cloudflared/cert.pem`):
   ```bash
   cloudflared tunnel login
   ```
   The zone **`decdn.org`** must be in this Cloudflare account; pick it when prompted.
2. **Create the tunnel** (prints a `<TUNNEL_ID>` and writes a credentials JSON):
   ```bash
   cloudflared tunnel create rpc-dev
   ```
3. **Place config + credentials** where the service expects them:
   ```bash
   sudo cp /etc/cloudflared/config.yml.example /etc/cloudflared/config.yml
   sudo sed -i 's/<TUNNEL_ID>/PASTE_ID_HERE/g' /etc/cloudflared/config.yml
   sudo mv ~/.cloudflared/<TUNNEL_ID>.json /etc/cloudflared/<TUNNEL_ID>.json
   sudo chown cloudflared:cloudflared /etc/cloudflared/<TUNNEL_ID>.json
   sudo chmod 600 /etc/cloudflared/<TUNNEL_ID>.json
   ```
4. **Create the DNS route** (adds the proxied CNAME `rpc-dev → <id>.cfargotunnel.com`):
   ```bash
   cloudflared tunnel route dns rpc-dev rpc-dev.decdn.org
   ```
   *(Dashboard equivalent: DNS → add CNAME `rpc-dev` → `<TUNNEL_ID>.cfargotunnel.com`,
   proxied/orange-cloud.)*
5. **Start the tunnel**:
   ```bash
   sudo systemctl enable --now cloudflared
   ```
6. **Verify** from your laptop:
   ```bash
   curl -s -u dev:'<password>' https://rpc-dev.decdn.org \
     -H 'content-type: application/json' \
     -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'
   # → {"jsonrpc":"2.0","id":1,"result":"0x7a69"}   (0x7a69 = 31337)
   ```

Optional hardening worth considering in the dashboard: a Cloudflare **WAF rate-limit**
rule on the hostname, and **Cloudflare Access** (e.g. email/SSO) as a second factor in
front of basic-auth.

---

## Developer setup

Get your basic-auth **username/password** and the **shared mnemonic** from the operator
(they are distributed out-of-band — never committed).

```bash
cd <your project>
cp /path/to/services/anvil-devnet/.env.example .env
# edit .env: put your creds into ETH_RPC_URL
```

`.env`:
```dotenv
ETH_RPC_URL=https://YOURUSER:YOURPASS@rpc-dev.decdn.org
CHAIN_ID=31337
```

Use it:
```bash
export $(grep -v '^#' .env | xargs)        # or your tool's dotenv loader
cast chain-id --rpc-url "$ETH_RPC_URL"      # → 31337
cast block-number --rpc-url "$ETH_RPC_URL"

# Your pre-funded account #0 (same for everyone, from the shared mnemonic):
cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index 0
```

The credentials live in the URL userinfo (`https://user:pass@host`), which Foundry,
ethers, viem, and Hardhat all accept, so no extra header config is needed.

---

## Deployed addresses

Deterministic via **CREATE2** (address = `f(factory, salt, initcode)`, independent of
nonce) — identical for every dev and across resets. The live manifest is written to
`/var/lib/anvil/deployments.json` by `deploy.sh`.

> **TODO — contracts not wired up yet.** See [`contracts/README.md`](contracts/README.md).
> Until then the table below is a placeholder.

| Contract | Address |
|----------|---------|
| `TODO_DecdnToken` | `0x0000000000000000000000000000000000000000` |
| `TODO_SettlementVault` | `0x0000000000000000000000000000000000000000` |

Deploy / redeploy:
```bash
sudo bin/deploy.sh
```

---

## Operations

### Add / update a dev's basic-auth credentials
```bash
sudo bin/caddy-add-user.sh alice          # prompts for password (blank = auto-generate)
# auto-generated passwords are printed once — share securely
```
Removing a user: delete their line from `/etc/caddy/rpc-dev.users.tsv`, then
`sudo bin/caddy-add-user.sh <any-existing-user>` (or rerun the regenerate step) and
`sudo systemctl reload caddy`.

### Wipe & redeploy (DESTRUCTIVE)
Resets the chain to genesis for everyone — coordinate first.
```bash
sudo bin/reset.sh        # requires typing "rpc-dev" to confirm
```

### Logs / status
```bash
systemctl status anvil caddy cloudflared
journalctl -u anvil -e
journalctl -u cloudflared -e
```

### State & reboots
`anvil --state /var/lib/anvil/state.json` loads state on boot and dumps it on graceful
stop (SIGTERM). `--state-interval 30` also snapshots every 30s, so an unclean reboot
loses at most ~30s of activity rather than everything.

---

## Security notes

- **anvil binds `127.0.0.1:8545` only** (hard requirement, set in `anvil.service`). The
  only public path is Cloudflare Tunnel → Caddy basic-auth.
- **No secrets in git.** Mnemonic → `/etc/anvil/anvil.env` (600, `anvil:anvil`);
  bcrypt hashes → `/etc/caddy/rpc-dev.*`; tunnel creds → `/etc/cloudflared/*.json`
  (600, `cloudflared`). The repo ships only `*.example` files; `.gitignore` is a backstop.
- **Known limitation:** the mnemonic is passed to anvil as a CLI arg, so it is visible
  in `ps`/`systemctl show` *on the VPS*. Acceptable here — it controls only funded
  **test** accounts on a single-tenant box — but it's exactly why the RPC must never be
  exposed without auth. Don't reuse this mnemonic anywhere with real value.
- **anvil.service is hardened**: dedicated user, `NoNewPrivileges`, `ProtectSystem=strict`,
  private tmp/devices, restricted syscalls and address families.
