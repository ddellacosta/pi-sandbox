---
name: network-tools
description: Network utilities for detecting sandbox network blocks. Use these tools to identify blocked domains and get instructions for adding them to the host-side whitelist once the proxy is enabled.
---

# Network Tools

Network utilities for the Pi sandbox. These tools detect when network access is blocked and tell you exactly what command to run **on the host** to allow it.

The host-side whitelist is at `/etc/pi-sandbox/whitelist.conf` and is managed with `host/pi-sandbox-whitelist`. The proxy reloads it automatically.

## Check if Domain is Allowed

```bash
./scripts/check-whitelist.sh <domain>
```

Quick test to see if a domain is accessible from the sandbox.

## Fetch URL with Whitelist Detection

```bash
./scripts/fetch.sh <url>
```

Fetches a URL and automatically detects if it's blocked by the proxy or firewall. If blocked, it prints the exact command to add the domain to the whitelist.

## Manual Testing

```bash
# Test DNS
dig example.com

# Test through the explicit proxy
curl -v --proxy 10.0.3.1:8080 https://example.com

# View the current whitelist file (host path)
cat /etc/pi-sandbox/whitelist.conf
```

## Quick Reference

| Command | Purpose |
|---------|---------|
| `./fetch.sh <url>` | Fetch with whitelist error detection |
| `./check-whitelist.sh <domain>` | Test if domain is allowed |
| `./whitelist-helper.sh <d1> <d2> ...` | Generate whitelist commands |
| `dig <domain>` | Test DNS resolution |
| `curl -v <url>` | Verbose connection test |
| `cat /etc/pi-sandbox/whitelist.conf` | View current whitelist file |

## Adding Domains to the Whitelist

On the host (repo root):

```bash
sudo ./host/pi-sandbox-whitelist add ollama.com
```

Then retry the request inside the VM. No VM rebuild or restart is required.