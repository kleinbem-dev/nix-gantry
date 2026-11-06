# Tests for lib.mkContainer + nixosModules.updater/.host:
#   happy-path      VM: manifest fetch -> realise -> symlink swap -> start,
#                   on a real factory-built closure; rollback without a
#                   previous generation fails; a closure that doesn't start
#                   is rolled back; the container journal
#                   reaches the host, readable without root, across restarts,
#                   and the guest still gets cgroup controllers (pids for podman).
#   bad-manifest    VM: an unfetchable manifest fails staging, the
#                   container stays stopped and the nightly unit fails.
#   podman-run      VM: podman inside a usesPodman container, with journal
#                   forwarding on, loads a Nix-built image and runs it.
#   podman-nesting  eval only: usesPodman wires the storage mount, CAP_BPF,
#                   /dev/fuse.
#   egress-replies  eval only: egress replies are accepted before the LAN drop.
#   tls-sidecar     eval + caddy adapt: upstream listeners bind loopback and
#                   tls.airlock ends the output and forward chains in a reject.
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
  # Not a NixOS system: a container started on it fails.
  brokenClosure = pkgs.writeText "not-a-system" "";

  # A factory-mode container with an inbound sidecar, one upstream and airlock.
  mkTlsEval =
    innerExtra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        shimModule
        (
          { config, ... }:
          {
            inherit
              (self.lib.mkContainer {
                inherit config;
                name = "demo-tls";
                cfg = {
                  ip = "10.233.4.2/24";
                  hostBridge = "cbr0";
                  tls = {
                    enable = true;
                    serverPort = 8080;
                    upstreams = [
                      {
                        name = "api";
                        target = "10.233.4.3";
                        port = 4000;
                      }
                    ];
                    airlock = true;
                  };
                };
                innerConfig = {
                  system.stateVersion = "25.11";
                }
                // innerExtra;
              })
              containers
              ;
            system.stateVersion = "25.11";
          }
        )
      ];
    };
  tlsInner = (mkTlsEval { }).config.containers.demo-tls.config;
  tlsInnerNoV6 = (mkTlsEval { networking.enableIPv6 = false; }).config.containers.demo-tls.config;

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
        journal.maxUseFor.demo = "64M";
      };

      my.services.container-updater.containers = [ "demo" ];

      users.users.reader = {
        isNormalUser = true;
        extraGroups = [ "systemd-journal" ];
      };

      networking.firewall.enable = false;
      system.extraDependencies = [ brokenClosure ];
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

      # One generation, no `previous`: rollback must fail and leave demo running.
      host.fail("systemctl start --wait update-container-rollback@demo.service")
      host.succeed("systemctl is-active container@demo.service")
      # Nor may it "roll back" to a previous link that is the current closure.
      host.succeed("ln -sfn ${demoClosure} /var/lib/machines/demo/previous")
      host.fail("systemctl start --wait update-container-rollback@demo.service")
      host.succeed("rm /var/lib/machines/demo/previous")

      # A closure that fails to start is rolled back, not left selected.
      profile = "/nix/var/nix/profiles/containers/demo"
      host.succeed(f"nix-env --profile {profile} --set ${brokenClosure}")
      host.fail("systemctl start --wait update-container-activate@demo.service")
      host.succeed(f"test $(readlink -f {profile}) = ${demoClosure}")
      host.wait_for_unit("container@demo.service")
      # This test's restarts add up to container@'s start limit (5 per 15 min).
      host.succeed("systemctl reset-failed container@demo.service")

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

      # With forwarding on, the guest still gets cgroup controllers delegated:
      # podman/crun inside need pids. journal-remote must not sit in the
      # unit's top cgroup, or nspawn can't enable them for payload/.
      cg = "/sys/fs/cgroup/machine.slice/container@demo.service"
      host.succeed(f"test -z \"$(cat {cg}/cgroup.procs)\"")
      host.succeed(f"grep -qw pids {cg}/payload/cgroup.controllers")
      host.succeed(f"grep -qw memory {cg}/payload/cgroup.controllers")

      # journal.maxUseFor overrides the default cap for this one container.
      host.succeed("grep -q -- '--forward-journal-max-use=64M' /etc/nixos-containers/demo.conf")
    '';
  };

  # No network in VM tests, so the image is built here and loaded, not pulled.
  podman-run =
    let
      probeImage = pkgs.dockerTools.buildImage {
        name = "gantry-probe";
        tag = "latest";
        copyToRoot = [ pkgs.busybox ];
        config.Cmd = [
          "/bin/echo"
          "gantry-podman-probe"
        ];
      };
    in
    pkgs.testers.runNixOSTest {
      name = "nix-gantry-podman-run";
      nodes.host = {
        imports = [
          self.nixosModules.host
          self.nixosModules.updater
          shimModule
          (
            { config, ... }:
            self.lib.mkContainer {
              inherit config;
              name = "demo-podman";
              cfg = {
                ip = "10.233.1.3/24";
                hostBridge = "cbr0";
                hostDataDir = "/var/lib/demo-podman";
              };
              usesPodman = true;
              innerConfig = {
                system.stateVersion = "25.11";
                systemd.services.podman-probe = {
                  wantedBy = [ "multi-user.target" ];
                  serviceConfig.Type = "oneshot";
                  serviceConfig.RemainAfterExit = true;
                  path = [ "/run/current-system/sw" ];
                  script = ''
                    podman load -i ${probeImage}
                    podman run --rm --network=none localhost/gantry-probe:latest
                  '';
                };
              };
            }
          )
        ];
        my.container-host = {
          enable = true;
          subnet = "10.233.1.0/24";
          hostAddress = "10.233.1.1";
          # Embedded in the host's closure, so no manifest is ever fetched.
          manifestUrl = "file:///nonexistent";
          excludeFromStandalone = [ "demo-podman" ];
          journal.forward = true;
        };
        virtualisation.memorySize = 2048;
        virtualisation.diskSize = 4096;
        networking.firewall.enable = false;
        system.stateVersion = "25.11";
      };
      testScript = ''
        start_all()
        host.wait_for_unit("container@demo-podman.service", timeout=300)
        host.wait_until_succeeds(
            "systemctl -M demo-podman is-active podman-probe.service", timeout=120
        )
        # The container's own output, from crun inside the nspawn container.
        # Forwarding is asynchronous, so the line can trail the unit state.
        host.wait_until_succeeds(
            "journalctl -D /var/log/containers/demo-podman --no-pager -o cat"
            " | grep -qx gantry-podman-probe",
            timeout=60,
        )
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

      # The nightly run reports the failed stage instead of exiting 0.
      host.fail("systemctl start update-containers.service")
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

  tls-sidecar =
    let
      text = tlsInner.environment.etc."caddy-sidecar/Caddyfile".text;
      textNoV6 = tlsInnerNoV6.environment.etc."caddy-sidecar/Caddyfile".text;
      caddyfile = pkgs.writeText "Caddyfile" text;
      nft = tlsInner.networking.nftables.tables.zt-factory.content;
    in
    pkgs.runCommand "nix-gantry-tls-sidecar-check"
      {
        nativeBuildInputs = [
          pkgs.caddy
          pkgs.jq
        ];
      }
      ''
        ${
          if lib.length (lib.splitString "reject with icmpx type admin-prohibited" nft) == 3 then
            ""
          else
            throw "tls.airlock: output and forward chains must both reject"
        }
        ${
          if lib.hasInfix "[::1]" text && !(lib.hasInfix "[::1]" textNoV6) then
            ""
          else
            throw "tls upstream: [::1] must be bound exactly when IPv6 is on"
        }
        HOME=$TMPDIR caddy adapt --adapter caddyfile --config ${caddyfile} > adapted.json
        # Every :4000 listener must be loopback, and there must be one.
        jq -e '[.apps.http.servers[].listen[] | select(endswith(":4000"))]
          | length > 0 and all(. == "127.0.0.1:4000" or . == "[::1]:4000")' adapted.json \
          || { echo "upstream listener not loopback-only"; jq '[.apps.http.servers[].listen]' adapted.json; exit 1; }
        touch $out
      '';
}
