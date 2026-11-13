# Changelog

See [README's Versioning section](README.md#versioning) for what
"breaking" means at this stage (`0.x`).

## Unreleased

**Added:**
- `packages.nix-gantry` (`packages.default`, `overlays.default`) and the
  `nix-gantry` CLI (`publish-manifest`, `status`, `stage`, `activate`,
  `update`, `rollback`, `--help`, `--version`), plus the `publish-manifest`
  compatibility binary and `$out/share/nix-gantry/{lib,modules}`. Installed on
  container hosts by `nixosModules.updater` (`services.nix-gantry.updater.package`).
- Canonical NixOS module options under `services.nix-gantry.{host,updater}`,
  with `lib.mkRenamedOptionModule` aliases from `my.container-host.*` and
  `my.services.container-updater.*`.
- `services.nix-gantry.updater.activateLast` (default `[ "attic" ]`),
  `services.nix-gantry.host.persistPath` (default `"/nix/persist"`),
  `tls.pkiDir` (default `"/nix/persist/pki/internal"`), and optional `cfg`
  overrides for `nameservers`, `gateway`, and `enableAvahi` in `lib.mkContainer`.

**Fixed:**
- `nixosModules.host` and `egress.restrictLan` enable `networking.nftables` via
  `mkDefault true`, so bridge forward rules and `zt-<name>-egress` LAN-drop
  tables are enforced on stock NixOS hosts where `nftables` defaults to `false`.
- Fallback rollbacks via `/var/lib/machines/<name>/previous` update the Nix
  profile before swapping `current`, keeping `/var/lib/machines/<name>/current ->
  /nix/var/nix/profiles/containers/<name>` intact across subsequent stages.
- Initial container staging during live `nixos-rebuild switch` no longer leaves
  `/run/container-updater/changed-<name>` behind to trigger a redundant restart
  at the next nightly run.
- `stage`, `activate`, and `rollback` serialize per container via `flock`,
  validate container names and manifest `/nix/store/` paths, root substituted
  closures with `--add-root` before setting the profile, and fail fast when
  `activate` is called on an unstaged container.
- `publish-manifest` drops the broken ambient `nix-fast-build` branch, rejects
  standalone non-store `.path` configurations with a clear message, and checks
  argument bounds under `set -u`.
- `hostDataDir` and `subDirs` get their mode and owner only when tmpfiles
  creates them. Host activations no longer reset an existing dir to
  `dataDirOwner`/`dataDirGroup` (default 1000:100) under a guest service
  that owns it (postgres, `StateDirectory`, podman storage). Changing
  `dataDirOwner` no longer re-owns an existing dir either.
- `host-persistence` creates a new persisted `hostDataDir` with the
  factory's mode and owner instead of impermanence's root:root default.

**Breaking:**
- `lib.mkContainer` no longer sets `nixpkgs.config.allowUnfree = true` or
  `allowInsecurePredicate` inside guest containers; pass those in `innerConfig`
  or your own `mkContainer` wrapper where needed.
- TLS containers no longer get the shared `client.crt`/`client.key` mounted.
  Upstreams present the container's own certificate since v0.3.0; a guest
  built from v0.2.0 or older needs a host on v0.3.0 until it is updated.

## v0.3.0

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

**Added:**
- `tls.allowedClients`: names of the containers a TLS listener accepts. Others
  with a valid internal-CA certificate get a 403. The name is the client
  certificate's first DNS SAN, so a renewed certificate keeps working. Empty
  (the default) accepts any certificate from the CA, as before.

- `my.container-host.journal.maxUseFor.<name>` overrides the forwarded
  journal's disk cap for one container, e.g. a busy reverse proxy that
  fills the default 256M in a day.
- Container journals reach the host. `lib.mkContainer` passes nspawn
  `--forward-journal`, so each container's journal lands in
  `/var/log/containers/<name>`, survives the ephemeral root's restarts and
  is readable by the `systemd-journal` group with `journalctl -D`. Set by
  `my.container-host.journal.forward` (on with systemd 261 or newer) and
  capped by `my.container-host.journal.maxUse` (default `256M`).
  `nixosModules.host-persistence` persists `/var/log/containers`. Guests
  need systemd 256 or newer; older ones keep their journal inside the
  container as before.

**Changed:**
- TLS upstreams present the container's own certificate instead of the shared
  `client.crt`, so a listener sees which container calls it. Listeners still
  accept any certificate from the internal CA. `client.crt`/`.key` stay
  mounted for guests built before this change and go away in a later release.

**Fixed:**
- A healthcheck command that hangs no longer blocks the rollback. It ran
  without a limit, so systemd killed the activation at the unit's start
  timeout and the bad closure stayed selected. Each run is now limited to
  what is left of `healthcheckTimeoutSec` and counts as failed when killed.
  Healthchecks run with `bash -c` and get the container name in `$CONTAINER`.
- `nixosModules.host` no longer fails with "The option `my.network' does not
  exist" in a config that doesn't declare it, which included the quickstart
  in `examples/`. It still mirrors `subnet` and `hostAddress` there when the
  option exists.
- Podman inside a container works again with journal forwarding on.
  nspawn forks `systemd-journal-remote` before it moves itself into
  `supervisor/`, so the receiver stayed in the unit's top cgroup and nspawn
  couldn't delegate controllers to the guest: crun failed with "controller
  `pids` is not available". `container@` now sets
  `DelegateSubgroup=supervisor`, as systemd's own `systemd-nspawn@.service`
  does.
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
- mTLS upstream listeners bind loopback only. `tls.upstreams.*.port` is
  documented as that local port.
- Evaluation fails with a clear message when a `tls.upstreams` port is used
  twice or collides with the inbound `:443`/`serverPort`, which made Caddy
  reject its config and the sidecar restart in a loop.
- README: with a tmpfs `/var`, `/var/lib/machines` has to be persisted by
  the host; `nixosModules.host-persistence` doesn't do it.

Full diff: [v0.2.0...v0.3.0](https://github.com/kleinbem-dev/nix-gantry/compare/v0.2.0...v0.3.0)

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
