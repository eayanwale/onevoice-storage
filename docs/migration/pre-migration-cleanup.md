# Pre-migration cleanup: third-party agents (#102)

Done on the Bluehost VPS on **2026-10-02**, before any containerization work.

Two components had been installed on the host outside this repo. Neither appears in `provision.sh` or `configure.sh`, so a re-provision would not have recreated them, and their removal needs no script change.

## Removed or changed

| Component | Action | Verified |
|---|---|---|
| Splunk Universal Forwarder | Stopped and disabled. Package removed (`dnf remove`), along with the install directory, the systemd unit, the daily cron job that re-applied log ACLs, the downloaded installer and the ACL entries it had added on `/var/log/secure`, `/var/log/messages` and `/var/log/nginx` (including the default ACL) | Package gone, no process, unit not found, zero remaining ACL entries. No other package depended on it. |
| Tailscale | `tailscale logout`. Package and `tailscaled` left installed but disconnected, to be rejoined to the owner's own tailnet. | No tailnet address on `tailscale0` |

**Left in place pending owner confirmation:** the forwarder's system account (`splunkfwd`, nologin) and the firewalld rule for Tailscale's UDP port. The owner may want the port once Tailscale rejoins a tailnet.

Nextcloud was unaffected: `occ status` was healthy before and after, and the site answered 200 locally.

## Not recorded here

The access review (accounts, keys, sessions) and the credential-exposure assessment were reported to the owner privately. This repository is public.
