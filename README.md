# nix-gantry

CI builds a container closure once. A host fetches a small JSON manifest,
realises the store path from a binary cache, atomically swaps a symlink,
and restarts the container. **The host never evaluates or builds
anything.**

That's the whole mechanism: `lib.mkContainer` declares a
`systemd-nspawn` container whose `path` is a live symlink
(`/var/lib/machines/<name>/current`), and `nixosModules.updater` is the
systemd timer/units that keep that symlink pointed at whatever your CI
last published and cache-verified.

## Why

Plain NixOS `containers.*` embeds a container's full configuration in
your host's own system generation — updating one container means
re-evaluating and re-building (or at least re-deploying) the whole host.
On a fleet with several containers per host and several hosts, that adds
up fast, and it's a hard requirement even for edge devices (a
Raspberry Pi, a router) that would rather not evaluate a flake at all.

nix-gantry decouples the two: build centrally (wherever you have CPU to
spare), publish a manifest, and let hosts pull an already-built,
already-cache-verified artifact on their own schedule — a systemd timer,
not a rebuild.

## How it compares

| | Host evaluates/builds? | Decoupled from host rebuild? | Scope |
|---|---|---|---|
| Plain `containers.*` | Yes, every generation | No | — |
| [`extra-container`](https://github.com/erikarvstedt/extra-container) | Yes, on every `extra-container create`/`--update-changed` | Partially (skips full host eval, but still host-CLI-driven, no remote artifact) | Containers |
| [`nixos-container update --refresh`](https://www.leftfold.tech/posts/nixos-continuous-delivery/) (systemd-timer pull pattern) | Yes, evaluates + builds the container's flake on every cycle | Yes (timer-driven) | Containers |
| [`comin`](https://github.com/nlewo/comin) | Yes, whole-host eval on every deploy | Yes (Git-poll driven) | Whole host, not container-scoped |
| [`microvm.nix`](https://github.com/astro/microvm.nix) | Yes, at build time | Depends on setup | MicroVMs, not nspawn containers |
| **nix-gantry** | **No — zero eval/build on the host** | **Yes** | Containers |

The closest prior art (`extra-container`, and the `nixos-container
update --refresh` pattern) both still build on the host. Neither
publishes a pre-built artifact a host can consume with nothing but
`curl` + `nix-store --realise`. That gap — genuinely no Nix evaluation
on the host at update time — is what nix-gantry is for. It matters
concretely for a fleet with underpowered or ARM hosts (a Pi, a router, a
Jetson) that shouldn't need to evaluate or build anything themselves;
they just pull what a beefier CI runner already built and cache-verified.

## What's in this flake

- **`lib.mkContainer`** — builds a `containers.<name>` block: nspawn
  networking/capabilities/device passthrough, optional podman-in-nspawn
  boilerplate, optional mTLS sidecar, and (when the container's name is
  registered with the updater) the standalone symlink wiring.
- **`nixosModules.updater`** — the systemd timer/units: stage (fetch
  manifest, realise, swap symlink — never touches the running
  container), activate (restart to pick up the staged closure), a bulk
  nightly orchestrator, and a boot-time bootstrap for a container that's
  never been staged.
- **`nixosModules.host`** — per-host glue: bridge/subnet/firewall setup,
  auto-derives the updater's container list from your enabled
  containers.
- **`nixosModules.host-persistence`** — optional, not part of `default`:
  wires enabled containers' `hostDataDir`s into
  [`impermanence`](https://github.com/nix-community/impermanence)'s
  `environment.persistence`. Import it alongside impermanence itself if
  you use it.
- **`nixosModules.default`** — `updater` + `host` composed
  (`host-persistence` is opt-in, see above).
- **`apps.publish-manifest`** — the CI-side half: builds a system's
  containers from a `nixosConfiguration`, verifies each is actually
  cache-reachable (drops anything that isn't rather than blocking), and
  emits a manifest fragment. See
  [`.github/workflows/publish-manifest.yaml`](.github/workflows/publish-manifest.yaml)
  for the reusable workflow that runs this per-system and publishes the
  merged manifest as a GitHub release asset.

## Quickstart

See [`examples/`](examples/) for a minimal flake consuming
`nixosModules.default` end to end, runnable via `nixos-rebuild
build-vm` with no external infrastructure required.

## Options reference

[`docs/OPTIONS.md`](docs/OPTIONS.md) — every `my.container-host.*` and
`my.services.container-updater.*` option, generated from source.

## External requirements

`nixosModules.host` creates the bridge interface it configures firewall
rules for (`networking.bridges.<name>.interfaces = [ ]`, via
`lib.mkDefault` so your own definition wins if you already have one),
and `enablePersistence` defaults to `false` — the external
[`impermanence`](https://github.com/nix-community/impermanence) module
is only required if you opt into it.

`lib.mkContainer` reads no option paths outside what you pass it
directly: `cfg.hostBridge` is a required field (no fallback to a
config path this flake doesn't own), and `cfg.gpuRenderNode` is
required when a container sets `enableGPU = true`. If you want these
to default from your own config (e.g. a fleet-wide
`config.my.network.bridge`), do that at your own call site — see
[`nix-presets`](https://github.com/kleinbem/nix-presets)'s
`mkContainer` re-export for the pattern: it injects fleet-specific
defaults for both fields before calling into this flake's `mkContainer`,
so nix-gantry itself stays option-path-agnostic while the fleet keeps
its own convention.

Every container you build with `lib.mkContainer` should declare its own
options under `my.containers.<name>` (with at least `enable` and, if it
has persistent state, `hostDataDir`) — `nixosModules.host` derives the
updater's container list and persistence directories from that
convention. See [`examples/`](examples/) for a working container preset.

## Non-goals

Things this flake deliberately does not do, so a feature request has
something to check itself against:

- **Build or manage container images/OCI artifacts.** `usesPodman`
  wires nspawn's storage bind-mount correctly; pulling actual images is
  your container's own service config, not this flake's job.
- **Manage secrets.** Bring your own (sops-nix, agenix, ...) and bind-mount
  or pass them in via `cfg.secretsFile`.
- **Own DNS or reverse-proxy config.** A container gets an IP; how
  traffic reaches it is your concern.
- **Orchestrate multi-container application topologies.** One
  `mkContainer` call is one systemd-nspawn container. Dependencies
  between containers are your own `systemd.services.*` wiring, not a
  compose-like graph this flake understands.
- **Run or manage a binary cache.** `apps.publish-manifest` verifies
  cache-reachability against substituters you configure; it doesn't
  stand one up.
- **Provision or bootstrap hosts.** This assumes a running NixOS
  system already exists (disko/nixos-anywhere/etc. are a layer below).

## Versioning

Pre-`1.0`, following the common `0.x` convention: **`0.MINOR` bumps are
breaking, `0.PATCH` bumps are not.** "Breaking" means: a `lib.mkContainer`
argument becomes required or changes meaning, a `my.container-host`/
`my.services.container-updater` option is removed/renamed, or a default
value change alters behavior for an existing consumer who didn't set
that option explicitly (as opposed to, say, a new optional field, a bug
fix, or added test coverage). See [`CHANGELOG.md`](CHANGELOG.md) for
what actually shipped in each release.

## Status

Early (`v0.x`). The mechanism runs a personal NixOS fleet in
production; the module surface may still change before `v1`.

## License

[MIT](LICENSE)
