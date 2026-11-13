{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.nix-gantry.updater;
  hostSystem = pkgs.stdenv.hostPlatform.system;
  # Only real nspawn containers have manifest entries; drop OCI/podman names.
  registered = lib.filter (c: builtins.hasAttr c config.containers) cfg.containers;
  nightly = lib.subtractLists cfg.excludeFromNightly registered;
  phase2Containers = lib.filter (c: !(builtins.elem c cfg.activateLast)) nightly;
  phase3Containers = lib.filter (c: builtins.elem c nightly) cfg.activateLast;

  # Seconds in a systemd duration ("90s", "15min", "1h 30min"; bare int = seconds).
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
    w = 604800;
    week = 604800;
    weeks = 604800;
  };
  subSecond = {
    ms = 1000;
    msec = 1000;
    us = 1000000;
    usec = 1000000;
  };
  toSeconds =
    t:
    let
      parts = builtins.split "([0-9]+) *([a-z]*)" t;
      tokens = lib.filter builtins.isList parts;
      rest = lib.concatStrings (lib.filter builtins.isString parts);
      n = tok: lib.toIntBase10 (lib.head tok);
      u = tok: lib.elemAt tok 1;
      # Sub-second units round up so an upper bound never shrinks.
      sec =
        tok:
        if subSecond ? ${u tok} then
          (n tok + subSecond.${u tok} - 1) / subSecond.${u tok}
        else
          n tok
          * (unitSeconds.${u tok} or (throw "nix-gantry: unknown time unit in container timeout \"${t}\""));
      total = lib.foldl' (acc: tok: acc + sec tok) 0 tokens;
    in
    if t == "infinity" then
      null
    else if tokens == [ ] || builtins.match " *" rest == null then
      throw "nix-gantry: can't read container timeout \"${t}\"; use e.g. \"90s\", \"15min\" or \"1h 30min\""
    else if total == 0 then
      null
    else
      total;

  maxOf = floor: ts: if builtins.elem null ts then null else lib.foldl' lib.max floor ts;
  maxStartSec = maxOf 60 (map (c: toSeconds config.containers.${c}.timeoutStartSec) registered);
  maxStopSec = maxOf 90 (
    map (
      c:
      toSeconds (
        toString (config.systemd.services."container@${c}".serviceConfig.TimeoutStopSec or "90s")
      )
    ) registered
  );
  bounded = maxStopSec != null && maxStartSec != null;
  restartSec = maxStopSec + maxStartSec;
  activateTimeoutSec =
    if bounded then 2 * restartSec + cfg.healthcheckTimeoutSec + 60 else "infinity";
  rollbackTimeoutSec = if bounded then restartSec + 60 else "infinity";

  healthcheckCases = lib.optionalString (cfg.healthchecks != { }) ''
    case "$CONTAINER" in
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (
        name: cmd:
        let
          probe = pkgs.writeShellScript "nix-gantry-healthcheck-${name}" ''
            set -uo pipefail
            ${cmd}
          '';
        in
        ''
          "${name}")
            local remaining=$((deadline - SECONDS))
            [ "$remaining" -ge 1 ] || remaining=1
            if ! timeout --kill-after=5 "$remaining" ${probe} 9>&-; then
              sleep "$interval"
              continue
            fi
            ;;
        ''
      ) cfg.healthchecks
    )}
    *)
      ;;
    esac
  '';

  # Unified privileged controller for stage, activate, and rollback; shellchecked at build time.
  updaterCtl = pkgs.writeShellApplication {
    name = "nix-gantry-updater";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      pkgs.nix
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      validate_container() {
        if [[ -z "$1" || ! "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; then
          echo "nix-gantry: invalid container name '$1'" >&2
          exit 1
        fi
      }

      acquire_lock() {
        mkdir -p /run/container-updater
        exec 9>"/run/container-updater/$1.lock"
        flock 9
      }

      STAGE_GCROOT=""
      cleanup_gcroot() {
        if [ -n "$STAGE_GCROOT" ]; then
          rm -f -- "$STAGE_GCROOT"
        fi
      }

      swap_link() {
        local tmp="$2.tmp.$$"
        ln -sfn -- "$1" "$tmp" || return 1
        mv -Tf -- "$tmp" "$2" || {
          rm -f -- "$tmp"
          return 1
        }
      }

      # Keep /var/lib/machines/<name>/current -> $profile invariant across both
      # profile-generation rollbacks and fallback `previous` symlink restores.
      # Explicit `|| return 1` guards are required because `if roll_back` disables errexit.
      roll_back() {
        local c=$1
        local profile="/nix/var/nix/profiles/containers/$c"
        local current="/var/lib/machines/$c/current"
        local previous="/var/lib/machines/$c/previous"
        local cur_target="" prev_target="" profile_target=""
        if [ -e "$current" ]; then
          cur_target=$(readlink -f -- "$current") || return 1
        fi
        if nix-env --profile "$profile" --rollback 2>/dev/null; then
          profile_target=$(readlink -f -- "$profile") || return 1
          if [ -z "$cur_target" ] || [ "$profile_target" != "$cur_target" ]; then
            if [ "$(readlink -- "$current" 2>/dev/null || true)" != "$profile" ]; then
              swap_link "$profile" "$current" || return 1
            fi
            echo "Rolled back Nix profile $profile to previous generation."
            return 0
          fi
        fi
        if [ -e "$previous" ]; then
          prev_target=$(readlink -f -- "$previous") || return 1
          if [ -n "$prev_target" ] && [ -e "$prev_target" ] && [ "$prev_target" != "$cur_target" ]; then
            echo "Falling back to previous closure: $prev_target"
            nix-env --profile "$profile" --set -- "$prev_target" || return 1
            swap_link "$profile" "$current" || return 1
            return 0
          fi
        fi
        echo "No previous generation available for $c."
        return 1
      }

      cmd_stage() {
        local initial=0
        if [ "''${1:-}" = "--initial" ]; then
          initial=1
          shift
        fi
        local CONTAINER=''${1:-}
        validate_container "$CONTAINER"

        mkdir -p \
          /nix/var/nix/profiles/containers \
          /nix/var/nix/gcroots/containers \
          /run/container-updater \
          "/var/lib/machines/$CONTAINER"
        acquire_lock "$CONTAINER"

        echo "Staging update for container: $CONTAINER (system: ${hostSystem})"
        echo "Fetching manifest ${cfg.manifestUrl}..."
        local MANIFEST REV STORE_PATH
        MANIFEST=$(curl -fsSL --retry 3 --max-time 60 -- "${cfg.manifestUrl}")
        REV=$(jq -r '.rev // "unknown"' <<<"$MANIFEST")
        STORE_PATH=$(jq -r --arg sys "${hostSystem}" --arg c "$CONTAINER" '.systems[$sys][$c] // empty' <<<"$MANIFEST")

        if [ -z "$STORE_PATH" ]; then
          echo "Container $CONTAINER has no entry for ${hostSystem} in manifest (rev $REV). Aborting." >&2
          exit 1
        fi
        if [[ ! "$STORE_PATH" =~ ^/nix/store/[a-z0-9]{32}-[^/]+$ ]]; then
          echo "Invalid store path '$STORE_PATH' for $CONTAINER in manifest (rev $REV). Aborting." >&2
          exit 1
        fi

        echo "Manifest (rev $REV): $CONTAINER -> $STORE_PATH"
        echo "Substituting from binary cache..."
        STAGE_GCROOT="/run/container-updater/gcroot-$CONTAINER"
        trap cleanup_gcroot EXIT INT TERM
        nix-store --add-root "$STAGE_GCROOT" --indirect --realise -- "$STORE_PATH" >/dev/null

        local PROFILE="/nix/var/nix/profiles/containers/$CONTAINER"
        local CURRENT="/var/lib/machines/$CONTAINER/current"
        local prev_link="/var/lib/machines/$CONTAINER/previous"
        local prev_gcroot="/nix/var/nix/gcroots/containers/$CONTAINER-previous"
        local OLD_PATH="none"
        if [ -e "$CURRENT" ]; then
          OLD_PATH=$(readlink -f -- "$CURRENT")
        elif [ -e "$PROFILE" ]; then
          OLD_PATH=$(readlink -f -- "$PROFILE")
        fi

        # Root `$OLD_PATH` under /nix/var/nix/gcroots before moving the profile so
        # host GC of old profile generations cannot collect the fallback closure.
        if [ "$OLD_PATH" != "none" ] && [ -e "$OLD_PATH" ] && [ "$OLD_PATH" != "$STORE_PATH" ]; then
          echo "Preserving previous generation symlink for $CONTAINER: $OLD_PATH"
          swap_link "$OLD_PATH" "$prev_gcroot"
          swap_link "$OLD_PATH" "$prev_link"
        elif [ -L "$prev_link" ]; then
          local existing_prev
          existing_prev=$(readlink -f -- "$prev_link" || true)
          if [ -n "$existing_prev" ] && [ -e "$existing_prev" ]; then
            swap_link "$existing_prev" "$prev_gcroot"
          else
            rm -f -- "$prev_link" "$prev_gcroot"
          fi
        else
          rm -f -- "$prev_gcroot"
        fi

        echo "Registering $CONTAINER as a Nix profile (GC safe)..."
        nix-env --profile "$PROFILE" --set -- "$STORE_PATH"
        cleanup_gcroot
        STAGE_GCROOT=""
        trap - EXIT INT TERM

        if [ "$(readlink -- "$CURRENT" 2>/dev/null || true)" != "$PROFILE" ]; then
          echo "Pointing $CURRENT at $PROFILE..."
          swap_link "$PROFILE" "$CURRENT"
        fi

        if [ "$OLD_PATH" != "$STORE_PATH" ]; then
          # Initial staging during live switch is followed immediately by systemd
          # starting container@<name>, so don't queue a redundant nightly restart.
          if [ "$initial" -eq 0 ]; then
            touch "/run/container-updater/changed-$CONTAINER"
          fi
          echo "Closure changed ($OLD_PATH -> $STORE_PATH)."
        else
          echo "Closure unchanged; no restart needed."
        fi

        echo "Stage complete for $CONTAINER."
      }

      cmd_activate() {
        local CONTAINER=''${1:-}
        validate_container "$CONTAINER"
        acquire_lock "$CONTAINER"

        if [ ! -e "/var/lib/machines/$CONTAINER/current" ]; then
          echo "Container $CONTAINER has no staged closure (/var/lib/machines/$CONTAINER/current missing)." >&2
          exit 1
        fi

        echo "Activating staged update for container: $CONTAINER"
        local started=1
        # systemctl restart starts an inactive unit and waits for a running one to reboot;
        # machinectl restart returns mid-reboot while the old closure still looks active.
        # no-link: documented systemd behavior, machinectl only signals guest init.
        systemctl restart "container@$CONTAINER" || started=0

        local timeout=${toString cfg.healthcheckTimeoutSec}
        local interval=2
        local healthy=0
        if [ "$started" -eq 0 ]; then
          echo "container@$CONTAINER failed to start."
          timeout=0
        else
          sleep 2
        fi

        export CONTAINER
        local start=$SECONDS
        local deadline=$((start + timeout))
        while [ "$SECONDS" -lt "$deadline" ]; do
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
        done
        local elapsed=$((SECONDS - start))

        if [ "$healthy" -eq 1 ]; then
          rm -f -- "/run/container-updater/changed-$CONTAINER"
          echo "Activation complete for $CONTAINER."
          exit 0
        fi

        echo "Healthcheck FAILED for container $CONTAINER after ''${elapsed}s!"
        ${lib.optionalString cfg.autoRollback ''
          echo "Initiating automatic rollback for $CONTAINER..."
          if roll_back "$CONTAINER"; then
            echo "Restarting container@$CONTAINER on restored closure..."
            systemctl reset-failed "container@$CONTAINER" || true
            if systemctl restart "container@$CONTAINER"; then
              echo "Rollback completed for $CONTAINER."
            else
              echo "Restored closure of $CONTAINER failed to start too."
            fi
          fi
        ''}
        rm -f -- "/run/container-updater/changed-$CONTAINER"
        exit 1
      }

      cmd_rollback() {
        local CONTAINER=''${1:-}
        validate_container "$CONTAINER"
        acquire_lock "$CONTAINER"

        echo "Rollback requested for container: $CONTAINER"
        roll_back "$CONTAINER"
        echo "Restarting container@$CONTAINER on restored closure..."
        systemctl reset-failed "container@$CONTAINER" || true
        systemctl restart "container@$CONTAINER"
        echo "Rollback completed for $CONTAINER."
      }

      case "''${1:-}" in
        stage) shift; cmd_stage "$@" ;;
        activate) shift; cmd_activate "$@" ;;
        rollback) shift; cmd_rollback "$@" ;;
        *)
          echo "usage: nix-gantry-updater <stage|activate|rollback> [--initial] <container>" >&2
          exit 1
          ;;
      esac
    '';
  };

  reconcilePreviousRoots =
    let
      keepCases =
        lib.optionalString (cfg.enable && registered != [ ])
          "${lib.concatMapStringsSep "|" lib.escapeShellArg registered}) ;;";
    in
    ''
      if [ -z "''${IN_NIXOS_SYSTEMD_STAGE1:-}" ] && [ -d /nix/var/nix/gcroots/containers ]; then
        for root_link in /nix/var/nix/gcroots/containers/*-previous; do
          [ -L "$root_link" ] || [ -e "$root_link" ] || continue
          c=''${root_link#/nix/var/nix/gcroots/containers/}
          c=''${c%-previous}
          case "$c" in
            ${keepCases}
            *)
              ${pkgs.coreutils}/bin/rm -f -- "$root_link"
              ;;
          esac
        done
      fi
    '';

  # Submodule bridge for legacy `my.services.container-updater.*` when `options.my.services`
  # uses `types.submoduleWith`. no-link: `mkRenamedOptionModule` resolves top-level option
  # paths only by design; drop once consumers migrate to `services.nix-gantry.updater`.
  legacyOptionTypes = {
    enable = lib.types.bool;
    manifestUrl = lib.types.str;
    containers = lib.types.listOf lib.types.str;
    excludeFromNightly = lib.types.listOf lib.types.str;
    activateLast = lib.types.listOf lib.types.str;
    autoRollback = lib.types.bool;
    healthcheckTimeoutSec = lib.types.ints.positive;
    healthchecks = lib.types.attrsOf lib.types.str;
  };
in
{
  options.my.services.container-updater = lib.mkOption {
    visible = false;
    default = { };
    type = lib.types.submodule (
      { options, ... }:
      {
        options =
          lib.mapAttrs (
            name: optType:
            lib.mkOption {
              type = optType;
              visible = false;
              apply = _: cfg.${name};
            }
          ) legacyOptionTypes
          // {
            _legacyMeta = lib.mkOption {
              type = lib.types.raw;
              internal = true;
              visible = false;
              default = lib.mapAttrs (name: _: {
                defined = options.${name}.isDefined;
                prio = options.${name}.highestPrio or lib.modules.defaultOverridePriority;
                inherit (options.${name}) definitions;
              }) legacyOptionTypes;
            };
          };
      }
    );
  };

  options.services.nix-gantry.updater = {
    enable = lib.mkEnableOption "automated container closures updater via Nix profiles";
    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default =
        pkgs.nix-gantry
          or (if builtins.pathExists ../package.nix then pkgs.callPackage ../package.nix { } else null);
      defaultText = lib.literalExpression "pkgs.nix-gantry";
      description = "The `nix-gantry` CLI package installed on the host, or `null` to omit it.";
    };
    manifestUrl = lib.mkOption {
      type = lib.types.str;
      example = "https://github.com/you/your-flake/releases/download/container-manifest/manifest.json";
      description = ''
        URL of the CI-published container manifest: a JSON map of
        system -> container name -> store path. Consuming the manifest
        instead of evaluating a flake keeps updates evaluation-free on the host.
      '';
    };
    containers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "caddy"
        "gatus"
      ];
      description = "Standalone containers managed by the updater.";
    };
    excludeFromNightly = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "caddy" ];
      description = ''
        Containers from `containers` skipped by the automatic nightly bulk
        update. Still standalone, bootstrapped on first boot if never staged,
        and updatable manually via `nix-gantry update <name>` or
        `systemctl start update-container@<name>`.
      '';
    };
    activateLast = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "attic" ];
      example = [ "attic" ];
      description = ''
        Containers activated sequentially in Phase 3 after all other changed
        containers finish Phase 2 — e.g. a self-hosted binary cache container
        that should keep serving while peers stage and restart.
      '';
    };
    autoRollback = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Automatically roll back to the previous container generation when a
        container fails to start or fails its healthcheck after activation.
      '';
    };
    healthcheckTimeoutSec = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = ''
        Maximum time (seconds) to wait for a container to reach active state
        and pass any configured healthcheck after restart. A healthcheck still
        running at the deadline is killed and counts as failed.
      '';
    };
    healthchecks = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        caddy = "curl -fsS http://10.85.46.107:80/health";
      };
      description = ''
        Optional host-side shell command per container name to verify health.
        Executed with systemd, nix, coreutils and curl on PATH and the
        container name in `$CONTAINER`; retried until `healthcheckTimeoutSec`.
      '';
    };
  };

  config = lib.mkMerge [
    {
      services.nix-gantry.updater = lib.mapAttrs (
        name: _:
        let
          meta = config.my.services.container-updater._legacyMeta.${name};
        in
        lib.mkIf meta.defined (lib.mkMerge (map (lib.mkOverride meta.prio) meta.definitions))
      ) legacyOptionTypes;

      # Drop stale `*-previous` GC roots when a container is removed or the updater disabled.
      system.activationScripts.container-updater-reconcile-gcroots = lib.stringAfter [
        "var"
      ] reconcilePreviousRoots;
    }
    (lib.mkIf cfg.enable {
      environment.systemPackages = lib.optional (cfg.package != null) cfg.package;

      systemd = {
        services = {
          "update-container-stage@" = {
            description = "Stage update for NixOS Container %i (no restart)";
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            # Oneshot CLI/timer actions (`Restart=no`) should never trip start-limit-hit
            # when an operator retries `nix-gantry stage/activate/update/rollback`.
            unitConfig.StartLimitIntervalSec = 0;
            scriptArgs = "%i";
            script = ''
              exec ${lib.getExe updaterCtl} stage "$@"
            '';
            serviceConfig = {
              Type = "oneshot";
              TimeoutStartSec = "15m";
            };
          };

          "update-container-activate@" = {
            description = "Activate staged update for NixOS Container %i (restart + healthcheck)";
            unitConfig.StartLimitIntervalSec = 0;
            scriptArgs = "%i";
            script = ''
              exec ${lib.getExe updaterCtl} activate "$@"
            '';
            serviceConfig = {
              Type = "oneshot";
              TimeoutStartSec = activateTimeoutSec;
            };
          };

          "update-container-rollback@" = {
            description = "Roll back NixOS Container %i to previous generation";
            unitConfig.StartLimitIntervalSec = 0;
            scriptArgs = "%i";
            script = ''
              exec ${lib.getExe updaterCtl} rollback "$@"
            '';
            serviceConfig = {
              Type = "oneshot";
              TimeoutStartSec = rollbackTimeoutSec;
            };
          };

          "update-container@" = {
            description = "Update NixOS Container %i (stage + activate)";
            unitConfig.StartLimitIntervalSec = 0;
            path = [ pkgs.systemd ];
            scriptArgs = "%i";
            script = ''
              systemctl start --wait "update-container-stage@$1.service"
              systemctl start --wait "update-container-activate@$1.service"
            '';
            serviceConfig = {
              Type = "oneshot";
              TimeoutStartSec = "infinity";
            };
          };

          "update-containers" = lib.mkIf (nightly != [ ]) {
            description = "Smart bulk update of standalone NixOS containers";
            unitConfig.StartLimitIntervalSec = 0;
            path = [ pkgs.systemd ];
            serviceConfig = {
              Type = "oneshot";
              TimeoutStartSec = "infinity";
            };
            script = ''
              ALL_CONTAINERS=(${lib.escapeShellArgs nightly})
              PHASE2_CONTAINERS=(${lib.escapeShellArgs phase2Containers})
              PHASE3_CONTAINERS=(${lib.escapeShellArgs phase3Containers})
              failed=0
              pids=()

              wait_all() {
                local pid
                for pid in "''${pids[@]}"; do
                  wait "$pid" || failed=1
                done
                pids=()
              }

              needs_activation() {
                [ -e "/run/container-updater/changed-$1" ] && return 0
                machinectl status "$1" >/dev/null 2>&1 && return 1
                return 0
              }

              echo "=== Phase 1: staging updates in parallel ==="
              for c in "''${ALL_CONTAINERS[@]}"; do
                echo "  staging $c..."
                systemctl start --wait "update-container-stage@$c.service" &
                pids+=("$!")
              done
              wait_all

              echo "=== Phase 2: activating changed containers in parallel ==="
              for c in "''${PHASE2_CONTAINERS[@]}"; do
                if needs_activation "$c"; then
                  echo "  activating $c..."
                  systemctl start --wait "update-container-activate@$c.service" &
                  pids+=("$!")
                fi
              done
              wait_all

              for c in "''${PHASE3_CONTAINERS[@]}"; do
                if needs_activation "$c"; then
                  echo "=== Phase 3: activating $c last ==="
                  systemctl start --wait "update-container-activate@$c.service" || failed=1
                fi
              done

              if [ "$failed" -ne 0 ]; then
                echo "Bulk update finished with failures; see update-container-stage@/activate@ logs." >&2
                exit 1
              fi
              echo "Bulk update complete."
            '';
          };

          "container-updater-bootstrap" = lib.mkIf (registered != [ ]) {
            description = "Bootstrap standalone containers that have never been staged";
            after = [ "network-online.target" ];
            wants = [ "network-online.target" ];
            wantedBy = [ "multi-user.target" ];
            path = [ pkgs.systemd ];
            serviceConfig = {
              Type = "oneshot";
              TimeoutStartSec = "infinity";
            };
            script = ''
              for c in ${lib.escapeShellArgs registered}; do
                if [ ! -e "/var/lib/machines/$c/current" ]; then
                  echo "Container $c has no staged closure — bootstrapping..."
                  systemctl start --wait "update-container@$c.service" || \
                    echo "Bootstrap of $c failed; it will retry on the nightly timer." >&2
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

        tmpfiles.rules = [
          "d /nix/var/nix/profiles/containers 0755 root root - -"
          "d /nix/var/nix/gcroots/containers 0755 root root - -"
          "d /run/container-updater 0755 root root - -"
        ];
      };

      # Stage never-deployed containers during live switches before systemd starts
      # container@<name>. Skipped during boot (before impermanence mounts /var/lib/machines).
      system.activationScripts.container-updater-stage-missing = lib.mkIf (registered != [ ]) (
        lib.stringAfter
          [
            "etc"
            "var"
          ]
          ''
            if [ -z "''${IN_NIXOS_SYSTEMD_STAGE1:-}" ] && [ -e /run/current-system ]; then
              for c in ${lib.escapeShellArgs registered}; do
                if [ ! -e "/var/lib/machines/$c/current" ]; then
                  echo "container-updater: $c has no staged closure yet — staging before activation continues..."
                  ${lib.getExe updaterCtl} stage --initial "$c" || \
                    echo "container-updater: staging $c failed during activation; it will retry on the nightly timer or next boot." >&2
                fi
              done
            fi
          ''
      );
    })
  ];
}
