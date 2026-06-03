#!/usr/bin/env bash
# Add or update a per-dev HTTP basic-auth user for the devnet RPC.
# Usage:
#   sudo bin/caddy-add-user.sh [username]
# Prompts for a password (blank = auto-generate a strong one and print it once).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh
need_root
command -v caddy >/dev/null 2>&1 || die "caddy not installed."

user="${1:-}"
if [ -z "$user" ]; then read -r -p "New basic-auth username: " user; fi
[ -n "$user" ] || die "Username is required."
[[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid username (allowed: letters, digits, . _ -)."

read -r -s -p "Password for '${user}' (leave blank to auto-generate): " pw; echo
generated=0
if [ -z "$pw" ]; then
	pw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 28)"
	generated=1
fi

# bcrypt the password via Caddy. NOTE: --plaintext puts the password in this
# process's argv briefly; fine for a devnet, but don't reuse production secrets.
hash="$(caddy hash-password --plaintext "$pw")"

upsert_basicauth_user "$user" "$hash"
regenerate_basicauth

if systemctl reload caddy 2>/dev/null; then
	log "Reloaded caddy."
else
	warn "Could not reload caddy automatically. Run: sudo systemctl reload caddy"
fi

log "Basic-auth user '${user}' added/updated."
if [ "$generated" -eq 1 ]; then
	cat >&2 <<'BANNER'

  Generated password — shown ONCE. Share it securely; do not commit it.
BANNER
	printf '    username: %s\n    password: %s\n\n    ETH_RPC_URL=https://%s:%s@%s\n\n' \
		"$user" "$pw" "$user" "$pw" "$PUBLIC_HOST" >&2
fi
