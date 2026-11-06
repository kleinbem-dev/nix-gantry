#!/usr/bin/env bash
# publish-manifest: build one system's containers from a nixosConfiguration's
# `config.containers` and print { "<system>": { "<name>": "<store-path>" } }.
# A container goes in only if every path of its closure is in one of the
# --substituter caches and, with --trusted-public-keys (the hosts' keys), is
# signed by one of them (content-addressed paths need no signature, as on the
# hosts). Anything else is skipped (logged to stderr) instead of
# failing the run, unless a substituter can't be queried at all: then the run
# fails, so an outage never publishes an emptied manifest. Without
# --substituter the cache check is skipped.
# ../.github/workflows/publish-manifest.yaml merges the per-system fragments
# and publishes the manifest.
#
# Usage:
#   publish-manifest --flake-ref <ref> --config <nixosConfiguration-name> \
#     --system <system> [--substituter <url> ...] [--trusted-public-keys "<key> ..."]
set -euo pipefail

FLAKE_REF=""
CONFIG=""
SYSTEM=""
SUBSTITUTERS=()
TRUSTED_KEYS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --flake-ref) FLAKE_REF="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --system) SYSTEM="$2"; shift 2 ;;
    --substituter) SUBSTITUTERS+=("$2"); shift 2 ;;
    --trusted-public-keys) TRUSTED_KEYS="$2"; shift 2 ;;
    *) echo "publish-manifest: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$FLAKE_REF" ] || [ -z "$CONFIG" ] || [ -z "$SYSTEM" ]; then
  echo "publish-manifest: --flake-ref, --config and --system are required" >&2
  exit 1
fi

CONFIG_ATTR="${FLAKE_REF}#nixosConfigurations.${CONFIG}.config.containers"

echo "Evaluating container names from ${CONFIG_ATTR}..." >&2
CONTAINER_NAMES=$(nix eval --json "${CONFIG_ATTR}" --apply builtins.attrNames)

# One extra-substituters value: a repeated --option keeps only the last.
# Signatures stay checked against the trusted-public-keys in nix.conf.
SUBSTITUTER_ARGS=()
if [ "${#SUBSTITUTERS[@]}" -gt 0 ]; then
  SUBSTITUTER_ARGS=(--option extra-substituters "${SUBSTITUTERS[*]}")
fi
# Paths among "$@" that store $1 has; handles both path-info --json layouts.
# Fails if the store can't be queried; missing paths alone don't fail it.
present_in() {
  local store=$1 info
  shift
  info=$(nix path-info --store "$store" --json "$@" 2>/dev/null) || return 1
  jq -r 'if type == "array" then .[] | select(.valid != false) | .path
         else to_entries[] | select(.value != null) | .key end' <<<"$info"
}

# Paths among "$@" that store $1 has signed with one of TRUSTED_KEYS.
trusted_in() {
  local store=$1 p
  shift
  [ $# -gt 0 ] || return 0
  verify() {
    nix store verify --store "$store" --no-contents --sigs-needed 1 \
      --trusted-public-keys "$TRUSTED_KEYS" "$@" >/dev/null 2>&1
  }
  # One batch call; per path only to find the culprits.
  if verify "$@"; then
    printf '%s\n' "$@"
  else
    for p in "$@"; do
      if verify "$p"; then echo "$p"; fi
    done
  fi
}

# True if every path of $1's closure is in (and, with keys, trusted by) at
# least one substituter. The host realises the whole closure, not just $1.
# Returns 2 if paths are left over and a substituter couldn't be queried:
# that's an outage, not a missing container.
closure_cached() {
  local s closure out unreachable=()
  local -a missing ok
  closure=$(nix path-info --recursive "$1") || return 1
  mapfile -t missing <<<"$closure"
  for s in "${SUBSTITUTERS[@]}"; do
    [ "${#missing[@]}" -gt 0 ] || break
    if ! out=$(present_in "$s" "${missing[@]}"); then
      unreachable+=("$s")
      continue
    fi
    mapfile -t ok < <(printf '%s' "$out" | sed '/^$/d')
    if [ -n "$TRUSTED_KEYS" ]; then
      mapfile -t ok < <(trusted_in "$s" "${ok[@]}")
    fi
    mapfile -t missing < <(comm -23 <(printf '%s\n' "${missing[@]}" | sort) \
      <(printf '%s\n' "${ok[@]}" | sort) | sed '/^$/d')
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

FRAGMENT="{}"
for name in $(echo "$CONTAINER_NAMES" | jq -r '.[]'); do
  path_attr="${FLAKE_REF}#nixosConfigurations.${CONFIG}.config.containers.\"${name}\".path"

  echo "Building ${name}..." >&2
  if command -v nix-fast-build >/dev/null 2>&1; then
    nix-fast-build --flake "${path_attr}" "${SUBSTITUTER_ARGS[@]}" >&2 || {
      echo "  ${name}: build failed, skipping" >&2
      continue
    }
  else
    nix build --no-link "${path_attr}" "${SUBSTITUTER_ARGS[@]}" || {
      echo "  ${name}: build failed, skipping" >&2
      continue
    }
  fi

  store_path=$(nix eval --raw "${path_attr}")

  # Ask the caches themselves: the local build just made the path valid here,
  # so anything that looks at the local store always says yes.
  if [ "${#SUBSTITUTERS[@]}" -gt 0 ]; then
    echo "Verifying ${name}'s closure is cache-reachable..." >&2
    rc=0
    closure_cached "$store_path" || rc=$?
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
  FRAGMENT=$(echo "$FRAGMENT" | jq --arg n "$name" --arg p "$store_path" '. + {($n): $p}')
done

jq -n --arg sys "$SYSTEM" --argjson containers "$FRAGMENT" '{($sys): $containers}'
