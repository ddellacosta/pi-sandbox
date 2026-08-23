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

      # Maki coding agent: pre-built static binary fetched from GitHub Releases.
      maki = pkgs.stdenv.mkDerivation {
        pname = "maki";
        version = sandbox.makiVersion;
        src = pkgs.fetchurl {
          url = "https://github.com/tontinton/maki/releases/download/v${sandbox.makiVersion}/maki-v${sandbox.makiVersion}-x86_64-unknown-linux-musl.tar.gz";
          hash = "sha256-lvi4zcMETR1rc5932o5bUkBJPpxSX0pXVKihNcdbGCw=";
        };
        sourceRoot = ".";
        installPhase = ''
          install -Dm755 maki $out/bin/maki
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

        environment.systemPackages = with pkgs; [
          maki
          git
          curl
          wget
          vim
          bind
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
        systemd.tmpfiles.rules = [
          "d ${sandbox.makiConfigDir} 0755 root root -"
          "L+ ${sandbox.makiConfigDir}/config.toml - - - - ${sandbox.workspaceVmMountPoint}/maki-config/config.toml"
          "L+ ${sandbox.makiConfigDir}/providers.toml - - - - ${sandbox.workspaceVmMountPoint}/maki-config/providers.toml"
          "L+ ${sandbox.makiConfigDir}/AGENTS.md - - - - ${sandbox.workspaceVmMountPoint}/maki-config/AGENTS.md"
          "L+ ${sandbox.makiConfigDir}/skills/network-tools - - - - ${sandbox.workspaceVmMountPoint}/maki-config/skills/network-tools"
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

        export MAKI_SANDBOX_WORKSPACE="$REPO_ROOT/${sandbox.workspaceHostPath}"

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
      };

      nixosModules.default = import ./nixos-module.nix;

      devShells.${system}.default = pkgs.mkShell {
        name = "maki-sandbox";
        buildInputs = with pkgs; [
          nixpkgs-fmt
          nil
          nftables
          iproute2
          mitmproxy
        ];
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
        '';
      };
    };
}
