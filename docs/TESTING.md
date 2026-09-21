# Testing

Only what is listed as *passing* here is claimed as supported. Results below are
from real runs of the suite in this repository; raw TAP output is produced by
`tests/run-matrix.sh` (and uploaded as CI artifacts).

## Layers

| Layer | Tool | What it covers |
|---|---|---|
| Static analysis | ShellCheck (CI-enforced), `bash -n`, forbidden-pattern grep (`curl -k`, `chmod 777`, `iptables -F`, `nft flush ruleset`, `ufw disable/reset`, `eval`) | every script |
| Unit tests | Bats (`tests/unit`) | input validation (usernames, passwords, ports, ranges, exclusions, dates, hostnames), config parsing/injection, platform gating, client card, hostile backup archives |
| Integration tests | Bats inside a **systemd-booted Ubuntu container per release** (`tests/integration`) | real installer, systemd units/timers, sshd, nftables, iptables, UFW, users, expiry, limits, update/rollback, backup/restore, uninstall, interactive menus (pty) |
| Transport tests | Open-source Hysteria v1 client fixture + network namespace | packets to range ports reach the upstream core through *our* redirect; exclusions are not captured; wrong ALPN/obfuscation parameters are refused by the core |
| Reference relay | Stock Hysteria v1 *server* (not the upstream binary) | SSH tunnel account works over a QUIC/UDP relay, data integrity by SHA-256, negative control |
| Native VM job | same integration suite on GitHub `ubuntu-22.04` / `ubuntu-24.04` runners | real VM systemd/sshd/firewall (no container) |
| Public installer | `tests/public-install-test.sh` | the exact `curl … \| sudo bash` command against GitHub RAW, then the full acceptance checklist |

Run locally (Docker with `--privileged`):

```bash
bash tests/fixtures/build-hy-client.sh          # once: builds the MIT-licensed reference client
bash tests/run-matrix.sh 22.04 24.04            # any of 20.04 22.04 24.04 26.04
```

## Results

Local container matrix, run 2026-09-22 on Docker Desktop (WSL2 kernel 6.18), each release in
its own `--privileged` container with systemd as PID 1:

| Ubuntu | systemd | Unit | Integration | Total | Passed | Failed | Skipped |
|---|---|---|---|---|---|---|---|
| 20.04 LTS | 245 | 206 | 136 | 342 | **342** | 0 | 0 |
| 22.04 LTS | 249 | 206 | 136 | 342 | **342** | 0 | 0 |
| 24.04 LTS | 255 | 206 | 136 | 342 | **342** | 0 | 0 |
| 26.04 LTS | 259 | 206 | 136 | 342 | **342** | 0 | 0 |

Architecture for all of the above: x86_64. GitHub Actions re-runs the same matrix plus a
native-VM job on every push (see the badge/status in the repository); its status is
recorded in the release notes.

Platform findings while testing (all fixed and now covered by tests):

* **systemd ≥ 255** counts manual `restart`s toward the unit start-rate limit → the manager
  now clears the counter for manual operations (crash-loop protection stays).
* **Ubuntu 24.04+** socket-activates `ssh`; **26.04 (OpenSSH 10)** renames the session
  process to `sshd-session` → session detection handles both.
* **Ubuntu 26.04** ships CMake 4 / GCC 15 → the optional UDPGW source build passes
  `CMAKE_POLICY_VERSION_MINIMUM=3.5` and `-std=gnu99`.
* **nft 0.8.2 (Ubuntu 18.04)** rejects named hook priorities → numeric priorities are used;
  if nft cannot load the rules the manager falls back to iptables automatically.
* Ubuntu 20.04 defaults to *legacy* iptables; the test image switches it to the nf_tables
  variant only because the Docker Desktop kernel lacks the legacy ip6tables modules.

### Ubuntu 18.04 (not supported)

`install.sh` refuses it by default ("end-of-life / not supported"). With
`SSHUDP_FORCE_UNSUPPORTED=1` a one-off **smoke test** passed in a container (systemd 237,
OpenSSH 7.6 without an `Include` line): install, doctor, user creation, SSH tunnel with
SHA-256-verified data, backup, uninstall (the marked block was appended to and removed
from `sshd_config`, `sshd -t` clean). The full suite was **not** run on 18.04 and the
release is EOL, so it is **not claimed as supported**.

### What the suites verify (highlights)

* **Installer:** unsupported OS/arch refused; not-root refused; unreachable release server;
  tampered archive (checksum); malformed version; upstream download failure; upstream
  checksum mismatch; occupied UDP port; interrupted install at two different steps
  (full rollback, OpenSSH untouched); fresh install; idempotent re-run keeps settings and
  users; partial/damaged installs repaired; interactive Quick/Advanced menus through a pty
  with invalid-answer re-prompting; non-interactive `curl | bash` path.
* **Safety:** the upstream core's blanket `1:65535` DNAT is absent; the core runs as `sshudp`
  with no capabilities and `NoNewPrivs`; unrelated nftables tables, iptables rules, UFW
  rules/state, services and admin accounts are unchanged across install, restart, fw
  apply/remove and uninstall; `doctor` is read-only.
* **Accounts:** create/duplicate/delete/renew/lock/unlock/reset; hostile usernames and
  validities; passwords never on argv, disk, journal or process list; nologin tunnel accounts
  cannot get a shell, exec or TTY yet forward TCP with intact data; expiry via the real
  systemd service; OS-level expiry; login-limit enforcement; forged metadata and reused-UID
  accounts refused; non-managed users untouched.
* **Firewall:** nftables, iptables and UFW paths, duplicate-rule avoidance, pre-existing UFW
  rule preserved, live UDP listeners excluded from the redirect, protected ports never
  redirected, runtime range changes.
* **Update/backup:** same-version no-op, check, upgrade preserving config/users/core,
  tampered/broken releases rejected, health-check failure → automatic rollback, downgrade
  not offered; backup permissions/contents, valid restore, corrupt/traversal/absolute/symlink
  archives, incompatible version, password-hash backup restoring a deleted account with the
  same password.
* **Uninstall:** with/without users/config, OpenSSH and admin accounts preserved, service
  account/sysctl restored, reinstall after uninstall and after purge.

## End-to-end SSH over UDP - what is and is not proven

**Proven (automated):**

1. Packets to any port inside the configured range are redirected by **our** firewall rules to the
   upstream core, and the obfuscated QUIC/TLS 1.3 handshake **completes** (`HandshakeDone`),
   from a separate network namespace via a veth pair (so the redirect path is really used;
   the nft counters rise). Excluded (53) and out-of-range (19999) ports are not captured.
   The core itself answers: a wrong ALPN gets a TLS alert from the core, a wrong obfuscation key
   gets silence. Stopping the service removes the redirect.
2. **Reference relay:** with a *stock Hysteria v1 server* (not the upstream binary) an SSH
   tunnel account logs in **through a QUIC/UDP relay**, forwards TCP and a 2 MB file arrives with the
   correct SHA-256, shell/exec is denied; and a **negative control** (relay server stopped) makes the
   same SSH attempt fail - proving the traffic really used UDP. This proves *our account/sshd policy*
   works over a UDP transport; it does not prove the upstream binary's own login.
3. Direct SSH with the same accounts: login, forwarding, SHA-256, denial of shell/TTY.

**Not proven:** the application-level login of the closed upstream core (its control message
differs from stock Hysteria - see [UPSTREAM.md](UPSTREAM.md)), and therefore
**HTTP Custom / UDP Custom Android compatibility is unverified**.

## Manual Android test remaining

See [CLIENT-SETUP.md](CLIENT-SETUP.md#manual-android-test). One connection from the real app
(with `sshudp doctor` green) is the only check that remains.

## Not covered (by design or limits)

* arm64 (unsupported), Ubuntu < 20.04, non-Ubuntu.
* An actual **reboot** (units are checked as enabled; systemd handles boot ordering; the firewall
  unit's stop/start cycle is tested).
* Real Internet firewalls/NAT (cloud security groups), IPv6 redirect on the `ip`-family nft
  fallback (old kernels), per-user traffic (not offered).
* Long-running load/soak behaviour of the upstream core.

## Public installer test (GitHub RAW)

Validated after the v1.0.0 release was published, using the exact user command
(`curl -fsSL https://raw.githubusercontent.com/Humran13/SSH-UDP-Custom-Server/main/install.sh | sudo bash`),
not a local file, by `tests/public-install-test.sh`:

* **Hash check:** SHA-256 of `install.sh` downloaded from GitHub RAW =
  `69c41696635c7b84fb90d1f3be72cb4fbc9590373574f470352a8b4274fd0e83` = SHA-256 of the file in the
  repository (identical).
* **Ubuntu 20.04, 22.04, 24.04, 26.04 (clean containers):** 30/30 checks pass on each: RAW hash,
  installer exit code and success message, installed version = repository `VERSION`, `status`,
  UDP service + port, `sshd_config` untouched, pre-existing admin SSH login still works, `doctor`
  (0 failed), user creation, tunnel login + forward + SHA-256 of 1.5 MB, no shell, expiry service
  locks the expired user and only that user, renew, `update --check` against real GitHub, `repair`
  after damage, backup, restore, `doctor` after restore, uninstall (admin/OpenSSH preserved, services
  and firewall table gone), reinstall with the public one-liner, `doctor` again.
* **GitHub-hosted VMs (`ubuntu-22.04`, `ubuntu-24.04`):** the same workflow
  (`.github/workflows/public-install.yml`) passed (run 35668056141).
* **CI for the release commit:** all jobs green - ShellCheck, secret scan, 206 unit tests, the
  integration suite in Ubuntu 20.04/22.04/24.04/26.04 systemd containers and on native
  22.04/24.04 VMs, reproducible release archive (run 35667182495).

The update path was tested with mock releases (upgrade, tamper, rollback); against real GitHub only
`update --check` ("already up to date") is possible while v1.0.0 is the only release.
