# tls-options.nix — Reusable TLS option submodule for container presets.
# Import this in any container module that supports mTLS sidecar.
{ lib }:
{
  tls = {
    enable = lib.mkEnableOption "mTLS sidecar proxy for this container";
    serverPort = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "The plain-HTTP service port to wrap with TLS (0 = no inbound sidecar).";
    };
    upstreams = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            name = lib.mkOption {
              type = lib.types.str;
              description = "Logical name of the upstream service (e.g., 'ollama').";
            };
            target = lib.mkOption {
              type = lib.types.str;
              description = "IP of the upstream container.";
            };
            port = lib.mkOption {
              type = lib.types.int;
              default = 443;
              description = "Local loopback port this container's sidecar listens on for this upstream; the upstream itself is reached on 443. Must differ from 443 and serverPort when serverPort > 0.";
            };
          };
        }
      );
      default = [ ];
      description = "List of upstream containers to connect to via mTLS.";
    };
    airlock = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Drop all egress except the container's /24, loopback, mDNS, IPv6 link-local and the tls.upstreams targets on 443. No DNS to outside resolvers.";
    };
    whitelistDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Not enforced yet: reserved for domains to allow through the airlock.";
    };
  };
}
