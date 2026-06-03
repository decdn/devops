# contracts/ — deCDN devnet deployment (TODO: plug in real contracts)

This is a Foundry project skeleton. The actual deCDN contracts are **not wired up
yet** — this directory exists so there's an obvious, well-marked place for them and a
deterministic deploy path ready to go.

## To plug in the contracts

1. Add sources under `src/` (and any deps under `lib/` via `forge install`).
2. Pin `solc` in `foundry.toml` to the contracts' version (identical bytecode →
   identical CREATE2 addresses across all devs).
3. Rename `script/Deploy.s.sol.example` → `script/Deploy.s.sol` and implement `run()`,
   deploying each contract with the CREATE2 salt (`new C{salt: salt}(...)`).
4. Run `sudo ../bin/deploy.sh` on the VPS. It derives the deployer from the shared
   mnemonic (account #0), broadcasts the script, and writes the address manifest to
   `/var/lib/anvil/deployments.json`.
5. Update the manifest writer + the README "Deployed addresses" table with the real
   contract names/addresses.

## Why CREATE2 (deterministic addresses)

A normal `CREATE` address is `f(deployer, nonce)` — fragile, since it depends on
deploy order and prior transactions. A `CREATE2` address is
`f(factory, salt, initcode)` — independent of nonce. With a fixed salt and a pinned
compiler, **every dev (and every reset) gets the exact same contract addresses**, which
is the whole point of a shared devnet. Foundry deploys the canonical CREATE2 factory
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`) automatically on first use.

**Alternative — pinned nonce:** deploy from account #0 in a fixed order on a
freshly-reset chain; addresses are then `f(account#0, nonce)`. Simpler but requires the
clean genesis state that `bin/reset.sh` guarantees. CREATE2 is preferred because it
survives out-of-order or repeated deploys.
