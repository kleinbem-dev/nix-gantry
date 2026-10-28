# Test matrix for the pull-side mechanism (lib.mkContainer +
# nixosModules.updater/.host). Four checks:
#
#   happy-path      full VM integration test: manifest fetch -> realise
#                   -> symlink swap -> container start, on a REAL
#                   container closure built the same way container-factory
#                   builds one (isStandalone=false at build time).
#   bad-manifest    VM integration test: a missing/unfetchable manifest
#                   fails the stage step safely, without crash-looping
#                   past container@'s StartLimitBurst guard.
#   podman-nesting  pure eval-level structural check (no VM -- a podman
#                   image pull needs network access NixOS VM tests don't
#                   have): confirms usesPodman wires the storage bind
#                   mount, CAP_BPF, and /dev/fuse device that authentik's
#                   real "no space left on device" incident depended on.
#   egress-replies  pure eval-level check: egress containment lets replies
#                   to inbound connections out before its LAN drop.
{
  pkgs,
  self,
  inputs,
  lib,
}:
let
  inherit (pkgs) system;

  # Minimal option shim a bare NixOS eval needs before it can import
  # nixosModules.host: it writes my.network.subnet/hostAddress (for
  # other fleet modules to read back, not consumed by this flake
  # itself), so something has to declare them. No my.network.bridge or
  # environment.persistence stub needed anymore -- lib.mkContainer takes
  # hostBridge/gpuRenderNode directly on cfg now (see lib/factory.nix's
  # header comment), and enablePersistence defaults to false.
  shimModule =
    { lib, ... }:
    {
      options.my.network = {
        subnet = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
        hostAddress = lib.mkOption {
          type = lib.types.str;
          default = "";
        };
      };
    };

  demoCfg = {
    ip = "10.233.1.2/24";
    hostBridge = "cbr0";
    # The real-world default. A prior version of this test set this to
    # false to sidestep an apparent boot-time race against
    # container-updater-bootstrap -- that turned out to be a bug in the
    # test itself (see mkHostNode's `imports` comment), not in the
    # module: ConditionPathExists correctly gates container@ from
    # starting before staging, once the test actually wires up the full
    # mkContainer return value instead of just `.containers`.
    autoStart = true;
  };

  demoInnerConfig = {
    system.stateVersion = "25.11";
  };

  # Built once, in isolated (non-standalone) mode: no my.services.container-updater
  # registration in scope, so mkContainer's isStandalone resolves false and
  # .path is a real, buildable NixOS system closure -- exactly how
  # container-factory builds a container's closure for real (standaloneRunner
  # forced off at the factory call site; here it's just never turned on).
  demoFactoryEval = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      shimModule
      (
        { config, ... }:
        {
          inherit
            (self.lib.mkContainer {
              inherit config;
              name = "demo";
              cfg = demoCfg;
              innerConfig = demoInnerConfig;
            })
            containers
            ;
          system.stateVersion = "25.11";
        }
      )
    ];
  };
  demoClosure = demoFactoryEval.config.containers.demo.path;

  manifestFile = pkgs.writeText "manifest.json" (
    builtins.toJSON {
      rev = "test";
      generated = "1970-01-01T00:00:00Z";
      systems = {
        ${system} = {
          demo = "${demoClosure}";
        };
      };
    }
  );

  # The "host" node: a real deployment target, with demo registered as
  # standalone (isStandalone=true -> .path is the runtime symlink the
  # updater swaps) -- the same container definition as demoFactoryEval,
  # just evaluated in a different context.
  mkHostNode =
    { manifestUrl }:
    {
      imports = [
        self.nixosModules.host
        self.nixosModules.updater
        shimModule
        # The WHOLE return value of mkContainer, not just `.containers` --
        # it also carries systemd.services."container@demo".unitConfig
        # (ConditionPathExists, StartLimitBurst, Restart=on-failure) and
        # tmpfiles rules as sibling top-level keys. Extracting only
        # `.containers` (as an earlier version of this test did) silently
        # drops ConditionPathExists, which is exactly why a first draft of
        # this test saw container@demo hit real "No such file or
        # directory" exit-code failures instead of gracefully skipping
        # via the condition -- confirmed live via a dedicated diagnostic
        # test (ConditionResult=yes with no ConditionPathExists= at all in
        # `systemctl cat`). Real presets merge the full return value the
        # same way (see nix-presets/containers/*.nix's `mkMerge [
        # (self.lib.mkContainer {...}) {...} ]` pattern) -- this was a
        # test-harness bug, not a bug in the module itself.
        (
          { config, ... }:
          self.lib.mkContainer {
            inherit config;
            name = "demo";
            cfg = demoCfg;
            innerConfig = demoInnerConfig;
          }
        )
      ];

      my.container-host = {
        enable = true;
        subnet = "10.233.1.0/24";
        hostAddress = "10.233.1.1";
        inherit manifestUrl;
        # enablePersistence and the bridge interface both default
        # correctly now -- nothing to override here.
      };

      my.services.container-updater.containers = [ "demo" ];

      networking.firewall.enable = false;
      system.stateVersion = "25.11";
    };
in
{
  happy-path = pkgs.testers.runNixOSTest {
    name = "nix-gantry-happy-path";
    nodes.host = mkHostNode { manifestUrl = "file://${manifestFile}"; };
    testScript = ''
      start_all()
      host.wait_for_unit("multi-user.target")

      # Full stage+activate: manifest fetch -> realise -> symlink swap
      # -> container start, on a never-before-staged container.
      host.succeed("systemctl start --wait update-container@demo.service")
      host.succeed("test -L /var/lib/machines/demo/current")
      host.wait_for_unit("container@demo.service")
      host.succeed("machinectl status demo")

      # Re-running against an unchanged manifest is a no-op stage (same
      # store path) that still completes without error. (Not asserting
      # machinectl state afterward here -- machinectl restart on an
      # already-running container is a separate behavior from the
      # stage/activate mechanism this test is about.)
      host.succeed("systemctl start --wait update-container@demo.service")
    '';
  };

  bad-manifest = pkgs.testers.runNixOSTest {
    name = "nix-gantry-bad-manifest";
    nodes.host = mkHostNode { manifestUrl = "file:///nonexistent/manifest.json"; };
    testScript = ''
      start_all()
      host.wait_for_unit("multi-user.target")

      # Staging fails cleanly (curl can't read a missing file) --
      # nothing crashes, nothing loops.
      host.fail("systemctl start --wait update-container-stage@demo.service")
      host.succeed("systemctl is-failed update-container-stage@demo.service")

      # No symlink was ever created, so container@demo's
      # ConditionPathExists correctly keeps it stopped rather than
      # crash-looping against a target that doesn't exist.
      host.fail("systemctl is-active container@demo.service")
      host.fail("test -e /var/lib/machines/demo/current")
    '';
  };

  podman-nesting =
    let
      built = self.lib.mkContainer {
        config = {
          my.services.container-updater.containers = [ ];
        };
        name = "demo-podman";
        cfg = {
          ip = "10.233.2.2/24";
          hostBridge = "cbr0";
          hostDataDir = "/var/lib/demo-podman";
        };
        usesPodman = true;
      };
      c = built.containers.demo-podman;
      hasStorageMount = c.bindMounts ? "/var/lib/containers";
      hasBpf = builtins.elem "CAP_BPF" c.additionalCapabilities;
      hasFuseDevice = builtins.any (d: d.node == "/dev/fuse") c.allowedDevices;
      hasContainersSubdir = builtins.any (
        rule: lib.hasInfix "demo-podman/containers" rule
      ) built.systemd.tmpfiles.rules;
    in
    pkgs.runCommand "nix-gantry-podman-nesting-check" { } ''
      ${if hasStorageMount then "" else throw "usesPodman: missing /var/lib/containers bind mount"}
      ${
        if hasBpf then
          ""
        else
          throw "usesPodman: missing CAP_BPF (needed for crun's cgroup-v2 eBPF device management)"
      }
      ${if hasFuseDevice then "" else throw "usesPodman: missing /dev/fuse allowedDevice"}
      ${
        if hasContainersSubdir then
          ""
        else
          throw "usesPodman: missing tmpfiles rule pre-creating hostDataDir/containers"
      }
      touch $out
    '';

  # Pure eval-level check: the egress containment must let replies to
  # inbound connections out before it drops LAN-bound traffic, or a
  # contained container behind Caddy on another host answers nothing (502).
  egress-replies =
    let
      built = self.lib.mkContainer {
        config = {
          my.services.container-updater.containers = [ ];
        };
        name = "demo-egress";
        cfg = {
          ip = "10.233.3.2/24";
          hostBridge = "cbr0";
          egress.restrictLan = true;
        };
      };
      content = built.networking.nftables.tables.zt-demo-egress-egress.content;
      position = needle: lib.stringLength (lib.head (lib.splitString needle content));
      replies = "ct state { established, related } accept";
    in
    pkgs.runCommand "nix-gantry-egress-replies-check" { } ''
      ${if lib.hasInfix replies content then "" else throw "egress: no established/related accept"}
      ${
        if position replies < position "} drop" then
          ""
        else
          throw "egress: the LAN drop comes before the established/related accept"
      }
      touch $out
    '';
}
