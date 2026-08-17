{
  description = "Pi sandbox: NixOS VM with host-kernel network isolation and a shared workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;
      sandbox = import ./lib/sandbox-config.nix;

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
              source = "$PI_SANDBOX_WORKSPACE";
              target = sandbox.workspaceVmMountPoint;
              securityModel = "passthrough";
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
          nodejs_24
          git
          curl
          wget
          vim
          bind
        ];

        environment.extraInit = ''
          export PATH="$PATH:/root/.npm-global/bin:/root/.npm-global/lib/node_modules/.bin"
        '';

        environment.variables = {
          NPM_CONFIG_PREFIX = "/root/.npm-global";
          EDITOR = "vim";
          VISUAL = "vim";
          # Route all HTTP/HTTPS through the host whitelist proxy. Direct
          # outbound TCP 80/443 is still dropped by the host firewall, so a
          # process that ignores these variables cannot bypass the proxy.
          HTTP_PROXY = "http://${sandbox.hostIp}:8080";
          HTTPS_PROXY = "http://${sandbox.hostIp}:8080";
          NO_PROXY = "localhost,127.0.0.1,${sandbox.hostIp}";
        };

        # Symlink Pi runtime config and the pre-installed package tree from the
        # shared workspace. These paths are populated on the host before the VM
        # starts.
        systemd.tmpfiles.rules = [
          "d /root/.pi/agent 0755 root root -"
          "L+ /root/.pi/agent/models.json - - - - ${sandbox.workspaceVmMountPoint}/pi-config/models.json"
          "L+ /root/.pi/agent/settings.json - - - - ${sandbox.workspaceVmMountPoint}/pi-config/settings.json"
          "L+ /root/.pi/agent/skills/network-tools - - - - ${sandbox.workspaceVmMountPoint}/pi-config/skills/network-tools"
          "L+ /root/.npm-global - - - - ${sandbox.workspaceVmMountPoint}/pi-npm"
        ];

        users.motd = ''
          ╔═══════════════════════════════════════════════════════════╗
          ║         Welcome to the Pi Sandbox!                      ║
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
          ║    pi                         # Start Pi agent            ║
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

      runScript = pkgs.writeShellScriptBin "pi" ''
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

        # Ensure Node.js, npm and Python are available regardless of host PATH.
        export PATH="${pkgs.nodejs}/bin:${pkgs.python3}/bin:$PATH"

        # Prepare the workspace.
        mkdir -p "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-config/skills"
        mkdir -p "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm"

        # Seed Pi agent configuration from defaults if missing.
        for f in pi-version models.json settings.json; do
          if [ ! -f "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-config/$f" ] && [ -f "$REPO_ROOT/host/pi-defaults/$f" ]; then
            cp "$REPO_ROOT/host/pi-defaults/$f" "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-config/$f"
          fi
        done

        # Keep the network-tools skill in sync with the repo copy.
        rm -rf "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-config/skills/network-tools"
        cp -r "$REPO_ROOT/skills/network-tools" "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-config/skills/network-tools"

        # Install or update the pinned Pi version on the host.
        PI_VERSION=$(cat "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-config/pi-version" 2>/dev/null || echo "${sandbox.piVersion}")
        INSTALLED_VERSION=""
        for candidate in \
          "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm/lib/node_modules/@earendil-works/pi-coding-agent/package.json" \
          "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm/node_modules/@earendil-works/pi-coding-agent/package.json"; do
          if [ -f "$candidate" ]; then
            INSTALLED_VERSION=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' < "$candidate")
            break
          fi
        done
        if [ "$INSTALLED_VERSION" != "$PI_VERSION" ]; then
          echo "📦 Installing Pi $PI_VERSION into ./${sandbox.workspaceHostPath}/pi-npm..."
          npm install --ignore-scripts --prefix "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm" \
            "@earendil-works/pi-coding-agent@$PI_VERSION"
        else
          echo "✅ Pi $PI_VERSION already installed in ./${sandbox.workspaceHostPath}/pi-npm"
        fi

        # Find the installed Pi package regardless of whether npm used
        # lib/node_modules or node_modules under the prefix.
        PI_BIN="$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm/bin"
        PI_PKG=""
        for candidate in \
          "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm/lib/node_modules/@earendil-works/pi-coding-agent" \
          "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm/node_modules/@earendil-works/pi-coding-agent"; do
          if [ -f "$candidate/package.json" ]; then
            PI_PKG="$candidate"
            break
          fi
        done

        if [ -z "$PI_PKG" ]; then
          echo "❌ Could not find installed @earendil-works/pi-coding-agent package" >&2
          echo "   Looked under ./${sandbox.workspaceHostPath}/pi-npm/lib/node_modules and ./node_modules" >&2
          exit 1
        fi

        PI_CLI="$PI_PKG/dist/cli.js"
        mkdir -p "$PI_BIN"
        if [ -f "$PI_CLI" ] && [ ! -e "$PI_BIN/pi" ]; then
          cat > "$PI_BIN/pi" <<EOF
#!/usr/bin/env bash
exec ${pkgs.nodejs}/bin/node "$PI_CLI" "\$@"
EOF
          chmod +x "$PI_BIN/pi"
          echo "   Created $PI_BIN/pi wrapper"
        fi

        echo ""
        echo "Starting Pi sandbox VM..."
        echo "  Workspace host path: $REPO_ROOT/${sandbox.workspaceHostPath}"
        echo "  Workspace VM mount:  ${sandbox.workspaceVmMountPoint}"
        echo "  VM IP:               ${sandbox.vmIp}"
        echo "  Gateway/Ollama:      ${sandbox.hostIp}:${toString sandbox.ollamaPort}"
        echo "  DNS:                 ${lib.concatStringsSep ", " sandbox.dns}"
        echo ""

        export PI_SANDBOX_WORKSPACE="$REPO_ROOT/${sandbox.workspaceHostPath}"

        cd "$REPO_ROOT"
        exec "${builtVm}/bin/run-nixos-vm" "$@"
      '';

    in {
      apps.${system} = {
        default = {
          type = "app";
          program = "${runScript}/bin/pi";
        };
        pi = {
          type = "app";
          program = "${runScript}/bin/pi";
        };
      };

      nixosModules.default = import ./nixos-module.nix;

      devShells.${system}.default = pkgs.mkShell {
        name = "pi-sandbox";
        buildInputs = with pkgs; [
          nixpkgs-fmt
          nil
          nodejs
          python3
          nftables
          iproute2
          mitmproxy
        ];
        shellHook = ''
          echo "Pi Sandbox development shell"
          echo ""
          echo "Host setup (import in NixOS configuration):"
          echo "  services.pi-sandbox.enable = true;"
          echo "  services.pi-sandbox.user = \"\$USER\";"
          echo ""
          echo "Run the sandbox:"
          echo "  nix run .#pi"
          echo ""
        '';
      };
    };
}
