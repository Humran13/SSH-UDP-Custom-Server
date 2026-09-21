# SSH UDP Custom Server

An installer and manager for **SSH over UDP Custom** on an Ubuntu VPS you own:
one command installs it, `sshudp` manages it. It wraps OpenSSH, the third-party
`udp-custom` transport, systemd, your firewall and account expiry into one tool.

> **Read this first - honest status**
> * The UDP transport is a **closed-source, unlicensed third-party binary** (see
>   [docs/UPSTREAM.md](docs/UPSTREAM.md)). This project does not implement it and does
>   not redistribute it; the installer downloads it from upstream at a pinned commit and
>   verifies its SHA-256.
> * Everything on the server side is tested (real systemd, sshd, nftables, iptables, UFW
>   in containers). **Compatibility with the HTTP Custom / UDP Custom Android app is
>   *not verified*** - the app is proprietary and could not be automated. A five-minute
>   manual check is described in [docs/CLIENT-SETUP.md](docs/CLIENT-SETUP.md#manual-android-test).
> * For legitimate self-hosted tunnels on infrastructure you own or administer.

## Install

On a fresh Ubuntu VPS, as a sudo-capable user:

```bash
curl -fsSL https://raw.githubusercontent.com/Humran13/SSH-UDP-Custom-Server/main/install.sh | sudo bash
```

Choose **1. Quick Install** (defaults are sensible; just press Enter). Then:

```bash
sudo sshudp                # interactive manager
sudo sshudp create-user    # username, password (or generated), validity → account card
```

What the installer does: checks OS/arch/systemd/network **before changing anything**,
installs missing dependencies (no full upgrade, no reboot), verifies and installs the
release, downloads and verifies the upstream core, creates a hardened service, sshd
policy for tunnel accounts, project-owned firewall rules and timers, runs a health
check, and **rolls back** a failed first install. Re-running it is safe.

## Supported systems

Only combinations with passing automated tests are listed. Details and raw results:
[docs/TESTING.md](docs/TESTING.md).

| Ubuntu | x86_64 | Status |
|---|---|---|
| 20.04 LTS | yes | 342/342 tests pass |
| 22.04 LTS | yes | 342/342 tests pass |
| 24.04 LTS | yes | 342/342 tests pass |
| 26.04 LTS | yes | 342/342 tests pass |
| 18.04 and older, non-Ubuntu | - | refused with a clear message (18.04 smoke-tested only when forced; see TESTING.md) |
| arm64 | - | not supported (upstream publishes no official arm64 build) |

Requirements: root, systemd, OpenSSH server, outbound HTTPS to `github.com` and
`raw.githubusercontent.com`, ~100 MB disk. Cloud firewalls must allow the UDP range.

## What you get

* **Quick / Advanced install** (ports, range, exclusions, hostname, IP override,
  firewall mode, login limit, run-as, optional UDPGW), every input validated.
* **`sshudp` dashboard** and CLI: users, online sessions, UDP config, client card,
  traffic/sessions, settings, firewall, logs, backup/restore, diagnostics, update,
  repair, uninstall.
* **Accounts:** create / delete / renew / lock / unlock / reset password / search /
  details / cleanup. `nologin` tunnel accounts (forwarding only), separate metadata,
  only accounts created by this tool are ever touched, passwords never stored.
* **Expiry:** daily systemd timer (`Persistent=true`) plus OS-level account expiry.
* **Session limit per user:** reactive, ≤60 s (documented in the architecture notes).
* **UDP ports:** one listen port plus a redirected range with exclusions; protected
  system ports and live UDP listeners are never captured.
* **Firewall coexistence:** nftables / iptables / UFW; only project-owned objects;
  uninstall removes only those.
* **Diagnostics:** `sshudp doctor` (PASS/WARN/FAIL with fixes, read-only), `sshudp repair`.
* **Updates:** `sshudp update` with checksum verification, backup and automatic
  rollback; `sshudp core-update` for the pinned upstream core.
* **Backup/restore** with strict archive validation; optional password-hash backups.
* Optional: UDPGW (`sshudp udpgw enable`), Fail2ban (`sshudp fail2ban enable`).

## Everyday commands

```text
sshudp                       interactive manager
sshudp status | doctor | users | online | traffic
sshudp create-user [NAME] [--days N | --expires YYYY-MM-DD] [--limit N] [--generate | --password-stdin]
sshudp delete-user NAME     renew-user NAME [DAYS]     lock-user NAME     unlock-user NAME
sshudp reset-password NAME  cleanup-expired [--delete] client NAME
sshudp config [show | server-host H | server-ip IP | udp-ports SPEC | udp-exclude SPEC | udp-port N | ...]
sshudp start | stop | restart | logs [udp|expiry|events|all] [-n N] [-f] | fw [status|apply|remove]
sshudp backup [--with-hashes] | backups | restore FILE
sshudp update [--check] | core-update | repair | uninstall | version | help
```

Dashboard preview:

```text
╔════════════════════════════════════════════════╗
║      SSH UDP CUSTOM MANAGER  v1.0.0            ║
╠════════════════════════════════════════════════╣
║ Server IP       : 203.0.113.10                 ║
║ Hostname        : (not set)                    ║
║ SSH Port        : 22                           ║
║ UDP Ports       : 20000-50000                  ║
║ UDP Service     : ● ONLINE                     ║
║ SSH Service     : ● ONLINE                     ║
║ Users           : 12                           ║
║ Online          : 4                            ║
║ Expired         : 1                            ║
║ Server Load     : 0.34                         ║
║ RAM             : 28%                          ║
║ Uptime          : 3d 07h                       ║
╠════════════════════════════════════════════════╣
║  1. User Manager                               ║
║  2. Online Users   …   13. Uninstall           ║
║  0. Exit                                       ║
╚════════════════════════════════════════════════╝
```

## Client setup

See [docs/CLIENT-SETUP.md](docs/CLIENT-SETUP.md): which fields matter (server, UDP
range, SSH user/password, SSH port, optional UDPGW), what is *not* needed (SNI,
payload, TLS), and the manual Android check.

## Ports and firewall

* Core listens on **36712/udp**. Clients may use any UDP port in **20000-50000** (default);
  our rules redirect those ports to the core.
* Never redirected: 53, 67, 68, 69, 123, 137, 138, 161, 443, 500, 853, 1194, 1701, 4500,
  5353, 51820, your exclusions, and any UDP port that already has a listener.
* We never run `ufw disable/reset`, `iptables -F`, or `nft flush ruleset`, and never
  install firewall packages. Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#firewall).

## Backup, restore, updates, uninstall

```bash
sudo sshudp backup                 # config + account metadata (no shadow, no keys)
sudo sshudp backup --with-hashes   # explicit opt-in: managed users' password hashes, 0600
sudo sshudp restore sshudp-backup-YYYYMMDD-HHMMSS.tar.gz
sudo sshudp update                 # verify → backup → install → health check → auto-rollback
sudo sshudp uninstall              # asks about users/config; only project objects removed
```

## Security

Summary: unprivileged sandboxed service, no capabilities, project-owned firewall rules
only, `sshd -t` before reload, hardened tunnel accounts, secrets never stored/logged,
strict input validation and archive validation. **Known risks** (closed-source core,
fixed embedded keys, PAM reads password hashes, any account with a password can
authenticate at the transport, reactive login limits) are spelled out in
[docs/SECURITY.md](docs/SECURITY.md). Please read them.

## Documentation

[UPSTREAM](docs/UPSTREAM.md) · [ARCHITECTURE](docs/ARCHITECTURE.md) ·
[CLIENT-SETUP](docs/CLIENT-SETUP.md) · [TESTING](docs/TESTING.md) ·
[TROUBLESHOOTING](docs/TROUBLESHOOTING.md) · [SECURITY](docs/SECURITY.md) ·
[CHANGELOG](CHANGELOG.md)

## Testing status

Unit tests (Bats), integration tests in real systemd containers per Ubuntu release,
ShellCheck, and a public-installer test against the GitHub RAW URL. Exact numbers and
what is *not* covered: [docs/TESTING.md](docs/TESTING.md).

## Credits and licenses

* **UDP Custom core** - © "ePro Dev. Team", closed source, **no license granted**;
  fetched from <https://github.com/http-custom/udp-custom> at install time. Built on
  [Hysteria](https://github.com/apernet/hysteria) v1 (MIT) and quic-go (MIT).
* **Project code** (this repository) - [MIT](LICENSE).
* OpenSSH, systemd, nftables, iptables, UFW belong to their respective projects.
