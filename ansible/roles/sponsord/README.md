# Role: `sponsord`

Deploys [sponsord](https://github.com/decdn/sponsord), the deCDN onboarding sponsor.
It holds the **treasury wallet**, which owns one `PaymentPool` pool, and does two
things:

- signs capped, expiring capabilities for callers that present its API token;
- tops the pool up from the treasury whenever it runs low.

It is independent of the node. It needs an RPC endpoint and the PaymentPool contract,
never a local `decdn-node`, so it can run on its own host or beside a node.

The role covers the daemon only. Its public companion, `sponsord-onramp` (Turnstile
gate, installers, behind a TLS reverse proxy), is the
[`sponsord_onramp`](../sponsord_onramp/README.md) role: list the host in
`sponsord_onramp_hosts` too. It runs on the same host and reads the API token from
`/etc/sponsord/api-token`.

## What it does

- **Installs the binary.**
  - `manual` (the default) copies a binary built from a `decdn/sponsord` checkout
    on the control machine (`sponsord_manual_bin_src`, or
    `sponsord_release_target_dir` with an ELF/arch check).
  - `release` downloads `sponsord-v<version>` and verifies it against the
    GPG-signed `SHA256SUMS`, using `files/sponsord-release-KEYS.asc`, a copy of
    upstream's `KEYS`.
  - Upstream has cut no release yet, so `manual` is the only working method today.
- **Places the secrets.** All of them live under `/etc/sponsord`, root 0600:

  | File | Who provides it |
  |------|-----------------|
  | `api-token` | The role generates it on the host when absent and never replaces it, because the onramp (or your own gate) uses it. |
  | `treasury-keystore.json`, `treasury-password` | **You** do, or, with `sponsord_generate_treasury_wallet: true`, the role creates them on the host when the keystore is absent (and never replaces an existing one). |
  | `secret.env` (`SPONSORD_RPC_URL`) | `sponsord_rpc_url` from inventory, or a file you write on the host. The two-way rules match `decdn_rpc_url`: an empty `sponsord_rpc_url` with a file the role wrote earlier fails the deploy, because that means `secret.yml` went missing. A host-written file may hold `SPONSORD_RPC_URL` **only**: as an `EnvironmentFile` it would override every other setting, so the role refuses any other key in it. |

- **Writes non-secret settings** to `/etc/sponsord/sponsord.env` (0644): bind
  address, chain, PaymentPool, pool id and any limits you set.
- **Runs a hardened unit.** `sponsord.service` runs with `DynamicUser=`, which gives
  it no persistent uid, no state directory and a read-only filesystem. systemd hands
  it the three secret files as `LoadCredential=` credentials, so they never sit in
  its environment.
  - The keystore needs one extra step. Newer systemd writes credentials 0440
    (seen on Ubuntu 24.04's systemd 255; Debian 12's 252 still writes 0400), and
    sponsord refuses a keystore with any group bit. So `ExecStartPre` copies that
    one credential at 0600 into the unit's private, tmpfs `RuntimeDirectory`.
  - Upstream's reference unit reads it straight from the credentials directory, and
    fails on Ubuntu 24.04
    ([decdn/sponsord#36](https://github.com/decdn/sponsord/issues/36)).
- **Gates the deploy on `/healthz`.** sponsord binds only after it has decrypted the
  keystore and confirmed on-chain that the treasury owns `sponsord_pool_id`. If
  `/healthz` does not answer 200 within the readiness window, the deploy fails.
  sponsord has no `config validate` command, so this is the config check.
- **Restarts on out-of-band changes.** The role records a hash of everything the
  daemon starts from (credentials, both env files, the unit, the binary), once the
  daemon is healthy. If any of them differs on the next run, it restarts the daemon:
  - you replaced a credential or edited a host-provisioned `secret.env`;
  - an earlier run changed a file and then failed before its restart handler ran.

## Before the first deploy

There are two ways to get the treasury wallet onto the host. Either the role
generates it there (below), or you create it elsewhere and copy it in (steps 1-2).

**Generated on the host.** Set `sponsord_generate_treasury_wallet: true` and
`sponsord_decdn_cli_bin_src` (a decdn CLI built for the host), leave
`sponsord_pool_id` empty, and do steps 3-4 below. The first deploy then:

- installs that CLI at `/usr/local/lib/sponsord/decdn`, apart from any node's
  `decdn`;
- runs `decdn key-gen` on the host, writes a random password beside the keystore,
  and records the address in `/etc/sponsord/treasury-address`;
- installs the binary, the API token and `secret.env`, then **stops** with the
  wallet's address and the `decdn pool open` command to run on the host.

Fund the address with USDC and gas, run that command, put the pool id it prints in
`sponsord_pool_id`, and deploy again. The key never leaves the host, so back up
`/etc/sponsord/treasury-keystore.json` and `treasury-password` yourself.

**Created elsewhere.**

1. **Create the treasury wallet** with the decdn CLI (`decdn key-gen`). **Open its
   pool** from it (`decdn pool open`), which prints the pool id. Fund the wallet with
   USDC plus gas.
   - This is a hot key: hold only a few top-ups' worth.
2. **Copy the wallet files onto the host**, as root:

   ```bash
   umask 077
   sudo mkdir -p /etc/sponsord
   sudo install -m 0600 treasury-keystore.json /etc/sponsord/treasury-keystore.json
   sudo install -m 0600 treasury-password      /etc/sponsord/treasury-password
   ```

3. **Provide the RPC URL**, either way:
   - `/etc/sponsord/secret.env` on the host (see `files/secret.env.example`);
   - `sponsord_rpc_url` in the git-ignored `host_vars/<host>/secret.yml`.
4. **Set inventory:** `sponsord_network: arbitrum-sepolia` (or `sponsord_chain_id` +
   `sponsord_payment_pool_address`), plus `sponsord_pool_id`.

Then run `make deploy-sponsord` from `ansible/`. Hosts in `sponsord_hosts` are also
deployed by `make deploy`, through `site.yml`.

## Variables

See [`defaults/main.yml`](defaults/main.yml) for the full list with comments.

| Variable | Default | Notes |
|----------|---------|-------|
| `sponsord_install_method` | `manual` | `manual` or `release` |
| `sponsord_manual_bin_src` / `sponsord_release_target_dir` | `""` | `manual` only. Set one. |
| `sponsord_version` | `""` | Required in `release` mode, e.g. `0.1.0` → tag `sponsord-v0.1.0`. |
| `sponsord_network` | `""` | Network profile: `arbitrum-sepolia` supplies chain id and PaymentPool. |
| `sponsord_chain_id`, `sponsord_payment_pool_address` | from profile | Explicit values win over the profile. |
| `sponsord_pool_id` | `""` | **Required.** 0x + 64 hex. `""` only on the wallet-creation run. |
| `sponsord_generate_treasury_wallet` | `false` | `true`: create the treasury wallet on the host when its keystore is absent. |
| `sponsord_decdn_cli_bin_src` | `""` | Control-machine path to a decdn CLI for the host. Required with wallet generation. |
| `sponsord_rpc_url` | `""` | **Sensitive.** Leave empty to provision `secret.env` on the host. |
| `sponsord_bind_address` / `sponsord_port` | `127.0.0.1` / `8090` | IPv4 loopback only (asserted). |
| `sponsord_max_spending_cap_micro_usdc`, `_max_ttl_secs`, `_pool_low_water_micro_usdc`, `_pool_refill_micro_usdc`, `_pool_watch_interval_secs` | `""` | `""` uses the daemon's default. These are economic choices, not repo facts. |
| `sponsord_generate_api_token` | `true` | `false`: provision `/etc/sponsord/api-token` yourself (≥ 32 bytes). |
| `sponsord_secret_env_overwrite_host_file` | `false` | Confirm that `sponsord_rpc_url` may replace a `secret.env` the role did not write. |
| `sponsord_stop_timeout_sec` | `120` | Cap on the graceful stop. The daemon waits for a top-up it already sent. |
| `sponsord_readiness_retries` / `_delay` | `30` / `2` | `/healthz` window (about 60 s). |

## Observability

With `decdn_grafana_cloud_enabled: true`, the `grafana_alloy` role ships sponsord's
`/metrics` as `job="sponsord"` (pool balance, top-ups, keeper failures, issued
capabilities) and its journal with `service_name="sponsord"`. This repo's playbooks
turn that on for hosts in `sponsord_hosts`, and turn the node scrape off on a host
that is not in `decdn_nodes` (`playbooks/group_vars/all.yml`). From your own
playbook, set `grafana_alloy_sponsord_enabled` / `grafana_alloy_node_enabled`
yourself.

## Day 2

- **Rotate the API token:** write the new token to `/etc/sponsord/api-token`, then
  re-run the role, which restarts sponsord. The onramp reads the same file and
  restarts with the daemon (`PartOf=`).
- **Rotate the treasury:** replace the keystore and password files, then re-run.
  The new wallet must own `sponsord_pool_id`, or sponsord refuses to start and the
  deploy fails at `/healthz`.
- **Logs:** `journalctl -u sponsord`. Plain text, with colour off. In Loki its `level` label comes from the line itself, not journald's priority, which is info for every line.
- **Removal** (no decommission playbook yet; the daemon itself keeps no state):

  ```bash
  sudo systemctl disable --now sponsord
  sudo rm /etc/systemd/system/sponsord.service
  sudo systemctl daemon-reload
  sudo rm -f /usr/local/bin/sponsord
  sudo rm -rf /usr/local/lib/sponsord     # the release version stamp and decdn CLI
  ```

  Then delete `/etc/sponsord` (secrets, env files and the role's two `.sha256`
  records) once the treasury files are safe elsewhere.

## Testing

- `molecule/sponsord` runs `playbooks/sponsord.yml` on a host with no node
  (Debian 12 and Ubuntu 24.04), against a stub daemon. It checks:
  - idempotence;
  - a restart after a credential rotation;
  - that the `/healthz` gate fails the deploy when the daemon will not start;
  - each `secret.env` hand-off between inventory and host, with its guards;
  - release mode against a locally signed mirror: the version stamp, a re-run
    with the mirror down, and rejection of a bad checksum, a bad signature and
    a binary that is not the pinned version;
  - the Alloy toggles;
  - treasury wallet generation through a `key-gen` stub: the files and modes, the
    stop on an empty pool id, an existing wallet kept, and the daemon starting on it.
- `molecule/grafana-cloud` co-locates sponsord with a node.
- `molecule/cloud-init-sponsord` deploys it from `cloud-init/user-data-sponsord.yaml`
  (no control machine), in release mode, beside the onramp.
- `molecule/validation` holds the negative cases.
