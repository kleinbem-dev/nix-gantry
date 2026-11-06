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
    # Persist only hostDataDirs that live on tmpfs. One on a real disk
    # (e.g. /mnt/data) is already persistent; a bind from /nix/persist would
    # hide that disk's copy and keep the data on the root disk instead.
    environment.persistence."/nix/persist".directories =
      let
        hasPrefix = mp: path: mp == "/" || path == mp || lib.hasPrefix "${mp}/" path;
        # Longest mount point containing the path; unknown counts as tmpfs.
        onTmpfs =
          path:
          let
            mounts = lib.filter (fs: hasPrefix fs.mountPoint path) (lib.attrValues config.fileSystems);
            deepest = lib.foldl' (
              a: b: if a == null || lib.stringLength b.mountPoint > lib.stringLength a.mountPoint then b else a
            ) null mounts;
          in
          deepest == null || deepest.fsType == "tmpfs";
        containerDirs = lib.concatMap (
          name:
          let
            container = config.my.containers.${name};
            dir = container.hostDataDir or null;
          in
          lib.optional ((container.enable or false) && dir != null && onTmpfs dir) dir
        ) (lib.attrNames config.my.containers);
      in
      lib.unique containerDirs ++ lib.optional cfg.journal.forward "/var/log/containers";
  };
}
