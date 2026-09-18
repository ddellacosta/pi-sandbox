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

          virtualisation.memorySize = sandbox.vmMemoryMb;
          virtualisation.cores = sandbox.vmCores;
          virtualisation.diskSize = sandbox.vmDiskSizeMb;

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
          bind
          curl
          fd
          git
          nodejs_24
          ripgrep
          vim
          wget
        ];

        environment.extraInit = ''
          export PATH="$PATH:/root/.npm-global/bin:/root/.npm-global/lib/node_modules/.bin"
        '';

        environment.variables = {
          NPM_CONFIG_PREFIX = "/root/.npm-global";
          EDITOR = "vim";
          VISUAL = "vim";
          TERM_PROGRAM = "kitty"; # pretty pics
          # Route all HTTP/HTTPS through the host whitelist proxy. Direct
          # outbound TCP 80/443 is still dropped by the host firewall, so a
          # process that ignores these variables cannot bypass the proxy.
          HTTP_PROXY = "http://${sandbox.hostIp}:8080";
          HTTPS_PROXY = "http://${sandbox.hostIp}:8080";
          NO_PROXY = "localhost,127.0.0.1,${sandbox.hostIp}";
          NODE_COMPILE_CACHE = "/root/.pi-compile-cache";
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

        # Pi's package tree (13k+ files) otherwise lives on the 9p share, where
        # a single stat costs ~0.8 ms; Node touches essentially all of it at
        # startup, so that walk dominates launch time. Stream ONE archive over
        # 9p and extract it to local disk instead. The stamp comparison makes
        # this a no-op on every boot after the first, and re-runs exactly once
        # after a Pi version bump.
        systemd.services.pi-npm-local = {
          description = "Materialize the Pi package on the VM's local disk";
          wantedBy = [ "multi-user.target" ];
          before = [ "getty.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = pkgs.writeShellScript "pi-npm-local" ''
              set -eu
              src=${sandbox.workspaceVmMountPoint}
              dst=/var/lib/pi-npm
              tmp="$dst.new"
              want="$(cat "$src/pi-npm.stamp" 2>/dev/null || echo missing)"
              have="$(cat "$dst/.stamp" 2>/dev/null || echo none)"
              if [ "$want" = "missing" ]; then
                echo "pi-npm.stamp absent from $src; keeping existing $dst" >&2
                exit 0
              fi
              if [ "$want" != "$have" ] && [ -f "$src/pi-npm.tar" ]; then
                echo "Materializing Pi package on local disk (stamp $want)..."
                # tar is not on the systemd service PATH; the system profile is
                # not included, so always use the store path. Extract to a scratch
                # dir first so a failed/partial extract can never leave $dst
                # half-populated with no pi in it.
                rm -rf "$tmp"
                mkdir -p "$tmp"
                ${pkgs.gnutar}/bin/tar -xf "$src/pi-npm.tar" -C "$tmp"
                printf '%s\n' "$want" > "$tmp/.stamp"
                rm -rf "$dst"
                mv "$tmp" "$dst"
              fi
            '';
          };
        };

        # MOTD box. The border and padding are computed, not hand-drawn: the
        # box widens to fit the longest line, so interpolated config values
        # (IPs, ports, paths) can never push the right border out of alignment.
        users.motd =
          let
            sp = n: builtins.concatStringsSep "" (builtins.genList (_: " ") n);
            bar = n: builtins.concatStringsSep "" (builtins.genList (_: "═") n);
            half = n: n / 2; # integer division, tested

            # Nix string primitives count bytes, not terminal columns: the
            # • bullet is 3 bytes but renders 1 column wide. Compensate so the
            # border stays aligned on bullet lines.
            colWidth = l:
              builtins.stringLength l
              - 2 * ((builtins.length (builtins.split "•" l) - 1) / 2);

            title = "Welcome to the Pi Sandbox!";
            commands = [
              [ "pi" "# Start Pi agent" ]
              [ "dig example.com" "# Test DNS" ]
              [ "curl http://${sandbox.ollamaIp}:${toString sandbox.ollamaPort}/" "# Ollama" ]
              [ "curl -v https://example.com" "# Blocked until whitelisted" ]
            ];
            cmdWidth = builtins.foldl'
              (w: c:
                if builtins.stringLength (builtins.elemAt c 0) > w
                then builtins.stringLength (builtins.elemAt c 0) else w)
              0 commands;
            cmdRow = c:
              "    ${builtins.elemAt c 0}${sp (cmdWidth - builtins.stringLength (builtins.elemAt c 0))}  ${builtins.elemAt c 1}";
            content = [
              ""
              "  NETWORK MODE: WHITELISTED"
              "  • DNS resolvers: ${builtins.concatStringsSep ", " sandbox.dns}"
              "  • Ollama host: ${sandbox.ollamaIp}:${toString sandbox.ollamaPort}"
              "  • Whitelist proxy: ${sandbox.hostIp}:8080"
              "  • Direct TCP 80/443 to internet is blocked"
              ""
              "  Shared workspace: ${sandbox.workspaceVmMountPoint}"
              "  Maps to host: ./${sandbox.workspaceHostPath}/"
              ""
              "  Quick commands:"
            ] ++ map cmdRow commands;
            width = builtins.foldl'
              (w: l: if colWidth l > w then colWidth l else w)
              (colWidth title) content;
            gap = width - colWidth title;
            row = l: "║ ${l}${sp (width - colWidth l)} ║";
          in
            builtins.concatStringsSep "\n" ([
              "╔${bar (width + 2)}╗"
              "║ ${sp (half gap)}${title}${sp (gap - half gap)} ║"
              "╠${bar (width + 2)}╣"
            ] ++ map row content ++ [
              "╚${bar (width + 2)}╝"
            ]);
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

        # Keep pi extensions in sync with the repo copy. Every .ts file in
        # the repo-root extensions/ directory is copied into the shared
        # pi-config, which settings.json references by absolute path.
        mkdir -p "$REPO_ROOT/extensions" "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-config/extensions"
        for ext in "$REPO_ROOT"/extensions/*.ts; do
          [ -e "$ext" ] || continue
          cp "$ext" "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-config/extensions/"
        done

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

        # Find the installed Pi package on the host, then compute the path
        # the wrapper will see inside the VM (/mnt/shared/...).
        PI_BIN="$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm/bin"
        PI_PKG_HOST=""
        PI_PKG_REL=""
        PI_PKG_VM=""
        for rel in \
          "lib/node_modules/@earendil-works/pi-coding-agent" \
          "node_modules/@earendil-works/pi-coding-agent"; do
          candidate_host="$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm/$rel"
          if [ -f "$candidate_host/package.json" ]; then
            PI_PKG_HOST="$candidate_host"
            PI_PKG_REL="$rel"
            PI_PKG_VM="${sandbox.workspaceVmMountPoint}/pi-npm/$rel"
            break
          fi
        done

        if [ -z "$PI_PKG_HOST" ]; then
          echo "❌ Could not find installed @earendil-works/pi-coding-agent package" >&2
          echo "   Looked under ./${sandbox.workspaceHostPath}/pi-npm/lib/node_modules and ./node_modules" >&2
          exit 1
        fi

        mkdir -p "$PI_BIN"
        # Recreate the wrapper on every run. It resolves the package relative to
        # its own location, so the identical tree works both on the 9p share and
        # in the local-disk copy the VM materializes at boot.
        if [ -f "$PI_PKG_HOST/dist/cli.js" ]; then
          cat > "$PI_BIN/pi" <<EOF
#!/usr/bin/env bash
HERE="\$(cd -- "\$(dirname -- "\$0")" && pwd -P)"
# Prefer the copy the VM materialized on local disk; fall back to this (9p)
# tree if materialization hasn't run or failed. The wrapper itself always
# lives on the share, so `pi` is on PATH regardless.
CLI=/var/lib/pi-npm/$PI_PKG_REL/dist/cli.js
[ -f "\$CLI" ] || CLI="\$HERE/../$PI_PKG_REL/dist/cli.js"
exec ${pkgs.nodejs}/bin/node "\$CLI" "\$@"
EOF
          chmod +x "$PI_BIN/pi"
          echo "   Created $PI_BIN/pi wrapper"
        fi

        # Pack the pi-npm tree into a single archive. The VM streams this over
        # 9p in one sequential read and extracts it to local disk, which avoids
        # the ~0.8 ms-per-stat walk over 13k files in the guest. The stamp ties
        # the archive to (version + wrapper) so a change triggers one repack and
        # one re-extract, and nothing in between.
        PI_STAMP="$PI_VERSION:$(sha256sum "$PI_BIN/pi" | cut -c1-12)"
        PI_STAMP_FILE="$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm.stamp"
        PI_TAR_FILE="$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm.tar"
        if [ "$(cat "$PI_STAMP_FILE" 2>/dev/null || true)" != "$PI_STAMP" ] || [ ! -f "$PI_TAR_FILE" ]; then
          echo "📦 Packing Pi for local-disk materialization..."
          ( cd "$REPO_ROOT/${sandbox.workspaceHostPath}/pi-npm" && ${pkgs.gnutar}/bin/tar -cf ../pi-npm.tar . )
          printf '%s\n' "$PI_STAMP" > "$PI_STAMP_FILE"
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
