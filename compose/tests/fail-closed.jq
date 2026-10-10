# What an unset variable renders to, checked by `make lint-compose` against
# `docker compose config --format json` with every profile on and an EMPTY .env.
# compose.yaml cannot require variables with `:?` (Compose interpolates disabled
# services too), so each default must instead be something the service refuses.
# A default that works (a real image, uid 0, a resolvable-looking host) would let
# a half-configured host start. Prints one line per violation.

def check($svc; $what; $ok): if $ok then empty else "\($svc): unset \($what)" end;

# The images compose.yaml pins itself by digest, rather than taking them from .env.
def pinned_images: ["caddy", "iroh-relay"];
# The services whose account compose.yaml fixes (uid 0, which invariants.jq allows
# for these only) instead of naming a host account's uid from .env.
def fixed_user: ["iroh-relay"];

.services as $all
| ($all | to_entries[] | .key as $n | .value as $s
   # Every other image names its variable and is not a valid reference.
   | (if any(pinned_images[]; . == $n) then empty
      else check($n; "image digest renders an invalid reference"; ($s.image // "") | test("@sha256:unset-set-[A-Z_]+-in-\\.env$"))
      end),
     (if any(fixed_user[]; . == $n) then empty
      else check($n; "uid/gid render unknown users"; ($s.user // "") | test("^unset-[A-Z_]+:unset-[A-Z_]+$"))
      end)),

  # A host name with a non-numeric port: the onramp refuses ONRAMP_PUBLIC_URL
  # ("invalid port number") and Caddy refuses the site address.
  check("sponsord-onramp"; "domain renders an unparsable ONRAMP_PUBLIC_URL";
    ($all["sponsord-onramp"].environment.ONRAMP_PUBLIC_URL // "") | test("^https://unset-[A-Z_]+:[^0-9]")),
  check("caddy"; "domain renders an unparsable site address";
    ($all.caddy.environment.SPONSORD_ONRAMP_DOMAIN // "") | test("^unset-[A-Z_]+:[^0-9]"))
