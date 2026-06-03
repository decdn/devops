#!/usr/bin/env bash
# DESTRUCTIVE: wipe all devnet chain state and redeploy from scratch.
# Stops anvil -> deletes state.json -> restarts anvil -> re-runs deploy.sh.
# Every dev's assumptions (balances, nonces, deployed code) reset to genesis.
#
#   sudo bin/reset.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh
need_root

cat <<EOF
┌──────────────────────────────────────────────────────────────────────────────┐
│  DESTRUCTIVE RESET                                                             │
│                                                                               │
│  This will:                                                                   │
│    • stop the anvil service                                                   │
│    • DELETE ${ANVIL_STATE}
│    • restart anvil from genesis (block 0, fresh accounts)                      │
│    • re-run deploy.sh                                                          │
│                                                                               │
│  Every dev pointing at ${PUBLIC_HOST} will see balances, nonces, and          │
│  deployed contracts reset. Coordinate with the team before doing this.        │
└──────────────────────────────────────────────────────────────────────────────┘
EOF

read -r -p 'Type the chain name "rpc-dev" to confirm the wipe: ' confirm
[ "$confirm" = "rpc-dev" ] || die "Confirmation did not match. Aborted — nothing changed."

log "Stopping anvil…"
systemctl stop anvil.service

if [ -f "$ANVIL_STATE" ]; then
	rm -f "$ANVIL_STATE"
	log "Deleted ${ANVIL_STATE}"
else
	warn "${ANVIL_STATE} did not exist (already clean)."
fi

log "Starting anvil…"
systemctl start anvil.service
wait_for_rpc 60

log "Redeploying contracts…"
./deploy.sh

log "Reset complete. The devnet is back at genesis with fresh deployments."
