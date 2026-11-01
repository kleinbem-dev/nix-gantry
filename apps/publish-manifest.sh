#!/usr/bin/env bash
# publish-manifest: build one system's containers from a nixosConfiguration's
# `config.containers` and print { "<system>": { "<name>": "<store-path>" } }.
# A container that fails to build or isn't cache-reachable is skipped (logged
# to stderr) instead of failing the run. ../.github/workflows/publish-manifest.yaml
# merges the per-system fragments and publishes the manifest.
#
# Usage:
#   publish-manifest --flake-ref <ref> --config <nixosConfiguration-name> \
#     --system <system> [--substituter <url> ...]
set -euo pipefail

FLAKE_REF=""
CONFIG=""
SYSTEM=""
SUBSTITUTERS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --flake-ref) FLAKE_REF="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;
    --system) SYSTEM="$2"; shift 2 ;;
    --substituter) SUBSTITUTERS+=("$2"); shift 2 ;;
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

SUBSTITUTER_ARGS=()
for s in "${SUBSTITUTERS[@]:-}"; do
  [ -n "$s" ] && SUBSTITUTER_ARGS+=(--option substituters "$s" --option require-sigs false)
done

FRAGMENT="{}"
for name in $(echo "$CONTAINER_NAMES" | jq -r '.[]'); do
  path_attr="${FLAKE_REF}#nixosConfigurations.${CONFIG}.config.containers.\"${name}\".path"

  echo "Building ${name}..." >&2
  if command -v nix-fast-build >/dev/null 2>&1; then
    nix-fast-build --flake "${path_attr}" "${SUBSTITUTER_ARGS[@]}" || {
      echo "  ${name}: build failed, skipping" >&2
      continue
    }
  else
    nix build --no-link "${path_attr}" "${SUBSTITUTER_ARGS[@]}" || {
      echo "  ${name}: build failed, skipping" >&2
      continue
    }
  fi

  echo "Verifying ${name} is cache-reachable..." >&2
  if ! nix build --dry-run "${path_attr}" "${SUBSTITUTER_ARGS[@]}" 2>/dev/null; then
    echo "  ${name}: not yet cache-verified, dropping from this fragment" >&2
    continue
  fi

  store_path=$(nix eval --raw "${path_attr}")
  FRAGMENT=$(echo "$FRAGMENT" | jq --arg n "$name" --arg p "$store_path" '. + {($n): $p}')
done

jq -n --arg sys "$SYSTEM" --argjson containers "$FRAGMENT" '{($sys): $containers}'
