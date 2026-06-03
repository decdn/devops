#!/usr/bin/env bash
# Deploy the deCDN contracts to the shared devnet at DETERMINISTIC addresses so
# every dev can hardcode identical values. Run as root on the VPS (needs the
# mnemonic) or via reset.sh.
#
#   sudo bin/deploy.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh

CONTRACTS_DIR="$(cd ../contracts && pwd)"

log "Deploying to ${RPC_URL} (chain ${CHAIN_ID})"
wait_for_rpc 30
read_mnemonic

DEPLOYER_ADDR="$("$CAST" wallet address     --mnemonic "$ANVIL_MNEMONIC" --mnemonic-index 0)"
DEPLOYER_KEY="$( "$CAST" wallet private-key --mnemonic "$ANVIL_MNEMONIC" --mnemonic-index 0)"
log "Deployer = mnemonic account #0 = ${DEPLOYER_ADDR}"

# Deterministic CREATE2 salt. Keep this STABLE for stable addresses; bump it only
# when you intentionally want every contract to move to a new address.
SALT="${DECDN_CREATE2_SALT:-0x0000000000000000000000000000000000000000000000000000000000000001}"

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║  TODO: PLUG IN THE deCDN CONTRACTS HERE.                                      ║
# ╠════════════════════════════════════════════════════════════════════════════╣
# ║ The contracts/ Foundry project is a stub. To get IDENTICAL addresses for      ║
# ║ every dev, deploy via CREATE2 (address depends only on factory+salt+initcode, ║
# ║ never on the deployer's nonce):                                               ║
# ║                                                                               ║
# ║   1. Add sources under contracts/src/ and a broadcast script at               ║
# ║      contracts/script/Deploy.s.sol that deploys each contract with the salt,  ║
# ║      e.g.  new SettlementVault{salt: SALT}(args);                             ║
# ║      Foundry auto-deploys the canonical CREATE2 factory                       ║
# ║      0x4e59b44847b379578588920cA78FbF26c0B4956C on first use.                  ║
# ║   2. Rename the stub to Deploy.s.sol — this script will then broadcast it      ║
# ║      automatically (block below).                                             ║
# ║   3. Replace the TODO_* entries in the manifest writer at the bottom with the ║
# ║      real names, parsed from contracts/broadcast/.../run-latest.json.         ║
# ║                                                                               ║
# ║ Alternative — pinned nonce: deploy from account #0 in a FIXED order on a       ║
# ║ freshly-reset chain (addresses = f(deployer, nonce)). reset.sh guarantees the ║
# ║ clean starting state this relies on.                                          ║
# ╚════════════════════════════════════════════════════════════════════════════╝

if [ -f "${CONTRACTS_DIR}/script/Deploy.s.sol" ]; then
	log "Found contracts/script/Deploy.s.sol — broadcasting…"
	( cd "$CONTRACTS_DIR" && DECDN_CREATE2_SALT="$SALT" \
		"$FORGE" script script/Deploy.s.sol \
			--rpc-url "$RPC_URL" \
			--private-key "$DEPLOYER_KEY" \
			--broadcast )
	warn "TODO: map contracts/broadcast/.../run-latest.json into ${DEPLOYMENTS_JSON}."
else
	warn "No contracts/script/Deploy.s.sol yet — nothing to deploy."
	warn "This is expected until the deCDN contracts are added (see the TODO above)."
fi

# Always write a manifest so devs have ONE file/URL to read addresses from.
umask 022
cat > "$DEPLOYMENTS_JSON" <<EOF
{
  "chainId": ${CHAIN_ID},
  "rpc": "${RPC_URL}",
  "deployer": "${DEPLOYER_ADDR}",
  "create2Salt": "${SALT}",
  "contracts": {
    "TODO_SettlementVault": "0x0000000000000000000000000000000000000000",
    "TODO_DecdnToken": "0x0000000000000000000000000000000000000000"
  }
}
EOF
chown "$ANVIL_USER:$ANVIL_USER" "$DEPLOYMENTS_JSON" 2>/dev/null || true
log "Wrote deployments manifest: ${DEPLOYMENTS_JSON}"
