# NixOS module for the Pi sandbox host-side network isolation.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.pi-sandbox;
  sandbox = import ./lib/sandbox-config.nix;
in
{
  options.services.pi-sandbox = {
    enable = lib.mkEnableOption "Pi sandbox VM networking";

    user = lib.mkOption {
      type = lib.types.str;
      description = ''
        Existing user that will run the VM. This user owns the TAP device
        so QEMU can open it without root privileges.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Tell the NixOS firewall to trust traffic from the sandbox bridge.
    # Our pi-sandbox nftables table (which runs at an earlier priority) is the
    # real enforcement point; this just prevents the default NixOS firewall
    # from dropping allowed VM traffic after we have already accepted it.
    networking.firewall.trustedInterfaces = [ sandbox.bridge ];

    # The bridge gives the host a presence in the sandbox subnet.
    networking.bridges.${sandbox.bridge}.interfaces = [ sandbox.tap ];
    networking.interfaces.${sandbox.bridge}.ipv4.addresses = [{
      address = sandbox.hostIp;
      prefixLength = 24;
    }];

    # Create the TAP device before NixOS tries to attach it to the bridge.
    # QEMU is run as cfg.user, so the TAP is owned by that user.
    systemd.services.pi-sandbox-tap = {
      description = "Pi sandbox TAP device";
      before = [ "network-setup.service" ];
      wantedBy = [ "network-setup.service" "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "pi-sandbox-tap-up" ''
          if ! ${pkgs.iproute2}/bin/ip link show ${sandbox.tap} >/dev/null 2>&1; then
            ${pkgs.iproute2}/bin/ip tuntap add dev ${sandbox.tap} mode tap user ${cfg.user}
          fi
          ${pkgs.iproute2}/bin/ip link set ${sandbox.tap} up
        '';
        ExecStop = pkgs.writeShellScript "pi-sandbox-tap-down" ''
          ${pkgs.iproute2}/bin/ip link set ${sandbox.tap} nomaster 2>/dev/null || true
          sleep 0.1
          ${pkgs.iproute2}/bin/ip link delete ${sandbox.tap} 2>/dev/null || true
        '';
      };
    };

    # The firewall lives entirely in its own table and only affects the sandbox
    # bridge. Other host firewall configuration is left untouched.
    networking.nftables = {
      enable = true;
      ruleset = ''
        table inet pi-sandbox {
          set dns_resolvers {
            type ipv4_addr
            flags interval
            elements = { ${lib.concatStringsSep ", " sandbox.dns} }
          }

          chain input {
            type filter hook input priority -10; policy accept;

            # Accept return traffic before any other table can drop it.
            ct state established,related accept

            iifname "${sandbox.bridge}" jump sandbox_input
          }

          chain sandbox_input {
            # ICMP is useful for basic diagnostics.
            ip protocol icmp accept

            # DNS to configured resolvers.
            ip daddr @dns_resolvers udp dport 53 accept
            ip daddr @dns_resolvers tcp dport 53 accept

            # Host Ollama server.
            ip daddr ${sandbox.ollamaIp} tcp dport ${toString sandbox.ollamaPort} accept

            # Future milestone: whitelist proxy on the host.
            # ip daddr ${sandbox.ollamaIp} tcp dport 8080 accept

            # Default drop for anything else coming from the sandbox.
            drop
          }

          chain forward {
            type filter hook forward priority -10; policy accept;

            # Accept return traffic to the VM before other tables can drop it.
            ct state established,related accept

            # Also accept any traffic destined back to the sandbox bridge,
            # regardless of which interface it arrived on. This covers replies
            # from external DNS resolvers and (later) the whitelist proxy.
            oifname "${sandbox.bridge}" ct state established,related accept

            iifname "${sandbox.bridge}" jump sandbox_forward
          }

          chain sandbox_forward {
            # DNS only in the first milestone.
            ip daddr @dns_resolvers udp dport 53 accept
            ip daddr @dns_resolvers tcp dport 53 accept

            # Future milestone: whitelist proxy on the host.
            # ip daddr ${sandbox.ollamaIp} tcp dport 8080 accept

            drop
          }

          chain postrouting {
            type nat hook postrouting priority 100; policy accept;
            # Masquerade outbound traffic from the sandbox subnet so DNS answers
            # and allowed connections return to the host and can be forwarded to
            # the VM.
            ip saddr ${sandbox.subnet} oifname != "${sandbox.bridge}" masquerade
          }
        }
      '';
    };

    # Forwarding is required for the VM to reach external DNS resolvers.
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  };
}
