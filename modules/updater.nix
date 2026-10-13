{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.services.container-updater;
  hostSystem = pkgs.stdenv.hostPlatform.system;
  # Guard: only real nspawn containers can be staged. Hosts auto-derive their
  # list from `my.containers` enables, which also covers OCI/podman services
  # (comfyui, vllm, langflow) that have no nspawn closure and thus no manifest
  # entry — intersecting with `config.containers` filters those out.
  registered = lib.filter (c: builtins.hasAttr c config.containers) cfg.containers;
  # Subset of `registered` eligible for the automatic nightly bulk update —
  # everything else in `registered` is still pulled/cached/CI-built (isStandalone
  # in nix-presets/lib/factory.nix matches against the full `cfg.containers`,
  # not this subset) and still stageable/activatable any time via
  # `systemctl start update-container@<name>`, it just never gets auto-restarted
  # by the 03:00 timer. For something like a reverse proxy you want built once,
  # centrally, and cached — but never unattended-restarted.
  nightly = lib.subtractLists cfg.excludeFromNightly registered;

  # Shared by the "update-container-stage@" systemd template unit AND the
  # system.activationScripts hook below — the latter runs with a minimal
  # environment (no PATH), so every tool is referenced by full store path.
  # Fetch manifest, substitute from cache, register as a Nix profile, swap
  # the /var/lib/machines/<name>/current symlink. Never touches the running
  # container.
  stageScript = pkgs.writeShellScript "container-stage" ''
    set -euo pipefail
    CONTAINER=$1
    echo "Staging update for container: $CONTAINER (system: ${hostSystem})"

    echo "Fetching manifest ${cfg.manifestUrl}..."
    MANIFEST=$(${pkgs.curl}/bin/curl -fsSL --retry 3 --max-time 60 "${cfg.manifestUrl}")

    REV=$(echo "$MANIFEST" | ${pkgs.jq}/bin/jq -r '.rev // "unknown"')
    STORE_PATH=$(echo "$MANIFEST" \
      | ${pkgs.jq}/bin/jq -r --arg sys "${hostSystem}" --arg c "$CONTAINER" \
          '.systems[$sys][$c] // empty')

    if [ -z "$STORE_PATH" ]; then
      echo "Container $CONTAINER has no entry for ${hostSystem} in manifest (rev $REV)."
      echo "Either CI has not built it for this arch yet, or the name is wrong. Aborting."
      exit 1
    fi

    echo "Manifest (rev $REV): $CONTAINER -> $STORE_PATH"
    echo "Substituting from binary cache..."
    ${pkgs.nix}/bin/nix-store --realise "$STORE_PATH"

    PROFILE="/nix/var/nix/profiles/containers/$CONTAINER"
    OLD_PATH=$(readlink -f "$PROFILE" 2>/dev/null || echo "none")

    # Defensive: /var/lib/machines/<name>/ is normally created by the NixOS
    # containers module when my.containers.<name>.enable = true on this host.
    # Create it ourselves if missing so a one-off update for a never-deployed
    # container doesn't fail at the symlink swap.
    mkdir -p "/var/lib/machines/$CONTAINER"

    if [ "$OLD_PATH" != "none" ] && [ -e "$OLD_PATH" ] && [ "$OLD_PATH" != "$STORE_PATH" ]; then
      echo "Preserving previous generation symlink for $CONTAINER: $OLD_PATH"
      ln -sfn "$OLD_PATH" "/var/lib/machines/$CONTAINER/previous"
    fi

    echo "Registering $CONTAINER as a Nix profile (GC safe)..."
    ${pkgs.nix}/bin/nix-env --profile "$PROFILE" --set "$STORE_PATH"

    echo "Updating symlink /var/lib/machines/$CONTAINER/current..."
    ln -sfn "$PROFILE" "/var/lib/machines/$CONTAINER/current"

    if [ "$OLD_PATH" != "$STORE_PATH" ]; then
      touch "/run/container-updater/changed-$CONTAINER"
      echo "Closure changed ($OLD_PATH -> $STORE_PATH); activation needed."
    else
      echo "Closure unchanged; no restart needed."
    fi

    echo "Stage complete for $CONTAINER."
  '';

  healthcheckCases =
    if cfg.healthchecks != { } then
      ''
        case "$CONTAINER" in
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (name: cmd: ''
            "${name}")
              if ! ( ${cmd} ); then
                sleep "$interval"
                elapsed=$((elapsed + interval))
                continue
              fi
              ;;
          '') cfg.healthchecks
        )}
        *)
          ;;
        esac
      ''
    else
      "";

  activateScript = pkgs.writeShellScript "container-activate" ''
    set -euo pipefail
    CONTAINER=$1
    PROFILE="/nix/var/nix/profiles/containers/$CONTAINER"

    echo "Activating staged update for container: $CONTAINER"

    if machinectl status "$CONTAINER" >/dev/null 2>&1; then
      echo "Restarting container $CONTAINER to apply staged update..."
      machinectl restart "$CONTAINER" 2>/dev/null || systemctl restart "container@$CONTAINER"
    else
      echo "Container $CONTAINER is not currently running. Starting it..."
      systemctl start "container@$CONTAINER"
    fi

    # Allow container transition to settle
    sleep 2

    echo "Waiting for container@$CONTAINER to reach active status..."
    timeout=${toString cfg.healthcheckTimeoutSec}
    elapsed=0
    interval=2
    healthy=0

    while [ "$elapsed" -lt "$timeout" ]; do
      if systemctl is-active --quiet "container@$CONTAINER"; then
        ${healthcheckCases}
        healthy=1
        break
      fi

      if [ "$(systemctl is-failed "container@$CONTAINER" 2>/dev/null || true)" = "failed" ]; then
        echo "container@$CONTAINER entered failed state!"
        break
      fi

      sleep "$interval"
      elapsed=$((elapsed + interval))
    done

    if [ "$healthy" -eq 1 ]; then
      rm -f "/run/container-updater/changed-$CONTAINER"
      echo "Activation complete for $CONTAINER."
      exit 0
    fi

    echo "Healthcheck FAILED for container $CONTAINER after ''${elapsed}s!"

    ${lib.optionalString cfg.autoRollback ''
      PREVIOUS="/var/lib/machines/$CONTAINER/previous"
      if [ -e "$PREVIOUS" ] || [ -e "$PROFILE-1-link" ]; then
        echo "Initiating automatic rollback for $CONTAINER..."
        if ${pkgs.nix}/bin/nix-env --profile "$PROFILE" --rollback 2>/dev/null; then
          echo "Rolled back Nix profile $PROFILE to previous generation."
        elif [ -e "$PREVIOUS" ]; then
          echo "Falling back to previous symlink: $PREVIOUS"
          ln -sfn "$(readlink -f "$PREVIOUS")" "/var/lib/machines/$CONTAINER/current"
        fi

        echo "Restarting container@$CONTAINER on restored closure..."
        systemctl restart "container@$CONTAINER" || true
        echo "Rollback completed for $CONTAINER."
      else
        echo "No previous generation available for $CONTAINER to roll back to!"
      fi
    ''}

    rm -f "/run/container-updater/changed-$CONTAINER"
    exit 1
  '';

  rollbackScript = pkgs.writeShellScript "container-rollback" ''
    set -euo pipefail
    CONTAINER=$1
    PROFILE="/nix/var/nix/profiles/containers/$CONTAINER"
    PREVIOUS="/var/lib/machines/$CONTAINER/previous"

    echo "Rollback requested for container: $CONTAINER"
    if [ -e "$PREVIOUS" ] || [ -e "$PROFILE-1-link" ]; then
      if ${pkgs.nix}/bin/nix-env --profile "$PROFILE" --rollback 2>/dev/null; then
        echo "Rolled back Nix profile $PROFILE to previous generation."
      elif [ -e "$PREVIOUS" ]; then
        echo "Updating current symlink back to previous target..."
        ln -sfn "$(readlink -f "$PREVIOUS")" "/var/lib/machines/$CONTAINER/current"
      fi

      echo "Restarting container@$CONTAINER on restored closure..."
      systemctl restart "container@$CONTAINER"
      echo "Rollback completed for $CONTAINER."
    else
      echo "No previous generation available for $CONTAINER."
      exit 1
    fi
  '';
in
{
  options.my.services.container-updater = {
    enable = lib.mkEnableOption "Automated container closures updater via Nix Profiles";
    manifestUrl = lib.mkOption {
      type = lib.types.str;
      # No default: this points at a specific fleet's release, so every
      # consumer must set it explicitly rather than silently inheriting
      # someone else's manifest URL (see container-host.nix and the two
      # direct-consumer hosts, nixos-nvme/orin-nano, for this fleet's value).
      description = ''
        URL of the CI-published container manifest: a JSON map of
        system → container name → store path, generated by the
        promote-production workflow for the exact SHA the `production`
        tag points at. Consuming the manifest instead of evaluating the
        flake keeps the nightly update eval-free on the device — an
        RPi-class host only fetches a JSON file and substitutes a store
        path from the binary cache.
      '';
    };
    containers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of standalone containers to auto-update.";
    };
    excludeFromNightly = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Containers from `containers` (above) to skip in the automatic nightly
        bulk update (e.g. a reverse proxy you don't want unattended-restarted).
        They're still built by container-factory, cached from the CI manifest,
        staged automatically on first boot if never staged
        (container-updater-bootstrap), and updatable any time via
        `systemctl start update-container@<name>` — this only opts them out
        of the automatic 03:00 timer.
      '';
    };
    autoRollback = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Automatically roll back to the previous container generation if the
        container fails to start or fails its healthcheck after activation.
      '';
    };
    healthcheckTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        Maximum time (seconds) to wait for a container to reach active state
        and pass any configured healthcheck after restart.
      '';
    };
    healthchecks = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = ''
        Optional custom healthcheck shell command per container name to verify service health.
        Executed on the host; must exit 0 when healthy.
        Example: { "caddy" = "curl -fsS http://10.85.46.107:80/health"; }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd = {
      # ----------------------------------------------------------------
      # Stage: resolve the container's closure from the CI manifest,
      # substitute it from the binary cache, register as profile, swap
      # symlink. NO nix evaluation happens on the device. The running
      # container is NOT touched — it keeps serving the old closure
      # until activated. When the staged path differs from the previous
      # profile target, a change flag is dropped in /run so the bulk
      # orchestrator only restarts containers that actually changed.
      # ----------------------------------------------------------------
      services = {
        "update-container-stage@" = {
          description = "Stage update for NixOS Container %i (no restart)";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];

          path = with pkgs; [ systemd ];

          scriptArgs = "%i";
          script = ''
            exec ${stageScript} "$@"
          '';

          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "15m";
          };
        };

        # ----------------------------------------------------------------
        # Activate: restart the container so it picks up the staged closure.
        # ~5-30s downtime per container. Must be run AFTER stage.
        # ----------------------------------------------------------------
        "update-container-activate@" = {
          description = "Activate staged update for NixOS Container %i (restart + healthcheck)";

          path = with pkgs; [
            systemd
            nix
            coreutils
          ];

          scriptArgs = "%i";
          script = ''
            exec ${activateScript} "$@"
          '';

          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "5m";
          };
        };

        # ----------------------------------------------------------------
        # Rollback: revert the container to its previous closure and restart.
        # ----------------------------------------------------------------
        "update-container-rollback@" = {
          description = "Roll back NixOS Container %i to previous generation";

          path = with pkgs; [
            systemd
            nix
            coreutils
          ];

          scriptArgs = "%i";
          script = ''
            exec ${rollbackScript} "$@"
          '';

          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "5m";
          };
        };

        # ----------------------------------------------------------------
        # Combined stage + activate (backward-compatible entry point).
        # Equivalent to the original update-container@ behaviour: fetch,
        # swap, restart, all in one shot. Restart is unconditional here —
        # this is the manual "make it so" button.
        # ----------------------------------------------------------------
        "update-container@" = {
          description = "Update NixOS Container %i (stage + activate)";

          path = with pkgs; [ systemd ];

          scriptArgs = "%i";
          script = ''
            CONTAINER=$1
            systemctl start --wait "update-container-stage@$CONTAINER.service"
            systemctl start --wait "update-container-activate@$CONTAINER.service"
          '';

          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "20m";
          };
        };

        # ----------------------------------------------------------------
        # Bulk orchestrator: three-phase update of every registered
        # container, designed to avoid the attic-eats-itself bootstrap
        # window. Stage everything in parallel (no restarts → attic keeps
        # serving). Then activate non-attic in parallel. Then attic last.
        # Only containers whose staged closure actually CHANGED are
        # restarted — an unchanged container (e.g. home-assistant between
        # releases) is left untouched instead of blipping nightly.
        # ----------------------------------------------------------------
        "update-containers" = lib.mkIf (nightly != [ ]) {
          description = "Smart bulk update of standalone NixOS containers (stage all → activate changed non-attic → activate attic last)";

          path = with pkgs; [ systemd ];

          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "1h";
          };

          script = ''
            set -e
            CONTAINERS="${lib.concatStringsSep " " nightly}"

            echo "=== Phase 1: staging updates for all containers in parallel ==="
            for c in $CONTAINERS; do
              echo "  staging $c..."
              systemctl start --wait "update-container-stage@$c.service" &
            done
            wait
            echo "All stages complete."

            needs_activation() {
              # Restart if the closure changed OR the container isn't running
              # (e.g. first stage after enabling: ConditionPathExists held it back).
              [ -e "/run/container-updater/changed-$1" ] && return 0
              machinectl status "$1" >/dev/null 2>&1 && return 1
              return 0
            }

            echo "=== Phase 2: activating changed non-attic containers in parallel ==="
            for c in $CONTAINERS; do
              if [ "$c" != "attic" ] && needs_activation "$c"; then
                echo "  activating $c..."
                systemctl start --wait "update-container-activate@$c.service" &
              fi
            done
            wait
            echo "Non-attic activations complete."

            if echo " $CONTAINERS " | grep -q " attic " && needs_activation attic; then
              echo "=== Phase 3: activating attic last ==="
              systemctl start --wait "update-container-activate@attic.service"
            fi

            echo "Bulk update complete."
          '';
        };

        # ----------------------------------------------------------------
        # Bootstrap: standalone container@ units carry
        # ConditionPathExists=/var/lib/machines/<name>/current, so on a
        # host that just switched a container from embedded to standalone
        # (or on a fresh install) the container stays DOWN until first
        # staged. Don't wait for the 03:00 timer — stage + start any
        # registered container whose symlink is missing, right at boot.
        # ----------------------------------------------------------------
        "container-updater-bootstrap" = lib.mkIf (registered != [ ]) {
          description = "Bootstrap standalone containers that have never been staged";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];

          path = with pkgs; [ systemd ];

          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "30m";
          };

          script = ''
            CONTAINERS="${lib.concatStringsSep " " registered}"
            for c in $CONTAINERS; do
              if [ ! -e "/var/lib/machines/$c/current" ]; then
                echo "Container $c has no staged closure — bootstrapping..."
                systemctl start --wait "update-container@$c.service" || \
                  echo "Bootstrap of $c failed; it will retry on the nightly timer."
              fi
            done
          '';
        };
      };

      timers."update-containers" = lib.mkIf (nightly != [ ]) {
        description = "Nightly update of standalone NixOS containers";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*-*-* 03:00:00";
          Persistent = true;
          RandomizedDelaySec = "30m";
        };
      };

      # Ensure the profiles + change-flag directories exist
      tmpfiles.rules = [
        "d /nix/var/nix/profiles/containers 0755 root root - -"
        "d /run/container-updater 0755 root root - -"
      ];
    };

    # ----------------------------------------------------------------
    # container-updater-bootstrap (systemd service, above) only runs on
    # BOOT (wantedBy multi-user.target) — a plain `nixos-rebuild switch`
    # never fires it. But switch-to-configuration restarts a container's
    # unit in the SAME activation that first makes it standalone (its
    # `.path` flips from an embedded derivation to
    # `/var/lib/machines/<name>/current`), and that restart happens via
    # normal unit reconciliation AFTER activationScripts run — so a
    # container going embedded→standalone for the first time gets
    # restarted against a symlink nothing has ever staged, fails
    # ConditionPathExists, and stays down until a reboot or someone
    # notices. This actually happened (nix-config commit e37e23b5,
    # 2026-09-24) — core-pi's public reverse proxy was down for 2+ hours
    # because this exact gap meant nothing auto-recovered it.
    #
    # Runs synchronously during every switch/boot, before the switch's
    # own unit restarts, and stages (never activates/restarts) any
    # registered container whose symlink doesn't exist yet — so by the
    # time switch-to-configuration restarts that container's unit
    # moments later, the symlink already resolves and the container
    # comes up first-try instead of failing and waiting for a manual
    # fix. Blocking and synchronous on purpose (activation scripts run
    # serially before boot/switch is considered done) — acceptable
    # because this only does real work the ONE time a container is new
    # to standalone; every other switch it's a no-op symlink check.
    system.activationScripts.container-updater-stage-missing = lib.mkIf (registered != [ ]) (
      lib.stringAfter [ "var" ] ''
        for c in ${lib.concatStringsSep " " registered}; do
          if [ ! -e "/var/lib/machines/$c/current" ]; then
            echo "container-updater: $c has no staged closure yet — staging before activation continues..."
            ${stageScript} "$c" || echo "container-updater: staging $c failed during activation; it will retry on the nightly timer or next boot."
          fi
        done
      ''
    );
  };
}
