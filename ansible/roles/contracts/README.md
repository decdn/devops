# roles/contracts — STUB (out of scope for v1)

Deterministic deployment of the deCDN contracts onto the devnet is **not wired up
yet**.

When it lands, this role will:

- vendor / build the Foundry project for the deCDN contracts,
- deploy via **CREATE2** so addresses are identical for every dev and stable across
  resets (`address = f(factory, salt, initcode)`, independent of nonce),
- write the address manifest to `/var/lib/anvil/deployments.json`,
- be added to `playbooks/anvil.yml` after the `anvil` role.

Contract addresses and any protocol facts must trace back to an ADR in
`decdn/adr/` — never invented here (see the repo `CLAUDE.md`).

Until then this role is a no-op and is intentionally absent from `anvil.yml`.
