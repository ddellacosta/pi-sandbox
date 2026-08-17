# Pi Sandbox

A lightweight NixOS-based VM that runs the [Pi](https://github.com/earendil-works/pi-mono) coding agent with strong host-kernel network isolation, a shared workspace, and a host-enforced HTTP/HTTPS domain whitelist.

The VM is attached to the host through a bridge (`br-pi`) and a TAP device (`pi-tap`). The host kernel filters all traffic from the VM with `nftables`. Because the firewall rules and the whitelist proxy live in the host's NixOS configuration, the agent inside the VM cannot modify them.

## What is allowed by default

| Traffic | Allowed? | Notes |
|---------|----------|-------|
| DNS | ✅ | To Quad9 (9.9.9.9) and Cloudflare (1.1.1.1) |
| Host Ollama | ✅ | At `10.0.3.1:11434` |
| HTTP/HTTPS | ⚠️ | Only via the host whitelist proxy; direct TCP 80/443 is dropped |
| Everything else | ❌ | Dropped by host firewall |

## Architecture

```
┌──────────────────────────────────────────────┐
│  NixOS host                                   │
│  • br-pi bridge (10.0.3.1/24)                 │
│  • pi-tap connected to br-pi                    │
│  • mitmproxy whitelist proxy on 10.0.3.1:8080 │
│  • nftables table inet pi-sandbox              │
│    drops everything from br-pi except DNS,    │
│    Ollama, and the whitelist proxy             │
│  • Whitelist file: /etc/pi-sandbox/whitelist.conf │
└──────────────┬───────────────────────────────────┘
               │ pi-tap
┌──────────────▼───────────────────────────────────┐
│  NixOS VM                                       │
│  • eth0: 10.0.3.2/24                            │
│  • default gateway: 10.0.3.1                     │
│  • HTTP_PROXY/HTTPS_PROXY = http://10.0.3.1:8080 │
│  • /mnt/shared workspace via 9p                  │
│  • Pi process runs here                         │
└──────────────────────────────────────────────────┘
```

## Setup

### 1. Import the module into your NixOS configuration

With flakes:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pi-sandbox.url = "path:/path/to/pi-sandbox";
  };

  outputs = { self, nixpkgs, pi-sandbox, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        pi-sandbox.nixosModules.default
        {
          services.pi-sandbox.enable = true;
          services.pi-sandbox.user = "your-username";
        }
      ];
    };
  };
}
```

Or without flakes, add to `/etc/nixos/configuration.nix`:

```nix
{ config, pkgs, ... }:

{
  imports = [
    /path/to/pi-sandbox/nixos-module.nix
  ];

  services.pi-sandbox.enable = true;
  services.pi-sandbox.user = "your-username";
}
```

Then rebuild:

```bash
sudo nixos-rebuild switch
# or: sudo nixos-rebuild switch --flake .#myhost
```

This creates the bridge, TAP device, `nftables` rules, and the mitmproxy systemd service.

### 2. Start Ollama on the host

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

Or bind only to the bridge:

```bash
OLLAMA_HOST=10.0.3.1:11434 ollama serve
```

### 3. Start the sandbox

From the repository root:

```bash
nix run .#pi
```

### 4. Run Pi

Inside the VM:

```bash
pi
```

## Workspace

The host directory `workspace/` is mounted at `/mnt/shared` inside the VM. It contains:

| Path | Purpose |
|------|---------|
| `workspace/pi-config/models.json` | Pi model configuration |
| `workspace/pi-config/settings.json` | Pi settings |
| `workspace/pi-config/skills/network-tools` | Network tools skill |
| `workspace/pi-npm/` | Pre-installed Pi package tree |
| `workspace/` | Your project files |

You can edit files on the host while the VM is running. Changing `workspace/pi-config/models.json` takes effect the next time you start the VM.

## Whitelist management

On the host, from the repository root:

```bash
# Add a domain
sudo ./host/pi-sandbox-whitelist add ollama.com

# List allowed domains
sudo ./host/pi-sandbox-whitelist list

# Remove a domain
sudo ./host/pi-sandbox-whitelist remove ollama.com

# Edit directly
sudo ./host/pi-sandbox-whitelist edit
```

The proxy reloads `/etc/pi-sandbox/whitelist.conf` automatically. No VM restart is required.

## Common tests

Inside the VM:

```bash
# DNS
dig example.com

# Ollama
curl http://10.0.3.1:11434/

# HTTPS through the proxy (blocked until whitelisted)
curl -v https://example.com

# After adding example.com on the host:
curl -v https://example.com
```

## Security properties

- The VM cannot modify `/etc/pi-sandbox/whitelist.conf` (it is not mounted).
- The VM cannot stop or reconfigure the host mitmproxy service.
- Direct TCP 80/443 from the VM to the internet is dropped by host `nftables`.
- `HTTP_PROXY`/`HTTPS_PROXY` are set in the VM, but even a process that ignores them cannot bypass the proxy because direct internet HTTP/HTTPS is blocked at the kernel.

## Files

| File | Purpose |
|------|---------|
| `flake.nix` | VM definition and run script |
| `nixos-module.nix` | NixOS host networking, firewall, and proxy service |
| `lib/sandbox-config.nix` | Shared network and workspace defaults |
| `host/mitmproxy/whitelist-addon.py` | mitmproxy whitelist addon |
| `host/pi-sandbox-whitelist` | Host-side whitelist management CLI |
| `host/pi-defaults/` | Default Pi config templates |
| `skills/network-tools/` | VM-side helper scripts |
| `workspace/` | Shared workspace (created on first run) |

## License

MIT
