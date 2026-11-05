# oidc-options.nix — Reusable OIDC option submodule for container presets.
# Import this in any container module that supports native OIDC SSO.
{
  lib,
  defaultName ? "",
  issuerUrl ? null,
}:
{
  oidc = {
    enable = lib.mkEnableOption "OIDC SSO integration for ${defaultName}";
    clientId = lib.mkOption {
      type = lib.types.str;
      default = defaultName;
      description = "OAuth2 Client ID registered with the OIDC identity provider";
    };
    # No fallback issuer: each consumer names its own identity provider.
    issuerUrl = lib.mkOption (
      {
        type = lib.types.str;
        description = "OpenID Connect discovery endpoint URL";
      }
      // lib.optionalAttrs (issuerUrl != null) { default = issuerUrl; }
    );
    scopes = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "openid"
        "email"
        "profile"
      ];
      description = "OAuth scopes to request from the identity provider";
    };
  };
}
