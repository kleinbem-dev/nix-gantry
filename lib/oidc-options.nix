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
    issuerUrl = lib.mkOption {
      type = lib.types.str;
      default =
        if issuerUrl != null then
          issuerUrl
        else
          "https://auth.kleinbem.dev/application/o/${defaultName}/.well-known/openid-configuration";
      description = "OpenID Connect discovery endpoint URL";
    };
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
