# Client setup

> **Compatibility status:** the server side is tested as deeply as possible without
> the proprietary Android app (see [TESTING.md](TESTING.md)). Compatibility with
> **HTTP Custom / UDP Custom** has **not** been verified end-to-end and is not
> claimed. Section [Manual Android test](#manual-android-test) tells you exactly
> how to verify it in five minutes.

## 1. Create an account

```bash
sudo sshudp create-user
```

Answer the prompts (username, generated or own password, validity, optional login
limit). You get a card like this - **copy the password now, it is not stored**:

```
╔════════════════════════════════════════════════╗
║             SSH UDP CUSTOM ACCOUNT             ║
╠════════════════════════════════════════════════╣
║ Server     : 203.0.113.10                      ║
║ Username   : demo                              ║
║ Password   : ExamplePass123                    ║
║ SSH Port   : 22                                ║
║ UDP Ports  : 20000-50000                       ║
║ Expires    : 2026-10-21                        ║
╚════════════════════════════════════════════════╝
```

Show it again later (without the password) with `sudo sshudp client demo`; set a new
password with `sudo sshudp reset-password demo`.

## 2. Fields that matter

Only these values are part of the setup. Nothing else is required by the server:

| Field in the client | Value | Notes |
|---|---|---|
| Tunnel type | SSH + **UDP Custom** | in HTTP Custom: the SSH tunnel type with the *UDP Custom* option |
| Server / host | server address from the card | hostname if you set one (`sshudp config server-host`) |
| UDP port(s) | the range from the card (default `20000-50000`) | must be inside the range the server redirects; ports listed as excluded/protected will not work |
| SSH username / password | from the card | |
| SSH port | from the card (default 22) | the port of the server's OpenSSH |
| UDPGW | `127.0.0.1:7300` **only if** you ran `sshudp udpgw enable` **and** the app's UDPGW option is on | optional, see below |

Account line used in public HTTP Custom guides *(public claim, unverified against
the current app)*:

```
SERVER:20000-50000@USERNAME:PASSWORD
```

What is **not** needed and therefore not shown: SNI, TLS settings, payload, proxy
fields. The buffer / "RX/TX" / "UDP tweak" numbers in the app are client-side
tuning; the server does not require particular values (the server-side buffers are
`stream_buffer` / `receive_buffer` in `config.conf`).

No import URI or file format is generated: none is documented for this mode.

## 3. UDPGW (optional)

UDPGW lets an app tunnel **UDP** traffic (DNS, voice, games) through the SSH
connection. It is not needed for the UDP Custom transport itself.

```bash
sudo sshudp udpgw enable        # builds badvpn-udpgw from pinned, verified source; listens on 127.0.0.1:7300 only
sudo sshudp udpgw status
sudo sshudp udpgw disable
```

## 4. Choosing the port range

* Default `20000-50000`. Use a range that does not overlap services you run.
* `sudo sshudp config udp-ports 30000-40000` and
  `sudo sshudp config udp-exclude 53,123,7300` change it live.
* Never redirected, regardless of settings: 53, 67, 68, 69, 123, 137, 138, 161, 443,
  500, 853, 1194, 1701, 4500, 5353, 51820, the core's listen port, and any UDP port that
  already has a listener when the rules load.
* Behind a cloud firewall / security group you must open the **UDP range** there too;
  that is outside the server's control.

## Manual Android test

This is the one check that cannot be automated (proprietary Android app).

1. On the VPS: `sudo sshudp doctor` → all PASS; `sudo sshudp create-user`.
2. In the app, create an SSH profile with the values above and choose *UDP Custom*.
3. Connect. On the VPS run `sudo sshudp online` - the user should appear (source
   `127.0.0.1` = via the UDP transport) and `sudo sshudp traffic` counters should rise.
4. Browse something; then disconnect.
5. Please report the result (app version, Android version, works/fails, and
   `sudo sshudp logs udp -n 100` on failure) via a GitHub issue. If it fails right
   after the handshake, that is consistent with the open question in
   [UPSTREAM.md](UPSTREAM.md#compatibility-notes---what-we-could-and-could-not-verify).
