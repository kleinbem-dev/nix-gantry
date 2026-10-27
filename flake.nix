{
  description = "CI builds once; hosts fetch a manifest and atomically swap in a NixOS/systemd-nspawn container. No evaluation or building on the host.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs =
    inputs@{ flake-parts, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          pkgs,
          lib,
          ...
        }:
        let
          # Options reference generation: evaluate the three modules as
          # part of a real (if minimal) nixosSystem, so the standard
          # namespaces they read/write (containers, networking, systemd,
          # environment.etc) come from the real NixOS module set instead
          # of needing individual shims -- only my.containers/my.network
          # (this fleet's own convention) and environment.persistence
          # (the external impermanence module) are genuinely outside
          # both this flake and nixpkgs (see each module's header
          # comment) and need stubbing; my.services.container-updater.*
          # comes from updater.nix itself, already in the module set.
          allOptions =
            (inputs.nixpkgs.lib.nixosSystem {
              inherit (pkgs.stdenv.hostPlatform) system;
              modules = [
                ./modules/host.nix
                ./modules/updater.nix
                ./modules/host-persistence.nix
                {
                  options = {
                    my.containers = lib.mkOption {
                      type = lib.types.attrsOf lib.types.attrs;
                      default = { };
                      description = "Doc-generation stub for your own container presets' options -- not declared by this flake.";
                    };
                    my.network = lib.mkOption {
                      type = lib.types.attrsOf lib.types.anything;
                      default = { };
                      description = "Doc-generation stub for your own fleet-wide network config -- not declared by this flake.";
                    };
                    # Genuinely external (the impermanence module, not
                    # part of nixpkgs) -- everything else here comes
                    # from the real NixOS module set via nixosSystem.
                    environment.persistence = lib.mkOption {
                      type = lib.types.attrsOf lib.types.attrs;
                      default = { };
                      description = "Doc-generation stub for the external impermanence module -- not declared by this flake.";
                    };
                  };
                  config.system.stateVersion = lib.mkDefault "25.11";
                }
              ];
            }).options;
          # nixosSystem pulls in the whole NixOS option tree (hundreds
          # of unrelated options); only render what this flake actually
          # declares.
          optionsDoc = pkgs.nixosOptionsDoc {
            options = {
              my = {
                inherit (allOptions.my) container-host;
                services.container-updater = allOptions.my.services.container-updater;
              };
            };
          };
        in
        {
          formatter = pkgs.nixfmt-rfc-style;

          packages.options-doc = optionsDoc.optionsCommonMark;

          checks = {
            # Hand-rolled in place of git-hooks.nix (removed as a flake
            # input -- this was its only use, and running the same four
            # tools directly needs no external dependency at all).
            lint =
              pkgs.runCommandLocal "nix-gantry-lint"
                {
                  nativeBuildInputs = [
                    pkgs.nixfmt-rfc-style
                    pkgs.statix
                    pkgs.deadnix
                    pkgs.shellcheck
                  ];
                }
                ''
                  cp -r ${./.} src
                  chmod -R +w src
                  cd src
                  echo "Checking nixfmt..."
                  find . -name '*.nix' -print0 | xargs -0 nixfmt --check
                  echo "Checking statix..."
                  statix check .
                  echo "Checking deadnix..."
                  deadnix --fail .
                  echo "Checking shellcheck..."
                  shellcheck apps/publish-manifest.sh
                  touch $out
                '';
          }
          // (import ./tests {
            inherit pkgs self inputs;
            inherit (pkgs) lib;
          });

          apps.publish-manifest = {
            type = "app";
            program = "${
              pkgs.writeShellApplication {
                name = "publish-manifest";
                runtimeInputs = with pkgs; [
                  jq
                  nix
                ];
                text = builtins.readFile ./apps/publish-manifest.sh;
              }
            }/bin/publish-manifest";
          };

          devShells.default = pkgs.mkShell {
            shellHook = ''
              echo "nix-gantry devshell"
            '';
            buildInputs = with pkgs; [
              nixfmt-rfc-style
              statix
              deadnix
              shellcheck
            ];
          };
        };

      flake = {
        lib = {
          mkContainer = import ./lib/factory.nix { inherit (inputs.nixpkgs) lib; };
          tlsOptions = import ./lib/tls-options.nix;
        };

        nixosModules = {
          updater = import ./modules/updater.nix;
          host = import ./modules/host.nix;
          # Not part of `default` -- opt-in only, alongside your own
          # impermanence import. See its header comment.
          host-persistence = import ./modules/host-persistence.nix;
          default.imports = [
            ./modules/updater.nix
            ./modules/host.nix
          ];
        };
      };
    };
}
