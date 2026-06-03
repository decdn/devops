# Changelog — `decdn.node`

All notable changes to the `decdn.node` Ansible collection are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the
collection adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] — unreleased

Initial packaging of the public deCDN node roles as a distributable collection.
Not yet published to Galaxy (pre-1.0; the published shape may still change).

### Added

- `decdn.node.baseline` — Debian/Ubuntu host baseline: nftables default-deny
  inbound, fail2ban, unattended-upgrades, chrony, an admin sudo account, and DevSec
  OS + SSH hardening applied last.
- `decdn.node.decdn_node` — the `decdn-node` daemon, installed from a pinned GitHub
  Release tarball under a hardened systemd unit; public QUIC udp/4433, loopback
  metrics + admin RPC.

<!-- No release tags exist yet; these resolve today. Switch to compare/tag links
     (compare/v0.1.0...HEAD and releases/tag/v0.1.0) once v0.1.0 is cut. -->
[Unreleased]: https://github.com/decdn/devops/commits/main
[0.1.0]: https://github.com/decdn/devops/releases
