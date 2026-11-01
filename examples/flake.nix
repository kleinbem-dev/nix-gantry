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

      # A minimal inline preset (a real one declares options.my.containers.<name>).
      # Import the whole mkContainer result, not just `.containers`: the
      # container@ unitConfig (ConditionPathExists, restart limits) is a sibling
      # key, and without it container@ starts before anything is staged.
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

      # Factory build: no container-updater registration here, so isStandalone
      # is false and .path is a real closure. In production CI does this
      # (.github/workflows/publish-manifest.yaml).
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
            nix-gantry.nixosModules.host
            nix-gantry.nixosModules.updater
            demoContainer
          ];

          my.container-host = {
            enable = true;
            subnet = "10.233.1.0/24";
            hostAddress = "10.233.1.1";
            manifestUrl = "file://${manifestFile}";
            # enablePersistence defaults to false and the bridge is created
            # automatically. See README's "External requirements".
          };

          my.services.container-updater.containers = [ "hello" ];

          networking.firewall.enable = false;
          system.stateVersion = "25.11";
        };
    in
    {
      nixosConfigurations = {
        quickstart = lib.nixosSystem {
          inherit system;
          modules = [ host ];
        };
        # Only for CI (../.github/workflows/ci.yaml), which runs
        # apps.publish-manifest against this factory-mode config.
        quickstart-factory = factoryEval;
      };
    };
}
