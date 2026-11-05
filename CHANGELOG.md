# Changelog

See [README's Versioning section](README.md#versioning) for what
"breaking" means at this stage (`0.x`).

## Unreleased

**Fixed:**
- A guest service that hangs on stop usually no longer gets the whole
  container SIGKILLed. Guest units default to a 45s stop timeout and
  `container@` waits 150s (above postgresql's 120s), so the guest's own
  systemd kills the hung unit first. Stop timeouts are per unit: services
  ordered after each other that all hang can still add up past 150s, so
  raise `container@<name>`'s `TimeoutStopSec` for such a guest. A killed
  nspawn leaves its unix-export mount behind, and the next start failed with
  "Mount point … exists already, refusing" (systemd/systemd#36455). Both
  are `mkDefault`.
- `update-container-activate@` and `update-container-rollback@` count each
  restart as the slowest `container@` stop plus the slowest start, so the
  longer stop can't time out an activation or a rollback. A container with
  `TimeoutStopSec` or `timeoutStartSec` set to `infinity` or `0` makes both
  unbounded; sub-second units (`ms`, `us`) round up instead of failing
  evaluation.

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
  flake, which never had the app. Bump that lock with the workflow ref:
  `trusted-public-keys` needs a `nix-gantry` input from this release.
- `publish-manifest` fails when a substituter can't be queried and paths are
  still unaccounted for, instead of dropping every container from the
  manifest.
- `lib.oidcOptions`' `issuerUrl` has no fallback any more: pass
  `issuerUrl` when importing it, or set the option. It used to default to
  this fleet's `auth.kleinbem.dev`.

**Fixed:**
- `nixosModules.host-persistence` only persists a `hostDataDir` that lives on
  tmpfs. One on a real disk (e.g. `/mnt/data/...`) is already persistent, and
  the bind from `/nix/persist` hid that disk's copy, so the data stayed on the
  root disk.
- `apps.publish-manifest` checks the container's whole closure against the
  `--substituter` caches: every path has to be in one of them. The old
  `nix build --dry-run` check passed for every container, cached or not.
  With `--trusted-public-keys` (workflow input `trusted-public-keys`, your
  hosts' keys) every path also has to carry a signature from one of them;
  content-addressed paths pass unsigned, as they do on the hosts.
  Several `--substituter`s now all apply (only the last one did), and
  signature checks are no longer turned off.
- `publish-manifest.yaml` builds a matrix from the `configs` keys (a map
  can't be a matrix), passes inputs through `env:` instead of splicing them
  into scripts, and gives `gh` the repository in the job without a checkout.
- `update-containers` (the nightly run) fails when any stage or activation
  failed. It exited 0 because a bare `wait` drops background failures.
- `update-container-rollback@` and `autoRollback` report a rollback only
  when one happened. With a single generation and no `previous` link they
  restarted the container and claimed success.
- Healthchecks run with `curl` on `PATH`, so the documented
  `curl -fsS ...` example works instead of always failing and rolling back.
- Staging from the activation script creates `/run/container-updater` and
  the profiles directory itself (tmpfiles hasn't run yet) and runs after
  `etc`, so `nix.conf` is in place.
- `/var/lib/machines/<name>/current` is replaced by rename, and only when it
  doesn't already point at the profile, so a container start never finds it
  missing.
- Activation restarts a running container with `systemctl restart
  container@<name>`, which waits for the new boot. `machinectl restart`
  returned mid-reboot, so the health wait could pass on the old instance.
  A closure that fails to start goes through `autoRollback` like a failed
  healthcheck; before, the script exited and left it selected.
- `update-container-activate@`'s timeout covers two container starts (the
  slowest `timeoutStartSec` of the registered containers) plus
  `healthcheckTimeoutSec`, instead of a fixed 5 minutes that a podman
  container's 15-minute start could outlast. `update-container-rollback@`
  is sized the same way; the wrapper units (`update-container@`,
  `update-containers`, `container-updater-bootstrap`) have no timeout of
  their own, since they only wait on these.
- Rollback refuses a `previous` link that points at the current closure
  instead of "rolling back" to it.
- `nixosModules.host` no longer defines the empty
  `service-container-updater` unit.
- `tls.airlock` is enforced: the container's output chain rejects
  everything but its own /24, loopback, mDNS, IPv6 link-local and the
  `tls.upstreams` targets on 443. It used to accept everything. A forward
  chain applies the same allowlist to what the container routes (rootful
  podman), plus DNAT'd inbound connections.
  `tls.whitelistDomains` is still not enforced, and says so.
- mTLS upstream listeners bind loopback only; they present the shared client
  certificate. `tls.upstreams.*.port` is documented as that local port.
- Evaluation fails with a clear message when a `tls.upstreams` port is used
  twice or collides with the inbound `:443`/`serverPort`, which made Caddy
  reject its config and the sidecar restart in a loop.
- README: with a tmpfs `/var`, `/var/lib/machines` has to be persisted by
  the host; `nixosModules.host-persistence` doesn't do it.

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
