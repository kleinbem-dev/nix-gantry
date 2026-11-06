# Container host: bridge, firewall and updater wiring. Mirrors subnet and
# hostAddress into my.network where your config declares it. Impermanence
# wiring is opt-in, in ./host-persistence.nix.
#
# Usage in host config:
#
#   imports = [
#     inputs.nix-gantry.nixosModules.host
#     inputs.nix-gantry.nixosModules.updater  # Must also import this
#   ];
#
#   my.container-host = {
#     enable = true;
#     subnet = "10.85.48.0/24";
#     hostAddress = "10.85.48.1";
#     manifestUrl = "https://github.com/you/your-flake/releases/download/container-manifest/manifest.json";
#     excludeFromUpdater = [ "attic" "caddy" "crowdsec" ];
#   };
#
#   my.containers = {
#     caddy = {
#       enable = true;
#       ip = "10.85.48.5/24";
#       hostDataDir = "/var/lib/caddy";
#     };
#     # ... more, each declared by your own preset (see ../lib/factory.nix)
#   };

{
  config,
  lib,
  options,
  ...
}:

let
  cfg = config.my.container-host;
in
{
  options.my.container-host = {
    enable = lib.mkEnableOption "Container Host (LXD networking, persistence, auto-update)";

    subnet = lib.mkOption {
      type = lib.types.str;
      description = "Container subnet (e.g., 10.85.48.0/24)";
      example = "10.85.48.0/24";
    };

    hostAddress = lib.mkOption {
      type = lib.types.str;
      description = "Host bridge IP on container subnet";
      example = "10.85.48.1";
    };

    manifestUrl = lib.mkOption {
      type = lib.types.str;
      description = ''
        Forwarded to my.services.container-updater.manifestUrl. Set here
        (once, alongside subnet/hostAddress) instead of separately
        importing nixosModules.updater just to set one string.
      '';
      example = "https://github.com/you/your-flake/releases/download/container-manifest/manifest.json";
    };

    bridge = lib.mkOption {
      type = lib.types.str;
      default = "cbr0";
      description = "Container bridge name";
    };

    excludeFromUpdater = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Containers still built by container-factory and pulled/cached from the
        CI manifest, but excluded from the automatic nightly bulk update —
        e.g. a reverse proxy you don't want unattended-restarted. Still
        stageable/updatable any time via
        `systemctl start update-container@<name>`.
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
        Containers that must build embedded on this host and never be
        treated as standalone/pulled at all — for a container-factory
        structural conflict (e.g. an attrsOf option that recurses in the
        factory's eval), not merely "don't auto-restart" (use
        excludeFromUpdater for that).
      '';
    };

    journal = {
      forward = lib.mkOption {
        type = lib.types.bool;
        default = lib.versionAtLeast config.systemd.package.version "261";
        defaultText = lib.literalExpression ''lib.versionAtLeast config.systemd.package.version "261"'';
        description = ''
          Stream each container's journal to /var/log/containers/<name> on the
          host (nspawn --forward-journal, needs systemd 261 or newer). Readable by the
          systemd-journal group with `journalctl -D`, and it survives container
          restarts. Guests need systemd 256 or newer; an older guest ignores the
          forwarding and keeps its journal inside the container. With
          enablePersistence, nixosModules.host-persistence persists the directory.
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
        description = "Per-container overrides of `maxUse`, by container name.";
      };
    };

    # Needs nixosModules.host-persistence plus the impermanence module.
    enablePersistence = lib.mkEnableOption "Impermanence for container host";
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Only where declared, so the module also works in a config without it.
      (lib.optionalAttrs (options ? my.network) {
        my.network = {
          inherit (cfg) subnet hostAddress;
        };
      })
      {
        # ─── Container Networking ───────────────────────────────────
        # Create the bridge empty (containers attach at start); mkDefault so a
        # definition elsewhere wins.
        networking.bridges.${cfg.bridge}.interfaces = lib.mkDefault [ ];

        # ─── Firewall Rules for Container Traffic ───────────────────
        # Allow container traffic on the bridge
        networking.firewall = {
          extraForwardRules = ''
            # Allow traffic between containers on bridge
            iifname "${cfg.bridge}" oifname "${cfg.bridge}" accept
            # Allow containers to reach external networks
            iifname "${cfg.bridge}" accept
            oifname "${cfg.bridge}" accept
          '';
        };

        # ─── Container Auto-Update Orchestration (ADR 002) ──────────
        # Containers are decoupled from host generation and refreshed
        # nightly from CI-published manifest (eval-free on edge devices).
        # Requires nixosModules.updater.
        my.services.container-updater = {
          enable = true;
          inherit (cfg) manifestUrl;
          # Real nspawn names from config.containers, not my.containers keys: a
          # preset's container name can differ from its option name, and
          # isStandalone in ../lib/factory.nix matches this list. Only
          # excludeFromStandalone is subtracted here; excludeFromUpdater just skips
          # the nightly run (removing it here would build it embedded again).
          containers = lib.subtractLists cfg.excludeFromStandalone (lib.attrNames config.containers);
          excludeFromNightly = cfg.excludeFromUpdater;
        };
      }
    ]
  );
}
