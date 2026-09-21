# Troubleshooting

Start with `sudo sshudp doctor` (read-only). Each `[FAIL]`/`[WARN]` line prints a
suggested `fix:`. Then `sudo sshudp repair` fixes the common problems without
touching your settings or accounts.

| Symptom | Likely cause | What to do |
|---|---|---|
| Installer: "unsupported operating system / has not been tested" | Not a tested Ubuntu LTS | Use a tested release ([README](../README.md#supported-systems)). `SSHUDP_FORCE_UNSUPPORTED=1` overrides the release check (not the CPU check) at your own risk |
| Installer: "unsupported CPU architecture" | arm64/other | Only x86_64 is supported: upstream publishes no official arm64 build |
| Installer: "UDP port 36712 is already in use" | Another program owns the port | Free it, or run the **Advanced install** and pick another listen port |
| Installer: "cannot reach the upstream download host" | DNS/outbound firewall | `curl -I https://raw.githubusercontent.com` must work |
| `[FAIL] UDP port 36712 not listening` | Service crashed / bad config | `sshudp logs udp`, then `sudo sshudp repair` |
| `[FAIL] Firewall redirect rules missing` | Rules unloaded (manual flush, other firewall tool reloaded) | `sudo sshudp fw apply` |
| `[WARN] nftables input chain has policy drop` | Your own nftables ruleset blocks the port | add `udp dport 36712 accept` to your input chain (we never edit foreign rulesets) |
| `[WARN] Other UDP listeners inside the range` | A local service uses a port in the range | They are excluded automatically; add them to `sshudp config udp-exclude` to make it permanent and visible |
| Client connects to nothing / times out | Cloud/provider firewall blocks the UDP range | open the range (UDP) in the provider panel |
| Client: authentication fails | Wrong password, locked or expired account | `sudo sshudp users`; `sshudp unlock-user`/`renew-user`/`reset-password` |
| Client: SSH login works directly but not via UDP | `AllowUsers`/`AllowGroups` in sshd_config excludes the group | `doctor` warns; add group `sshudp-users` |
| Expired user still online | Timer has not run yet | `sudo sshudp cleanup-expired` (also kills sessions) |
| Login limit not enforced immediately | Limits are checked every 60 s | by design, see ARCHITECTURE |
| `sshudp: command not found` | Link missing | `sudo /usr/local/lib/ssh-udp-custom/bin/sshudp repair` |
| Everything gone after a rollback | - | backups: `sshudp backups`; restore: `sudo sshudp restore <file>` |
| Public IP wrong (private address shown) | Server behind NAT | `sudo sshudp config server-ip <public-ip>` |
| fail2ban banned a user | Jail without loopback exception | `sudo sshudp fail2ban disable` (our jail ignores loopback and your admin IP) |

## Logs

```bash
sudo sshudp logs udp            # last 50 lines of the core
sudo sshudp logs udp -f         # follow
sudo sshudp logs events         # account/firewall/update events (never contains passwords)
sudo sshudp logs expiry         # expiry timer runs
```

## Recovering from a failed update

Updates roll back automatically. If you interrupted one:
`ls /var/backups/ssh-udp-custom` - `lib-v<old>-<time>` is a full snapshot of the previous
program files; `sshudp-backup-*-preupdate.tar.gz` holds settings and account metadata.
Re-running the installer command is always safe (idempotent).

## Removing everything

```bash
sudo sshudp uninstall            # asks about tunnel users and configuration
```

Only project-owned objects are removed. OpenSSH, other users and other firewall rules
stay.
