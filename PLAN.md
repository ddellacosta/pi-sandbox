# Plan: Replace Pi with Maki

> Status: **draft for review** — no code changes made yet. This branch (`maki`) is
> the working branch for the migration.

## Goal

Swap the coding agent inside the sandbox VM from **Pi** (Node.js) to **Maki**
(Rust), while keeping the network-isolation architecture (bridge, TAP,
`nftables`, mitmproxy whitelist proxy) exactly as it is.

## Motivation

Pi's startup is ~90–115s in this VM. The measured causes are:

1. Pi is a Node.js app that loads a **145 MB / 13,182-file module graph** at
   startup (the dominant cost — ~56–70s of CPU-bound module evaluation).
2. The VM has **1 CPU core and ~1 GB RAM**, so that evaluation is slow.
3. The install lives on a **9p shared filesystem** (`/mnt/shared`), which is
   ~10–130× slower than local disk for file operations.

Maki is a **single compiled Rust binary** (`src/main.rs` → one native
executable). It has no module graph to load, so it starts in milliseconds and
sidesteps all three problems. Its README advertises "SUPER fast startup …
Not running any JavaScript."

## What stays the same

- Host network isolation: `br-pi` bridge, `pi-tap` TAP, the `inet pi-sandbox`
  `nftables` table, and the mitmproxy whitelist proxy on `10.0.3.1:8080`.
- The whitelist management CLI (`host/pi-sandbox-whitelist`).
- Workspace sharing via 9p (`/mnt/shared`).
- The `network-tools` skill (adapted, see below).
- DNS (Quad9/Cloudflare), host Ollama (`10.0.3.1:11434`), and the
  HTTP/HTTPS proxy environment variables.

## What changes

| Concern | Pi (current) | Maki (target) |
|---|---|---|
| Agent binary | `npm install @earendil-works/pi-coding-agent` → `pi` wrapper exec'ing `node` | single `maki` binary |
| Config location | `~/.pi/agent/{models.json,settings.json}` | `~/.config/maki/` |
| Provider config | `models.json` (ollama, `baseUrl`, model list) | `OLLAMA_HOST` env var + `--model` |
| Model selection | `defaultModel` in `settings.json` | `--model ollama/<id>` (or last-used) |
| Skills | `~/.pi/agent/skills/` | `~/.config/maki/skills/` |
| Runtime | `nodejs_24` in systemPackages | not needed (Rust binary) |

## Detailed changes

### 1. `lib/sandbox-config.nix`

- Replace `piVersion = "0.84.2"` with `makiVersion = "<pinned tag>"`.
- Add maki-specific values: binary name, install dir, config dir.
- Keep all network values (`bridge`, `tap`, `subnet`, `hostIp`, `vmIp`,
  `ollamaIp`, `ollamaPort`, `dns`, workspace paths) unchanged.

### 2. `flake.nix` (VM module)

- `environment.systemPackages`: drop `nodejs_24` (no longer needed by the
  agent). Keep `git`, `curl`, `wget`, `vim`, `bind`.
- `environment.extraInit`: add the maki binary dir to `PATH` instead of
  `/root/.npm-global/bin`.
- `environment.variables`: add `OLLAMA_HOST = "http://10.0.3.1:11434"`.
  Keep `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` as-is.
- `systemd.tmpfiles.rules`: replace the Pi symlinks with Maki config symlinks
  (see "Config" below).
- `users.motd`: update the welcome text and quick commands (`maki` instead of
  `pi`).

### 3. `flake.nix` (run script)

- Remove the `npm install` / `pi-version` / `pi` wrapper logic.
- Add Maki binary provisioning (see "Key decision: binary source" below).
- Seed Maki config from defaults (see "Config" below).
- Keep the `network-tools` skill sync (retargeted to Maki's skills dir).
- Rename the app from `pi` to `maki` (keep a `pi` alias during transition if
  desired).

### 4. Config (`host/pi-defaults/` → `host/maki-defaults/`)

Replace the three Pi default files with Maki equivalents:

- `maki-version` — pinned release tag (e.g. `v0.4.11`).
- `config.toml` — Maki main config (mostly defaults; can be empty/minimal).
- `providers.toml` — optional; only needed if we want to override the Ollama
  base URL in config rather than via `OLLAMA_HOST`.
- `AGENTS.md` — optional global preferences (empty placeholder).

The Ollama provider is driven by `OLLAMA_HOST=http://10.0.3.1:11434` (set in
the VM environment). The model is selected with `maki --model ollama/<id>`
(e.g. `ollama/deepseek-v4-pro:cloud`), or left to Maki's "last used model"
default.

### 5. Skills (`skills/network-tools/`)

The `SKILL.md` format is compatible (Maki reads `SKILL.md` with optional
`name`/`description` frontmatter). Changes:

- Retarget the install path to `~/.config/maki/skills/network-tools`.
- Update references from `pi-sandbox` → `agent-sandbox` (the whitelist CLI
  name) and any `pi`-specific paths.

### 6. Whitelist CLI (`host/pi-sandbox-whitelist`)

The script itself is agent-agnostic (it just edits
`/etc/pi-sandbox/whitelist.conf`). No functional change required. Renaming it
to `agent-sandbox-whitelist` is part of the later repo rename, not this branch.

### 7. `README.md` and `.gitignore`

- Update the README: Maki instead of Pi, new quick commands, new config paths.
- Update `.gitignore` workspace entries (`pi-npm/` → `maki/`, `pi-config/` →
  `maki-config/`).

## Key decisions (need your input)

### A. Binary source

- **Option 1 — pre-built binary (recommended).** Download the release asset
  from GitHub Releases (`maki-<tag>-x86_64-unknown-linux-musl.tar.gz`), the
  same way `install.sh` does. Fast, no toolchain. Requires the *host* to reach
  `github.com` + `objects.githubusercontent.com` (the host has full network;
  the VM does not).
- **Option 2 — build from source.** `cargo install --git …`. Needs the Rust
  toolchain and is slow on a 1-CPU box (one-time cost).

### B. Install location (important for the speed goal)

The whole point is to avoid the 9p penalty. A single binary is *much* better
than 13k files, but reading a ~20 MB binary off 9p is still slow (~0.3 MB/s →
tens of seconds). So the binary should live on the **VM's local disk**, not
`/mnt/shared`.

- **Option 1 (recommended):** host downloads the binary into the workspace,
  and the VM copies it to `/root/.local/bin` at boot (a `systemd` oneshot or
  `tmpfiles` rule). Keeps the existing "host provisions, VM consumes" pattern.
- **Option 2:** bake the binary into the VM image via `pkgs.fetchurl` at Nix
  build time. Cleanest runtime, but pins the URL at build time and requires
  network at build time.

### C. Naming scope

- **This branch:** swap the agent (`pi` → `maki`) and its user-facing config
  paths. Leave the network infra names (`br-pi`, `pi-tap`,
  `services.pi-sandbox`, `pi-sandbox-whitelist`) untouched to minimize churn.
- **Later (separate branch):** full rename to `agent-sandbox` (repo, module,
  bridge/TAP, whitelist CLI, docs).

## Migration steps (proposed order)

1. Add `makiVersion` and Maki defaults (`host/maki-defaults/`).
2. Rework the `flake.nix` run script: drop npm, add binary provisioning +
   config seeding + skill sync.
3. Rework the VM module: packages, env vars, tmpfiles symlinks, MOTD.
4. Retarget `skills/network-tools/`.
5. Update `README.md` and `.gitignore`.
6. Test: `nix run .#maki`, confirm `maki` starts instantly and reaches Ollama.
7. (Later) full `agent-sandbox` rename.

## Risks / open questions

- **Model mapping.** Pi's `models.json` lists several Ollama models with large
  context windows. Maki selects a model via `--model ollama/<id>`; we need to
  confirm the exact model spec format and whether context-window hints carry
  over (they may not be needed).
- **Whitelist for Maki's own network calls.** Maki's `webfetch`/provider calls
  go through the same `HTTP_PROXY`/`HTTPS_PROXY`, so the existing whitelist
  still applies. No change expected, but worth a smoke test.
- **Maturity.** Maki is young (its README notes >90% of its code was written by
  Maki). This is a feature/UX tradeoff, not a sandbox-architecture one.
- **`pi` alias.** Decide whether to keep a `pi` alias during transition or cut
  over cleanly.
