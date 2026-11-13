# Container host: bridge, firewall, and updater wiring. Mirrors subnet and
# hostAddress into my.network when declared; impermanence wiring lives in
# ./host-persistence.nix so the external module stays opt-in.
{
  config,
  lib,
  options,
  ...
}:
let
  cfg = config.services.nix-gantry.host;
  renamedPaths = [
    [ "enable" ]
    [ "subnet" ]
    [ "hostAddress" ]
    [ "manifestUrl" ]
    [ "bridge" ]
    [ "excludeFromUpdater" ]
    [ "excludeFromStandalone" ]
    [
      "journal"
      "forward"
    ]
    [
      "journal"
      "maxUse"
    ]
    [
      "journal"
      "maxUseFor"
    ]
    [ "enablePersistence" ]
  ];
in
{
  imports = map (
    path:
    lib.mkRenamedOptionModule
      (
        [
          "my"
          "container-host"
        ]
        ++ path
      )
      (
        [
          "services"
          "nix-gantry"
          "host"
        ]
        ++ path
      )
  ) renamedPaths;

  options.services.nix-gantry.host = {
    enable = lib.mkEnableOption "container host bridge networking and updater wiring";

    subnet = lib.mkOption {
      type = lib.types.str;
      description = "Container subnet CIDR.";
      example = "10.85.48.0/24";
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      description = "Host bridge IP on the container subnet.";
      example = "10.85.48.1";
    };

    manifestUrl = lib.mkOption {
      type = lib.types.str;
      description = "Forwarded to `services.nix-gantry.updater.manifestUrl`.";
      example = "https://github.com/you/your-flake/releases/download/container-manifest/manifest.json";
    };

    bridge = lib.mkOption {
      type = lib.types.str;
      default = "cbr0";
      description = "Container bridge interface name.";
    };

    excludeFromUpdater = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Containers still built standalone and pulled from the CI manifest, but
        excluded from the automatic nightly bulk update — e.g. a reverse proxy
        you do not want restarted unattended. Still updatable manually via
        `nix-gantry update <name>` or `systemctl start update-container@<name>`.
      '';
      example = [
        "attic"
        "caddy"
        "crowdsec"
      ];
    };

    excludeFromStandalone = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Containers built embedded on this host and never pulled from the
        manifest — for structural evaluation conflicts, not merely skipping
        unattended restarts (use `excludeFromUpdater` for that).
      '';
    };

    journal = {
      forward = lib.mkOption {
        type = lib.types.bool;
        default = lib.versionAtLeast config.systemd.package.version "261";
        defaultText = lib.literalExpression ''lib.versionAtLeast config.systemd.package.version "261"'';
        description = ''
          Stream each container's journal to `/var/log/containers/<name>` on the
          host (`nspawn --forward-journal`, requires host systemd >= 261 and
          guest systemd >= 256). Readable by the `systemd-journal` group via
          `journalctl -D` across container restarts.
        '';
      };
      maxUse = lib.mkOption {
        type = lib.types.str;
        default = "256M";
        description = "Disk cap per container for the forwarded journal.";
      };
      maxUseFor = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          caddy = "1G";
        };
        description = "Per-container overrides of `maxUse`, keyed by container name.";
      };
    };

    enablePersistence = lib.mkEnableOption "impermanence wiring for container host data directories";

    persistPath = lib.mkOption {
      type = lib.types.str;
      default = "/nix/persist";
      example = "/persist";
      description = "Impermanence mount root under `environment.persistence` when `enablePersistence` is enabled.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.optionalAttrs (options ? my.network) {
        my.network = {
          inherit (cfg) subnet hostAddress;
        };
      })
      {
        networking = {
          bridges.${cfg.bridge}.interfaces = lib.mkDefault [ ];
          # extraForwardRules and per-container zt-*-egress tables require nftables.
          nftables.enable = lib.mkDefault true;
          firewall.extraForwardRules = ''
            iifname "${cfg.bridge}" oifname "${cfg.bridge}" accept
            iifname "${cfg.bridge}" accept
            oifname "${cfg.bridge}" accept
          '';
        };

        services.nix-gantry.updater = {
          enable = true;
          inherit (cfg) manifestUrl;
          containers = lib.subtractLists cfg.excludeFromStandalone (lib.attrNames config.containers);
          excludeFromNightly = cfg.excludeFromUpdater;
        };
      }
    ]
  );
}
