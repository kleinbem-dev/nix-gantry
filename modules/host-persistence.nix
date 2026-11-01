# Persistence for container hostDataDirs, kept out of modules/host.nix because
# `environment.persistence` comes from the external impermanence module. Any
# definition of an undeclared option fails ("option does not exist"), even
# under `lib.mkIf false`, so only import this if you use impermanence:
#
#   imports = [
#     inputs.nix-gantry.nixosModules.host
#     inputs.nix-gantry.nixosModules.host-persistence
#     inputs.impermanence.nixosModules.impermanence
#   ];
#
#   my.container-host.enablePersistence = true;
{
  config,
  lib,
  ...
}:
let
  cfg = config.my.container-host;
in
{
  config = lib.mkIf (cfg.enable && cfg.enablePersistence) {
    # ─── Persistence for Container State ────────────────────────
    # Keep container data directories across reboots.
    environment.persistence."/nix/persist".directories =
      let
        # Extract all hostDataDir values from enabled containers
        containerDirs = lib.concatMap (
          name:
          (
            let
              container = config.my.containers.${name};
            in
            if container.enable or false then
              lib.optional ((container.hostDataDir or null) != null) container.hostDataDir
            else
              [ ]
          )
        ) (lib.attrNames config.my.containers);
      in
      lib.unique containerDirs;
  };
}
