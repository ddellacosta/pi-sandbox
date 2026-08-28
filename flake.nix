{
  description = "Maki sandbox: NixOS VM with host-kernel network isolation and a shared workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;
      sandbox = import ./lib/sandbox-config.nix;

      # Maki coding agent: built locally from /workspace/maki on the host.
      #
      # `runScript` (below) builds the binary via `cargo build --release`
      # and exports `MAKI_MAKI_BIN` pointing at the resulting host path.
      # This `maki` derivation reads that env var at flake-eval time and
      # copies the binary into the Nix store, where it becomes available
      # to the VM via `environment.systemPackages = [ maki ]`.
      #
      # TIMING NOTE: `builtins.getEnv` reads at flake-eval time. The
      # `runScript` that sets `MAKI_MAKI_BIN` cannot run before eval -- it
      # *is* the eval. Therefore you must set `MAKI_MAKI_BIN` in your
      # shell *before* running `nix run .#maki`. The runScript below
      # does this by re-invoking `nix run` after building, breaking the
      # cycle. See `runWrapper` and `runVm` at the bottom of this file.
      #
      # To restore the upstream tarball flow, comment out the new `maki`
      # and uncomment the fetchurl block below.
      #maki = pkgs.stdenv.mkDerivation {
      #  pname = "maki";
      #  version = sandbox.makiVersion;
      #  src = pkgs.fetchurl {
      #    url = "https://github.com/tontinton/maki/releases/download/v${sandbox.makiVersion}/maki-v${sandbox.makiVersion}-x86_64-unknown-linux-musl.tar.gz";
      #    hash = "sha256-k2GcRBiDbm1M4/ipgL3frMxiAxkAMdqVSgYg9ggPTbg=";
      #  };
      #  sourceRoot = ".";
      #  installPhase = ''
      #    install -Dm755 maki $out/bin/maki
      #  '';
      #};
      maki = pkgs.stdenv.mkDerivation {
        pname = "maki";
        version = sandbox.makiVersion;
        src = builtins.getEnv "MAKI_MAKI_BIN";
        dontUnpack = true;
        installPhase = ''
          install -Dm755 $src $out/bin/maki
        '';
      };

      # NixOS module describing the VM.
      vmModule = { config, pkgs, ... }: {
        system.stateVersion = "24.05";

        services.getty.autologinUser = "root";

        virtualisation.vmVariant = {
          # Console only.
          virtualisation.graphics = false;

          # Replace the default QEMU user-mode networking with a TAP interface
          # connected to the host bridge. Real filtering happens on the host.
          virtualisation.qemu.networkingOptions = lib.mkForce [
            "-netdev tap,id=net0,ifname=${sandbox.tap},script=no,downscript=no"
            "-device virtio-net-pci,netdev=net0"
          ];

          # Share the workspace directory via virtio-9p. The source path is a
          # shell variable that the run script exports before launching the VM,
          # so it works regardless of the repository location.
          virtualisation.sharedDirectories = {
            workspace = {
              source = "$MAKI_SANDBOX_WORKSPACE";
              target = sandbox.workspaceVmMountPoint;
              securityModel = "mapped-xattr";
            };
          };
        };

        # Static network configuration inside the VM.
        networking.useDHCP = false;
        networking.enableIPv6 = false;
        networking.defaultGateway = sandbox.hostIp;
        networking.nameservers = sandbox.dns;
        networking.interfaces.eth0.ipv4.addresses = [{
          address = sandbox.vmIp;
          prefixLength = 24;
        }];

        # No VM-internal firewall. Enforcement is on the host.
        networking.firewall.enable = false;
        networking.nftables.enable = false;

        # SSH server: lets the host terminal resize events reach the guest.
        #
        # QEMU's `-nographic` serial console doesn't propagate `TIOCSWINSZ`
        # ioctls from the host PTY into the guest, which means TUI apps like
        # maki inside the VM never see host-side window resizes. SSH allocates
        # a real PTY on both sides and translates SIGWINCH/TIOCSWINSZ correctly,
        # so running maki over SSH gives a properly-responsive TUI.
        #
        # Auth model: root:root, password auth. This is a single-user dev
        # sandbox behind a host firewall; anything on the bridge subnet can
        # already reach the VM directly. Don't expose port 22 outside the
        # bridge.
        services.openssh = {
          enable = true;
          settings = {
            PermitRootLogin = "yes";
            PasswordAuthentication = true;
          };
        };
        users.users.root.password = "root";

        environment.systemPackages = with pkgs; [
          maki
          git
          curl
          wget
          vim
          bind
          chafa
          tesseract
          imagemagick
          python314
          python314Packages.pillow
        ];

        environment.variables = {
          EDITOR = "vim";
          VISUAL = "vim";
          OLLAMA_HOST = "http://${sandbox.ollamaIp}:${toString sandbox.ollamaPort}";
          # Route all HTTP/HTTPS through the host whitelist proxy. Direct
          # outbound TCP 80/443 is still dropped by the host firewall, so a
          # process that ignores these variables cannot bypass the proxy.
          HTTP_PROXY = "http://${sandbox.hostIp}:8080";
          HTTPS_PROXY = "http://${sandbox.hostIp}:8080";
          NO_PROXY = "localhost,127.0.0.1,${sandbox.hostIp}";
        };

        # Symlink Maki config from the shared workspace. These paths are
        # populated on the host before the VM starts.
        #
        # Maki reads configuration from the first of ~/.maki or ~/.config/maki
        # that exists, preferring the legacy ~/.maki. We collapse the two by
        # making ~/.maki a symlink to ~/.config/maki and symlinking each
        # config file from there into the workspace share. Runtime state
        # (maki.log, sessions/, input_history.json) then lives in
        # ~/.config/maki on the VM's root fs, keeping 9p out of the hot path.
        systemd.tmpfiles.rules = [
          "d ${sandbox.makiConfigDir} 0755 root root -"
          "L+ ${sandbox.makiConfigDir}/config.toml - - - - ${sandbox.workspaceVmMountPoint}/maki-config/config.toml"
          "L+ ${sandbox.makiConfigDir}/providers.toml - - - - ${sandbox.workspaceVmMountPoint}/maki-config/providers.toml"
          "L+ ${sandbox.makiConfigDir}/AGENTS.md - - - - ${sandbox.workspaceVmMountPoint}/maki-config/AGENTS.md"
          "L+ ${sandbox.makiConfigDir}/skills - - - - ${sandbox.workspaceVmMountPoint}/maki-config/skills"
          "L+ ${sandbox.makiLegacyDir} - - - - ${sandbox.makiConfigDir}"
        ];

        users.motd = ''
          ╔═══════════════════════════════════════════════════════════╗
          ║         Welcome to the Maki Sandbox!                    ║
          ╠═══════════════════════════════════════════════════════════╣
          ║                                                           ║
          ║  NETWORK MODE: WHITELISTED                                ║
          ║  • DNS resolvers: ${lib.concatStringsSep ", " sandbox.dns}                            ║
          ║  • Ollama host:   ${sandbox.ollamaIp}:${toString sandbox.ollamaPort}                             ║
          ║  • Whitelist proxy: ${sandbox.hostIp}:8080                             ║
          ║  • Direct TCP 80/443 to internet is blocked             ║
          ║                                                           ║
          ║  Shared workspace: ${sandbox.workspaceVmMountPoint}                            ║
          ║  Maps to host:     ./${sandbox.workspaceHostPath}/                                    ║
          ║                                                           ║
          ║  Quick commands:                                          ║
          ║    maki                       # Start Maki agent          ║
          ║    dig example.com            # Test DNS                  ║
          ║    curl http://${sandbox.ollamaIp}:${toString sandbox.ollamaPort}/ # Ollama  ║
          ║    curl -v https://example.com  # Blocked until whitelisted ║
          ╚═══════════════════════════════════════════════════════════╝
        '';
      };

      vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ vmModule ];
      };

      builtVm = vm.config.system.build.vm;

      sshScript = pkgs.writeShellScriptBin "maki-ssh" ''
        set -euo pipefail

        VM_PID_FILE=$(mktemp)

        cleanup() {
          if [ -f "$VM_PID_FILE" ]; then
            local pid
            pid=$(cat "$VM_PID_FILE" 2>/dev/null || true)
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
              kill "$pid" 2>/dev/null || true
              wait "$pid" 2>/dev/null || true
            fi
            rm -f "$VM_PID_FILE"
          fi
        }
        trap cleanup EXIT INT TERM

        # Start the VM in the background.
        "${runScript}/bin/maki" &
        echo $! > "$VM_PID_FILE"

        # Poll SSH until the VM has booted and the daemon is ready. Each
        # probe uses sshpass with a short timeout. After ~120s we give up.
        echo "Waiting for VM SSH at ${sandbox.vmIp}:22 (timeout 120s)..."
        for i in $(seq 1 120); do
          if ${pkgs.openssh}/bin/sshpass -p root ${pkgs.openssh}/bin/ssh \
              -o StrictHostKeyChecking=no \
              -o UserKnownHostsFile=/dev/null \
              -o ConnectTimeout=2 \
              -o NumberOfPasswordPrompts=1 \
              root@${sandbox.vmIp} true >/dev/null 2>&1; then
            echo "SSH reachable after ''${i}s."
            break
          fi
          if [ "$i" -eq 120 ]; then
            echo "Timed out waiting for SSH." >&2
            exit 1
          fi
          sleep 1
        done

        # Hand the terminal to SSH. -t allocates a TTY so resize events flow.
        exec ${pkgs.openssh}/bin/sshpass -p root ${pkgs.openssh}/bin/ssh \
          -o StrictHostKeyChecking=no \
          -o UserKnownHostsFile=/dev/null \
          -t root@${sandbox.vmIp}
      '';

      runScript = pkgs.writeShellScriptBin "maki" ''
        set -euo pipefail

        REPO_ROOT=$(pwd)
        if [ ! -f "$REPO_ROOT/flake.nix" ]; then
          echo "Error: must be run from the pi-sandbox repository root" >&2
          exit 1
        fi

        # Verify the host NixOS module has set up the bridge and TAP.
        if ! ip link show "${sandbox.bridge}" >/dev/null 2>&1; then
          echo "Error: bridge ${sandbox.bridge} not found." >&2
          echo "Enable the NixOS module in your host configuration:" >&2
          echo "  services.pi-sandbox.enable = true;" >&2
          echo "  services.pi-sandbox.user = \"\$USER\";" >&2
          exit 1
        fi
        if ! ip link show "${sandbox.tap}" >/dev/null 2>&1; then
          echo "Error: TAP ${sandbox.tap} not found. Run nixos-rebuild switch." >&2
          exit 1
        fi

        # Prepare the workspace.
        mkdir -p "$REPO_ROOT/${sandbox.workspaceHostPath}/maki-config/skills"

        # Build maki from the local source if not already built.
        if [ ! -x "$REPO_ROOT/${sandbox.workspaceHostPath}/maki/target/release/maki" ]; then
          echo "Building maki from source..."
          (cd "$REPO_ROOT/${sandbox.workspaceHostPath}/maki" && cargo build --release --locked)
        fi

        # Seed Maki configuration from defaults if missing.
        for f in config.toml providers.toml AGENTS.md; do
          if [ ! -f "$REPO_ROOT/${sandbox.workspaceHostPath}/maki-config/$f" ] && [ -f "$REPO_ROOT/host/maki-defaults/$f" ]; then
            cp "$REPO_ROOT/host/maki-defaults/$f" "$REPO_ROOT/${sandbox.workspaceHostPath}/maki-config/$f"
          fi
        done

        # Keep the network-tools skill in sync with the repo copy.
        rm -rf "$REPO_ROOT/${sandbox.workspaceHostPath}/maki-config/skills/network-tools"
        cp -r "$REPO_ROOT/skills/network-tools" "$REPO_ROOT/${sandbox.workspaceHostPath}/maki-config/skills/network-tools"

        echo ""
        echo "Starting Maki sandbox VM..."
        echo "  Workspace host path: $REPO_ROOT/${sandbox.workspaceHostPath}"
        echo "  Workspace VM mount:  ${sandbox.workspaceVmMountPoint}"
        echo "  VM IP:               ${sandbox.vmIp}"
        echo "  Gateway/Ollama:      ${sandbox.hostIp}:${toString sandbox.ollamaPort}"
        echo "  DNS:                 ${lib.concatStringsSep ", " sandbox.dns}"
        echo ""
        echo "  SSH into the VM with:  ssh root@${sandbox.vmIp}  (password: root)"
        echo "  (Maki TUI requires SSH for proper terminal resize handling.)"
        echo ""

        export MAKI_SANDBOX_WORKSPACE="$REPO_ROOT/${sandbox.workspaceHostPath}"
        export MAKI_MAKI_BIN="$REPO_ROOT/${sandbox.workspaceHostPath}/maki/target/release/maki"
        export MAKI_SANDBOX_VM_IP="${sandbox.vmIp}"
        export MAKI_SANDBOX_VM_USER="root"

        cd "$REPO_ROOT"
        exec "${builtVm}/bin/run-nixos-vm" "$@"
      '';

    in {
      apps.${system} = {
        default = {
          type = "app";
          program = "${runScript}/bin/maki";
        };
        maki = {
          type = "app";
          program = "${runScript}/bin/maki";
        };
        ssh = {
          type = "app";
          program = "${sshScript}/bin/maki-ssh";
        };
      };

      # Host-side developer shell. Used for two things:
      #   1. Maintaining the flake itself (nixpkgs-fmt, nil, networking tools,
      #      the MITM proxy used to build the whitelist).
      #   2. Building maki from /mnt/shared/maki (rust toolchain + C deps).
      # nixpkgs-unstable currently ships rustc 1.97.1 / cargo 1.97.0, which
      # comfortably exceeds maki's MSRV of 1.88, so no rust-toolchain pin.
      devShells.${system}.default = pkgs.mkShell {
        name = "maki-sandbox";
        packages = with pkgs; [
          nixpkgs-fmt
          nil
          nftables
          iproute2
          mitmproxy
          # maki build toolchain:
          rustc          # 1.97.1
          cargo          # 1.97.0 (bundled with rustc on nixpkgs-unstable)
          pkg-config     # openssl discovery for isahc / rustls
          openssl        # link target for the http + tls stacks
          git            # cargo needs it for `git = "..."` deps (e.g. crossterm)
        ];

        # Make openssl's .so files visible to cargo's build-script probe and
        # to anything linking against libssl/libcrypto at runtime.
        env = {
          LD_LIBRARY_PATH = lib.makeLibraryPath [ pkgs.openssl ];
        };

        shellHook = ''
          echo "Maki Sandbox development shell"
          echo ""
          echo "Host setup (import in NixOS configuration):"
          echo "  services.pi-sandbox.enable = true;"
          echo "  services.pi-sandbox.user = \"\$USER\";"
          echo ""
          echo "Run the sandbox:"
          echo "  nix run .#maki"
          echo ""
          echo "Build maki from source:"
          echo "  cd /mnt/shared/maki"
          echo "  cargo check --workspace"
          echo "  cargo test  -p maki-ui --lib"
          echo "  cargo run   --bin maki"
          echo ""
        '';
      };
    };
}
