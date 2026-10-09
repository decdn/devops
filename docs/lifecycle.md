# Node lifecycle: backup, restore, migration, decommission

Day-2 procedures for a running deCDN node, and for sponsord in
[its own section](#sponsord-the-onboarding-sponsor). The Ansible targets run from
`ansible/`; the manual commands work for any deploy path.

## What makes a node *that* node

| File | What it is | Lose it and… |
|------|-----------|--------------|
| `/var/lib/decdn/node.secret` | iroh node key (the wire identity) | peers see a new node; the on-chain binding points at a key you no longer hold |
| `/var/lib/decdn/keystore.json` | operator Ethereum key, encrypted | you cannot unbond, withdraw or appeal a slash: **the bond is stranded** |
| `/etc/decdn/keystore.password` | password for the keystore | same as losing the keystore |
| `/var/lib/decdn/*.redb`, receipts | daemon state, including vouchers not yet redeemed | unredeemed revenue and settlement progress |
| `/var/lib/decdn/cache/` | cached blobs | nothing lasting: it refills from origins and peers |

Back up the first three the day a node is created, and again before any host change.

## Backup (`make backup`)

Backups are encrypted **on the node** to public keys you choose, so plaintext key
material never leaves the host and nothing secret is needed on the control machine.
Generate a key pair once, somewhere that is neither the node nor this repo:

```bash
age-keygen -o ~/.config/decdn/backup-age.key     # keep this file safe and offline-capable
age-keygen -y ~/.config/decdn/backup-age.key     # prints the public recipient, age1…
```

Put the public key(s) in inventory (SSH public keys work too):

```yaml
# group_vars/decdn_nodes.yml
decdn_backup_age_recipients:
  - age1…               # yours
  - ssh-ed25519 AAAA…   # a second custodian, optional
```

```bash
cd ansible
make backup LIMIT=<host>                                          # identity, hot
make backup LIMIT=<host> ANSIBLE_ARGS='-e decdn_backup_scope=full' # stops the node for the copy
```

| Scope | Archives | Node downtime |
|-------|----------|---------------|
| `identity` (default) | `node.secret`, `keystore.json`, `keystore.password` | none |
| `full` | the whole data dir except the cache, plus the keystore (wherever it lives) and the password file | the copy (the redb stores are only consistent at rest); restarted afterwards if it was up |

Add `-e decdn_backup_include_env=true` to include `decdn.env` (your RPC URL, which
may embed an API key). The archive is written to `/var/backups/decdn/` on the host
(`root` `0600`). `make backup` runs one host at a time.

- **Identity** archives (kilobytes) are fetched to `ansible/backups/<host>/`, which is
  git-ignored.
- **Full** archives are **not** fetched by default: Ansible's `fetch` would read the
  whole file into memory on both ends. The run prints a streaming copy command instead
  (`ssh <host> sudo cat <file> > <file>`). Force a fetch with
  `-e decdn_backup_fetch=true` if you know the archive is small.

If the archive step fails (a bad recipient, a full disk), the node is restarted, no
partial file is left behind and the run fails. `decdn_backup_leave_stopped` only
applies to a backup that succeeded.

**Test the restore path, not just the backup:**

```bash
age -d -i ~/.config/decdn/backup-age.key ansible/backups/<host>/<file>.tar.age | tar -tz
```

Without Ansible (Compose or a hand-built host), the same archive is one command on
the node:

```bash
sudo tar -C / --numeric-owner -czf - var/lib/decdn/node.secret var/lib/decdn/keystore.json \
    etc/decdn/keystore.password | age -r age1… -o node-identity.tar.age
```

## Restore and host migration

Run two hosts with the same `node.secret` and keystore and they will fight over one
identity on the network and on-chain. **Stop the old host first.**

1. **Freeze the old host** and take a full backup in the same step:

   ```bash
   make backup LIMIT=old-host ANSIBLE_ARGS='-e decdn_backup_scope=full -e decdn_backup_leave_stopped=true'
   ```

   Then make sure it cannot come back on a reboot. Either run
   `make decommission LIMIT=old-host` (it removes the node's service and this repo's
   Alloy agent and keeps the data; ignore the on-chain exit steps it prints, since the
   identity is moving, not leaving) or run `sudo systemctl disable --now decdn-node`
   on it. On a host that also runs sponsord, `make decommission` takes sponsord and
   its onramp down too: to move only the node, use the `systemctl` command.

2. **Prepare the new host** with a normal deploy. Do *not* set
   `decdn_node_generate_keystore: true` for it. The deploy creates the `decdn` user
   and directories, then stops at the identity gate because the keys are not there
   yet. That is expected.

   ```bash
   make deploy LIMIT=new-host ANSIBLE_ARGS='-u root'   # first converge of a fresh box
   ```

3. **Restore**, streaming the archive from the old host through your workstation's
   `age` straight into the new host, so the plaintext never touches a disk off the
   target (the full archive stays on the old host; step 1 printed its path):

   ```bash
   ssh old-host sudo cat /var/backups/decdn/<file>.tar.age \
     | age -d -i ~/.config/decdn/backup-age.key \
     | ssh new-host 'sudo tar -xzf - -C / --no-same-owner \
         && sudo chown -R decdn:decdn /var/lib/decdn /etc/decdn/keystore.password'
   ```

   `--no-same-owner` plus the `chown` matter: the `decdn` user's uid on the new host
   need not match the old one. The next deploy re-applies `0600` to the key files.

4. **Converge** the new host: `make deploy LIMIT=new-host`.

5. **Update what is on-chain**, if it changed. The node is registered with its
   multiaddr and region. A new public IP needs `decdn node update-multiaddrs`; a new
   country needs `decdn node update-region`. With `decdn_chain` from
   [Running on-chain commands](#running-on-chain-commands), preview first:

   ```bash
   decdn_chain node update-multiaddrs --multiaddr /ip4/<new-public-ip>/udp/4433/quic-v1 --dry-run
   ```

   Then the same command without `--dry-run`. The address set you pass replaces the
   one on-chain.

## Decommission (`make decommission`)

```bash
make backup LIMIT=<host>          # first, always
make decommission LIMIT=<host>    # LIMIT is required; you type the host name to confirm
```

It stops `decdn-node` with `systemctl` (SIGTERM, which is the daemon's graceful drain
path), disables it and removes the unit, and tears down the Grafana Alloy agent this
repo installed, if any. On a host that also runs an iroh relay it removes the relay
too ([iroh relay](#iroh-relay)). On a host that also runs sponsord it removes sponsord and its
onramp as well, after checking for a held top-up
([sponsord](#sponsord-the-onboarding-sponsor)); the one confirmation prompt lists every
service it covers. `-e decdn_decommission_purge_cache=true` also deletes the
cache. It refuses to run on more than one host unless you raise
`decdn_decommission_max_hosts`, and an unanswered confirmation prompt fails after
`decdn_decommission_prompt_seconds` (300). Both entry points refuse a
`decdn_cache_dir` that equals or encloses the identity, so a purge can never take the
keys with it.

It **keeps** the identity, `/etc/decdn` and the binaries, because the keystore is
what withdraws the bond. It does **not** touch the chain. The exit is two operator
steps with the `decdn` CLI, both with `--dry-run` first (use `decdn_chain` from
[Running on-chain commands](#running-on-chain-commands)):

1. `decdn_chain node deregister` leaves the active node set. The bond is **not**
   returned: it stays deposited and slashable.
2. `decdn_chain node unbond --all` starts the unbonding window. Run it again after the
   window to withdraw.

Delete the keystore only after the withdrawal has landed. The public `udp/4433`
firewall rule stays until baseline is re-run without it.

Do not use `decdn node drain` to take a systemd-managed node down: the unit is
`Restart=always`, so systemd starts the drained daemon again five seconds later.

## Running on-chain commands

`decdn setup`, `node bond`, `node register`, `node update-multiaddrs`,
`node update-region`, `node deregister` and `node unbond` sign with the operator key
and need the RPC endpoint. **They do not read `DECDN_RPC_URL`** from the environment,
unlike the daemon: they take `--rpc-url`, or `blockchain.rpc_url` from `node.toml`.
The Ansible role leaves `rpc_url` out of `node.toml` on purpose (it may embed an API
key), and on Compose `config init` wrote the public endpoint there. So pass it
explicitly. This helper runs the CLI as `decdn` with the unit's own environment file
and hands the URL over as `--rpc-url`:

```bash
decdn_chain() {
  sudo systemd-run --pty --wait --collect -p User=decdn \
    -p EnvironmentFile=/etc/decdn/decdn.env \
    /bin/sh -c 'exec /usr/local/bin/decdn "$@" --config /etc/decdn/node.toml \
      --rpc-url "$DECDN_RPC_URL" --keystore-password-file /etc/decdn/keystore.password' \
    decdn "$@"
}

decdn_chain setup --mbps 100 --region DE \
  --multiaddr /ip4/<public-ip>/udp/4433/quic-v1 --dry-run
```

The URL is in the `decdn` process's arguments while the command runs, so other local
users could read it with `ps`. On a shared host, write a `0600` copy of `node.toml`
with `rpc_url` set under `[blockchain]` and pass that as `--config` instead. The clean
fix is upstream: give `CommonChainArgs.rpc_url` (`crates/common/src/cli/common.rs`)
`env = "DECDN_RPC_URL"`, as the daemon has. Then `EnvironmentFile=` alone would be
enough and the helper could drop `--rpc-url`.

Register the node's public `/ip4/` multiaddr, and on a dual-stack host its `/ip6/` one
too (repeat `--multiaddr`). Since decdn/decdn#2144 (`869141e9`) the daemon binds QUIC
on both `0.0.0.0:4433` and `[::]:4433`; on a host without IPv6 it starts IPv4-only and
logs a `warn`. Check `ss -ulpn` shows `[::]:4433` before registering an `/ip6/` address.
An older build binds IPv6 on a random port, so an `/ip6/` address on-chain would point
at a port nothing listens on: register `/ip4/` only there. To add the `/ip6/` address
after an upgrade, run `decdn_chain node update-multiaddrs` with **both** addresses; it
replaces the whole on-chain set.

To fund the wallet you need its address, and `keystore.json` has no plaintext address
field. `whoami` decrypts it. It takes no `--rpc-url`, so run it directly rather than
through `decdn_chain`:

```bash
sudo systemd-run --pty --wait --collect -p User=decdn \
  /usr/local/bin/decdn --config /etc/decdn/node.toml whoami \
  --keystore-password-file /etc/decdn/keystore.password
```

## sponsord (the onboarding sponsor)

sponsord keeps no state. What makes it *that* sponsor are its credentials under
`/etc/sponsord/`:

| File | What it is | Lose it and… |
|------|-----------|--------------|
| `treasury-keystore.json` | the treasury wallet, encrypted: it owns the pool, signs every capability and pays the top-ups | the pool and the USDC in it are out of reach |
| `treasury-password` | its password | same as losing the keystore |
| `api-token` | the bearer token the onramp presents | regenerate it (the onramp reads the new one) |
| `turnstile-secret` | the onramp's Turnstile secret | re-copy it from the Cloudflare dashboard |

**Backup.** `make backup` also covers hosts in `sponsord_hosts`: it archives those
files (and `secret.env` with `-e sponsord_backup_include_env=true`) hot, encrypted on
the host to `sponsord_backup_age_recipients` (by default `decdn_backup_age_recipients`,
so one list covers a co-located host), into `/var/backups/sponsord/`, and fetches the
archive to `ansible/backups/<host>/`. Whoever decrypts it controls the pool's funds.

**The top-up hold.** When sponsord's keeper broadcasts a pool top-up and cannot read
its receipt, it holds every further top-up until that transaction mines or provably
never can (`sponsord_pool_topup_unconfirmed_since_unix` > 0 on `/metrics`). The hold
lives only in the process: a restart or a stop forgets it, and the pool can then be
refilled twice. So the role reads `/metrics` before any restart a deploy would cause,
and `make decommission` before it stops sponsord, and both **fail** while a hold is
on. Wait for it to clear (send 0-value transactions from the treasury to itself if
the transaction was dropped; the daemon's error log line says how many), then re-run.
`ANSIBLE_ARGS='-e {"sponsord_restart_ignore_topup_hold":true}'` overrides both checks
(and the refusal when `/metrics` does not answer), only for a hold you have confirmed
can never mine. Use the JSON form: `-e name=true` passes the string `"true"`, which
the role's boolean check refuses. Nothing guards a restart this repo does not cause
(a crash, or a package upgrade restarting services); the `SponsordTopupHeld` alert
is how you learn of a hold.

**Migration.** Never run two sponsord daemons on one treasury: both would top up the
pool.

1. Back up and decommission the old host: `make backup LIMIT=old-host`, then
   `make decommission LIMIT=old-host` (on a host that also runs a node, that takes the
   node down too). Take the old host out of `sponsord_hosts` and
   `sponsord_onramp_hosts`: decommission keeps `/etc/sponsord`, so a later deploy
   would start a second daemon on the same treasury.
2. Restore the fetched archive onto the new host. The files stay `root` `0600`:

   ```bash
   age -d -i ~/.config/decdn/backup-age.key ansible/backups/old-host/<file>.tar.age \
     | ssh new-host 'sudo tar -xzf - -C / --no-same-owner'
   ```

3. Deploy the new host.

**Decommission.** On a host in `sponsord_onramp_hosts`, `make decommission` stops and
removes the onramp's unit and stops and disables the role's Caddy (only when
`/etc/caddy/Caddyfile` carries the role's marker). On a host in `sponsord_hosts`, it
then checks for a held top-up once more and stops and removes sponsord's unit. One
typed confirmation per run, in the first play that reaches the host, names every
service it covers there.
It keeps `/etc/sponsord` (the treasury owns the pool), the binaries and the caddy
package, and does not touch the chain: the pool and its USDC stay with the treasury
wallet until you withdraw them with the `decdn` CLI. tcp/80 and tcp/443 stay open
until the host leaves `sponsord_onramp_hosts` and baseline runs again.

## iroh relay

A self-hosted iroh relay ([`roles/iroh_relay`](../ansible/roles/iroh_relay/README.md))
holds no identity and no operator-provisioned secret, so it has **no backup**. Its
only state is the Let's Encrypt account key and certificate (with its private key)
under `/var/lib/private/iroh-relay` (`0700`), which a new host re-issues for itself.

- **Migration:** deploy the relay on the new host with the same `iroh_relay_hostname`,
  then move the name's A/AAAA records. Until the records move, Let's Encrypt cannot
  reach the new host and the deploy's certificate check warns; re-run `make
  deploy-relay LIMIT=<new host>` once DNS has moved. Mind Let's Encrypt's rate limits
  (five certificates per exact name per week): do not re-image a relay in a loop.
- **Decommission:** take the relay's URL out of every node's `decdn_relay_urls` and
  re-deploy them first. A node keeps trying a relay it was told to use, and the list
  replaces n0's relays, so keep at least one other relay in it. Then `make
  decommission LIMIT=<host>` stops `iroh-relay` (SIGINT, its graceful shutdown),
  disables it and removes the unit, and tears down the Alloy agent. It keeps the
  binary, `/etc/iroh-relay` and the ACME state. tcp/80, tcp/443 and udp/7842 stay
  open until the host leaves `iroh_relay_hosts` and baseline runs again.

## Compose and Kubernetes

- **Compose** ([`compose/`](../compose/README.md)) uses the same host paths
  (`/var/lib/decdn`, `/etc/decdn`), so the manual backup command and the restore steps
  above apply unchanged; stop the node with
  `sudo docker compose -f compose/compose.yaml stop decdn-node`.
  sponsord's Compose layout uses `/etc/sponsord` too; its README shows the manual
  backup and the top-up-hold check before a restart.
- **Helm**: the identity lives in the operator-provisioned `existingSecret`, which you
  created off-cluster and should already hold elsewhere. The daemon's state is on the
  PVC; snapshot it with your storage's `VolumeSnapshot` support after scaling the
  StatefulSet to zero. Never run two releases with the same identity Secret.
