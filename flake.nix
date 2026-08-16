{
  description = "Pi sandbox: VM with host-kernel network isolation and a shared workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      # --- Host-side sandbox network layout ---
      sandbox = {
        bridge = "br-pi";
        tap = "pi-tap";
        subnet = "10.0.3.0/24";
        hostIp = "10.0.3.1";
        vmIp = "10.0.3.2";
        ollamaIp = "10.0.3.1";
        ollamaPort = 11434;
        dns = [ "9.9.9.9" "1.1.1.1" ];
      };

      # Relative host path that is shared with the VM.  The run scripts must be
      # invoked from the repository root so QEMU resolves this path correctly.
      workspaceHostPath = "workspace";
      workspaceVmMountPoint = "/mnt/shared";

      # NixOS module describing the VM.
      vmModule = { config, pkgs, ... }: {
        system.stateVersion = "24.05";

        services.getty.autologinUser = "root";

        virtualisation.vmVariant = {
          # Console only.
          virtualisation.graphics = false;

          # Attach the VM to the host TAP interface instead of user-mode
          # networking.  Real filtering happens on the host with nftables.
          virtualisation.qemu.networkingOptions = [
            "-netdev tap,id=net0,ifname=${sandbox.tap},script=no,downscript=no"
            "-device virtio-net-pci,netdev=net0"
          ];

          # Share the workspace directory via virtio-9p.
          virtualisation.fileSystems = [{
            mount_tag = "workspace";
            mount_type = "9p";
            source = workspaceHostPath;
          }];
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

        # Mount the workspace share inside the VM.
        fileSystems."${workspaceVmMountPoint}" = {
          fsType = "9p";
          device = "workspace";
          options = [ "trans=virtio" "version=9p2000.L" "msize=1048576" "rw" ];
        };

        # No VM-internal firewall.  Enforcement is on the host.
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
          export PATH="$PATH:/root/.npm-global/bin"
        '';

        environment.variables = {
          NPM_CONFIG_PREFIX = "/root/.npm-global";
          EDITOR = "vim";
          VISUAL = "vim";
        };

        # Symlink Pi runtime config and the pre-installed package tree from the
        # shared workspace.  These paths are populated on the host before the VM
        # starts.
        systemd.tmpfiles.rules = [
          "d /root/.pi/agent 0755 root root -"
          "L+ /root/.pi/agent/models.json - - - - ${workspaceVmMountPoint}/pi-config/models.json"
          "L+ /root/.pi/agent/settings.json - - - - ${workspaceVmMountPoint}/pi-config/settings.json"
          "L+ /root/.pi/agent/skills/network-tools - - - - ${workspaceVmMountPoint}/pi-config/skills/network-tools"
          "L+ /root/.npm-global - - - - ${workspaceVmMountPoint}/pi-npm"
        ];

        users.motd = ''
          ╔═══════════════════════════════════════════════════════════╗
          ║         Welcome to the Pi Sandbox!                      ║
          ╠═══════════════════════════════════════════════════════════╣
          ║                                                           ║
          ║  NETWORK MODE: ${lib.toUpper "whitelisted"}                                   ║
          ║  • DNS + Ollama host access only                          ║
          ║  • General HTTP/HTTPS is blocked by host firewall         ║
          ║                                                           ║
          ║  Shared workspace: ${workspaceVmMountPoint}                            ║
          ║  Maps to host:     ./${workspaceHostPath}/                                    ║
          ║                                                           ║
          ║  Quick commands:                                          ║
          ║    pi                         # Start Pi agent            ║
          ║    curl -v https://example.com  # Should be blocked      ║
          ║    dig example.com            # Test DNS                  ║
          ║    curl http://${sandbox.ollamaIp}:${toString sandbox.ollamaPort}/ # Ollama  ║
          ╚═══════════════════════════════════════════════════════════╝
        '';
      };

      vm = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ vmModule ];
      };

      builtVm = vm.config.system.build.vm;

      nftablesRules = pkgs.writeText "pi-sandbox.nft" ''
        #!/usr/sbin/nft -f

        # Host-side firewall for the Pi sandbox VM.
        # Drop everything from the sandbox bridge except what is explicitly allowed.

        flush ruleset

        table inet pi-sandbox {
          # Allowed DNS resolvers.
          set dns_resolvers {
            type ipv4_addr
            flags interval
            elements = { ${lib.concatStringsSep ", " sandbox.dns} }
          }

          chain input {
            type filter hook input priority 0; policy drop;

            # Loopback is always fine.
            iif "lo" accept

            # Established/related connections.
            ct state established,related accept

            # The host can always receive ICMP from the sandbox (useful for
            # basic diagnostics).
            iifname "${sandbox.bridge}" ip protocol icmp accept

            # DNS from the sandbox to the host itself (if we ever run a local
            # resolver).  Not used in the first milestone, but harmless.
            iifname "${sandbox.bridge}" ip daddr @dns_resolvers udp dport 53 accept
            iifname "${sandbox.bridge}" ip daddr @dns_resolvers tcp dport 53 accept

            # Ollama on the host.  Ollama must be listening on ${sandbox.ollamaIp}
            # or on 0.0.0.0 for this to work.
            iifname "${sandbox.bridge}" ip daddr ${sandbox.ollamaIp} tcp dport ${toString sandbox.ollamaPort} accept

            # Placeholder for the future mitmproxy whitelist proxy.
            # iifname "${sandbox.bridge}" ip daddr ${sandbox.hostIp} tcp dport 8080 accept
          }

          chain forward {
            type filter hook forward priority 0; policy drop;

            # Established/related.
            ct state established,related accept

            # DNS to external resolvers.
            iifname "${sandbox.bridge}" oifname != "${sandbox.bridge}" ip daddr @dns_resolvers udp dport 53 accept
            iifname "${sandbox.bridge}" oifname != "${sandbox.bridge}" ip daddr @dns_resolvers tcp dport 53 accept

            # Future: allow HTTP/HTTPS only via the host mitmproxy.  For now,
            # direct HTTP/HTTPS from the sandbox is blocked.
            # iifname "${sandbox.bridge}" oifname != "${sandbox.bridge}" ip daddr ${sandbox.hostIp} tcp dport 8080 accept
          }

          chain postrouting {
            type nat hook postrouting priority 100; policy accept;

            # Masquerade allowed outbound traffic so external DNS answers come
            # back to the host and can be forwarded to the VM.
            oifname != "${sandbox.bridge}" masquerade
          }
        }
      '';

      setupScript = pkgs.writeShellScriptBin "pi-sandbox-setup" ''
        set -euo pipefail

        # This script must run as root.
        if [ "$EUID" -ne 0 ]; then
          echo "Error: pi-sandbox-setup must run as root (use sudo)." >&2
          exit 1
        fi

        RUN_USER="''${SUDO_USER:-$USER}"
        if [ "$RUN_USER" = "root" ]; then
          echo "Warning: could not detect a non-root user via SUDO_USER; the TAP" >&2
          echo "interface will be owned by root, so only root can start the VM." >&2
        fi

        echo "Setting up Pi sandbox host networking..."
        echo "  Bridge: ${sandbox.bridge} (${sandbox.hostIp}/24)"
        echo "  TAP:    ${sandbox.tap} (user: $RUN_USER)"

        # Create bridge if missing.
        if ! ip link show "${sandbox.bridge}" >/dev/null 2>&1; then
          echo "  Creating bridge ${sandbox.bridge}..."
          ip link add name "${sandbox.bridge}" type bridge
        fi

        # Assign host IP to the bridge and bring it up.
        if ! ip addr show "${sandbox.bridge}" | grep -q "${sandbox.hostIp}/24"; then
          echo "  Assigning ${sandbox.hostIp}/24 to ${sandbox.bridge}..."
          ip addr add "${sandbox.hostIp}/24" dev "${sandbox.bridge}"
        fi
        ip link set "${sandbox.bridge}" up

        # Create TAP if missing.
        if ! ip link show "${sandbox.tap}" >/dev/null 2>&1; then
          echo "  Creating TAP ${sandbox.tap}..."
          ip tuntap add dev "${sandbox.tap}" mode tap user "$RUN_USER"
        fi
        ip link set "${sandbox.tap}" up

        # Attach TAP to bridge.
        if ! ip link show "${sandbox.tap}" | grep -q "master ${sandbox.bridge}"; then
          echo "  Attaching ${sandbox.tap} to ${sandbox.bridge}..."
          ip link set "${sandbox.tap}" master "${sandbox.bridge}"
        fi

        # Disable STP to avoid startup delay.
        ip link set "${sandbox.bridge}" type bridge stp_state 0 && true

        # Enable IPv4 forwarding.
        sysctl -w net.ipv4.ip_forward=1 >/dev/null

        # Load nftables rules.
        echo "  Loading nftables rules..."
        ${pkgs.nftables}/bin/nft -f "${nftablesRules}"

        echo ""
        echo "✅ Pi sandbox host networking is ready."
        echo ""
        echo "Next, start Ollama bound to 0.0.0.0:${toString sandbox.ollamaPort} so the VM can reach it at"
        echo "${sandbox.ollamaIp}:${toString sandbox.ollamaPort}, then run:"
        echo ""
        echo "  nix run .#pi"
        echo ""
      '';

      runScript = pkgs.writeShellScriptBin "pi" ''
        set -euo pipefail

        REPO_ROOT=$(pwd)
        if [ ! -f "$REPO_ROOT/flake.nix" ]; then
          echo "Error: must be run from the pi-sandbox repository root" >&2
          exit 1
        fi

        # Check that host networking has been set up.
        if ! ip link show "${sandbox.bridge}" >/dev/null 2>&1 || \
           ! ip link show "${sandbox.tap}" >/dev/null 2>&1; then
          echo "Error: Pi sandbox host networking is not set up." >&2
          echo "Run as root: nix run .#setup" >&2
          exit 1
        fi

        # Ensure Node.js, npm and Python are available regardless of host PATH.
        export PATH="${pkgs.nodejs}/bin:${pkgs.python3}/bin:$PATH"

        # Prepare the workspace.
        mkdir -p "$REPO_ROOT/workspace/pi-config/skills"
        mkdir -p "$REPO_ROOT/workspace/pi-npm"

        # Seed Pi agent configuration from defaults if missing.
        for f in pi-version models.json settings.json; do
          if [ ! -f "$REPO_ROOT/workspace/pi-config/$f" ] && [ -f "$REPO_ROOT/host/pi-defaults/$f" ]; then
            cp "$REPO_ROOT/host/pi-defaults/$f" "$REPO_ROOT/workspace/pi-config/$f"
          fi
        done

        # Keep the network-tools skill in sync with the repo copy.
        rm -rf "$REPO_ROOT/workspace/pi-config/skills/network-tools"
        cp -r "$REPO_ROOT/skills/network-tools" "$REPO_ROOT/workspace/pi-config/skills/network-tools"

        # Install or update the pinned Pi version on the host.
        PI_VERSION=$(cat "$REPO_ROOT/workspace/pi-config/pi-version" 2>/dev/null || echo "0.84.2")
        INSTALLED_VERSION=""
        if [ -f "$REPO_ROOT/workspace/pi-npm/lib/node_modules/@earendil-works/pi-coding-agent/package.json" ]; then
          INSTALLED_VERSION=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' \
            < "$REPO_ROOT/workspace/pi-npm/lib/node_modules/@earendil-works/pi-coding-agent/package.json")
        fi
        if [ "$INSTALLED_VERSION" != "$PI_VERSION" ]; then
          echo "📦 Installing Pi $PI_VERSION into ./workspace/pi-npm..."
          npm install --ignore-scripts --prefix "$REPO_ROOT/workspace/pi-npm" \
            "@earendil-works/pi-coding-agent@$PI_VERSION"
        else
          echo "✅ Pi $PI_VERSION already installed in ./workspace/pi-npm"
        fi

        echo ""
        echo "Starting Pi sandbox VM..."
        echo "  Workspace host path: $REPO_ROOT/workspace"
        echo "  Workspace VM mount:  ${workspaceVmMountPoint}"
        echo "  VM IP:               ${sandbox.vmIp}"
        echo "  Gateway/Ollama:      ${sandbox.hostIp}:${toString sandbox.ollamaPort}"
        echo "  DNS:                 ${lib.concatStringsSep ", " sandbox.dns}"
        echo ""

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
        setup = {
          type = "app";
          program = "${setupScript}/bin/pi-sandbox-setup";
        };
      };

      devShells.${system}.default = pkgs.mkShell {
        name = "pi-sandbox";
        buildInputs = with pkgs; [
          nixpkgs-fmt
          nil
          nodejs
          python3
          nftables
          iproute2
        ];
        shellHook = ''
          echo "Pi Sandbox development shell"
          echo ""
          echo "  nix run .#setup  - Set up host networking (run once as root)"
          echo "  nix run .#pi     - Start the sandboxed VM and run Pi"
          echo ""
        '';
      };
    };
}
