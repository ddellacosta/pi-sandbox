# Pi Sandbox

A lightweight NixOS-based VM that runs the [Pi](https://github.com/earendil-works/pi-mono) coding agent with strong host-kernel network isolation and a shared workspace.

The agent runs inside a VM that is attached to a host bridge (`br-pi`) via a TAP interface. The host kernel filters all traffic from the VM with `nftables`. The VM cannot modify these rules because they live entirely on the host.

## Current milestone: DNS + Ollama only

In this first milestone the VM can reach:

- DNS resolvers (Quad9 and Cloudflare by default)
- The host Ollama server at `10.0.3.1:11434`

Everything else, including HTTP/HTTPS to the internet, is blocked by the host firewall.

The next milestone will add a host-side `mitmproxy` whitelist so specific domains can be allowed over HTTP/HTTPS.

## Quick start

### 1. Clone / enter the repo

```bash
cd /path/to/pi-sandbox
```

### 2. Set up host networking (one-time, requires root)

```bash
nix run .#setup
```

This creates the bridge `br-pi`, the TAP `pi-tap`, enables IP forwarding, and loads the `nftables` rules.

### 3. Start Ollama on the host

Ollama must be reachable from the VM. Bind it to `0.0.0.0`:

```bash
OLLAMA_HOST=0.0.0.0:11434 ollama serve
```

Or, if you prefer, bind only to the bridge IP:

```bash
OLLAMA_HOST=10.0.3.1:11434 ollama serve
```

### 4. Start the sandbox

```bash
nix run .#pi
```

This prepares the workspace, installs the pinned Pi version into `workspace/pi-npm/`, and launches the VM. You should be logged in as `root` automatically.

### 5. Run Pi

Inside the VM:

```bash
pi
```

## How it works

```
┌─────────────────────────────────────────┐
│  Host kernel                             │
│  • br-pi bridge (10.0.3.1/24)            │
│  • pi-tap connected to br-pi              │
│  • nftables drops everything from br-pi   │
│    except DNS and Ollama                  │
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

## Workspace

The host directory `workspace/` is mounted at `/mnt/shared` inside the VM. It contains:

| Path | Purpose |
|------|---------|
| `workspace/pi-config/models.json` | Pi model configuration |
| `workspace/pi-config/settings.json` | Pi settings |
| `workspace/pi-config/skills/network-tools` | Network tools skill |
| `workspace/pi-npm/` | Pre-installed Pi package tree |
| `workspace/` | Your project files |

You can edit files on the host while the VM is running.

## First-milestone tests

Inside the VM, verify:

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
| `flake.nix` | VM definition, setup script, run script |
| `host/pi-defaults/` | Default Pi config templates |
| `skills/network-tools/` | VM-side helper scripts |
| `workspace/` | Shared workspace (created on first run) |

## License

MIT
