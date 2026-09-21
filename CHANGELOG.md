# Changelog

All notable changes are documented here. The project follows
[Semantic Versioning](https://semver.org/) and [Keep a Changelog](https://keepachangelog.com/).

## [1.0.0] - 2026-09-22

First stable release.

### Added
- One-line installer (`install.sh`) with Quick and Advanced modes: OS/arch/systemd/network
  checks before any change, dependency handling without upgrades, release download with
  SHA-256 verification, pinned + verified upstream core download, health check, and
  automatic rollback of a failed first install. Re-runs are idempotent.
- `sshudp` manager: interactive dashboard and full CLI (users, online, traffic, config,
  client card, logs, firewall, UDPGW, Fail2ban, backup/restore, update, core-update,
  repair, uninstall).
- Managed SSH tunnel accounts (`nologin`, own group, forwarding only, OS-level expiry,
  password never stored, strict isolation from non-managed users), daily expiry timer,
  reactive per-user session limits.
- Hardened `ssh-udp-custom.service` (dedicated user, no capabilities, read-only system)
  and a firewall unit that manages **project-owned** nftables/iptables objects and a
  single UFW rule; replaces upstream's blanket "all UDP ports" DNAT.
- `sshudp doctor` (30+ checks, PASS/WARN/FAIL with fixes, read-only) and `sshudp repair`.
- Backup/restore with strict archive validation; optional password-hash backups.
- Self-update with checksum verification, pre-update backup and automatic rollback.
- Documentation: upstream research, architecture, client setup, testing, security,
  troubleshooting.
- Test-suite: 200+ unit tests, integration tests in real systemd containers, CI.

### Known limitations
- The closed-source, unlicensed upstream core cannot be audited or redistributed.
- Compatibility with the HTTP Custom / UDP Custom Android app is **not verified**
  (see docs/UPSTREAM.md and docs/CLIENT-SETUP.md).
- x86_64 only. Per-user traffic statistics are not available. Login limits are
  enforced reactively (≤60 s).
