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
  "decdn-node": (base_keys + ["healthcheck", "stop_grace_period", "tmpfs"]),
  "sponsord": (base_keys + ["secrets", "stop_grace_period"]),
  "sponsord-onramp": (base_keys + ["depends_on", "secrets", "stop_grace_period"]),
  "caddy": (base_keys + ["cap_add", "tmpfs"]),
  "iroh-relay": (base_keys + ["cap_add", "stop_grace_period", "ulimits"]),
  "iroh-dns-server": (base_keys + ["cap_add", "stop_grace_period", "ulimits"])
};

# The only services that may run as uid 0, and then only holding NET_BIND_SERVICE
# and nothing else: the iroh services bind their public ports themselves on the
# host network, where Docker cannot give a non-root process that capability
# (compose.yaml, README.md "Security notes"). Every other service runs as its own
# non-root host account.
def root_allowed: ["iroh-relay", "iroh-dns-server"];
def nonroot: test("^[1-9][0-9]*:[1-9][0-9]*$");

# The signal each daemon drains on (the units' KillSignal): iroh's servers shut
# down gracefully on SIGINT only.
def stop_signal($n): {"iroh-relay": "SIGINT", "iroh-dns-server": "SIGINT"}[$n] // "SIGTERM";

# Every mount, exactly: [source, target, read-only?, created?], volumes and secrets
# alike (a secret is a read-only bind of its host file, listed as "secret:<file>").
# Each container sees only its own files; the only writable ones are the node's
# data dir and the state of Caddy and the iroh services. "created?" is Docker
# creating a missing source (create_host_path, true unless set false): only for
# the onramp's optional gate-page directory, so a mistyped path or an NFS mount
# that is not up fails the start instead of mounting an empty directory. The
# Caddyfile's source is absolute (compose.yaml's directory), so it is matched by
# name; the origin content's source is the operator's DECDN_ORIGIN_DIR, so only
# its target and mode are pinned.
def allowed_mounts: {
  "decdn-node": [["/etc/decdn", "/etc/decdn", true, false], ["/var/lib/decdn", "/var/lib/decdn", false, false],
                 ["DECDN_ORIGIN_DIR", "/srv/decdn-origin", true, false]],
  "sponsord": [["secret:/etc/sponsord/api-token", "/run/secrets/api-token", true, false],
               ["secret:/etc/sponsord/treasury-password", "/run/secrets/treasury-password", true, false],
               ["secret:/etc/sponsord/treasury-keystore.json", "/run/secrets/treasury-keystore.json", true, false]],
  "sponsord-onramp": [["/etc/sponsord/onramp-gate", "/etc/sponsord/onramp-gate", true, true],
                      ["secret:/etc/sponsord/api-token", "/run/secrets/api-token", true, false],
                      ["secret:/etc/sponsord/turnstile-secret", "/run/secrets/turnstile-secret", true, false]],
  "caddy": [["Caddyfile", "/etc/caddy/Caddyfile", true, false], ["/var/lib/caddy", "/data", false, false]],
  "iroh-relay": [["/etc/iroh-relay/iroh-relay.toml", "/etc/iroh-relay/iroh-relay.toml", true, false],
                 ["/var/lib/iroh-relay", "/var/lib/iroh-relay", false, false]],
  "iroh-dns-server": [["/etc/iroh-dns-server/config.toml", "/etc/iroh-dns-server/config.toml", true, false],
                      ["/var/lib/iroh-dns-server", "/var/lib/iroh-dns-server", false, false]]
};
def mounts($secrets): [((.volumes // [])[]
    | [(if .type == "bind" then .source else "\(.type):\(.source)" end
        | if endswith("/Caddyfile") then "Caddyfile" else . end),
       .target, (.read_only == true), (.type == "bind" and .bind.create_host_path != false)]
    | if .[1] == "/srv/decdn-origin" then .[0] = "DECDN_ORIGIN_DIR" else . end),
  ((.secrets // [])[] | ["secret:\($secrets[.source].file // "?")", (.target // "/run/secrets/\(.source)"), true, false])]
  | sort;

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
| (.secrets // {}) as $secrets
| (["caddy", "decdn-node", "iroh-dns-server", "iroh-relay", "sponsord", "sponsord-onramp"] as $want
   | check("compose.yaml"; "services are exactly \($want | join(", "))"; ($all | keys) == $want)),

  # Every service: host networking and nothing published, so loopback listeners
  # stay loopback and Docker's iptables rules open nothing; an image by digest; a
  # read-only rootfs; every capability dropped; no-new-privileges and nothing
  # else in security_opt (no seccomp/apparmor opt-out); a non-root account, or
  # for root_allowed only, uid 0 holding NET_BIND_SERVICE alone.
  ($all | to_entries[] | .key as $n | .value as $s
   | check($n; "sets only allowed keys (extra: \(($s | keys) - (allowed_keys[$n] // []) | join(", ")))";
       (($s | keys) - (allowed_keys[$n] // [])) == []),
     check($n; "network_mode is host"; $s.network_mode == "host"),
     check($n; "publishes no ports"; $s.ports == null),
     check($n; "image is pinned by @sha256 digest"; ($s.image // "") | test("@sha256:[0-9a-f]{64}$")),
     check($n; "read_only rootfs"; $s.read_only == true),
     check($n; "cap_drop is [ALL]"; $s.cap_drop == ["ALL"]),
     check($n; "security_opt is exactly [no-new-privileges:true]"; $s.security_opt == ["no-new-privileges:true"]),
     check($n; "runs as a non-root uid:gid";
       (($s.user // "") | nonroot) or (any(root_allowed[]; . == $n) and $s.user == "0:0")),
     check($n; "runs as uid 0 only with cap_add exactly [NET_BIND_SERVICE]";
       (($s.user // "") | nonroot) or $s.cap_add == ["NET_BIND_SERVICE"]),
     check($n; "stop_signal is \(stop_signal($n))"; $s.stop_signal == stop_signal($n)),
     check($n; "mounts are exactly its allow-list"; ($s | mounts($secrets)) == (allowed_mounts[$n] // [] | sort))),

  # A secret comes from one absolute host file and nothing else: an `environment:`
  # source would read it from the shell or .env into the container.
  ($secrets | to_entries[]
   | check("secrets.\(.key)"; "is a single absolute host file";
       (.value | del(.name) | keys) == ["file"] and (.value.file | startswith("/etc/")))),

  # The node's healthcheck asks the daemon's admin RPC on loopback.
  check("decdn-node"; "healthcheck is `decdn node health`";
    ($all["decdn-node"].healthcheck.test // [])[0:4] == ["CMD", "decdn", "node", "health"]),

  # Caddy keeps only the capability for :80/:443 (the daemons may not set cap_add
  # at all: allowed_keys).
  check("caddy"; "cap_add is exactly [NET_BIND_SERVICE]"; $all.caddy.cap_add == ["NET_BIND_SERVICE"]),
  check("iroh-relay"; "cap_add is exactly [NET_BIND_SERVICE]"; $all["iroh-relay"].cap_add == ["NET_BIND_SERVICE"]),
  check("iroh-dns-server"; "cap_add is exactly [NET_BIND_SERVICE]"; $all["iroh-dns-server"].cap_add == ["NET_BIND_SERVICE"]),

  # Stop grace long enough for each daemon's drain (the units' TimeoutStopSec).
  check("decdn-node"; "stop_grace_period is 300s"; $all["decdn-node"].stop_grace_period == "5m0s"),
  check("sponsord"; "stop_grace_period is 120s"; $all.sponsord.stop_grace_period == "2m0s"),
  check("sponsord-onramp"; "stop_grace_period is 30s"; $all["sponsord-onramp"].stop_grace_period == "30s"),
  check("iroh-relay"; "stop_grace_period is 30s"; $all["iroh-relay"].stop_grace_period == "30s"),
  check("iroh-dns-server"; "stop_grace_period is 30s"; $all["iroh-dns-server"].stop_grace_period == "30s"),

  # The relay: the unit's ExecStart and nothing else (no `--dev`, which serves plain
  # http, and no entrypoint swap), its log level set (it logs only errors without
  # RUST_LOG), and the unit's LimitNOFILE.
  check("iroh-relay"; "command is exactly --config-path /etc/iroh-relay/iroh-relay.toml, with no entrypoint";
    $all["iroh-relay"].command == ["--config-path", "/etc/iroh-relay/iroh-relay.toml"]
    and $all["iroh-relay"].entrypoint == null),
  check("iroh-relay"; "RUST_LOG is set"; ($all["iroh-relay"].environment.RUST_LOG // "") != ""),
  check("iroh-relay"; "ulimits.nofile is 65536"; $all["iroh-relay"].ulimits == {"nofile": 65536}),

  # The DNS server likewise: the unit's ExecStart only, its log level, LimitNOFILE.
  check("iroh-dns-server"; "command is exactly --config /etc/iroh-dns-server/config.toml, with no entrypoint";
    $all["iroh-dns-server"].command == ["--config", "/etc/iroh-dns-server/config.toml"]
    and $all["iroh-dns-server"].entrypoint == null),
  check("iroh-dns-server"; "RUST_LOG is set"; ($all["iroh-dns-server"].environment.RUST_LOG // "") != ""),
  check("iroh-dns-server"; "ulimits.nofile is 65536"; $all["iroh-dns-server"].ulimits == {"nofile": 65536}),

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

  # Profiles: the onramp needs its daemon on the same host, so `onramp` starts both;
  # a cache node (`node`) and an origin (`origin`) are the same decdn-node.
  check("decdn-node"; "profiles are [node, origin]"; $all["decdn-node"].profiles == ["node", "origin"]),
  check("sponsord"; "profiles are [sponsord, onramp]"; $all.sponsord.profiles == ["sponsord", "onramp"]),
  check("sponsord-onramp"; "profiles are [onramp]"; $all["sponsord-onramp"].profiles == ["onramp"]),
  check("caddy"; "profiles are [caddy]"; $all.caddy.profiles == ["caddy"]),
  check("iroh-relay"; "profiles are [relay]"; $all["iroh-relay"].profiles == ["relay"]),
  check("iroh-dns-server"; "profiles are [dns]"; $all["iroh-dns-server"].profiles == ["dns"])
