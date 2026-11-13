{
  description = "nix-gantry quickstart: one container, pulled and swapped by a manifest, no fleet infrastructure required";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-gantry.url = "path:..";
    nix-gantry.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, nix-gantry, ... }:
    let
      system = "x86_64-linux";
      inherit (nixpkgs) lib;

      demoInnerConfig =
        { pkgs, ... }:
        {
          services.httpd = {
            enable = true;
            virtualHosts.localhost.documentRoot = pkgs.writeTextDir "index.html" "Hello from nix-gantry!";
          };
          networking.firewall.allowedTCPPorts = [ 80 ];
          system.stateVersion = "25.11";
        };

      # Minimal inline preset. Import the whole mkContainer attrset (not just
      # `.containers`) so container@ unitConfig and tmpfiles rules are wired too.
      demoContainer = {
        imports = [
          (
            { config, ... }:
            nix-gantry.lib.mkContainer {
              inherit config;
              name = "hello";
              cfg = {
                ip = "10.233.1.2/24";
                hostBridge = "cbr0";
                autoStart = true;
              };
              innerConfig = demoInnerConfig;
            }
          )
        ];
      };

      # Factory build: no updater registration here, so isStandalone is false
      # and `.path` is a real closure. In production CI builds this via
      # `nix-gantry publish-manifest` (.github/workflows/publish-manifest.yaml).
      factoryEval = lib.nixosSystem {
        inherit system;
        modules = [ demoContainer ];
      };
      helloClosure = factoryEval.config.containers.hello.path;

      host =
        { pkgs, ... }:
        let
          manifestFile = pkgs.writeText "manifest.json" (
            builtins.toJSON {
              rev = "quickstart";
              generated = "1970-01-01T00:00:00Z";
              systems.${system}.hello = "${helloClosure}";
            }
          );
        in
        {
          imports = [
            nix-gantry.nixosModules.default
            demoContainer
          ];

          services.nix-gantry = {
            host = {
              enable = true;
              subnet = "10.233.1.0/24";
              hostAddress = "10.233.1.1";
              manifestUrl = "file://${manifestFile}";
            };
            updater.containers = [ "hello" ];
          };

          networking.interfaces.cbr0.ipv4.addresses = [
            {
              address = "10.233.1.1";
              prefixLength = 24;
            }
          ];
          system.stateVersion = "25.11";
        };
    in
    {
      nixosConfigurations = {
        quickstart = lib.nixosSystem {
          inherit system;
          modules = [ host ];
        };
        # Fixture for CI (.github/workflows/ci.yaml), which runs publish-manifest
        # against this factory-mode configuration.
        quickstart-factory = factoryEval;
      };
    };
}
