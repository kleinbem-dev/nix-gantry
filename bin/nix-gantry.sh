#!/usr/bin/env bash
set -euo pipefail

VERSION="@version@"

usage() {
  cat <<'EOF'
Usage:
  nix-gantry <command> [options]

Commands:
  publish-manifest   Build & cache-verify a system's containers and emit JSON
  status             Show container state, active closures, and pending restarts
  stage <name...>    Fetch manifest and stage closure(s) without restarting
  activate <name...> Restart container(s) onto staged closure with healthcheck
  update [name...]   Stage + activate container(s), or run bulk nightly update
  rollback <name>    Roll back a container to its previous generation

Options:
  -h, --help         Show this help message
  -V, --version      Show version information
EOF
}

publish_usage() {
  cat <<'EOF'
Usage:
  nix-gantry publish-manifest --flake-ref <ref> --config <nixosConfiguration> \
    --system <system> [--substituter <url> ...] [--trusted-public-keys "<key> ..."]
EOF
}

validate_container() {
  if [[ -z "${1:-}" || ! "$1" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "nix-gantry: invalid container name '${1:-}'" >&2
    exit 1
  fi
}

# Paths among "$@" that store $1 has; handles both Nix JSON output shapes.
# Fails if the store cannot be queried; missing paths alone do not fail it.
present_in() {
  local store=$1 info
  shift
  info=$(nix path-info --store "$store" --json "$@" 2>/dev/null) || return 1
  jq -r 'if type == "array" then .[] | select(.valid != false) | .path
         else to_entries[] | select(.value != null) | .key end' <<<"$info"
}

verify_sigs() {
  local store=$1 keys=$2
  shift 2
  nix store verify --store "$store" --no-contents --sigs-needed 1 \
    --trusted-public-keys "$keys" "$@" >/dev/null 2>&1
}

# Paths among "$@" in store $1 signed by one of $2 (keys).
trusted_in() {
  local store=$1 keys=$2 p
  shift 2
  [ $# -gt 0 ] || return 0
  if verify_sigs "$store" "$keys" "$@"; then
    printf '%s\n' "$@"
  else
    for p in "$@"; do
      if verify_sigs "$store" "$keys" "$p"; then
        printf '%s\n' "$p"
      fi
    done
  fi
}

# True if every path of $1's closure is in (and, with keys, trusted by) at least
# one substituter. Returns 2 if paths remain and a substituter was unreachable.
closure_cached() {
  local target=$1 keys=$2
  shift 2
  local -a substituters=("$@") missing ok unreachable=()
  local closure s out left

  closure=$(nix path-info --recursive "$target") || return 1
  if [ -z "$closure" ]; then
    return 0
  fi
  mapfile -t missing <<<"$closure"

  for s in "${substituters[@]}"; do
    [ "${#missing[@]}" -gt 0 ] || break
    if ! out=$(present_in "$s" "${missing[@]}"); then
      unreachable+=("$s")
      continue
    fi
    if [ -z "$out" ]; then
      ok=()
    else
      mapfile -t ok <<<"$out"
    fi
    if [ -n "$keys" ] && [ "${#ok[@]}" -gt 0 ]; then
      out=$(trusted_in "$s" "$keys" "${ok[@]}")
      if [ -z "$out" ]; then
        ok=()
      else
        mapfile -t ok <<<"$out"
      fi
    fi
    if [ "${#ok[@]}" -gt 0 ]; then
      left=$(comm -23 <(printf '%s\n' "${missing[@]}" | sort -u) \
        <(printf '%s\n' "${ok[@]}" | sort -u))
      if [ -z "$left" ]; then
        missing=()
      else
        mapfile -t missing <<<"$left"
      fi
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    if [ "${#unreachable[@]}" -gt 0 ]; then
      echo "  could not query ${unreachable[*]}" >&2
      return 2
    fi
    echo "  ${#missing[@]} closure paths missing or untrusted, e.g. ${missing[0]}" >&2
    return 1
  fi
}

cmd_publish_manifest() {
  local flake_ref="" config="" system="" trusted_keys=""
  local -a substituters=() substituter_args=() names=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        publish_usage
        return 0
        ;;
      -V|--version)
        echo "nix-gantry $VERSION"
        return 0
        ;;
      --flake-ref)
        [ $# -ge 2 ] || { echo "publish-manifest: --flake-ref requires a value" >&2; exit 1; }
        flake_ref=$2
        shift 2
        ;;
      --config)
        [ $# -ge 2 ] || { echo "publish-manifest: --config requires a value" >&2; exit 1; }
        config=$2
        shift 2
        ;;
      --system)
        [ $# -ge 2 ] || { echo "publish-manifest: --system requires a value" >&2; exit 1; }
        system=$2
        shift 2
        ;;
      --substituter)
        [ $# -ge 2 ] || { echo "publish-manifest: --substituter requires a value" >&2; exit 1; }
        substituters+=("$2")
        shift 2
        ;;
      --trusted-public-keys)
        [ $# -ge 2 ] || { echo "publish-manifest: --trusted-public-keys requires a value" >&2; exit 1; }
        trusted_keys=$2
        shift 2
        ;;
      *)
        echo "publish-manifest: unknown argument '$1'" >&2
        exit 1
        ;;
    esac
  done

  if [ -z "$flake_ref" ] || [ -z "$config" ] || [ -z "$system" ]; then
    echo "publish-manifest: --flake-ref, --config and --system are required" >&2
    exit 1
  fi

  local config_attr="${flake_ref}#nixosConfigurations.${config}.config.containers"
  echo "Evaluating container names from ${config_attr}..." >&2
  local names_json
  names_json=$(nix eval --json "${config_attr}" --apply builtins.attrNames)
  if [ "$names_json" != "[]" ]; then
    mapfile -t names < <(jq -r '.[]' <<<"$names_json")
  fi

  # Pass all extra-substituters in one option; repeated --option keeps only the last.
  if [ "${#substituters[@]}" -gt 0 ]; then
    substituter_args=(--option extra-substituters "${substituters[*]}")
  fi

  local fragment="{}" name path_attr store_path rc
  for name in "${names[@]}"; do
    path_attr="${flake_ref}#nixosConfigurations.${config}.config.containers.\"${name}\".path"

    echo "Building ${name}..." >&2
    nix build --no-link "${path_attr}" "${substituter_args[@]}" || {
      echo "  ${name}: build failed, skipping" >&2
      continue
    }

    store_path=$(nix eval --raw "${path_attr}")
    if [[ ! "$store_path" =~ ^/nix/store/[a-z0-9]{32}-[^/]+$ ]]; then
      echo "error: ${name}.path resolved to '${store_path}', not a /nix/store path (pass a factory nixosConfiguration, not a standalone host)" >&2
      exit 1
    fi

    # Query remote caches directly; the local store already holds what we just built.
    if [ "${#substituters[@]}" -gt 0 ]; then
      echo "Verifying ${name}'s closure is cache-reachable..." >&2
      rc=0
      closure_cached "$store_path" "$trusted_keys" "${substituters[@]}" || rc=$?
      if [ "$rc" -eq 2 ]; then
        echo "error: substituter unreachable, not publishing a fragment" >&2
        exit 1
      elif [ "$rc" -ne 0 ]; then
        echo "  ${name}: not fully in the substituters, dropping from this fragment" >&2
        continue
      fi
    else
      echo "  ${name}: no --substituter given, cache check skipped" >&2
    fi

    fragment=$(jq --arg n "$name" --arg p "$store_path" '. + {($n): $p}' <<<"$fragment")
  done

  jq -n --arg sys "$system" --argjson containers "$fragment" '{($sys): $containers}'
}

cmd_status() {
  local json=0 root=""
  local -a containers=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        echo "Usage: nix-gantry status [--json] [--root <dir>] [container...]"
        return 0
        ;;
      --json)
        json=1
        shift
        ;;
      --root)
        [ $# -ge 2 ] || { echo "nix-gantry status: --root requires a value" >&2; exit 1; }
        root=$2
        shift 2
        ;;
      -*)
        echo "nix-gantry status: unknown option '$1'" >&2
        exit 1
        ;;
      *)
        validate_container "$1"
        containers+=("$1")
        shift
        ;;
    esac
  done

  if [ "${#containers[@]}" -eq 0 ]; then
    local discovered="" f b
    for f in "${root}/etc/nixos-containers/"*.conf; do
      [ -e "$f" ] || continue
      b=$(basename "$f" .conf)
      discovered+="${b}"$'\n'
    done
    for f in "${root}/var/lib/machines/"*; do
      [ -d "$f" ] || continue
      if [ -L "$f/current" ] || [ -L "$f/previous" ]; then
        b=$(basename "$f")
        discovered+="${b}"$'\n'
      fi
    done
    for f in "${root}/nix/var/nix/profiles/containers/"*; do
      [ -L "$f" ] || continue
      b=$(basename "$f")
      [[ "$b" =~ -[0-9]+-link$ ]] && continue
      discovered+="${b}"$'\n'
    done
    if [ -n "$discovered" ]; then
      mapfile -t containers < <(printf '%s' "$discovered" | sort -u)
    fi
  fi

  local items="[]" c state cur prev pending
  for c in "${containers[@]}"; do
    if [ -z "$root" ] && command -v systemctl >/dev/null 2>&1; then
      state=$(systemctl is-active "container@${c}.service" 2>/dev/null || true)
      [ -n "$state" ] || state="unknown"
    else
      state="unknown"
    fi
    cur=""
    if [ -e "${root}/var/lib/machines/${c}/current" ]; then
      cur=$(readlink -f -- "${root}/var/lib/machines/${c}/current")
    fi
    prev=""
    if [ -e "${root}/var/lib/machines/${c}/previous" ]; then
      prev=$(readlink -f -- "${root}/var/lib/machines/${c}/previous")
    fi
    pending="false"
    if [ -e "${root}/run/container-updater/changed-${c}" ]; then
      pending="true"
    fi
    items=$(jq \
      --arg name "$c" \
      --arg state "$state" \
      --arg cur "$cur" \
      --arg prev "$prev" \
      --argjson pending "$pending" \
      '. + [{
        name: $name,
        state: $state,
        pendingRestart: $pending,
        current: (if $cur == "" then null else $cur end),
        previous: (if $prev == "" then null else $prev end)
      }]' <<<"$items")
  done

  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$items"
    return 0
  fi

  if [ "${#containers[@]}" -eq 0 ]; then
    echo "No nix-gantry containers found."
    return 0
  fi

  printf '%-20s %-12s %-9s %s\n' "CONTAINER" "STATE" "PENDING" "CURRENT"
  jq -r '.[] | [
    .name,
    .state,
    (if .pendingRestart then "yes" else "no" end),
    (.current // "-")
  ] | @tsv' <<<"$items" | while IFS=$'\t' read -r c state pending cur; do
    printf '%-20s %-12s %-9s %s\n' "$c" "$state" "$pending" "$cur"
  done
}

cmd_unit_action() {
  local action=$1 unit_prefix=$2
  shift 2
  if [ $# -eq 0 ]; then
    echo "Usage: nix-gantry ${action} <container...>" >&2
    exit 1
  fi
  local c
  for c in "$@"; do
    validate_container "$c"
  done
  for c in "$@"; do
    systemctl start --wait "${unit_prefix}@${c}.service"
  done
}

case "${1:-}" in
  -h|--help|help)
    usage
    ;;
  -V|--version|version)
    echo "nix-gantry $VERSION"
    ;;
  publish-manifest)
    shift
    cmd_publish_manifest "$@"
    ;;
  status)
    shift
    cmd_status "$@"
    ;;
  stage)
    shift
    cmd_unit_action stage update-container-stage "$@"
    ;;
  activate)
    shift
    cmd_unit_action activate update-container-activate "$@"
    ;;
  update)
    shift
    if [ $# -eq 0 ]; then
      systemctl start --wait update-containers.service
    else
      cmd_unit_action update update-container "$@"
    fi
    ;;
  rollback)
    shift
    if [ $# -ne 1 ]; then
      echo "Usage: nix-gantry rollback <container>" >&2
      exit 1
    fi
    validate_container "$1"
    systemctl start --wait "update-container-rollback@$1.service"
    ;;
  "")
    usage >&2
    exit 1
    ;;
  *)
    echo "nix-gantry: unknown command '$1'" >&2
    usage >&2
    exit 1
    ;;
esac
