# The invariants compose/README.md promises, checked by `make lint-compose` against
# `docker compose config --format json` with every profile on and the example
# .env. Prints one "<service>: <invariant>" line per violation; no output means
# every invariant holds.

def check($svc; $what; $ok): if $ok then empty else "\($svc): \($what)" end;
def loopback: test("^(http://)?127(\\.[0-9]{1,3}){3}:[0-9]+$");

# The keys each service may set, as Compose renders them. Anything else
# (privileged, pid/ipc/userns_mode, devices, ports, cap_add on a daemon, …) is a
# violation until it is added here deliberately.
def base_keys: ["cap_drop", "command", "entrypoint", "environment", "image", "logging",
  "network_mode", "profiles", "read_only", "restart", "security_opt", "stop_signal",
  "user", "volumes"];
def allowed_keys: {
  "decdn-node": (base_keys + ["stop_grace_period", "tmpfs"]),
  "sponsord": (base_keys + ["stop_grace_period"]),
  "sponsord-onramp": (base_keys + ["stop_grace_period", "depends_on"]),
  "caddy": (base_keys + ["cap_add", "tmpfs"])
};

# Every mount, exactly: [source, target, read-only?]. Each container sees only its
# own files; the only writable ones are the node's data dir and Caddy's ACME state.
# The Caddyfile's source is absolute (compose.yaml's directory), so it is matched
# by name.
def allowed_mounts: {
  "decdn-node": [["/etc/decdn", "/etc/decdn", true], ["/var/lib/decdn", "/var/lib/decdn", false]],
  "sponsord": [["/etc/sponsord/api-token", "/run/secrets/api-token", true],
               ["/etc/sponsord/treasury-password", "/run/secrets/treasury-password", true],
               ["/etc/sponsord/treasury-keystore.json", "/run/secrets/treasury-keystore.json", true]],
  "sponsord-onramp": [["/etc/sponsord/api-token", "/run/secrets/api-token", true],
                      ["/etc/sponsord/onramp-gate", "/etc/sponsord/onramp-gate", true],
                      ["/etc/sponsord/turnstile-secret", "/run/secrets/turnstile-secret", true]],
  "caddy": [["Caddyfile", "/etc/caddy/Caddyfile", true], ["/var/lib/caddy", "/data", false]]
};
def mounts: [(.volumes // [])[]
  | [(if .type == "bind" then .source else "\(.type):\(.source)" end
      | if endswith("/Caddyfile") then "Caddyfile" else . end),
     .target, (.read_only == true)]] | sort;

# Secrets reach the sponsord daemons only as the files mounted above, never inline.
def secret_files: {
  "sponsord": {"SPONSORD_API_TOKEN_FILE": "/run/secrets/api-token",
               "SPONSORD_TREASURY_PASSWORD_FILE": "/run/secrets/treasury-password",
               "SPONSORD_TREASURY_KEYSTORE": "/run/secrets/treasury-keystore.json"},
  "sponsord-onramp": {"ONRAMP_DAEMON_TOKEN_FILE": "/run/secrets/api-token",
                      "ONRAMP_TURNSTILE_SECRET_FILE": "/run/secrets/turnstile-secret"}
};
def inline_secrets: {
  "sponsord": ["SPONSORD_API_TOKEN", "SPONSORD_TREASURY_PASSWORD"],
  "sponsord-onramp": ["ONRAMP_DAEMON_TOKEN", "ONRAMP_TURNSTILE_SECRET"]
};

# The onramp's entrypoint, as `config` renders it ($$ is Compose's escape for $):
# refuse an ONRAMP_GATE_TEMPLATE outside /etc/sponsord/onramp-gate/, then exec the
# binary with no arguments. A change to compose.yaml's script must be made here too.
def onramp_entrypoint: ["/bin/sh", "-c", "t=\"$${ONRAMP_GATE_TEMPLATE-}\"\nif [ -n \"$$t\" ]; then\n  r=\"$$(realpath -e -- \"$$t\")\" || { echo \"ONRAMP_GATE_TEMPLATE $$t is not readable\" >&2; exit 1; }\n  case \"$$r\" in\n    /etc/sponsord/onramp-gate/*) ;;\n    *) echo \"ONRAMP_GATE_TEMPLATE must be a file in /etc/sponsord/onramp-gate/ (it resolves to $$r)\" >&2; exit 1 ;;\n  esac\nfi\nexec sponsord-onramp\n"];

.services as $all
| (["caddy", "decdn-node", "sponsord", "sponsord-onramp"] as $want
   | check("compose.yaml"; "services are exactly \($want | join(", "))"; ($all | keys) == $want)),

  # Every service: host networking and nothing published, so loopback listeners
  # stay loopback and Docker's iptables rules open nothing; an image by digest; a
  # read-only rootfs; every capability dropped; no-new-privileges and nothing
  # else in security_opt (no seccomp/apparmor opt-out); a non-root account.
  ($all | to_entries[] | .key as $n | .value as $s
   | check($n; "sets only allowed keys (extra: \(($s | keys) - (allowed_keys[$n] // []) | join(", ")))";
       (($s | keys) - (allowed_keys[$n] // [])) == []),
     check($n; "network_mode is host"; $s.network_mode == "host"),
     check($n; "publishes no ports"; $s.ports == null),
     check($n; "image is pinned by @sha256 digest"; ($s.image // "") | test("@sha256:[0-9a-f]{64}$")),
     check($n; "read_only rootfs"; $s.read_only == true),
     check($n; "cap_drop is [ALL]"; $s.cap_drop == ["ALL"]),
     check($n; "security_opt is exactly [no-new-privileges:true]"; $s.security_opt == ["no-new-privileges:true"]),
     check($n; "runs as a non-root uid:gid"; ($s.user // "") | test("^[1-9][0-9]*:[1-9][0-9]*$")),
     check($n; "stop_signal is SIGTERM"; $s.stop_signal == "SIGTERM"),
     check($n; "mounts are exactly its allow-list"; ($s | mounts) == (allowed_mounts[$n] // [] | sort))),

  # Caddy keeps only the capability for :80/:443 (the daemons may not set cap_add
  # at all: allowed_keys).
  check("caddy"; "cap_add is exactly [NET_BIND_SERVICE]"; $all.caddy.cap_add == ["NET_BIND_SERVICE"]),

  # Stop grace long enough for each daemon's drain (the units' TimeoutStopSec).
  check("decdn-node"; "stop_grace_period is 300s"; $all["decdn-node"].stop_grace_period == "5m0s"),
  check("sponsord"; "stop_grace_period is 120s"; $all.sponsord.stop_grace_period == "2m0s"),
  check("sponsord-onramp"; "stop_grace_period is 30s"; $all["sponsord-onramp"].stop_grace_period == "30s"),

  # The sponsord daemons run the image's binary with no flags: a flag beats the
  # environment, so `--bind 0.0.0.0:…` would get past the loopback checks below.
  # sponsord runs the image's entrypoint; the onramp runs exactly the gate-page
  # path check in compose.yaml, which ends in a flagless exec of the binary.
  check("sponsord"; "no command or entrypoint override"; $all.sponsord.command == null and $all.sponsord.entrypoint == null),
  check("sponsord-onramp"; "entrypoint is exactly the gate-page check, with no command";
    $all["sponsord-onramp"].command == null and $all["sponsord-onramp"].entrypoint == onramp_entrypoint),

  # The sponsor's listeners stay on loopback whatever an env file says (the release
  # images default to 0.0.0.0); the rendered environment has env_file merged in.
  check("sponsord"; "SPONSORD_BIND is 127.x"; ($all.sponsord.environment.SPONSORD_BIND // "") | loopback),
  check("sponsord-onramp"; "ONRAMP_BIND is 127.x"; ($all["sponsord-onramp"].environment.ONRAMP_BIND // "") | loopback),
  check("sponsord-onramp"; "ONRAMP_DAEMON_URL is http://127.x"; ($all["sponsord-onramp"].environment.ONRAMP_DAEMON_URL // "") | loopback),

  (secret_files | to_entries[] | .key as $n | .value | to_entries[]
   | check($n; "\(.key) is \(.value)"; ($all[$n].environment // {})[.key] == .value)),
  (inline_secrets | to_entries[] | .key as $n | .value[] as $k
   | check($n; "no inline \($k)"; ($all[$n].environment // {}) | has($k) | not)),

  # Profiles: the onramp needs its daemon on the same host, so `onramp` starts both.
  check("decdn-node"; "profiles are [node]"; $all["decdn-node"].profiles == ["node"]),
  check("sponsord"; "profiles are [sponsord, onramp]"; $all.sponsord.profiles == ["sponsord", "onramp"]),
  check("sponsord-onramp"; "profiles are [onramp]"; $all["sponsord-onramp"].profiles == ["onramp"]),
  check("caddy"; "profiles are [caddy]"; $all.caddy.profiles == ["caddy"])
