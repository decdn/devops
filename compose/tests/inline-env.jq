# The environment written in compose.yaml itself, checked by `make lint-compose`
# against `docker compose config --format json` with every service env file pointed
# at /dev/null, so only the inline environment remains (not `--no-env-resolution`:
# the CI runner's older Compose still merges the env files with it). The other
# renders cannot tell an inline value from one in an env file, so this is what keeps a secret (DECDN_RPC_URL, SPONSORD_RPC_URL, …) out of
# the tracked file: each service may set only these keys inline; everything else
# belongs in its env file on the host. Prints one line per violation.

def allowed: {
  "decdn-node": [],
  "sponsord": ["NO_COLOR", "SPONSORD_API_TOKEN_FILE", "SPONSORD_BIND",
               "SPONSORD_TREASURY_KEYSTORE", "SPONSORD_TREASURY_PASSWORD_FILE"],
  "sponsord-onramp": ["NO_COLOR", "ONRAMP_BIND", "ONRAMP_DAEMON_TOKEN_FILE", "ONRAMP_DAEMON_URL",
                      "ONRAMP_PUBLIC_URL", "ONRAMP_TURNSTILE_SECRET_FILE"],
  "caddy": ["SPONSORD_ONRAMP_DOMAIN"],
  "iroh-relay": ["NO_COLOR", "RUST_LOG"],
  "iroh-dns-server": ["NO_COLOR", "RUST_LOG"]
};

.services | to_entries[] | .key as $n
| ((.value.environment // {}) | keys) - (allowed[$n] // []) | select(length > 0)
| "\($n): sets only allowed environment keys inline (extra: \(join(", ")))"
