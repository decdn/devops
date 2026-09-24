# deCDN node from cloud-init user-data

A deCDN node with no machine of your own in the loop. Paste
[`user-data.yaml`](user-data.yaml) into your provider's "create server" form, and a
fresh Debian 12/13 or Ubuntu 24.04/26.04 VM (x86_64 or aarch64) sets itself up. It
hardens itself and stops to wait for its RPC endpoint. You then SSH in once to write
that endpoint.

On the host it runs the [Ansible project](../ansible/README.md)'s `site.yml` against
localhost. That means the same `baseline` hardening (nftables default-deny with only
SSH and udp/4433 open, DevSec SSH/OS hardening, fail2ban, unattended upgrades) and the
same `decdn_node` role, with no second copy of either. Nearly every provider accepts
cloud-init: Hetzner, DigitalOcean, OVHcloud, Vultr, AWS, Scaleway and others.

Pick this path for one VM when you don't want a control machine. For a fleet, or
repeated deploys from your workstation, use the [Ansible project](../ansible/README.md)
directly. [`docs/requirements.md`](../docs/requirements.md) compares the paths.

> **Upstream has not published a release yet.** The node installs only from a
> GPG-verified release tarball (`release` mode). The `manual` mode would install
> binaries that nothing verified, so the lint refuses it. Until a release exists, serve
> `v<version>/{decdn-node,decdn}-<version>-<target>.tar.gz`, `SHA256SUMS` and
> `SHA256SUMS.asc` from a mirror, and set `decdn_node_release_base` in the user-data
> to point at it. The signature is still checked against deCDN's release key.

## What happens at boot

1. cloud-init writes four files early in boot:
   - `/etc/decdn-bootstrap/bootstrap.env`: which revision of this repo to run.
   - `/etc/decdn-bootstrap/inventory.yml`: your non-secret settings.
   - `/usr/local/sbin/decdn-bootstrap`: stage 1 of the bootstrap.
   - `/etc/profile.d/decdn-bootstrap.sh`: the login hint (below).

   In its final stage it installs `git`, `python3-venv`, `ca-certificates` and `sudo`,
   then runs stage 1.
2. **Stage 1** (`decdn-bootstrap`) takes a lock, so only one run happens at a time, and
   records `running`. It clones this repo into `/opt/decdn-devops` at `DEVOPS_REF`. If
   the ref is a full commit SHA, it checks that the checkout really is at that commit.
   It then runs the checkout's [`bootstrap.sh`](bootstrap.sh).
3. **Stage 2** (`bootstrap.sh`) installs the pinned toolchain:
   - ansible-core into `/opt/decdn-bootstrap/venv`, from
     [`requirements.txt`](requirements.txt) with pip's hash checking on;
   - the Galaxy collections at the exact versions in
     [`collections.lock.yml`](collections.lock.yml).

   It then syntax-checks the playbook. It also checks that the inventory puts localhost
   in `decdn_nodes`, and that `--tags baseline` still selects the baseline role.
4. With no `/etc/decdn/decdn.env` yet, stage 2 runs only the `baseline` role and
   records `awaiting-secret`. With the file present, it runs the whole playbook and
   records `complete`.

The state is in `/var/lib/decdn-bootstrap/state`: `running`, `awaiting-secret`,
`complete` or `failed`. Any failed run records `failed`, including one that stage 1
refused or a signal interrupted. The login hint (`/etc/profile.d/decdn-bootstrap.sh`)
prints the next step whenever the state is not `complete`. It also says when a
`running` bootstrap is no longer alive, for example after a reboot mid-run. The full
log is in `/var/log/cloud-init-output.log`.

## Set up

1. **Fill in the user-data.** Copy [`user-data.yaml`](user-data.yaml) and replace every
   `CHANGE_ME`:
   - `DEVOPS_REF`: a full 40-character commit SHA of this repo (recommended; it is
     verified after checkout) or a release tag. Branch names are refused.
   - `baseline_sudo_users`: your admin login and your SSH **public** key. Hardening
     disables root and password logins. Some providers (Hetzner, DigitalOcean) inject
     your key for `root` only, so without this entry you are locked out.
   - `decdn_node_version`: the upstream release to install.
   - `decdn_region`: the VM's ISO 3166-1 alpha-2 country code, e.g. `DE`.

   Optional:
   - `ssh_allow_cidrs`, to accept SSH only from your addresses;
   - `decdn_node_release_base`, for a mirror (see the note above);
   - `decdn_network`, `arbitrum-sepolia` today.

   Any other non-secret role knob can go in the same `vars:` block
   (`ansible/roles/*/defaults/main.yml`). The knobs that decide the install's trust
   (install method, wallet generation, signature verification) stay there too. The lint
   refuses them as host vars, and refuses `decdn_release_keyring` and `decdn_env_file`
   outright. Check the file before you paste it:

   ```bash
   make lint-cloud-init CLOUD_INIT_FILE=path/to/your-user-data.yaml
   ```

   It fails on your edited copy only if an invariant breaks. Examples: a secret added,
   another file written, or `release` mode changed.

2. **Create the VM** with the file as its user data. Examples:
   - **Hetzner Cloud:** "Cloud config" field, or `hcloud server create --user-data-from-file`.
   - **DigitalOcean:** "Advanced options → Add initialization scripts", or the
     `user_data` of a `digitalocean_droplet` in Terraform
     ([#48](https://github.com/decdn/devops/issues/48)).
   - **AWS EC2:** "Advanced details → User data".

   Open **udp/4433** in the provider's own firewall, if it has one. The host's nftables
   already allows it.

3. **Wait for the first boot to finish.** This takes a few minutes: packages, pip,
   Galaxy and the hardening run.

   ```bash
   ssh <admin>@<ip> cloud-init status --wait    # status: done
   ssh <admin>@<ip> cat /var/lib/decdn-bootstrap/state   # awaiting-secret
   ```

   Your admin account exists only once `baseline` has run, near the end of the first
   boot. Until then, and after a failure before that point, log in the way your
   provider set up (often `root` with the injected key).

   `status: error` means the bootstrap failed. The reason is at the end of
   `/var/log/cloud-init-output.log`. Fix it (usually a value in
   `/etc/decdn-bootstrap/inventory.yml`), then run `sudo decdn-bootstrap`.

4. **Write the RPC endpoint on the host.** The URL may embed a provider API key, so it
   never goes in user-data:

   ```bash
   umask 077
   sudo mkdir -p /etc/decdn
   echo 'DECDN_RPC_URL=https://…' | sudo tee /etc/decdn/decdn.env >/dev/null
   sudo chmod 600 /etc/decdn/decdn.env
   ```

   Other environment-borne secrets, such as S3 cache-origin credentials, go in the
   same file ([`decdn.env.example`](../ansible/roles/decdn_node/files/decdn.env.example)).

5. **Install and start the node:**

   ```bash
   sudo decdn-bootstrap        # ends with "decdn-bootstrap: complete"
   ```

   This runs the whole playbook:
   - installs the verified release;
   - generates the node's wallet on the host (`decdn_node_generate_keystore`);
   - writes `node.toml`, and has the real binary validate it;
   - starts `decdn-node`.

6. **Stake and register on chain.** This is an operator step, driven by `decdn setup`.
   Use the `decdn_chain` helper in
   [`docs/lifecycle.md`](../docs/lifecycle.md#running-on-chain-commands):

   ```bash
   decdn_chain setup --mbps 100 --region DE \
     --multiaddr /ip4/<public-ip>/udp/4433/quic-v1 --dry-run
   ```

   `decdn whoami` prints the wallet's address. The address is encrypted inside the
   keystore, so the command needs the keystore password, which is in the root-only
   `/etc/decdn/keystore.password`. Fund the wallet before you run the command without
   `--dry-run`.

## Operate

- **Re-run or change settings:** edit `/etc/decdn-bootstrap/inventory.yml`, then run
  `sudo decdn-bootstrap`. Once `/etc/decdn/decdn.env` exists, every run converges the
  whole host again, as `make deploy` does. Before that, runs apply `baseline` only.
- **Upgrade the deployment code:** set `DEVOPS_REF` in
  `/etc/decdn-bootstrap/bootstrap.env` to the new SHA or tag, then run
  `sudo decdn-bootstrap`. It fetches, verifies and re-installs the toolchain pinned at
  that revision. Nothing pulls on a timer: the host only runs code you pinned. A tag is
  resolved again on every run, so if someone re-points it, the next run follows. Pin a
  SHA if that matters to you.
- **Upgrade the node:** change `decdn_node_version` in the inventory and re-run.
- **Back up, migrate or decommission:** the host is an ordinary Ansible node. Add it to
  an inventory on your workstation with the same variables and use `make backup`,
  `make decommission` and the rest ([`docs/lifecycle.md`](../docs/lifecycle.md)). From
  then on, manage it from one place: either `decdn-bootstrap` on the host or
  `make deploy` from the workstation, never both.

## Security notes

- **User-data is not private.** Any local process can read it from the instance
  metadata service, and the provider keeps it in its console and API. The file carries
  only public material: an SSH public key, a version, a region, a repo URL. The RPC URL
  is written over SSH, and the wallet is generated on the host.
  `make lint-cloud-init` fails on:
  - any file written besides the bootstrap's own four, and any encoded file content;
  - any secret-looking key (RPC URL, password, token, private key, keystore,
    `decdn_extra_env`);
  - a `NAME=value` assignment of a secret-looking variable anywhere, including
    commands;
  - a URL with embedded credentials;
  - an unknown `bootstrap.env` key;
  - any mention of the test-only switch that skips hardening.
- **Everything is pinned.**
  - This repo: by commit SHA (checked after checkout), or by tag, which is weaker
    because a tag can be moved.
  - ansible-core: by version and hash.
  - The collections: by exact version.
  - The node: by release version, installed only if `SHA256SUMS` carries a valid
    signature from deCDN's release key. The lint refuses a user-data that turns
    `decdn_verify_release_signature` off, swaps `decdn_release_keyring`, or sets either
    one as a host var.

  Nothing is piped from `curl` into a shell.
- **No lockout.** Baseline refuses to harden SSH unless `baseline_sudo_users` names a
  non-root account with a key.
- **The network posture is the role's.** It is nftables default-deny with only SSH and
  the node's QUIC udp/4433 open. Metrics and the admin RPC stay on loopback.
- The files in `/etc/decdn-bootstrap/` are `root` `0600`. `decdn-bootstrap` refuses a
  `bootstrap.env` that is not `root`-owned `0600`. It reads the file as literal
  `KEY=value` lines and never sources it, and it rejects unknown keys. That leaves no
  way to pass Ansible arguments (extra-vars or skipped tags) from user-data.
- `runcmd` must be exactly stage 1, so a failure always reaches `cloud-init status`.

What CI proves:

- `make lint-cloud-init` (CI job `cloud-init`) checks the schema and the invariants
  above, and `make test-scripts` checks that it rejects broken variants.
- The molecule `cloud-init` scenario boots this file with cloud-init in Debian 12 and
  Ubuntu 26.04 containers. It covers the secret gate first. It then checks that stage 1
  refuses a branch name, the placeholder ref, an unknown key and a loose file mode,
  each recording `failed`. Finally, after an upgrade to a tag and `decdn.env`, it
  covers a running node installed from a locally signed mirror.
- The scenario skips `baseline`, because host hardening means nothing in a container.
  It is exercised on real hosts, as for the Ansible path.

## Updating the pins

- **ansible-core:** edit [`requirements.in`](requirements.in), then regenerate:

  ```bash
  uv pip compile --universal --generate-hashes --python-version 3.11 \
    cloud-init/requirements.in -o cloud-init/requirements.txt
  ```

  Keep a pin whose controller Python range covers 3.11 (Debian 12) and one covering
  3.12 to 3.14 (Ubuntu 24.04, Debian 13, Ubuntu 26.04).
- **Collections:** resolve from scratch (`rm -rf ansible/collections && make -C ansible
  deps`), because an existing tree keeps what it has. Then copy the resolved versions
  into [`collections.lock.yml`](collections.lock.yml). `make lint-cloud-init` checks the
  lock against `ansible/requirements.yml`. The molecule scenario checks that a node
  ends up with exactly the locked set.
