# Contributing

## Running the test matrix locally

```bash
nix flake check -L
```

This runs `checks.lint` (`nixfmt`, `statix`, `deadnix`, `shellcheck`), builds
`packages.nix-gantry` (including `versionCheckHook`), verifies `docs/OPTIONS.md`
is up to date (`checks.options-doc-freshness`), and runs the VM, evaluation,
and CLI checks in `tests/default.nix`:

- `happy-path`, `health-rollback`, `bad-manifest`, `podman-run`,
  `datadir-ownership`, and `tls-mtls` are full `pkgs.testers.runNixOSTest` VM
  integration tests.
- `quickstart-eval`, `podman-nesting`, `egress-replies`, `tls-sidecar`,
  `updater-timeouts`, `host-persistence`, `option-helpers`, `module-options`,
  and `publish-manifest-cli` are fast sandboxed evaluation and CLI checks.

Run a single check directly for faster iteration:

```bash
nix build .#checks.x86_64-linux.happy-path --no-link -L
```

## Module option conventions

Canonical module options live under `services.nix-gantry.{host,updater}`,
defaulting to `enable = false`. Legacy `my.container-host.*` and
`my.services.container-updater.*` paths are aliased via
`lib.mkRenamedOptionModule` for backwards compatibility.

## Options reference

[`docs/OPTIONS.md`](docs/OPTIONS.md) is generated and checked against drift by
`checks.options-doc-freshness`. After adding or changing an option under
`services.nix-gantry.*`, regenerate it:

```bash
cp --no-preserve=mode "$(nix build .#options-doc --no-link --print-out-paths)" docs/OPTIONS.md
```

## Scope

This flake extracts a specific mechanism (build once in CI, host pulls an
already-cache-verified artifact and swaps it in). Changes that add
fleet-specific assumptions — hardcoded IPs, hardcoded release URLs, unfree or
insecure package exemptions, or a hardcoded catalogue of containers — belong in
your own consuming flake, not here. See README's
[Non-goals](README.md#non-goals).

## Versioning and PRs

- Keep the test matrix green (`nix flake check`).
- Format Nix code with `nix fmt` (RFC 0166 `nixfmt`).
- See README's [Versioning](README.md#versioning) section for what counts as
  breaking at this `0.x` stage, and record changes under `## Unreleased` in
  [`CHANGELOG.md`](CHANGELOG.md).
