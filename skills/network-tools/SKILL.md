---
name: network-tools
description: Network utilities for detecting sandbox network blocks. Use these tools to identify blocked domains and get instructions for adding them to the host-side whitelist once the proxy is enabled.
---

# Network Tools

Network utilities for the Pi sandbox. These tools detect when network access is blocked and tell you exactly what command to run **on the host** to allow it.

## Check if Domain is Allowed

```bash
./scripts/check-whitelist.sh <domain>
```

Quick test to see if a domain is accessible from the sandbox.

## Fetch URL with Whitelist Detection

```bash
./scripts/fetch.sh <url>
```

Fetches a URL and automatically detects if it's blocked by the firewall or proxy.

## Quick Reference

| Command | Purpose |
|---------|---------|
| `./fetch.sh <url>` | Fetch with whitelist error detection |
| `./check-whitelist.sh <domain>` | Test if domain is allowed |
| `dig <domain>` | Test DNS resolution |
| `curl -v <url>` | Verbose connection test |
