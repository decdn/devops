# ansible — deCDN deployment

Declarative Ansible project for the deCDN team. Two deployments, one shared host
baseline:

| Playbook | Purpose | Exposure |
|----------|---------|----------|
| **`site.yml`** (primary) | A public **deCDN node** (`decdn-node`) — the product. | Public QUIC udp/4433 |
| `anvil.yml` (internal) | Our shared **anvil devnet** behind Caddy basic-auth. | Loopback (+ out-of-band tunnel) |

```
baseline   host hardening — DevSec os/ssh, nftables default-deny inbound,
           fail2ban, unattended-upgrades, chrony, an admin sudo user
   │
   ├─ site.yml  → decdn-node   public QUIC udp/4433; metrics+admin loopback;
   │                           release-tarball install; hardened systemd unit
   │
   └─ anvil.yml → anvil + caddy   loopback EVM devnet + per-dev basic auth
```

## Security model

- **Default-deny inbound (nftables).** SSH is the only universally-open port. The node host
  additionally opens **udp/4433** (QUIC) via `baseline_extra_inbound`; everything else
  (anvil 8545, caddy 8080, node metrics 9090, admin RPC 9191) stays **loopback** with no hole.
- **No secrets in the repo.** anvil's mnemonic + caddy basic-auth are **generated on the
  host** (stat-guarded, `no_log`, revealed once). The node's eth keystore is
  **operator-provisioned** and never generated here; its `rpc_url` (which may embed an API
  key) lives in git-ignored `host_vars` and is rendered to a `0600` config.
- **Host hardening via DevSec** (`os_hardening` + `ssh_hardening`): key-only SSH, no root
  login, kernel/sysctl/PAM hardening — applied last, after the admin key is in place.

## Requirements

- Control machine: **Ansible ≥ 2.15**, `ansible-lint`, `yamllint` (and Docker + `molecule`
  + `molecule-plugins[docker]` for the anvil molecule scenario).
- Target: **Debian (bookworm)** host(s) reachable over SSH with a sudo-capable user.

## Setup

```bash
cd ansible
make deps                                    # vendor pinned collections into ./collections
cp inventory/hosts.yml.example inventory/hosts.yml
$EDITOR inventory/hosts.yml                   # set hosts for decdn_nodes and/or anvil_devnet
$EDITOR inventory/group_vars/all.yml          # set ssh_admin_pubkey (REQUIRED)
```

`ssh_admin_pubkey` is **mandatory** — baseline refuses to run `ssh_hardening` (which
disables root + password login) without it, so you can't lock yourself out. After the first
deploy, switch each host's `ansible_user` to your `ssh_admin_user` (default `deploy`).

---

## Deploy the deCDN node (primary)

**Prerequisites** (see `roles/decdn_node/README.md` for the full flow):

1. A published **`v<version>` release** exists (the role downloads the release tarball).
2. Per-node `inventory/host_vars/<node>.yml` (git-ignored) with `decdn_node_version`,
   `decdn_rpc_url`, the three contract addresses, and `decdn_region`. Copy the shipped
   `host_vars/decdn-node-1.yml.example`. Contract addresses are protocol facts — source
   them from the deployment / an ADR, never guess.
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

## Deploy the anvil devnet (internal)

```bash
make check-anvil
make deploy-anvil   # baseline -> anvil -> caddy (loopback)
make add-dev USER_NAME=alice    # mint + reveal a basic-auth dev user
```

On the first anvil deploy the shared **mnemonic** and the `dev` basic-auth password are
printed **once** — save them to the team vault. anvil/caddy bind `127.0.0.1` only; attach a
public path (Cloudflare Tunnel) out-of-band — see the appendix.

---

## Testing

```bash
make lint           # yamllint + ansible-lint (production profile)
make molecule       # docker: converge anvil+caddy, assert eth_chainId/loopback/401 + idempotence
ansible-playbook playbooks/site.yml --syntax-check
```

The anvil stack is covered by the Molecule `default` scenario. The **node** role is verified
statically pre-release (syntax-check, `systemd-analyze verify` on the rendered unit, TOML
validity, fail-loud asserts); a containerised node scenario + live deploy follow once a
`v<version>` release is published (no real chain runs in CI). Molecule never exercises
`baseline` (its `ssh_hardening` would sever the container's own connection); `make check`
covers it as a non-mutating dry run.

## Configuration

Defaults live in each role (`roles/*/defaults/main.yml`); override in `group_vars`
(shared) or `host_vars` (per node, git-ignored). Highlights:

| Var | Default | Notes |
|-----|---------|-------|
| `ssh_admin_user` / `ssh_admin_pubkey` | `deploy` / `""` | **pubkey required**; admin created before SSH hardening. |
| `baseline_extra_inbound` | `[]` | public inbound ports; `decdn_nodes` opens udp/4433. |
| `decdn_node_version` | `""` | **required**; a `v<version>` release must exist. |
| `decdn_rpc_url` + 3 contract addresses | `""` | **required** per node (host_vars); sourced from an ADR/deployment. |
| `decdn_region` / `decdn_bind_port` / `decdn_rate_per_mb` | `""` / `4433` / `10` | node identity, QUIC port, USDC base units/MB. |
| `anvil_chain_id` … `rpc_hostname` | see `roles/anvil`,`roles/caddy` | internal devnet knobs. |

---

## Appendix — public path for the anvil devnet (Cloudflare Tunnel, manual)

Out of scope for the playbook (browser SSO can't be scripted). Expose the loopback caddy
listener via an outbound tunnel — no inbound ports opened:

```bash
cloudflared tunnel login
cloudflared tunnel create rpc-dev      # ingress -> http://127.0.0.1:8080
cloudflared tunnel route dns rpc-dev rpc-dev.decdn.org
sudo systemctl enable --now cloudflared
curl -s -u dev:'<password>' https://rpc-dev.decdn.org \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}'   # -> 0x7a69 (31337)
```
