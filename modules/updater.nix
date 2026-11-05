{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.services.container-updater;
  hostSystem = pkgs.stdenv.hostPlatform.system;
  # Only real nspawn containers can be staged: drop names with no entry in
  # config.containers (e.g. OCI/podman services, which have no manifest entry).
  registered = lib.filter (c: builtins.hasAttr c config.containers) cfg.containers;
  # The nightly-timer subset. Excluded containers stay standalone (isStandalone in
  # ../lib/factory.nix matches the full cfg.containers) and can still be updated
  # with `systemctl start update-container@<name>`.
  nightly = lib.subtractLists cfg.excludeFromNightly registered;

  # Seconds in a container timeout, as systemd reads it: a sum of
  # "<n><unit>" tokens ("90s", "15min", "1h 30min"; a bare number is seconds).
  # Anything else fails evaluation rather than guessing a limit.
  unitSeconds = {
    "" = 1;
    s = 1;
    sec = 1;
    second = 1;
    seconds = 1;
    m = 60;
    min = 60;
    minute = 60;
    minutes = 60;
    h = 3600;
    hr = 3600;
    hour = 3600;
    hours = 3600;
    d = 86400;
    day = 86400;
    days = 86400;
  };
  toSeconds =
    t:
    let
      parts = builtins.split "([0-9]+) *([a-z]*)" t;
      tokens = lib.filter builtins.isList parts;
      rest = lib.concatStrings (lib.filter builtins.isString parts);
      n = tok: lib.toInt (lib.head tok);
      u = tok: lib.elemAt tok 1;
      # Sub-second units round up: an upper bound must not shrink.
      sec =
        tok:
        if subSecond ? ${u tok} then
          (n tok + subSecond.${u tok} - 1) / subSecond.${u tok}
        else
          n tok
          * (unitSeconds.${u tok} or (throw "nix-gantry: unknown time unit in container timeout \"${t}\""));
    in
    if t == "infinity" then
      null
    else if tokens == [ ] || builtins.match " *" rest == null then
      throw "nix-gantry: can't read container timeout \"${t}\"; use e.g. \"90s\", \"15min\" or \"1h 30min\""
    else
      lib.foldl' (acc: tok: acc + sec tok) 0 tokens;
  subSecond = {
    ms = 1000;
    msec = 1000;
    us = 1000000;
    usec = 1000000;
  };
  # The largest limit, or null when any container's is "infinity".
  maxOf = floor: ts: if builtins.elem null ts then null else lib.foldl' lib.max floor ts;
  maxStartSec = maxOf 60 (map (c: toSeconds config.containers.${c}.timeoutStartSec) registered);
  # container@'s TimeoutStopSec (lib.mkContainer sets one); 90s is systemd's default.
  maxStopSec = maxOf 90 (
    map (
      c:
      toSeconds (
        toString (config.systemd.services."container@${c}".serviceConfig.TimeoutStopSec or "90s")
      )
    ) registered
  );
  # An unbounded stop or start makes the updater units unbounded too.
  bounded = maxStopSec != null && maxStartSec != null;
  restartSec = maxStopSec + maxStartSec;
  # Activation: restart, healthcheck, and on failure a second restart for the
  # rollback; 60s covers the settle sleeps and the closure swap.
  activateTimeoutSec =
    if bounded then 2 * restartSec + cfg.healthcheckTimeoutSec + 60 else "infinity";
  rollbackTimeoutSec = if bounded then restartSec + 60 else "infinity";

  # Replace a symlink by rename, so a container start never sees it missing.
  swapLinkFn = ''
    swap_link() {
      ln -sfn "$1" "$2.new"
      mv -Tf "$2.new" "$2"
    }
  '';

  # Fetch manifest, substitute from cache, register a Nix profile, swap the
  # current symlink; never touches the running container. Also used by the
  # activation script below, which has no PATH, hence full store paths.
  stageScript = pkgs.writeShellScript "container-stage" ''
    set -euo pipefail
    ${swapLinkFn}
    CONTAINER=$1
    echo "Staging update for container: $CONTAINER (system: ${hostSystem})"
    # Activation can run this before systemd-tmpfiles has created these.
    mkdir -p /nix/var/nix/profiles/containers /run/container-updater

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

    if [ "$(readlink "/var/lib/machines/$CONTAINER/current" 2>/dev/null)" != "$PROFILE" ]; then
      echo "Pointing /var/lib/machines/$CONTAINER/current at $PROFILE..."
      swap_link "$PROFILE" "/var/lib/machines/$CONTAINER/current"
    fi

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

  # Roll back via the Nix profile, else via the `previous` symlink. Returns
  # non-zero if neither worked (e.g. a profile with only one generation).
  rollbackFn = ''
    roll_back() {
      local profile="/nix/var/nix/profiles/containers/$1"
      local previous="/var/lib/machines/$1/previous"
      if ${pkgs.nix}/bin/nix-env --profile "$profile" --rollback 2>/dev/null; then
        echo "Rolled back Nix profile $profile to previous generation."
      elif [ -e "$previous" ] \
        && [ "$(readlink -f "$previous")" != "$(readlink -f "/var/lib/machines/$1/current")" ]; then
        echo "Falling back to previous symlink: $previous"
        swap_link "$(readlink -f "$previous")" "/var/lib/machines/$1/current"
      else
        echo "No previous generation available for $1."
        return 1
      fi
    }
  '';

  activateScript = pkgs.writeShellScript "container-activate" ''
    set -euo pipefail
    ${swapLinkFn}
    ${rollbackFn}
    CONTAINER=$1

    echo "Activating staged update for container: $CONTAINER"
    started=1

    if machinectl status "$CONTAINER" >/dev/null 2>&1; then
      echo "Restarting container $CONTAINER to apply staged update..."
      # Not machinectl restart: it returns mid-reboot, while container@ still
      # looks active, so the check below passed before the new closure ran.
      systemctl restart "container@$CONTAINER" || started=0
    else
      echo "Container $CONTAINER is not currently running. Starting it..."
      systemctl start "container@$CONTAINER" || started=0
    fi

    echo "Waiting for container@$CONTAINER to reach active status..."
    timeout=${toString cfg.healthcheckTimeoutSec}
    elapsed=0
    interval=2
    healthy=0
    # A failed start skips the wait and goes straight to the rollback below.
    if [ "$started" -eq 0 ]; then
      echo "container@$CONTAINER failed to start."
      timeout=0
    else
      sleep 2 # let the transition settle
    fi

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
      echo "Initiating automatic rollback for $CONTAINER..."
      if roll_back "$CONTAINER"; then
        echo "Restarting container@$CONTAINER on restored closure..."
        if systemctl restart "container@$CONTAINER"; then
          echo "Rollback completed for $CONTAINER."
        else
          echo "Restored closure of $CONTAINER failed to start too."
        fi
      fi
    ''}

    rm -f "/run/container-updater/changed-$CONTAINER"
    exit 1
  '';

  rollbackScript = pkgs.writeShellScript "container-rollback" ''
    set -euo pipefail
    ${swapLinkFn}
    ${rollbackFn}
    CONTAINER=$1

    echo "Rollback requested for container: $CONTAINER"
    roll_back "$CONTAINER"
    echo "Restarting container@$CONTAINER on restored closure..."
    systemctl restart "container@$CONTAINER"
    echo "Rollback completed for $CONTAINER."
  '';
in
{
  options.my.services.container-updater = {
    enable = lib.mkEnableOption "Automated container closures updater via Nix Profiles";
    manifestUrl = lib.mkOption {
      type = lib.types.str;
      # No default: every consumer must point at its own manifest.
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
        Executed on the host, with systemd, nix, coreutils and curl on PATH;
        must exit 0 when healthy.
        Example: { "caddy" = "curl -fsS http://10.85.46.107:80/health"; }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd = {
      # Stage: no evaluation on the device, no restart. A changed closure drops a
      # flag in /run/container-updater so the bulk run restarts only what changed.
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

          # curl for healthchecks like the example in `healthchecks`.
          path = with pkgs; [
            systemd
            nix
            coreutils
            curl
          ];

          scriptArgs = "%i";
          script = ''
            exec ${activateScript} "$@"
          '';

          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = activateTimeoutSec;
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
            TimeoutStartSec = rollbackTimeoutSec;
          };
        };

        # Stage + activate in one shot; always restarts. The manual entry point.
        "update-container@" = {
          description = "Update NixOS Container %i (stage + activate)";

          path = with pkgs; [ systemd ];

          scriptArgs = "%i";
          script = ''
            CONTAINER=$1
            systemctl start --wait "update-container-stage@$CONTAINER.service"
            systemctl start --wait "update-container-activate@$CONTAINER.service"
          '';

          # Only waits on stage@ and activate@, which have their own limits.
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "infinity";
          };
        };

        # Nightly bulk update: stage all in parallel (a container named attic keeps
        # serving the cache meanwhile), activate the changed ones except attic,
        # then attic last. Unchanged, running containers are not restarted.
        "update-containers" = lib.mkIf (nightly != [ ]) {
          description = "Smart bulk update of standalone NixOS containers (stage all → activate changed non-attic → activate attic last)";

          path = with pkgs; [ systemd ];

          # Only waits on stage@ and activate@, which have their own limits.
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "infinity";
          };

          # A failed container doesn't stop the others, but fails the unit at the end.
          script = ''
            CONTAINERS="${lib.concatStringsSep " " nightly}"
            failed=0
            pids=()

            # Waits for the jobs in pids; records any failure.
            wait_all() {
              local pid
              for pid in "''${pids[@]}"; do
                wait "$pid" || failed=1
              done
              pids=()
            }

            echo "=== Phase 1: staging updates for all containers in parallel ==="
            for c in $CONTAINERS; do
              echo "  staging $c..."
              systemctl start --wait "update-container-stage@$c.service" &
              pids+=("$!")
            done
            wait_all
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
                pids+=("$!")
              fi
            done
            wait_all
            echo "Non-attic activations complete."

            if [[ " $CONTAINERS " == *" attic "* ]] && needs_activation attic; then
              echo "=== Phase 3: activating attic last ==="
              systemctl start --wait "update-container-activate@attic.service" || failed=1
            fi

            if [ "$failed" -ne 0 ]; then
              echo "Bulk update finished with failures; see update-container-stage@/activate@ logs."
              exit 1
            fi
            echo "Bulk update complete."
          '';
        };

        # Standalone container@ units need /var/lib/machines/<name>/current, so a
        # never-staged container stays down. At boot, update any whose symlink is missing.
        "container-updater-bootstrap" = lib.mkIf (registered != [ ]) {
          description = "Bootstrap standalone containers that have never been staged";
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          wantedBy = [ "multi-user.target" ];

          path = with pkgs; [ systemd ];

          # Only waits on update-container@, see there.
          serviceConfig = {
            Type = "oneshot";
            TimeoutStartSec = "infinity";
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

    # The bootstrap unit only runs at boot. On a switch that first makes a
    # container standalone, its unit restarts after activation scripts against a
    # symlink nobody staged, fails ConditionPathExists and stays down. So stage
    # (never restart) missing containers here, before the unit restarts. It
    # blocks the switch, but only does work the first time; otherwise a no-op.
    system.activationScripts.container-updater-stage-missing = lib.mkIf (registered != [ ]) (
      # etc: nix-store --realise reads /etc/nix/nix.conf.
      lib.stringAfter
        [
          "etc"
          "var"
        ]
        ''
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
