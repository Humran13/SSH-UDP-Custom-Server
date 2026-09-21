# Security

## Threat model in one paragraph

You run a VPS you control and hand SSH tunnel accounts to other people. The upstream
transport binary is closed-source and unverifiable, so it is treated as **untrusted
code with network access**. The manager itself runs as root only when you invoke it
or when a systemd timer fires.

## What is protected, and how

| Area | Measure |
|---|---|
| Upstream binary | Pinned to a commit **and** SHA-256; downloaded over HTTPS with TLS verification always on; ELF/x86-64 and size checks; never stored in this repo or in releases (no license) |
| Runtime privileges | Dedicated `sshudp` user; `CapabilityBoundingSet=` empty; `NoNewPrivileges`; `ProtectSystem=strict`; `ProtectHome`; `PrivateTmp`; `PrivateDevices`; `ProtectKernelTunables/Modules/ControlGroups`; `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`; `RestrictNamespaces`; `LockPersonality`; `TasksMax`; `LimitNOFILE` |
| The one privilege it needs | PAM must read password hashes: group `shadow` (unit-scoped, not a permanent membership). Alternative: `sshudp config run-as root` (still capability-less) |
| Firewall | Only project-owned objects; no flush/reset/disable; UFW rule tracking; blanket-DNAT self-check in installer and `doctor` |
| sshd | Drop-in only (or a marked, backed-up block on OpenSSH without `Include`), validated with `sshd -t`, **reload not restart**, rolled back on failure |
| Tunnel accounts | `nologin`, own group, no sudo/admin groups, no home, no TTY/agent/X11/tunnel, password-only, OS-level expiry, managed-only operations |
| Secrets | Passwords go to `chpasswd` on stdin, are shown once, are never stored, logged or accepted on the command line (`--password` is refused; use `--generate` or `--password-stdin`); prompts use `read -s` |
| Files | Config 644 (no secrets), state/users/backups 700/600, atomic writes (`mktemp` in the target dir + rename), symlink targets refused |
| Input | Whitelist regexes for usernames, passwords, ports, port lists, dates, hostnames, IPs, backup names; nothing is `eval`ed; config/metadata are parsed as data, never sourced; newline/control characters rejected everywhere; test-suite covers metacharacters, `$()`, backticks, newlines, traversal |
| Backups | No `shadow`, no keys by default. `--with-hashes` is opt-in, 0600, managed users only. Restore validates: name, gzip, member paths (allow-list), types (no links/devices), size, manifest format/version, config keys, metadata fields - **before** extracting into a private temp dir and applying |
| Updates | HTTPS + `SHA256SUMS` verification, path/type checks, `bash -n`, pre-update backup + snapshot, automatic rollback |
| Testing hooks | Path/URL overrides (`SSHUDP_*`) are honoured **only** when `SSHUDP_TESTING=1`; plain-HTTP downloads are impossible outside it |

## Known risks you must understand

1. **Closed-source core.** We cannot audit it. It embeds a fixed TLS key and a fixed
   obfuscation key, so the QUIC layer gives no authentication of the *server*.
   Rely on the SSH host key inside the tunnel.
2. **Any account with a password can authenticate at the transport.** The core uses
   PAM, so a valid Linux username/password of *any* user passes its login (not only
   `sshudp-users`). sshd still restricts who gets what; the transport itself can
   relay TCP for whoever authenticates. Give administrators key-only logins, or use
   a dedicated VPS.
3. **`shadow` read access.** A compromise of the core could leak password hashes.
   Use strong, unique passwords (the generator makes 14-character random ones).
4. **Login limits are reactive** (≤60 s), see [ARCHITECTURE.md](ARCHITECTURE.md).
5. **fail2ban** (optional) sees tunnel logins as coming from `127.0.0.1`; the provided
   jail therefore ignores loopback and your current SSH address, otherwise one wrong
   password could ban every tunnel user or lock you out.
6. **Abuse.** SSH forwarding lets accounts reach any host. You are responsible for
   who you give accounts to. This project is meant for self-hosted tunnels on
   infrastructure you own or are authorised to administer.

## Decisions

* **Shell for tunnel accounts:** `/usr/sbin/nologin` + `PermitTTY no`. Rejected
  alternatives: a restricted shell (still a shell) and `ForceCommand` (breaks nothing
  extra but adds no security when forwarding is the whole point). Forwarding
  restrictions to specific destinations (`PermitOpen`) are impossible because clients
  need arbitrary destinations.
* **`shadow` group vs root:** a dedicated user with unit-scoped `shadow` is strictly
  weaker than root; root with an empty capability set was tested and also works and
  is available via `run-as root`.
* **Passwords not stored:** no reversible copy exists to leak; lost passwords are
  reset (`sshudp reset-password`).

## Security review (internal, v1.0.0)

Reviewed by reading every module for: shell injection, `eval`/`source` of
untrusted data, quoting, command substitution, temp-file and symlink races,
traversal, malicious archives, config injection, world-writable files, secret
leakage, unsafe downloads/TLS, `chmod 777`, sudo usage, systemd sandboxing.
Static analysis: ShellCheck on every script (CI-enforced). Dynamic: the test-suite's
hostile-input, hostile-archive, forged-metadata and permission tests.

Findings fixed during development: root-run manager honouring environment path
overrides (now test-mode only); RETURN-trap cleanup replaced by explicit cleanup;
ERR-trap rollback firing inside subshells; `ss` column mix-up that could have
misjudged port conflicts; `nft -f -` portability on old nft (`/dev/stdin`).

Residual, accepted: everything under "Known risks".

## Reporting a vulnerability

Open a private security advisory on GitHub (Security → Advisories) rather than a
public issue.
