# bind9sync — Proxmox VM name → BIND9 A records (DDNS via TSIG)

Small Bash script that syncs **Proxmox VE VMs** into **BIND9** zone:
- VM **NAME** → DNS **A record**
- VM IP is taken from **QEMU Guest Agent** (`qm guest cmd <vmid> network-get-interfaces`)
- Updates are applied via **RFC2136 DDNS** (`nsupdate`) authenticated by **TSIG key** provided as **base64** (`BIND_TSIG_KEYFILE_B64`)
- Designed to run via **systemd timer** and log to **journald**

## How it works

For each VM from `qm list`:
1. If VM is `running`, script asks guest-agent for interfaces and selects the first **IPv4** inside `NETWORK` CIDR.
2. Builds FQDN as: `<vm_name_sanitized>.<BIND_ZONE>`
3. Reads current A-record via `dig`.
4. If current != new IP, applies atomic update:
   - `update delete <fqdn> A` (removes old A records for this name)
   - `update add <fqdn> <TTL> A <ip>` (adds the new one)

Stopped VMs:
- default: skipped (DNS record stays)
- optional: if `DELETE_STOPPED=true`, deletes the A-record.

## Requirements

On Proxmox host:
- `qm` (Proxmox VE)
- `jq`
- `dig` (package `dnsutils`)
- `nsupdate` (package `dnsutils`)
- `base64`
