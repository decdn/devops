#!/usr/bin/env bash
# One-shot installer for the shared deCDN Anvil devnet on an Ubuntu VPS.
# Idempotent — safe to re-run. Run as root:
#
#   sudo bin/install.sh
#
# Installs: Foundry (anvil/cast/forge), Caddy, cloudflared, dedicated system
# users, directories, systemd units, and the Caddyfile; then bootstraps secrets
# and starts anvil + caddy. cloudflared is installed but NOT started (it needs
# the tunnel credentials you create manually — see the README).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./lib.sh
need_root

SVC_DIR="$(cd .. && pwd)"
ETC_SRC="${SVC_DIR}/etc"
BIN_SRC="${SVC_DIR}/bin"

log "Installing the deCDN anvil-devnet from ${SVC_DIR}"

# ── 1. Base packages ─────────────────────────────────────────────────────────
log "Installing base packages…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
	curl git jq openssl ca-certificates gnupg lsb-release \
	debian-keyring debian-archive-keyring apt-transport-https

# ── 2. Dedicated system users ────────────────────────────────────────────────
if ! id -u "$ANVIL_USER" >/dev/null 2>&1; then
	log "Creating system user '${ANVIL_USER}'…"
	useradd --system --home-dir "$ANVIL_HOME" --create-home --shell /usr/sbin/nologin "$ANVIL_USER"
fi
if ! id -u "$CFD_USER" >/dev/null 2>&1; then
	log "Creating system user '${CFD_USER}'…"
	useradd --system --home-dir /var/lib/cloudflared --create-home --shell /usr/sbin/nologin "$CFD_USER"
fi

# ── 3. Foundry into ${FOUNDRY_DIR} (owned by anvil) ──────────────────────────
if [ ! -x "$ANVIL" ]; then
	log "Installing Foundry into ${FOUNDRY_DIR}…"
	install -d -o "$ANVIL_USER" -g "$ANVIL_USER" -m 755 "$FOUNDRY_DIR"
	su -s /bin/bash "$ANVIL_USER" -c \
		"export FOUNDRY_DIR='${FOUNDRY_DIR}'; curl -L https://foundry.paradigm.xyz | bash"
	su -s /bin/bash "$ANVIL_USER" -c \
		"export FOUNDRY_DIR='${FOUNDRY_DIR}'; '${FOUNDRY_DIR}/bin/foundryup'"
else
	log "Foundry already present at ${ANVIL} ($("$ANVIL" --version | head -1))."
fi

# ── 4. Caddy (official Cloudsmith apt repo) ──────────────────────────────────
if ! command -v caddy >/dev/null 2>&1; then
	log "Installing Caddy…"
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
		| gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
	curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
		> /etc/apt/sources.list.d/caddy-stable.list
	apt-get update -y
	apt-get install -y caddy
else
	log "Caddy already installed ($(caddy version | head -1))."
fi

# ── 5. cloudflared (official Cloudflare apt repo) ────────────────────────────
if ! command -v cloudflared >/dev/null 2>&1; then
	log "Installing cloudflared…"
	# -m applies only to the deepest dir, which is all we create here.
	# shellcheck disable=SC2174
	mkdir -p --mode=0755 /usr/share/keyrings
	curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
		> /usr/share/keyrings/cloudflare-main.gpg
	echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
		> /etc/apt/sources.list.d/cloudflared.list
	apt-get update -y
	apt-get install -y cloudflared
else
	log "cloudflared already installed ($(cloudflared --version | head -1))."
fi

# ── 6. Directories ───────────────────────────────────────────────────────────
log "Creating directories…"
install -d -o "$ANVIL_USER" -g "$ANVIL_USER" -m 750 "$(dirname "$ANVIL_ENV")"   # /etc/anvil
install -d -o "$ANVIL_USER" -g "$ANVIL_USER" -m 750 "$STATE_DIR"                # /var/lib/anvil
install -d -o root          -g caddy         -m 750 /etc/caddy
install -d -o "$CFD_USER"   -g "$CFD_USER"   -m 750 "$CFD_DIR"                  # /etc/cloudflared

# ── 7. Config + unit files ───────────────────────────────────────────────────
log "Installing systemd units and Caddyfile…"
install -m 644 "${ETC_SRC}/systemd/system/anvil.service"       /etc/systemd/system/anvil.service
install -m 644 "${ETC_SRC}/systemd/system/cloudflared.service" /etc/systemd/system/cloudflared.service
install -m 644 "${ETC_SRC}/caddy/Caddyfile"                    /etc/caddy/Caddyfile
# cloudflared config is a template — only install if the operator hasn't created one.
if [ ! -f "${CFD_DIR}/config.yml" ]; then
	install -o "$CFD_USER" -g "$CFD_USER" -m 640 \
		"${ETC_SRC}/cloudflared/config.yml.example" "${CFD_DIR}/config.yml.example"
fi

# ── 8. Secrets (mnemonic + initial dev user) — prints once ───────────────────
log "Bootstrapping secrets…"
"${BIN_SRC}/bootstrap.sh"

# ── 9. Enable & start services ───────────────────────────────────────────────
log "Enabling and starting anvil…"
systemctl daemon-reload
systemctl enable --now anvil.service
wait_for_rpc 60

log "Validating and (re)loading Caddy…"
caddy validate --config /etc/caddy/Caddyfile || die "Caddyfile failed validation."
systemctl reload caddy 2>/dev/null || systemctl restart caddy

cat <<EOF

──────────────────────────────────────────────────────────────────────────────
 anvil-devnet is INSTALLED and RUNNING locally.

   RPC (local):   ${RPC_URL}   (chain ${CHAIN_ID}, block-time 2s)
   Caddy:         127.0.0.1:${CADDY_BIND_PORT}  (basic-auth -> anvil)
   State:         ${ANVIL_STATE}

 STILL MANUAL — Cloudflare Tunnel (so https://${PUBLIC_HOST} goes live):
   1. cloudflared tunnel login
   2. cloudflared tunnel create rpc-dev
   3. sudo cp /etc/cloudflared/config.yml.example /etc/cloudflared/config.yml
      and replace <TUNNEL_ID> (x2); move the credentials JSON to
      /etc/cloudflared/<TUNNEL_ID>.json (chown ${CFD_USER}, chmod 600)
   4. cloudflared tunnel route dns rpc-dev ${PUBLIC_HOST}
   5. sudo systemctl enable --now cloudflared
   (Full details: services/anvil-devnet/README.md → "Cloudflare: manual steps")

 Deploy contracts once they're wired up:  sudo bin/deploy.sh
──────────────────────────────────────────────────────────────────────────────
EOF
