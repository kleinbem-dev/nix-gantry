# Impermanence wiring for container hostDataDirs, split from ./host.nix because
# `environment.persistence` belongs to the external impermanence module.
{
  config,
  lib,
  ...
}:
let
  cfg = config.services.nix-gantry.host;
  containersAttr = config.services.nix-gantry.containers or config.my.containers or { };
in
{
  config = lib.mkIf (cfg.enable && cfg.enablePersistence) {
    # Persist only hostDataDirs backed by tmpfs; bind-mounting one already on a
    # persistent disk (e.g. /mnt/data) hides that disk behind the root persist volume.
    environment.persistence.${cfg.persistPath}.directories =
      let
        hasPrefix = mp: path: mp == "/" || path == mp || lib.hasPrefix "${mp}/" path;
        onTmpfs =
          path:
          let
            mounts = lib.filter (fs: hasPrefix fs.mountPoint path) (lib.attrValues config.fileSystems);
            deepest = lib.foldl' (
              a: b: if a == null || lib.stringLength b.mountPoint > lib.stringLength a.mountPoint then b else a
            ) null mounts;
          in
          deepest == null || deepest.fsType == "tmpfs";
        # Impermanence creates missing dirs before tmpfiles runs, and factory's
        # ":" rule only sets mode/owner on creation: forward them from tmpfiles.
        persistedDir =
          dir:
          let
            rule = "d ${lib.escapeRegex dir} :([0-7]+) :([^ ]+) :([^ ]+) - -";
            m = lib.findFirst (x: x != null) null (map (builtins.match rule) config.systemd.tmpfiles.rules);
          in
          if m == null then
            dir
          else
            {
              directory = dir;
              mode = lib.elemAt m 0;
              user = lib.elemAt m 1;
              group = lib.elemAt m 2;
            };
        containerDirs = lib.concatMap (
          name:
          let
            container = containersAttr.${name};
            dir = container.hostDataDir or null;
          in
          lib.optional ((container.enable or false) && dir != null && onTmpfs dir) (persistedDir dir)
        ) (lib.attrNames containersAttr);
      in
      lib.unique containerDirs ++ lib.optional cfg.journal.forward "/var/log/containers";
  };
}
