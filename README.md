# Pi Sandbox

A lightweight NixOS-based VM that runs the [Pi](https://github.com/earendil-works/pi-mono) coding agent with strong host-kernel network isolation and a shared workspace.

The VM is attached to the host through a bridge (`br-pi`) and a TAP device (`pi-tap`). The host kernel filters all traffic from the VM with `nftables`. Because the firewall rules live in the host's NixOS configuration, the agent inside the VM cannot modify them.

## Current milestone: DNS + Ollama only

In this first milestone the VM can reach:

- DNS resolvers (Quad9 and Cloudflare by default)
- The host Ollama server at `10.0.3.1:11434`

Everything else — including HTTP/HTTPS to the internet — is dropped by the host firewall.

The next milestone will add a host-side `mitmproxy` whitelist so specific domains can be allowed over HTTP/HTTPS.

## Architecture

```
┌─────────────────────────────────────────┐
│  NixOS host                              │
│  • br-pi bridge (10.0.3.1/24)            │
│  • pi-tap connected to br-pi              │
│  • nftables in table inet pi-sandbox      │
│    drops everything from br-pi except    │
│    DNS and Ollama                        │
│  • Ollama reachable at 10.0.3.1:11434    │
└──────────────┬───────────────────────────┘
               │ pi-tap
┌──────────────▼───────────────────────────┐
│  NixOS VM                                │
│  • eth0: 10.0.3.2/24                     │
│  • default gateway: 10.0.3.1              │
│  • /mnt/shared workspace via 9p           │
│  • Pi process runs here                  │
└──────────────────────────────────────────┘
```

## Setup

### 1. Add this flake as a NixOS input

In your host `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pi-sandbox.url = "path:/path/to/pi-sandbox"; # or github:...
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

Then rebuild:

```bash
sudo nixos-rebuild switch --flake .#myhost
```

This creates the bridge, TAP device, and `nftables` rules.

### 2. Start Ollama on the host

Ollama must be reachable from the VM. Bind it to `0.0.0.0`:

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

Or bind only to the bridge IP:

```bash
OLLAMA_HOST=10.0.3.1:11434 ollama serve
```

### 3. Start the sandbox

From the `pi-sandbox` repository root:

```bash
nix run .#pi
```

This prepares the workspace, installs the pinned Pi version into `workspace/pi-npm/`, and launches the VM.

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

## First-milestone tests

Inside the VM:

```bash
# DNS
dig example.com

# Ollama
curl http://10.0.3.1:11434/

# HTTP/HTTPS should be blocked
curl -v https://example.com
```

## Files

| File | Purpose |
|------|---------|
| `flake.nix` | VM definition and run script |
| `nixos-module.nix` | NixOS host networking module |
| `lib/sandbox-config.nix` | Shared network and workspace defaults |
| `host/pi-defaults/` | Default Pi config templates |
| `skills/network-tools/` | VM-side helper scripts |
| `workspace/` | Shared workspace (created on first run) |

## License

MIT
