# Architecture

## Components

```
                       UDP (any port in the configured range, e.g. 20000-50000)
 client app  ───────────────────────────────────────────────►  network interface
 (HTTP Custom /                                                     │
  UDP Custom)                                              nftables/iptables PREROUTING
                                                           (project-owned table/chains,
                                                            iifname != lo, protected ports
                                                            and live UDP listeners excluded)
                                                                    │ redirect → :36712
                                                                    ▼
                                            ssh-udp-custom.service  (upstream udp-custom core)
                                            user "sshudp", no capabilities, read-only system
                                            authenticates account+password via PAM
                                                                    │ TCP 127.0.0.1:<ssh-port>
                                                                    ▼
                                                        OpenSSH  (sshd, unchanged)
                                            Match Group sshudp-users → forwarding only
                                                                    │
                                                                    ▼
                                                              the Internet
```

| Piece | What it is | Owned by us? |
|---|---|---|
| `udp-custom` core | closed-source upstream binary, downloaded + SHA-256 verified at install | **no** (third party, unlicensed) |
| `ssh-udp-custom.service` | hardened unit that runs the core | yes |
| `ssh-udp-custom-firewall.service` | oneshot unit that loads/removes our redirect rules | yes |
| `sshudp` manager | Bash CLI + dashboard (`/usr/local/lib/ssh-udp-custom`) | yes |
| sshd drop-in | `/etc/ssh/sshd_config.d/90-ssh-udp-custom.conf` (`Match Group sshudp-users`) | yes |
| timers | `ssh-udp-custom-expiry.timer` (daily), `ssh-udp-custom-limiter.timer` (60 s) | yes |
| optional | `ssh-udp-custom-udpgw.service` (badvpn), Fail2ban jail file | yes, off by default |

## Filesystem layout

| Path | Purpose | Mode |
|---|---|---|
| `/usr/local/bin/sshudp` | symlink to the manager | - |
| `/usr/local/lib/ssh-udp-custom/` | manager code, unit templates, `upstream.conf`, `core/udp-custom` | root:root, no group/world write |
| `/etc/ssh-udp-custom/config.conf` | settings (`KEY=VALUE`, parsed, never sourced) | 644 |
| `/etc/ssh-udp-custom/udp-custom.json` | generated core config (no secrets) | 644 |
| `/var/lib/ssh-udp-custom/users/*.meta` | one metadata file per managed account | dir 700, files 600 |
| `/var/lib/ssh-udp-custom/state/` | firewall state, sysctl previous values | 700 |
| `/var/backups/ssh-udp-custom/` | backups, update snapshots | 700 |
| `/etc/systemd/system/ssh-udp-custom*` | rendered units | 644 |
| `/etc/sysctl.d/90-ssh-udp-custom.conf` | only if buffers had to be raised | 644 |

Logs go to the journal (`journalctl -u ssh-udp-custom`, `journalctl -t sshudp`).

## Accounts

* Metadata (`*.meta`: username, UID, created, expires, status, login limit) is kept
  separately from the OS account. **Passwords are never stored.**
* An account is *managed* only if a `.meta` file exists **and** the OS account exists
  **and** its UID equals the recorded UID **and** its primary group is `sshudp-users`.
  Anything else (administrators, forged metadata, reused names) is refused.
* Created with `useradd --no-create-home --shell /usr/sbin/nologin --gid sshudp-users
  --expiredate <expiry+1 day>`. The OS-level expiry is a second line of defence in
  case the timer is missed.
* **Why `nologin` works:** OpenSSH port forwarding does not need a shell. The
  `Match Group` block sets `PermitTTY no`, `AllowAgentForwarding no`,
  `X11Forwarding no`, `PermitTunnel no`, `AllowTcpForwarding yes`,
  `AuthenticationMethods password`. Shell/exec requests end with "This account is
  currently not available." *(Tested. Whether a specific Android client also
  tolerates an immediately-closing shell channel is part of the manual test.)*
* **Expiry:** `ssh-udp-custom-expiry.timer` (daily, `Persistent=true`, also 3 min after
  boot) runs `sshudp cleanup-expired`, which locks accounts whose expiry date has
  passed, kills their sessions and marks them `expired`. `--delete` removes them.
* **Simultaneous logins:** enforced *reactively*. A 60-second timer counts
  `sshd: USER` session processes and terminates the newest ones above the limit.
  It cannot prevent the extra connection from being established (it lives up to
  ~60 s) - a preventive limit would need `pam_limits`/utmp entries that
  forwarding-only sessions do not create. This is documented rather than faked.

## Firewall

* Backend choice (`FIREWALL_MODE=auto`): nftables if `nft` works, else iptables.
  We **never install** the `nftables` package (on some releases it enables a
  boot service that begins with `flush ruleset`).
* nftables: table `sshudp` (family `inet`, falling back to `ip`) with a
  `prerouting` NAT chain (`priority dstnat`) and an output stats chain. Removal =
  `nft delete table`.
* iptables: chains `SSHUDP_PRE` (nat), `SSHUDP_IN`, `SSHUDP_OUT`, each referenced by
  exactly one jump. Removal = delete the jump, flush and delete our chain.
* UFW: if active, one `ufw allow <listen-port>/udp`. The redirect runs in PREROUTING,
  so UFW only ever sees the listen port. The rule is recorded in
  `state/firewall.state`; if an identical rule existed before, it is marked
  pre-existing and never deleted.
* **Effective range** = `UDP_PORTS` − `UDP_EXCLUDE` − protected ports
  (53, 67, 68, 69, 123, 137, 138, 161, 443, 500, 853, 1194, 1701, 4500, 5353, 51820)
  − the listen port − UDP ports that currently have a listener. It is recomputed
  whenever rules are applied (boot, restart, `sshudp fw apply`, `repair`).
* Only packets from non-loopback interfaces are redirected.
* Replies to the server's own outbound UDP flows are unaffected: NAT rules see only
  the first packet of a flow.

## Traffic statistics

* **Service level (reliable):** kernel counters on the redirect rule (received) and
  on packets sent from the listen port by the core's UID (sent).
* **Per-user traffic is not offered.** The tunnel's payload lives inside a QUIC
  connection to one process and inside SSH sessions relayed from `127.0.0.1`; the
  kernel cannot attribute bytes to users without per-user cgroups/conntrack marks
  that would not survive the closed-source relay. Showing invented numbers would be
  worse than none.
* **Source addresses:** sessions arriving through the UDP transport show
  `127.0.0.1` (the local relay). Real client IPs are only known to the core.

## Update and rollback

`sshudp update`: read `VERSION` from the latest release → show change → back up
config/metadata (`preupdate`) → snapshot the installed tree → download archive +
`SHA256SUMS` → verify checksum → validate member paths, file types, `bash -n` of
every script → atomic swap of `/usr/local/lib/ssh-udp-custom` → run the *new*
code's `_post-update` (re-apply units/policy/firewall, restart, health check) →
on any failure restore the snapshot and re-run the health check.

## Kernel/network tuning (documented, reversible)

Only one: `net.core.rmem_max` and `net.core.wmem_max` are raised to 16 777 216 **if
lower**. Reason: the upstream core does exactly this itself when run as root and
QUIC needs large UDP buffers. Previous values are recorded in
`state/sysctl.prev`; uninstall restores them and deletes the drop-in. No other
sysctl, no congestion-control changes, no "low ping" tweaks.
