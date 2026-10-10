# Security

## Reporting a vulnerability

Email `security@decdn.org`. Please do not open a public issue for security
reports. That includes a secret or real host address you find committed here.

## Scope

This repo holds the deployment tooling for a deCDN node and a publisher's services: the
Ansible roles, the `decdn.node` and `decdn.publisher` Galaxy collections, the cloud-init
user-data, the Docker Compose file, and the Helm chart. Reports about the node daemon or
protocol belong to [decdn/decdn](https://github.com/decdn/decdn), but the same address
reaches both.

The security model these tools follow is described in [README.md § Security
model](README.md#security-model): nothing secret committed, loopback-only backends,
default-deny inbound, DevSec host hardening.

## Release verification

In `release` install mode, and while `decdn_verify_release_signature` keeps its
default of `true`, the `decdn_node` role checks every downloaded tarball against the
release's GPG-signed `SHA256SUMS`, using the maintainer keys vendored at
`ansible/roles/decdn_node/files/decdn-release-KEYS.asc`. The `sponsord` and
`sponsord_onramp` roles do the same with
`ansible/roles/sponsord/files/sponsord-release-KEYS.asc`. Both files are copies of
upstream's `KEYS` (decdn/decdn and decdn/sponsord), which hold the same maintainer
keys, and a good signature from any of them is accepted:

```
Ant Somers <ant@decdn.org>
Fingerprint: DA75 1570 6F18 73D2 74D8  A369 9E11 A9FF D62D AADB

Alper Gundogdu <alper@decdn.org>
Fingerprint: E27B 9A2D 2519 1E8E C90B  F8AE 57E2 823C 16CC D376
```

The same fingerprints are published in
[decdn/decdn's SECURITY.md](https://github.com/decdn/decdn/blob/main/SECURITY.md).
Check a new copy of the vendored keys against it before trusting that copy, with
`gpg --show-keys --with-fingerprint <file>`. `make test-scripts` checks that the two
vendored files hold the same keys.

Setting `decdn_verify_release_signature: false` (or `sponsord_verify_release_signature`
/ `sponsord_onramp_verify_release_signature`; meant for an air-gapped mirror that
strips signatures) drops that guarantee, and the role prints a warning when it's off.
`manual` mode verifies nothing: it installs whatever binaries you point it at.
`source` mode checks no signature either: it builds whatever the configured git ref
resolves to, trusting the transport to the git host and the checksums in the
checkout's `Cargo.lock`. It does run the build as an unprivileged user, never root.

Published Helm charts (`oci://ghcr.io/decdn/charts/decdn-node`) are signed with a
keyless cosign signature from this repo's chart release workflow; see
[RELEASING.md § Verifying a release](RELEASING.md#verifying-a-release).
