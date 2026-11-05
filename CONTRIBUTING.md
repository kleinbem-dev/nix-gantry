# Contributing

## Running the test matrix locally

```bash
nix flake check
```

This runs `nix fmt`/`statix`/`deadnix`/`shellcheck` (via `checks.lint`)
plus the three checks under `tests/`:

- `happy-path` and `bad-manifest` are full `pkgs.testers.runNixOSTest`
  VM integration tests — expect the first run to take a few minutes
  while it builds a VM image.
- `podman-nesting` is a pure eval-level structural check (no VM — a
  real podman image pull needs network access NixOS VM tests don't
  have by default).

Run a single check directly for faster iteration:

```bash
nix build .#checks.x86_64-linux.happy-path -L
```

## Module option conventions

Every option lives under `my.*`, defaulting to `enable = false` where
applicable — the same "Switchboard" convention `lib.mkContainer` and
`nixosModules.host`/`.updater` already follow. Keep new options
consistent with that shape.

## Options reference

[`docs/OPTIONS.md`](docs/OPTIONS.md) is generated, not hand-written.
After adding or changing an option under `my.container-host.*` or
`my.services.container-updater.*`, regenerate it:

```bash
nix build .#options-doc --no-link --print-out-paths
# copy the printed path's content into docs/OPTIONS.md, keeping the
# generated-file header line
```

## Scope

This flake extracts a specific mechanism (build once in CI, host pulls
an already-cache-verified artifact and swaps it in). Changes that add
fleet-specific assumptions back in — hardcoded IPs, hardcoded release
URLs, a hardcoded catalogue of containers — belong in your own
consuming flake, not here. See README's
[Non-goals](README.md#non-goals) for what this flake deliberately
doesn't take on, and `lib/factory.nix`'s / `modules/host.nix`'s header
comments for the option paths it doesn't read.

## Versioning and PRs

- Keep the test matrix green (`nix flake check`).
- See README's [Versioning](README.md#versioning) section for what
  counts as breaking at this `0.x` stage. If your PR is breaking by
  that definition, say so in the description and add an entry under
  an "unreleased" heading in [`CHANGELOG.md`](CHANGELOG.md).
- Releases are tagged `vX.Y.Z` with a matching GitHub release; the
  changelog entry becomes the release notes.
