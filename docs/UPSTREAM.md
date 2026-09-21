# Upstream: what "UDP Custom" actually is

This project does **not** implement a UDP transport. The transport is a third-party
program ("UDP Custom" by "ePro Dev. Team"). This document records what was
investigated before writing any code, what is verified, and what is not.

Research date: 2026-09-21. Everything below was observed first-hand (downloaded
artifacts, run in containers, inspected with `strings`/`strace`/packet captures),
except where marked *(public claim)*.

## Summary

| Question | Finding |
|---|---|
| Upstream project | `udp-custom` server binary by "ePro Dev. Team" (self-reported author string) |
| Where it is published | <https://github.com/http-custom/udp-custom> (a **personal** GitHub account named `http-custom`, not an organization; it is unverified whether this is the HTTP Custom app's maintainer) |
| Version | `UDP-Custom v1.4` (binary banner); installer/README says "2.5-Lite" for the *script bundle* |
| Pinned commit | `c76058cd37c1516b1c869e8ef45cdc952441b962` (last commit touching the binary, 2023-09-26) |
| Artifact | `bin/udp-custom-linux-amd64`, 4 782 592 bytes |
| SHA-256 | `2a1b5584c7947feb5a02e847e09795751024f63ce7137a353c2b9c2a4282d636` |
| Source code | **Not published.** Repository contains only the binary, helper scripts and units |
| License | **None.** No `LICENSE` file, no license in the README, GitHub reports no license |
| Redistribution | **Not permitted by default** (no license = all rights reserved). We therefore never ship or mirror the binary; the installer downloads it from the upstream URL at install time and verifies the SHA-256 |
| Architectures | Only `amd64` is published upstream. The only `arm64` build is on a third-party account (`powermx/udp-custom-arm64`, "credits to ePro Dev TEAM") - not upstream, unverifiable, **not supported here** |
| Ubuntu releases | Upstream README: "ubuntu 20.04 [x86_64] recommended". Our test results are in [TESTING.md](TESTING.md) |
| Trustworthiness | Unverifiable closed-source binary, UPX-packed. Treat it as untrusted code: it is run unprivileged, sandboxed by systemd, with no capabilities (see below and [SECURITY.md](SECURITY.md)) |
| Last upstream activity | 2023-09-29 - effectively unmaintained |

## What the binary is (observed)

* A statically linked Go 1.20.3 program, packed with UPX 4.01.
* Built from the **Hysteria v1** core (`github.com/apernet/hysteria/core`, MIT
  license) on `apernet/quic-go v0.32.1`, with ePro-specific additions:
  `dev.epro/udp-custom/app/auth.PAMAuth` (PAM password authentication),
  an iptables/sysctl helper (`cmd/core.ExecCmd`, `parsePortIptables`) and a
  custom control message.
* `udp-custom server --config <json>` is the only command. Config keys found in
  the binary: `listen`, `stream_buffer`, `receive_buffer`, `auth.mode`
  (`passwords`), `max_conn_client`, `disable_udp`, `resolver`, `up`/`down`.
  Only `listen`, `stream_buffer`, `receive_buffer` and `auth.mode=passwords` are
  documented by upstream's own default `config.json`, so **only those are exposed**
  by this project.
* Clients therefore authenticate with a **Linux account name and password** (PAM),
  which is why "SSH UDP Custom" accounts are ordinary SSH accounts.

### Behaviour that shaped the design (all reproduced in a container)

1. **It rewrites the firewall by itself.** On start it runs (equivalent to)
   `iptables -t nat -A PREROUTING -i eth0 -p udp --dport 1:65535 -j DNAT --to-destination :36712`
   plus `iptables -I INPUT -p udp --dport 36712 -j ACCEPT` (and `ip6tables`). The
   `--exclude 53,5300` flag only splits the range around those ports.
   It **never removes** these rules - not on SIGTERM, and a restart **adds duplicates**.
   This would hijack every UDP service on the machine (DNS, NTP, WireGuard, QUIC...).
2. **It runs `sysctl -w net.core.rmem_max=16777216` / `wmem_max`** and shells out to
   `ip route get 8.8.8.8` to find the interface.
3. **It works without root, without capabilities and without an `iptables` binary.**
   Started as an unprivileged user with an empty capability set, it just fails
   the firewall/sysctl calls silently and listens on the port.
4. It embeds a **hard-coded TLS key/certificate** and a **hard-coded obfuscation
   key** (see "Compatibility notes"). Both are identical on every server.
5. PAM verification of *other* users' passwords needs either uid 0 or read access
   to `/etc/shadow`. We tested (`tests`-independent probe): an unprivileged user
   fails, a member of group `shadow` succeeds, root without capabilities succeeds.
6. The upstream installer (not used here) runs `ufw disable`,
   `apt-get remove --purge ufw firewalld` and `apt remove netfilter-persistent`,
   changes the timezone and reboots. **None of that is reproduced.**

### What we do instead

| Upstream behaviour | This project |
|---|---|
| Runs as root | Dedicated `sshudp` user, supplementary group `shadow` only for PAM, `CapabilityBoundingSet=` empty, `NoNewPrivileges`, `ProtectSystem=strict`, minimal address families ([SECURITY.md](SECURITY.md)) |
| Blanket `1:65535` DNAT | Manager-owned nftables table / iptables chains that redirect only the **configured range** minus protected ports, exclusions and live UDP listeners |
| Never cleans rules | Rules are created/removed by a systemd unit and by `sshudp fw`; uninstall removes only ours |
| `sysctl -w` (as root) | One persistent, reversible sysctl drop-in that only *raises* the two buffers |
| Disables/purges firewalls | Never touches other firewall state |

## BadVPN UDPGW: needed or not?

The upstream bundle also ships a `udpgw` binary (listening on `127.0.0.1:7800`).
`udpgw` is **unrelated to the UDP Custom transport**. It only matters when a client
app tunnels *UDP* traffic (DNS, voice, games) *through the SSH connection* and has
its "UDPGW" option enabled. Consequently:

* It is **optional** and **off by default**.
* We do not ship the unknown `udpgw` binary. Ubuntu has **no** `badvpn` package, so
  `sshudp udpgw enable` downloads the pinned upstream *source* (`ambrop72/badvpn` tag
  `1.999.130`, BSD-3-Clause, SHA-256 verified), installs `cmake make gcc libc6-dev` if missing,
  builds only `badvpn-udpgw`, and runs it bound to
  `127.0.0.1` only, as an unprivileged user, in its own systemd unit.
* Default port `7300` (the conventional badvpn port that apps pre-fill).

## Client requirements (public claims, not verified here)

From public tutorials *(public claim)*: HTTP Custom has an "SSH" mode with a
"UDP Custom" option; the account is entered as `host:port-range@user:password`
where the range is typically `1-65535`; the app's "UDP Tweak"/buffer fields
are client-side tuning. SNI/TLS fields are **not** part of this mode. We show
only these fields (see [CLIENT-SETUP.md](CLIENT-SETUP.md)); we do not invent
import URIs or file formats.

RX/TX-like values (`stream_buffer`, `receive_buffer` in the server config, buffer
values in the app) are **performance tuning**, not authentication or protocol
requirements.

## Compatibility notes - what we could and could not verify

Verified with an open-source Hysteria v1.3.5 client (built from source, MIT)
against the pinned binary in a Linux container:

* The server answers only if the client uses the **fork's hard-coded packet
  obfuscation key** and the TLS ALPN **`h3`**. With the wrong ALPN the core
  replies with a TLS alert (`no application protocol`); with the wrong
  obfuscation key it stays silent. (Both values are constants inside the public
  binary; they are protocol parameters, not secrets.)
* With those parameters the QUIC/TLS 1.3 handshake **completes**
  (`HandshakeDone`), through this project's redirect from any port in the
  configured range.

**Not verified, and therefore not claimed:** the application-level login. The
fork changed Hysteria's control message (its structures carry an extra
`User`/`UserLen` field); a stock Hysteria client - and patched variants we tried -
stalls after the handshake and never reaches PAM. Reproducing the exact message
would require reverse-engineering a closed protocol, which we did not do beyond
the observations above. **Compatibility with HTTP Custom / UDP Custom Android
clients is therefore *not* verified** and needs one manual test on a phone
(see [TESTING.md](TESTING.md#manual-android-test-remaining)).

## Security considerations

* Closed-source, unlicensed, packed binary from a personal account: an
  auditable alternative does not exist. Mitigations: pinned commit + SHA-256,
  unprivileged execution, no capabilities, read-only system, no home, network
  families restricted to IP/netlink/unix, `TasksMax`, `LimitNOFILE`.
* The embedded TLS key is public knowledge, so the QUIC layer provides **no
  server authentication**: a network attacker could impersonate the server
  (clients skip certificate verification by design). The **SSH layer inside the
  tunnel** is what protects the session: always verify/pin the SSH host key in
  the client where the app allows it.
* The core forwards to destinations chosen by an authenticated client. Accounts
  are SSH accounts with forwarding allowed anyway, so this is no additional
  privilege for them - but it is why non-tunnel accounts (any Linux user with a
  password) can also authenticate at the transport. Keep administrator accounts
  key-only/locked-password if that matters, or use a separate host.
* The core reads password hashes via `shadow` group membership (or root). It is a
  privileged-data reader; that is the price of PAM authentication and the reason
  it is sandboxed.

## Update policy

`sshudp update` updates only *our* code. The core is pinned in `upstream.conf`
and only changes with a new, tested release of this project. `sshudp core-update`
re-fetches and re-verifies the pinned core; it never silently switches to a
different upstream build.
