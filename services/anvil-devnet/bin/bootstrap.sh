#!/usr/bin/env bash
# Generate the devnet's secrets ON THIS HOST and print them exactly once.
#   1. Shared anvil mnemonic  -> /etc/anvil/anvil.env   (mode 600, anvil:anvil)
#   2. Initial `dev` basic-auth user -> /etc/caddy/rpc-dev.basicauth
#
# Idempotent: existing secrets are left untouched (it never rotates silently).
# Nothing here is ever written into the repo.
#
# To use your OWN mnemonic instead of generating one, export it first:
#   sudo ANVIL_MNEMONIC_SUPPLIED="word word ... word" bin/bootstrap.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh
need_root

command -v "$CAST" >/dev/null 2>&1 || die "cast not found at ${CAST}. Run install.sh first."
command -v caddy   >/dev/null 2>&1 || die "caddy not installed. Run install.sh first."
command -v jq      >/dev/null 2>&1 || die "jq not installed. Run install.sh first."

PRINT_MNEMONIC=""
PRINT_DEV_PW=""

# ── 1. Shared mnemonic ───────────────────────────────────────────────────────
install -d -o "$ANVIL_USER" -g "$ANVIL_USER" -m 750 "$(dirname "$ANVIL_ENV")"
if [ -f "$ANVIL_ENV" ] && grep -q '^ANVIL_MNEMONIC=' "$ANVIL_ENV"; then
	warn "Mnemonic already exists at ${ANVIL_ENV} — leaving it unchanged."
else
	if [ -n "${ANVIL_MNEMONIC_SUPPLIED:-}" ]; then
		log "Using supplied mnemonic."
		MNEMONIC="$ANVIL_MNEMONIC_SUPPLIED"
	else
		log "Generating a fresh shared mnemonic with 'cast wallet new-mnemonic'."
		MNEMONIC="$("$CAST" wallet new-mnemonic --json | jq -r '.mnemonic')"
	fi
	[ -n "$MNEMONIC" ] || die "Failed to obtain a mnemonic."
	( umask 077; printf 'ANVIL_MNEMONIC=%s\n' "$MNEMONIC" > "$ANVIL_ENV" )
	chown "$ANVIL_USER:$ANVIL_USER" "$ANVIL_ENV"
	chmod 600 "$ANVIL_ENV"
	PRINT_MNEMONIC="$MNEMONIC"
	log "Wrote ${ANVIL_ENV} (600, ${ANVIL_USER}:${ANVIL_USER})."
fi

# ── 2. Initial `dev` basic-auth user ─────────────────────────────────────────
if [ -f "$CADDY_USERS_TSV" ] && awk -F '\t' '$1=="dev"{f=1} END{exit !f}' "$CADDY_USERS_TSV"; then
	warn "Basic-auth user 'dev' already exists — leaving it unchanged."
else
	log "Creating initial basic-auth user 'dev' with a generated password."
	DEV_PW="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 28)"
	HASH="$(caddy hash-password --plaintext "$DEV_PW")"
	upsert_basicauth_user "dev" "$HASH"
	regenerate_basicauth
	PRINT_DEV_PW="$DEV_PW"
fi

# ── Print secrets ONCE ───────────────────────────────────────────────────────
if [ -n "$PRINT_MNEMONIC" ] || [ -n "$PRINT_DEV_PW" ]; then
	cat >&2 <<'BANNER'

╔══════════════════════════════════════════════════════════════════════════════╗
║  SECRETS — shown ONCE. Save to the team dev docs (a password manager / the     ║
║  private internal/ repo). Do NOT commit them anywhere. Re-running bootstrap    ║
║  will NOT reprint these.                                                       ║
╚══════════════════════════════════════════════════════════════════════════════╝
BANNER
	if [ -n "$PRINT_MNEMONIC" ]; then
		printf '\n  Shared anvil mnemonic (all devs derive the same accounts from this):\n\n    %s\n' "$PRINT_MNEMONIC" >&2
	fi
	if [ -n "$PRINT_DEV_PW" ]; then
		printf '\n  Basic-auth user "dev":\n\n    username: dev\n    password: %s\n\n    ETH_RPC_URL=https://dev:%s@%s\n' \
			"$PRINT_DEV_PW" "$PRINT_DEV_PW" "$PUBLIC_HOST" >&2
	fi
	printf '\n' >&2
else
	log "Nothing new generated; no secrets to print."
fi
