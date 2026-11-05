# Tests for lib.mkContainer + nixosModules.updater/.host:
#   happy-path      VM: manifest fetch -> realise -> symlink swap -> start,
#                   on a real factory-built closure; the container journal
#                   reaches the host, readable without root, across restarts.
#   bad-manifest    VM: an unfetchable manifest fails staging and the
#                   container stays stopped.
#   podman-nesting  eval only (VM tests have no network for image pulls):
#                   usesPodman wires the storage mount, CAP_BPF, /dev/fuse.
#   egress-replies  eval only: egress replies are accepted before the LAN drop.
{
  pkgs,
  self,
  inputs,
  lib,
}:
let
  inherit (pkgs) system;

  # nixosModules.host writes my.network.subnet/hostAddress for other modules to
  # read, but this flake doesn't declare them.
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
    # ConditionPathExists keeps container@ from starting before staging.
    autoStart = true;
  };

  demoInnerConfig = {
    system.stateVersion = "25.11";
    systemd.services.journal-probe = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Type = "oneshot";
      script = "echo gantry-journal-probe";
    };
  };

  # Factory build: no container-updater registration, so isStandalone is false
  # and .path is a real, buildable closure.
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

  # Host node: the same container, registered as standalone, so .path is the
  # symlink the updater swaps.
  mkHostNode =
    { manifestUrl }:
    {
      imports = [
        self.nixosModules.host
        self.nixosModules.updater
        shimModule
        # The whole mkContainer result, not just `.containers`: the container@
        # unitConfig (ConditionPathExists, restart limits) and tmpfiles rules are
        # sibling keys. Without them container@demo fails instead of being skipped.
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
        # Explicit, so a nixpkgs without forwarding fails here instead of skipping.
        journal.forward = true;
      };

      my.services.container-updater.containers = [ "demo" ];

      users.users.reader = {
        isNormalUser = true;
        extraGroups = [ "systemd-journal" ];
      };

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

      # The guest journal is forwarded to the host, readable by the
      # systemd-journal group, and keeps every boot of the ephemeral root:
      # one probe line per container boot, none lost or duplicated.
      import json
      from datetime import timedelta

      def probe_boots():
          out = host.succeed(
              "runuser -u reader -- journalctl -D /var/log/containers/demo"
              " MESSAGE=gantry-journal-probe -o json --no-pager"
          )
          boots = [json.loads(l)["_BOOT_ID"] for l in out.splitlines() if l]
          assert len(boots) == len(set(boots)), f"duplicate probe lines: {boots}"
          return len(boots)

      host.wait_until_succeeds(
          "runuser -u reader -- journalctl -D /var/log/containers/demo"
          " MESSAGE=gantry-journal-probe -q --no-pager | grep -q .",
          timeout=timedelta(seconds=120),
      )
      before = probe_boots()
      host.succeed("machinectl stop demo")
      host.wait_until_fails("systemctl is-active container@demo.service")
      host.succeed("systemctl start container@demo.service")
      host.wait_until_succeeds(
          f"test $(runuser -u reader -- journalctl -D /var/log/containers/demo"
          f" MESSAGE=gantry-journal-probe -q --no-pager | wc -l) -gt {before}",
          timeout=timedelta(seconds=120),
      )
      assert probe_boots() == before + 1
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
