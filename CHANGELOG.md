# Changelog

See [README's Versioning section](README.md#versioning) for what
"breaking" means at this stage (`0.x`).

## Unreleased

**Added:**
- Container journals reach the host. `lib.mkContainer` passes nspawn
  `--forward-journal`, so each container's journal lands in
  `/var/log/containers/<name>`, survives the ephemeral root's restarts and
  is readable by the `systemd-journal` group with `journalctl -D`. Set by
  `my.container-host.journal.forward` (on with systemd 261 or newer) and
  capped by `my.container-host.journal.maxUse` (default `256M`).
  `nixosModules.host-persistence` persists `/var/log/containers`. Guests
  need systemd 256 or newer; older ones keep their journal inside the
  container as before.

**Breaking:**
- The reusable `publish-manifest.yaml` workflow requires `substituters`
  (was defaulting to `https://cache.nixos.org`, which never holds a
  container closure) and needs `permissions: contents: write` from the
  caller. It runs `publish-manifest` from the caller's locked `nix-gantry`
  input (`gantry-input`, default `nix-gantry`) instead of the caller's own
  flake, which never had the app.

**Fixed:**
- `apps.publish-manifest` checks each `--substituter` with
  `nix path-info --store`. The old `nix build --dry-run` check passed for
  every container, cached or not. Several `--substituter`s now all apply
  (only the last one did), and signature checks are no longer turned off.
- `publish-manifest.yaml` builds a matrix from the `configs` keys (a map
  can't be a matrix), passes inputs through `env:` instead of splicing them
  into scripts, and gives `gh` the repository in the job without a checkout.

## v0.2.0

**Added:**
- README gains [Non-goals](README.md#non-goals) and
  [Versioning](README.md#versioning) sections — a stated scope
  boundary and the SemVer policy this changelog follows.
- `apps.publish-manifest` gets real test coverage for the first time:
  `examples/flake.nix` exposes `nixosConfigurations.quickstart-factory`
  as a fixture, and CI runs the script against it end to end.
- A generated options reference: `packages.options-doc`, committed as
  [`docs/OPTIONS.md`](docs/OPTIONS.md).

**Breaking:**
- `lib.mkContainer`'s `cfg.hostBridge` is now a required field (was
  `cfg.hostBridge or config.my.network.bridge` — this flake no longer
  reads any option path it doesn't declare).
- `cfg.gpuRenderNode` is now required when a container sets
  `enableGPU = true` (previously read from
  `config.my.hardware.gpuRenderNode` unconditionally, with no override).
- `my.container-host.enablePersistence` now defaults to `false` (was
  `true`), and its config moved out of `nixosModules.host` into a
  separate, opt-in `nixosModules.host-persistence` — import it
  explicitly (alongside the external `impermanence` module) if you use
  it. See the module's header comment for why this had to be a real
  module split rather than an `mkIf`.

**Removed:**
- The `git-hooks.nix` flake input. `checks.lint` (a plain
  `pkgs.runCommandLocal` running nixfmt/statix/deadnix/shellcheck
  directly) replaces `checks.pre-commit-check`.

**Fixed:**
- `nixosModules.host` now creates the bridge interface it configures
  firewall rules for (`networking.bridges.${cfg.bridge}.interfaces`,
  via `mkDefault`) — previously referenced but never created.

## v0.1.1

**Fixed:**
- The test suite and `examples/flake.nix` were only importing
  `lib.mkContainer`'s `.containers` key instead of its whole return
  value, silently dropping `systemd.services."container@<name>"`'s
  `unitConfig` (`ConditionPathExists`, `StartLimitBurst`,
  `Restart=on-failure`). This masked whether the mechanism actually
  protects a fresh, never-staged container from racing its own
  boot-time start against staging. No change to `lib/factory.nix`,
  `modules/host.nix`, or `modules/updater.nix` — this was a test/example
  bug, not a module bug.

## v0.1.0

Initial release: `lib.mkContainer`, `nixosModules.updater`/`.host`/
`.default`, `apps.publish-manifest` + reusable
`publish-manifest.yaml` workflow, a 3-check VM/eval test matrix.
