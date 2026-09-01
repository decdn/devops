# `schema` scenario — config key-set drift guard

Renders `node.toml` with **every** operator-facing knob set, then asserts that
every key it emits exists in the upstream deCDN config schema.

## Why this exists

Upstream marks every config section `#[serde(deny_unknown_fields)]` and defines
**no** serde aliases anywhere in `crates/common/src/config/`. A key this role
renders that the daemon does not know is not a warning — it is a failed config
load and a systemd crash-loop.

Nothing else in this repo catches that:

- `default` asserts values and types, but only for keys it already knows about.
- The stub daemon (`molecule/default/files/decdn-node-stub`) has no schema. Its
  `config validate` checks TOML syntax, which a stale key passes.
- The role's own Ansible asserts mirror upstream constraints *by hand*, which is
  exactly the thing that drifted.

When this repo last fell behind (`decdn/decdn` @ `d306cc5c`), the role was
emitting 18 keys the daemon had removed or renamed — `payment_channel_address`,
the `[gossip]` table, `voucher_interval_mb`, the three `*_from_block` knobs, and
more. Every test passed. This scenario is that regression.

## Keeping it current

`files/schema-keys.txt` is generated from the upstream source; its header carries
the exact regeneration command. Re-run it whenever you sync this repo against a
new `decdn/decdn` revision, **before** touching the template — the diff on that
file is the changelog of what the config schema did.

When you add a knob to the role, add it to `converge.yml` as well. A knob that is
never set is a knob this guard cannot see; `verify.yml`'s breadth check is a
backstop against the converge quietly collapsing, not a substitute for that.

## What it does not check

Value ranges and cross-field constraints — `validation` covers the reject path,
and the real gate is `decdn config validate` running against an actual binary in
`tasks/main.yml`. This scenario is about key names only.
