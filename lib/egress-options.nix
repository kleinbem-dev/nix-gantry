# egress-options.nix — Reusable egress containment option submodule.
# Prevents compromised or untrusted containers from pivoting into the LAN / other subnets while allowing internet access.
{ lib }:
{
  egress = {
    restrictLan = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Block outbound traffic from this container to private LAN subnets (RFC1918 / CGNAT).";
    };
    lanAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of specific LAN IPs or subnets permitted even when restrictLan is enabled.";
    };
  };
}
