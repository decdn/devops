# Node lifecycle: backup, restore, migration, decommission

Day-2 procedures for a running deCDN node. The Ansible targets run from `ansible/`;
the manual commands work for any deploy path.

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
| `full` | the whole data dir except the cache, plus the password file | the copy (the redb stores are only consistent at rest); restarted afterwards |

Add `-e decdn_backup_include_env=true` to include `decdn.env` (your RPC URL, which
may embed an API key). The archive is written to `/var/backups/decdn/` on the host
(`root` `0600`) and the encrypted file is fetched to `ansible/backups/<host>/`, which
is git-ignored. `make backup` runs one host at a time.

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
   `make decommission LIMIT=old-host` (it only stops and removes the service; ignore
   the on-chain exit steps it prints, since the identity is moving, not leaving) or
   run `sudo systemctl disable --now decdn-node` on it.

2. **Prepare the new host** with a normal deploy. Do *not* set
   `decdn_node_generate_keystore: true` for it. The deploy creates the `decdn` user
   and directories, then stops at the identity gate because the keys are not there
   yet. That is expected.

   ```bash
   make deploy LIMIT=new-host ANSIBLE_ARGS='-u root'   # first converge of a fresh box
   ```

3. **Restore**, decrypting on your workstation and streaming straight into the new
   host, so the plaintext never touches a disk off the target:

   ```bash
   age -d -i ~/.config/decdn/backup-age.key ansible/backups/old-host/<file>.tar.age \
     | ssh new-host 'sudo tar -xzf - -C / --no-same-owner \
         && sudo chown -R decdn:decdn /var/lib/decdn /etc/decdn/keystore.password'
   ```

   `--no-same-owner` plus the `chown` matter: the `decdn` user's uid on the new host
   need not match the old one. The next deploy re-applies `0600` to the key files.

4. **Converge** the new host: `make deploy LIMIT=new-host`.

5. **Update what is on-chain**, if it changed. The node is registered with its
   multiaddr and region. A new public IP needs `decdn node update-multiaddrs`; a new
   country needs `decdn node update-region`. Both sign with the operator key and read
   the RPC URL from `decdn.env`, so run them through systemd with the unit's own
   environment file. Preview first:

   ```bash
   sudo systemd-run --pty --wait --collect -p User=decdn \
     -p EnvironmentFile=/etc/decdn/decdn.env \
     /usr/local/bin/decdn node update-multiaddrs --config /etc/decdn/node.toml \
     --keystore-password-file /etc/decdn/keystore.password \
     --multiaddr /ip4/<new-public-ip>/udp/4433/quic-v1 --dry-run
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
repo installed, if any. `-e decdn_decommission_purge_cache=true` also deletes the
cache. It refuses to run on more than one host unless you raise
`decdn_decommission_max_hosts`.

It **keeps** the identity, `/etc/decdn` and the binaries, because the keystore is
what withdraws the bond. It does **not** touch the chain. The exit is two operator
steps with the `decdn` CLI, both with `--dry-run` first (invocation as in step 5
above; see
[`roles/decdn_node/README.md` § On-chain onboarding](../ansible/roles/decdn_node/README.md#on-chain-onboarding)):

1. `decdn node deregister` leaves the active node set. The bond is **not** returned:
   it stays deposited and slashable.
2. `decdn node unbond --all` starts the unbonding window. Run it again after the
   window to withdraw.

Delete the keystore only after the withdrawal has landed. The public `udp/4433`
firewall rule stays until baseline is re-run without it.

Do not use `decdn node drain` to take a systemd-managed node down: the unit is
`Restart=always`, so systemd starts the drained daemon again five seconds later.

## Compose and Kubernetes

- **Compose** ([`compose/`](../compose/README.md)) uses the same host paths
  (`/var/lib/decdn`, `/etc/decdn`), so the manual backup command and the restore steps
  above apply unchanged; stop the node with `docker compose stop`.
- **Helm**: the identity lives in the operator-provisioned `existingSecret`, which you
  created off-cluster and should already hold elsewhere. The daemon's state is on the
  PVC; snapshot it with your storage's `VolumeSnapshot` support after scaling the
  StatefulSet to zero. Never run two releases with the same identity Secret.
