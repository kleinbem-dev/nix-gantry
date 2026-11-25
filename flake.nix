{
  description = "CI builds once; hosts fetch a manifest and atomically swap in a NixOS/systemd-nspawn container. No evaluation or building on the host.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    inputs@{ nixpkgs, self, ... }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems =
        f:
        lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
          }
        );

      lintSrc = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.fileFilter (f: f.hasExt "nix" || f.hasExt "sh") ./.;
      };
    in
    {
      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-tree);

      packages = forAllSystems (
        { pkgs, system }:
        let
          tests = import ./tests {
            inherit
              pkgs
              self
              inputs
              lib
              ;
          };
          nix-gantry = pkgs.callPackage ./package.nix {
            passthruTests = {
              inherit (tests)
                happy-path
                health-rollback
                bad-manifest
                tls-mtls
                ;
            };
          };

          # Evaluate our modules in a minimal nixosSystem so standard NixOS
          # namespaces exist; stub external impermanence and optional fleet paths.
          allOptions =
            (lib.nixosSystem {
              inherit system;
              modules = [
                ./modules/host.nix
                ./modules/updater.nix
                ./modules/host-persistence.nix
                {
                  options = {
                    my.containers = lib.mkOption {
                      type = lib.types.attrsOf lib.types.attrs;
                      default = { };
                    };
                    my.network = lib.mkOption {
                      type = lib.types.attrsOf lib.types.anything;
                      default = { };
                    };
                    environment.persistence = lib.mkOption {
                      type = lib.types.attrsOf lib.types.attrs;
                      default = { };
                    };
                  };
                  config.system.stateVersion = lib.mkDefault "25.11";
                }
              ];
            }).options;

          optionsDoc = pkgs.nixosOptionsDoc {
            transformOptions =
              opt:
              opt
              // {
                declarations = map (
                  decl:
                  let
                    file = lib.removePrefix "${self}/" (toString decl);
                  in
                  {
                    name = file;
                    url = "https://github.com/kleinbem-dev/nix-gantry/blob/main/${file}";
                  }
                ) opt.declarations;
              };
            options.services.nix-gantry = allOptions.services.nix-gantry;
          };

          options-doc = pkgs.runCommandLocal "nix-gantry-options-doc.md" { } ''
            {
              echo '<!-- Generated via `nix build .#options-doc`. Do not hand-edit -- see CONTRIBUTING.md. -->'
              cat ${optionsDoc.optionsCommonMark}
            } > $out
          '';
        in
        {
          inherit nix-gantry options-doc;
          default = nix-gantry;
        }
      );

      apps = forAllSystems (
        { system, ... }:
        let
          pkg = self.packages.${system}.nix-gantry;
          cliApp = {
            type = "app";
            program = "${pkg}/bin/nix-gantry";
            meta.description = "Manage nix-gantry containers and publish CI manifests";
          };
        in
        {
          default = cliApp;
          nix-gantry = cliApp;
          publish-manifest = {
            type = "app";
            program = "${pkg}/bin/publish-manifest";
            meta.description = "Build and cache-verify NixOS container closures into a manifest fragment";
          };
        }
      );

      checks = forAllSystems (
        { pkgs, system }:
        {
          package = self.packages.${system}.nix-gantry;
          lint =
            pkgs.runCommandLocal "nix-gantry-lint"
              {
                nativeBuildInputs = [
                  pkgs.nixfmt
                  pkgs.statix
                  pkgs.deadnix
                  pkgs.shellcheck
                  pkgs.findutils
                ];
              }
              ''
                cp -r ${lintSrc} src
                chmod -R +w src
                cd src
                echo "Checking nixfmt..."
                find . -name '*.nix' -print0 | xargs -0 nixfmt --check
                echo "Checking statix..."
                statix check .
                echo "Checking deadnix..."
                deadnix --fail .
                echo "Checking shellcheck..."
                find . -name '*.sh' -exec shellcheck {} +
                touch $out
              '';
        }
        // (import ./tests {
          inherit
            pkgs
            self
            inputs
            lib
            ;
        })
      );

      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              nixfmt
              statix
              deadnix
              shellcheck
              nix-update
            ];
          };
        }
      );

      overlays.default = final: _prev: {
        nix-gantry = final.callPackage ./package.nix { };
      };

      lib = {
        mkContainer = import ./lib/factory.nix { inherit lib; };
        tlsOptions = import ./lib/tls-options.nix;
        oidcOptions = import ./lib/oidc-options.nix;
        egressOptions = import ./lib/egress-options.nix;
      };

      nixosModules = {
        updater = import ./modules/updater.nix;
        host = import ./modules/host.nix;
        # Opt-in alongside the external impermanence module.
        host-persistence = import ./modules/host-persistence.nix;
        default.imports = [
          ./modules/updater.nix
          ./modules/host.nix
        ];
      };
    };
}
