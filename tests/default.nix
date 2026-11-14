# Tests for lib.mkContainer + nixosModules.updater/.host/.host-persistence + CLI:
#   happy-path            VM: manifest fetch -> realise -> symlink swap -> start,
#                         on a real factory-built closure; rollback without a
#                         previous generation fails; a closure that doesn't start
#                         is rolled back; the container journal reaches the host,
#                         readable without root, across restarts, and the guest
#                         still gets cgroup controllers (pids for podman).
#   health-rollback       VM: a closure that boots but fails its healthcheck (or
#                         hangs past budget) is rolled back to the healthy one.
#   bad-manifest          VM: unfetchable, malformed-JSON, and missing-entry
#                         manifests fail staging, keep the container stopped, and
#                         fail the nightly bulk unit.
#   podman-run            VM: podman inside a usesPodman container, with journal
#                         forwarding on, loads a Nix-built image and runs it.
#   datadir-ownership     VM: hostDataDir and subDirs are created with the
#                         configured owner, and a host tmpfiles run leaves the
#                         owner/mode a guest service gave them alone.
#   tls-mtls              VM: one container calls another over mTLS with its own
#                         cert; the listener refuses no cert and a foreign CA's,
#                         and answers 403 to a name not in tls.allowedClients.
#   quickstart-eval       eval: examples/flake.nix quickstart VM evaluates cleanly.
#   podman-nesting        eval: usesPodman wires storage mount, CAP_BPF, /dev/fuse.
#   egress-replies        eval: egress replies are accepted before the LAN drop.
#   tls-sidecar           eval + caddy adapt: upstream listeners bind loopback and
#                         tls.airlock ends the output and forward chains in a reject.
#   updater-timeouts      eval: systemd duration parser, sub-second rounding,
#                         unbounded limits, and invalid timeout rejection.
#   host-persistence      eval: onTmpfs longest-mount-prefix matching, owner/mode
#                         forwarding, disabled-container filtering, journal dir.
#   option-helpers        eval: tlsOptions, oidcOptions, egressOptions, TLS port
#                         assertions, mkContainer input assertions, hardware/limits.
#   module-options        eval: legacy my.* -> services.nix-gantry.* aliases,
#                         activateLast partitioning, pkiDir/DNS/avahi/unfree hygiene.
#   publish-manifest-cli  sandbox check: nix-gantry CLI (--version/--help/status) +
#                         publish-manifest mock-store union, sigs, and failure modes.
#   options-doc-freshness check: docs/OPTIONS.md matches packages.options-doc.
{
  pkgs,
  self,
  inputs,
  lib,
}:
let
  inherit (pkgs.stdenv.hostPlatform) system;

  # nixosModules.host mirrors subnet/hostAddress into my.network where a config
  # declares it, as here. quickstart-eval covers a config without it.
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
    # What the health-rollback test's healthcheck looks for.
    systemd.services.health-marker = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = "true";
    };
  };

  # Factory build: no container-updater registration, so isStandalone is false
  # and .path is a real, buildable closure.
  mkDemoClosure =
    innerConfig:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        shimModule
        (
          { config, ... }:
          {
            inherit
              (self.lib.mkContainer {
                inherit config innerConfig;
                name = "demo";
                cfg = demoCfg;
              })
              containers
              ;
            system.stateVersion = "25.11";
          }
        )
      ];
    }).config.containers.demo.path;
  demoClosure = mkDemoClosure demoInnerConfig;
  # Boots fine, but without health-marker its healthcheck never passes.
  unhealthyClosure = mkDemoClosure (
    lib.recursiveUpdate demoInnerConfig { systemd.services.health-marker.enable = false; }
  );
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
                    allowedClients = [ "web" ];
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

  # Certificates shaped like nix-config's pki.nix: CN and SAN = the name, no EKU.
  # foreign.crt comes from another CA.
  testPki = pkgs.runCommand "nix-gantry-test-pki" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out/certs
    openssl req -new -x509 -nodes -days 3650 -subj "/CN=Test CA" \
      -keyout $out/ca.key -out $out/ca.crt
    openssl req -new -x509 -nodes -days 3650 -subj "/CN=Foreign CA" \
      -keyout foreign.key -out foreign.crt
    sign() { # name, CA cert, CA key, output basename
      openssl req -new -nodes -subj "/CN=$1/O=kleinbem" \
        -addext "subjectAltName=DNS:$1" -keyout $out/certs/$4.key -out $1.csr
      openssl x509 -req -in $1.csr -CA $2 -CAkey $3 -CAcreateserial -days 3650 \
        -extfile <(echo "subjectAltName=DNS:$1") -out $out/certs/$4.crt
    }
    sign api $out/ca.crt $out/ca.key api
    sign caller $out/ca.crt $out/ca.key caller
    sign other $out/ca.crt $out/ca.key other
    sign foreign foreign.crt foreign.key foreign
    chmod 644 $out/certs/*
  '';

  mkTlsContainer =
    name: cfg: innerConfig:
    { config, ... }:
    self.lib.mkContainer {
      inherit config name;
      cfg = {
        hostBridge = "cbr0";
        autoStart = true;
      }
      // cfg;
      innerConfig = {
        system.stateVersion = "25.11";
      }
      // innerConfig;
    };

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
    {
      manifestUrl,
      healthchecks ? { },
    }:
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

      services.nix-gantry = {
        host = {
          enable = true;
          subnet = "10.233.1.0/24";
          hostAddress = "10.233.1.1";
          inherit manifestUrl;
          # Explicit, so a nixpkgs without forwarding fails here instead of skipping.
          journal.forward = true;
          journal.maxUseFor.demo = "64M";
        };
        updater = {
          containers = [ "demo" ];
          inherit healthchecks;
        };
      };

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
      import json
      from datetime import timedelta

      start_all()
      host.wait_for_unit("multi-user.target")

      # Host CLI installed by nixosModules.updater: stage+activate via `nix-gantry update`.
      host.succeed("nix-gantry --version")
      host.succeed("nix-gantry update demo")
      host.succeed("test -L /var/lib/machines/demo/current")
      host.wait_for_unit("container@demo.service")
      host.succeed("machinectl status demo")

      status = json.loads(host.succeed("nix-gantry status --json demo"))
      assert len(status) == 1 and status[0]["name"] == "demo", status
      assert status[0]["state"] == "active" and status[0]["pendingRestart"] is False, status
      assert status[0]["current"] == "${demoClosure}", status
      host.succeed("nix-gantry status | grep -q '^demo '")

      # Re-running against an unchanged manifest is a no-op stage (same
      # store path) that still completes without error.
      host.succeed("nix-gantry update demo")

      # One generation, no `previous`: rollback must fail and leave demo running.
      host.fail("nix-gantry rollback demo")
      host.succeed("systemctl is-active container@demo.service")
      # Nor may it "roll back" to a previous link that is the current closure.
      host.succeed("ln -sfn ${demoClosure} /var/lib/machines/demo/previous")
      host.fail("nix-gantry rollback demo")
      host.succeed("rm /var/lib/machines/demo/previous")

      # A closure that fails to start is rolled back via Nix profile generation.
      profile = "/nix/var/nix/profiles/containers/demo"
      host.succeed(f"nix-env --profile {profile} --set ${brokenClosure}")
      host.fail("nix-gantry activate demo")
      host.succeed(f"test $(readlink -f {profile}) = ${demoClosure}")
      host.wait_for_unit("container@demo.service")

      # Staging over a different closure roots `previous` under /nix/var/nix/gcroots/containers
      # and cleans up its temporary `/run/container-updater/gcroot-demo` link.
      host.succeed(f"nix-env --profile {profile} --set ${brokenClosure}")
      host.succeed("nix-gantry stage demo")
      host.succeed("test $(readlink -f /var/lib/machines/demo/previous) = ${brokenClosure}")
      host.succeed("test $(readlink -f /nix/var/nix/gcroots/containers/demo-previous) = ${brokenClosure}")
      host.fail("test -e /run/container-updater/gcroot-demo")

      # `demo-previous` keeps an otherwise unreferenced store path alive across `nix-store --gc`,
      # while activation reconciles stale `*-previous` roots for removed containers.
      kept = host.succeed("echo kept > /tmp/kept && nix-store --add /tmp/kept").strip()
      stale = host.succeed("echo stale > /tmp/stale && nix-store --add /tmp/stale").strip()
      host.succeed(f"ln -sfn {kept} /nix/var/nix/gcroots/containers/demo-previous")
      host.succeed(f"ln -sfn {stale} /nix/var/nix/gcroots/containers/removed-previous")
      host.succeed("nix-store --gc >/dev/null")
      host.succeed(f"test -e {kept} && test -e {stale}")
      host.succeed("/run/current-system/activate")
      host.fail("test -L /nix/var/nix/gcroots/containers/removed-previous")
      host.succeed("nix-store --gc >/dev/null")
      host.succeed(f"test -e {kept}")
      host.fail(f"test -e {stale}")

      # Fallback rollback via `previous` symlink (when older profile generations were GC'd)
      # must preserve `/var/lib/machines/demo/current -> profile` and recover even after
      # `container@demo.service` hits its 5-starts-per-15m burst limit.
      host.succeed("ln -sfn ${demoClosure} /var/lib/machines/demo/previous")
      host.succeed("ln -sfn ${demoClosure} /nix/var/nix/gcroots/containers/demo-previous")
      host.succeed(f"nix-env --profile {profile} --set ${brokenClosure}")
      host.succeed(f"nix-env --profile {profile} --delete-generations old")
      for _ in range(5):
          host.fail("systemctl restart container@demo.service")
      host.fail("nix-gantry activate demo")
      host.succeed(f"test $(readlink /var/lib/machines/demo/current) = {profile}")
      host.succeed(f"test $(readlink -f {profile}) = ${demoClosure}")
      host.wait_for_unit("container@demo.service")

      # Manual `nix-gantry rollback` also clears start-limit-hit before restarting.
      host.succeed(f"nix-env --profile {profile} --set ${brokenClosure}")
      for _ in range(5):
          host.fail("systemctl restart container@demo.service")
      host.succeed("nix-gantry rollback demo")
      host.wait_for_unit("container@demo.service")

      # The guest journal is forwarded to the host, readable by the
      # systemd-journal group, and keeps every boot of the ephemeral root:
      # one probe line per container boot, none lost or duplicated.

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
        services.nix-gantry.host = {
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
        from datetime import timedelta

        start_all()
        host.wait_for_unit("container@demo-podman.service", timeout=timedelta(seconds=300))
        host.wait_until_succeeds(
            "systemctl -M demo-podman is-active podman-probe.service",
            timeout=timedelta(seconds=120),
        )
        # The container's own output, from crun inside the nspawn container.
        # Forwarding is asynchronous, so the line can trail the unit state.
        host.wait_until_succeeds(
            "journalctl -D /var/log/containers/demo-podman --no-pager -o cat"
            " | grep -qx gantry-podman-probe",
            timeout=timedelta(seconds=60),
        )
      '';
    };

  datadir-ownership = pkgs.testers.runNixOSTest {
    name = "nix-gantry-datadir-ownership";
    nodes.host = {
      imports = [
        self.nixosModules.host
        self.nixosModules.updater
        shimModule
        (
          { config, ... }:
          self.lib.mkContainer {
            inherit config;
            name = "demo-data";
            cfg = {
              ip = "10.233.1.4/24";
              hostBridge = "cbr0";
              hostDataDir = "/var/lib/demo-data";
            };
            subDirs = [ "postgresql" ];
            bindMounts = {
              "/var/lib/demo" = {
                hostPath = "/var/lib/demo-data";
                isReadOnly = false;
              };
              "/var/lib/postgresql" = {
                hostPath = "/var/lib/demo-data/postgresql";
                isReadOnly = false;
              };
            };
            innerConfig = {
              system.stateVersion = "25.11";
              # ente's shape: StateDirectory owns the top dir, postgres a subdir.
              systemd.services.take-ownership = {
                serviceConfig = {
                  Type = "oneshot";
                  RemainAfterExit = true;
                };
                script = ''
                  chown 71:71 /var/lib/postgresql
                  chmod 0700 /var/lib/postgresql
                  chown 999:999 /var/lib/demo
                  chmod 0750 /var/lib/demo
                '';
              };
            };
          }
        )
      ];
      services.nix-gantry.host = {
        enable = true;
        subnet = "10.233.1.0/24";
        hostAddress = "10.233.1.1";
        manifestUrl = "file:///nonexistent";
        excludeFromStandalone = [ "demo-data" ];
      };
      networking.firewall.enable = false;
      system.stateVersion = "25.11";
    };
    testScript = ''
      from datetime import timedelta

      start_all()
      host.wait_for_unit("container@demo-data.service")

      def stat(path):
          return host.succeed(f"stat -c '%a %u %g' {path}").strip()

      top, pg = "/var/lib/demo-data", "/var/lib/demo-data/postgresql"
      # Fresh dirs get the configured owner and mode.
      assert stat(top) == "755 1000 100", stat(top)
      assert stat(pg) == "755 1000 100", stat(pg)

      host.wait_until_succeeds(
          "systemctl -M demo-data start take-ownership.service",
          timeout=timedelta(seconds=120),
      )
      assert stat(top) == "750 999 999", stat(top)
      assert stat(pg) == "700 71 71", stat(pg)

      # A host activation re-runs tmpfiles; it must not take the dirs back.
      host.succeed("systemctl restart systemd-tmpfiles-resetup.service")
      host.succeed("systemd-tmpfiles --create")
      assert stat(top) == "750 999 999", f"hostDataDir reset on activation: {stat(top)}"
      assert stat(pg) == "700 71 71", f"subDir reset on activation: {stat(pg)}"
    '';
  };

  health-rollback = pkgs.testers.runNixOSTest {
    name = "nix-gantry-health-rollback";
    nodes.host = {
      imports = [
        (mkHostNode {
          manifestUrl = "file://${manifestFile}";
          healthchecks.demo = ''
            if [ -e /run/hang-healthcheck ]; then sleep infinity & echo $! > /run/hang-pid; wait; fi
            systemctl -M "$CONTAINER" is-active --quiet health-marker.service
          '';
        })
      ];
      system.extraDependencies = [ unhealthyClosure ];
      # Keeps the failing activation short; the healthy boot needs far less.
      services.nix-gantry.updater.healthcheckTimeoutSec = 30;
    };
    testScript = ''
      from datetime import timedelta

      start_all()
      host.wait_for_unit("multi-user.target")

      # The healthy closure passes its healthcheck.
      host.succeed("systemctl start --wait update-container@demo.service")
      host.succeed("systemctl -M demo is-active health-marker.service")

      # A closure that boots but never turns healthy fails activation and is
      # rolled back to the healthy one, which runs again.
      profile = "/nix/var/nix/profiles/containers/demo"
      host.succeed(f"nix-env --profile {profile} --set ${unhealthyClosure}")
      host.fail("systemctl start --wait update-container-activate@demo.service")
      host.succeed(f"test $(readlink -f {profile}) = ${demoClosure}")
      host.wait_for_unit("container@demo.service")
      host.wait_until_succeeds(
          "systemctl -M demo is-active health-marker.service",
          timeout=timedelta(seconds=60),
      )
      host.succeed("journalctl -u update-container-activate@demo.service -o cat --no-pager | grep -q 'Healthcheck FAILED'")
      host.succeed("journalctl -u update-container-activate@demo.service -o cat --no-pager | grep -q 'Rollback completed for demo'")

      # A healthcheck that hangs is killed when the budget runs out and the
      # rollback still runs: the unit fails by exit code, not by its timeout.
      host.succeed("systemctl reset-failed container@demo.service")
      host.succeed("touch /run/hang-healthcheck")
      host.succeed(f"nix-env --profile {profile} --set ${unhealthyClosure}")
      host.fail("systemctl start --wait update-container-activate@demo.service")
      host.succeed("test $(systemctl show -P Result update-container-activate@demo.service) = exit-code")
      host.succeed(f"test $(readlink -f {profile}) = ${demoClosure}")
      # The check did hang (a failed start would skip it), and its child is gone.
      host.succeed("test -s /run/hang-pid")
      host.fail("kill -0 $(cat /run/hang-pid)")
      host.fail("test -e /run/container-updater/changed-demo")
    '';
  };

  bad-manifest = pkgs.testers.runNixOSTest {
    name = "nix-gantry-bad-manifest";
    nodes.host = mkHostNode { manifestUrl = "file:///run/test-manifest.json"; };
    testScript = ''
      start_all()
      host.wait_for_unit("multi-user.target")

      # 0. Activating before any closure is staged fails fast instead of waiting healthcheckTimeoutSec.
      host.fail("nix-gantry activate demo")
      host.succeed(
          "journalctl -u update-container-activate@demo.service -o cat --no-pager"
          " | grep -q 'has no staged closure'"
      )

      # 1. Missing manifest file: staging fails cleanly, nothing crash-loops.
      host.fail("systemctl start --wait update-container-stage@demo.service")
      host.succeed("systemctl is-failed update-container-stage@demo.service")
      host.fail("systemctl is-active container@demo.service")
      host.fail("test -e /var/lib/machines/demo/current")

      # The nightly run reports the failed stage instead of exiting 0.
      host.fail("systemctl start update-containers.service")

      # 2. Malformed JSON: jq rejects it, stage fails, current stays absent.
      host.succeed("printf '{not-json' > /run/test-manifest.json")
      host.fail("systemctl start --wait update-container-stage@demo.service")
      host.fail("test -e /var/lib/machines/demo/current")

      # 3. Valid JSON missing this container/arch: stage aborts with a clear message.
      host.succeed("printf '{\"rev\":\"r1\",\"systems\":{}}' > /run/test-manifest.json")
      host.fail("systemctl start --wait update-container-stage@demo.service")
      host.succeed(
          "journalctl -u update-container-stage@demo.service -o cat --no-pager"
          " | grep -q 'has no entry'"
      )
      host.fail("test -e /var/lib/machines/demo/current")

      # 4. Path traversal / non-store path in manifest is rejected before nix-store runs.
      host.succeed("printf '{\"rev\":\"r2\",\"systems\":{\"${system}\":{\"demo\":\"../../etc/passwd\"}}}' > /run/test-manifest.json")
      host.fail("systemctl start --wait update-container-stage@demo.service")
      host.succeed(
          "journalctl -u update-container-stage@demo.service -o cat --no-pager"
          " | grep -q 'Invalid store path'"
      )
      host.fail("test -e /var/lib/machines/demo/current")
    '';
  };

  # Pure eval-level check: the quickstart host evaluates as shipped, without
  # declaring my.network. CI otherwise only builds its factory half. The VM
  # variant, since that is what the README's `nixos-rebuild build-vm` builds.
  quickstart-eval =
    let
      example = (import ../examples/flake.nix).outputs {
        inherit (inputs) nixpkgs;
        nix-gantry = self;
      };
      inherit (example.nixosConfigurations.quickstart.config.system.build) vm;
    in
    pkgs.runCommand "nix-gantry-quickstart-eval-check" { } ''
      echo ${builtins.unsafeDiscardStringContext vm.drvPath} > $out
    '';

  podman-nesting =
    let
      built = self.lib.mkContainer {
        config = {
          services.nix-gantry.updater.containers = [ ];
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
          services.nix-gantry.updater.containers = [ ];
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

  tls-mtls = pkgs.testers.runNixOSTest {
    name = "nix-gantry-tls-mtls";
    nodes.host = {
      imports = [
        self.nixosModules.host
        self.nixosModules.updater
        shimModule
        (mkTlsContainer "api"
          {
            ip = "10.233.5.3/24";
            tls = {
              enable = true;
              serverPort = 8080;
              allowedClients = [ "caller" ];
            };
          }
          {
            systemd.services.api = {
              wantedBy = [ "multi-user.target" ];
              script = ''
                mkdir -p /srv && echo api-says-hi > /srv/index.html
                exec ${pkgs.python3}/bin/python3 -m http.server 8080 --bind 127.0.0.1 --directory /srv
              '';
            };
          }
        )
        (mkTlsContainer "caller" {
          ip = "10.233.5.2/24";
          egress = {
            restrictLan = true;
            lanAllowlist = [ "10.233.5.3" ];
          };
          tls = {
            enable = true;
            serverPort = 0;
            upstreams = [
              {
                name = "api";
                target = "10.233.5.3";
                port = 4000;
              }
            ];
          };
        } { environment.systemPackages = [ pkgs.curl ]; })
      ];

      services.nix-gantry.host = {
        enable = true;
        subnet = "10.233.5.0/24";
        hostAddress = "10.233.5.1";
        manifestUrl = "file:///nonexistent";
        # Embedded, so .path is a real closure and they start at boot.
        excludeFromStandalone = [
          "api"
          "caller"
        ];
      };
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      networking = {
        firewall = {
          enable = true;
          filterForward = true;
        };
        interfaces.cbr0.ipv4.addresses = [
          {
            address = "10.233.5.1";
            prefixLength = 24;
          }
        ];
      };
      systemd.tmpfiles.rules = [ "L+ /nix/persist/pki/internal - - - - ${testPki}" ];
      environment.systemPackages = [ pkgs.curl ];
      system.stateVersion = "25.11";
    };
    testScript = ''
      from datetime import timedelta

      start_all()
      host.wait_for_unit("container@api.service")
      host.wait_for_unit("container@caller.service")
      for c in ["api", "caller"]:
          host.wait_until_succeeds(
              f"nixos-container run {c} -- systemctl is-active mtls-sidecar",
              timeout=timedelta(seconds=60),
          )

      # Host nftables firewall and per-container egress containment are both loaded.
      host.succeed("nft list table inet nixos-fw")
      host.succeed("nft list table inet zt-caller-egress")

      pki = "${testPki}"
      api = f"curl -sS --max-time 5 --cacert {pki}/ca.crt --resolve api:443:10.233.5.3 https://api/"
      host.wait_until_succeeds(
          f"{api} --cert {pki}/certs/caller.crt --key {pki}/certs/caller.key | grep -q api-says-hi",
          timeout=timedelta(seconds=60),
      )

      # A container's own cert (no EKU) passes as a client cert, a foreign CA's doesn't.
      def refused(cmd, alert):
          out = host.fail(f"{cmd} 2>&1")
          assert alert in out, f"expected '{alert}', got: {out}"

      refused(api, "certificate required")
      refused(f"{api} --cert {pki}/certs/foreign.crt --key {pki}/certs/foreign.key", "unknown ca")

      # A cert from the right CA whose name isn't in allowedClients gets a 403.
      code = host.succeed(
          f"{api} -o /dev/null -w '%{{http_code}}' --cert {pki}/certs/other.crt --key {pki}/certs/other.key"
      )
      assert code == "403", f"unlisted client got {code}"

      # The caller's upstream presents its own cert; no container holds a shared client key.
      host.fail("nixos-container run caller -- test -e /etc/pki/internal/client.key")
      host.wait_until_succeeds(
          "nixos-container run caller -- curl -sS --max-time 5 http://127.0.0.1:4000/ | grep -q api-says-hi",
          timeout=timedelta(seconds=60),
      )

      # Routed RFC1918 traffic from caller is actively dropped and logged by zt-caller-egress.
      host.succeed("ip link add lan0 type dummy && ip addr add 192.168.99.1/24 dev lan0 && ip link set lan0 up")
      host.succeed("ip neigh replace 192.168.99.2 lladdr 02:00:00:00:00:02 dev lan0 nud permanent")
      host.fail("nixos-container run caller -- curl -sS --max-time 2 http://192.168.99.2/")
      host.wait_until_succeeds(
          "journalctl -k --no-pager | grep -q 'zt-caller-egress drop:'",
          timeout=timedelta(seconds=10),
      )
    '';
  };

  updater-timeouts =
    let
      evalTimeout =
        {
          startSec ? "90s",
          stopSec ? "150s",
          hcSec ? 60,
        }:
        let
          sys = inputs.nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.updater
              {
                containers.c1 = {
                  timeoutStartSec = startSec;
                  config.system.stateVersion = "25.11";
                };
                systemd.services."container@c1".serviceConfig.TimeoutStopSec = stopSec;
                services.nix-gantry.updater = {
                  enable = true;
                  manifestUrl = "https://example.invalid/manifest.json";
                  containers = [ "c1" ];
                  healthcheckTimeoutSec = hcSec;
                };
                system.stateVersion = "25.11";
              }
            ];
          };
        in
        {
          activate = sys.config.systemd.services."update-container-activate@".serviceConfig.TimeoutStartSec;
          rollback = sys.config.systemd.services."update-container-rollback@".serviceConfig.TimeoutStartSec;
        };
      # 15min (900) + 150s = 1050 restart; activate = 2*1050 + 60 + 60 = 2220; rollback = 1050 + 60 = 1110.
      podmanCase = evalTimeout {
        startSec = "15min";
        stopSec = "150s";
      };
      # Compound + sub-second rounding: "1h 30min" = 5400; "1500ms" rounds up to 2, floor is 90 -> 90.
      compoundCase = evalTimeout {
        startSec = "1h 30min";
        stopSec = "1500ms";
        hcSec = 30;
      };
      # Larger sub-second above floor: "90500ms" -> 91s start, "95000001us" -> 96s stop.
      subSecCase = evalTimeout {
        startSec = "90500ms";
        stopSec = "95000001us";
        hcSec = 10;
      };
      infStart = evalTimeout { startSec = "infinity"; };
      zeroStop = evalTimeout { stopSec = "0"; };
      badUnit = builtins.tryEval (
        builtins.seq (evalTimeout { startSec = "10fortnights"; }).activate true
      );
      badSyntax = builtins.tryEval (builtins.seq (evalTimeout { startSec = "bogus"; }).activate true);
    in
    pkgs.runCommandLocal "nix-gantry-updater-timeouts-check" { } ''
      ${
        if podmanCase.activate == 2220 && podmanCase.rollback == 1110 then
          ""
        else
          throw "updater-timeouts: expected 2220/1110, got ${toString podmanCase.activate}/${toString podmanCase.rollback}"
      }
      ${
        if
          compoundCase.activate == (2 * (5400 + 90) + 30 + 60) && compoundCase.rollback == (5400 + 90 + 60)
        then
          ""
        else
          throw "updater-timeouts: compound mismatch"
      }
      ${
        if subSecCase.activate == (2 * (91 + 96) + 10 + 60) && subSecCase.rollback == (91 + 96 + 60) then
          ""
        else
          throw "updater-timeouts: sub-second ceiling mismatch"
      }
      ${
        if infStart.activate == "infinity" && infStart.rollback == "infinity" then
          ""
        else
          throw "updater-timeouts: infinity start must make activate/rollback unbounded"
      }
      ${
        if zeroStop.activate == "infinity" && zeroStop.rollback == "infinity" then
          ""
        else
          throw "updater-timeouts: 0 stop must make activate/rollback unbounded"
      }
      ${
        if !badUnit.success && !badSyntax.success then
          ""
        else
          throw "updater-timeouts: invalid timeout did not throw"
      }
      touch $out
    '';

  host-persistence =
    let
      mkPersistEval =
        forwardJournal:
        (inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.default
            self.nixosModules.host-persistence
            (
              { config, lib, ... }:
              {
                options = {
                  my.containers = lib.mkOption {
                    type = lib.types.attrsOf lib.types.attrs;
                    default = { };
                  };
                  environment.persistence = lib.mkOption {
                    type = lib.types.attrsOf (
                      lib.types.submodule {
                        options.directories = lib.mkOption {
                          type = lib.types.listOf lib.types.anything;
                          default = [ ];
                        };
                      }
                    );
                    default = { };
                  };
                };
                config = lib.mkMerge [
                  {
                    fileSystems = {
                      "/" = {
                        device = "none";
                        fsType = "tmpfs";
                      };
                      "/mnt/data" = {
                        device = "/dev/sda1";
                        fsType = "ext4";
                      };
                      "/mnt/data/scratch" = {
                        device = "none";
                        fsType = "tmpfs";
                      };
                    };
                    services.nix-gantry.host = {
                      enable = true;
                      enablePersistence = true;
                      subnet = "10.233.9.0/24";
                      hostAddress = "10.233.9.1";
                      manifestUrl = "https://example.invalid/manifest.json";
                      journal.forward = forwardJournal;
                    };
                    my.containers = {
                      on-root = {
                        enable = true;
                        ip = "10.233.9.2/24";
                        hostBridge = "cbr0";
                        hostDataDir = "/var/lib/on-root";
                        dataDirOwner = 991;
                        dataDirGroup = 992;
                      };
                      on-disk = {
                        enable = true;
                        ip = "10.233.9.3/24";
                        hostBridge = "cbr0";
                        hostDataDir = "/mnt/data/on-disk";
                      };
                      on-nested-tmpfs = {
                        enable = true;
                        ip = "10.233.9.4/24";
                        hostBridge = "cbr0";
                        hostDataDir = "/mnt/data/scratch/nested";
                      };
                      disabled-one = {
                        enable = false;
                        ip = "10.233.9.5/24";
                        hostBridge = "cbr0";
                        hostDataDir = "/var/lib/disabled-one";
                      };
                    };
                    system.stateVersion = "25.11";
                  }
                  (self.lib.mkContainer {
                    inherit config;
                    name = "on-root";
                    cfg = config.my.containers.on-root;
                  })
                  (self.lib.mkContainer {
                    inherit config;
                    name = "on-disk";
                    cfg = config.my.containers.on-disk;
                  })
                  (self.lib.mkContainer {
                    inherit config;
                    name = "on-nested-tmpfs";
                    cfg = config.my.containers.on-nested-tmpfs;
                  })
                ];
              }
            )
          ];
        }).config.environment.persistence."/nix/persist".directories;
      dirsWithJournal = mkPersistEval true;
      dirsNoJournal = mkPersistEval false;
      expectedRoot = {
        directory = "/var/lib/on-root";
        mode = "0755";
        user = "991";
        group = "992";
      };
      expectedNested = {
        directory = "/mnt/data/scratch/nested";
        mode = "0755";
        user = "1000";
        group = "100";
      };
      mentionsDisk = builtins.any (
        d: (if builtins.isAttrs d then d.directory else d) == "/mnt/data/on-disk"
      ) dirsWithJournal;
      mentionsDisabled = builtins.any (
        d: (if builtins.isAttrs d then d.directory else d) == "/var/lib/disabled-one"
      ) dirsWithJournal;
    in
    pkgs.runCommandLocal "nix-gantry-host-persistence-check" { } ''
      ${
        if builtins.elem expectedRoot dirsWithJournal then
          ""
        else
          throw "host-persistence: missing /var/lib/on-root with 991:992"
      }
      ${
        if builtins.elem expectedNested dirsWithJournal then
          ""
        else
          throw "host-persistence: nested tmpfs under ext4 not persisted"
      }
      ${if !mentionsDisk then "" else throw "host-persistence: ext4 path must not be persisted"}
      ${
        if !mentionsDisabled then "" else throw "host-persistence: disabled container must not be persisted"
      }
      ${
        if
          builtins.elem "/var/log/containers" dirsWithJournal
          && !(builtins.elem "/var/log/containers" dirsNoJournal)
        then
          ""
        else
          throw "host-persistence: /var/log/containers must follow journal.forward"
      }
      touch $out
    '';

  option-helpers =
    let
      presetModule =
        { config, lib, ... }:
        {
          options.demo = {
            ip = lib.mkOption { type = lib.types.str; };
            hostBridge = lib.mkOption { type = lib.types.str; };
            gpuRenderNode = lib.mkOption { type = lib.types.str; };
            memoryLimit = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            memorySwapMax = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            cpuLimit = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
          }
          // self.lib.tlsOptions { inherit lib; }
          // self.lib.oidcOptions {
            inherit lib;
            defaultName = "demo-app";
            issuerUrl = "https://idp.example/.well-known/openid-configuration";
          }
          // self.lib.egressOptions { inherit lib; };

          config = lib.mkMerge [
            {
              demo = {
                ip = "10.233.8.2/24";
                hostBridge = "cbr0";
                gpuRenderNode = "/dev/dri/renderD128";
                memoryLimit = "2G";
                memorySwapMax = "0";
                cpuLimit = "200%";
                egress.lanAllowlist = [ "10.0.0.53" ];
              };
              system.stateVersion = "25.11";
            }
            (self.lib.mkContainer {
              inherit config;
              name = "demo";
              cfg = config.demo;
              secretsFile = "/run/keys/demo.env";
              secretsFilePath = "/etc/demo.env";
              enableGPU = true;
              enableAudio = true;
              enableVideo = true;
              enableUSB = true;
              healthCheck = {
                cmd = "true";
                interval = "30s";
                timeout = "5s";
              };
            })
          ];
        };
      evaluated =
        (inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [ presetModule ];
        }).config;
      c = evaluated.containers.demo;
      svc = evaluated.systemd.services."container@demo".serviceConfig;
      nft = evaluated.networking.nftables.tables.zt-demo-egress.content;
      pos = needle: lib.stringLength (lib.head (lib.splitString needle nft));

      # Assertion checks on invalid TLS configs inside the guest evaluation.
      failedTlsAssertions =
        tlsOverride:
        let
          guestCfg =
            (inputs.nixpkgs.lib.nixosSystem {
              inherit system;
              modules = [
                (
                  { config, ... }:
                  {
                    inherit
                      (self.lib.mkContainer {
                        inherit config;
                        name = "bad-tls";
                        cfg = {
                          ip = "10.233.8.9/24";
                          hostBridge = "cbr0";
                          # Omit serverPort on the base raw attrset to exercise the
                          # default fallback in lib/factory.nix.
                          tls = {
                            enable = true;
                          }
                          // tlsOverride;
                        };
                      })
                      containers
                      ;
                    system.stateVersion = "25.11";
                  }
                )
              ];
            }).config.containers.bad-tls.config;
        in
        builtins.filter (a: !a.assertion) guestCfg.assertions;
      dupPortFails =
        failedTlsAssertions {
          upstreams = [
            {
              name = "a";
              target = "10.233.8.10";
              port = 5000;
            }
            {
              name = "b";
              target = "10.233.8.11";
              port = 5000;
            }
          ];
        } != [ ];
      inboundCollisionFails =
        failedTlsAssertions {
          serverPort = 8080;
          upstreams = [
            {
              name = "a";
              target = "10.233.8.10";
              port = 8080;
            }
          ];
        } != [ ];
      clientsWithoutServerFails =
        failedTlsAssertions {
          allowedClients = [ "caller" ];
          upstreams = [
            {
              name = "a";
              target = "10.233.8.10";
              port = 5000;
            }
          ];
        } != [ ];

      # mkContainer input assertion guards.
      mkFail =
        args:
        builtins.any (a: !a.assertion)
          (self.lib.mkContainer (
            {
              config = { };
              name = "bad";
              cfg = {
                ip = "10.233.8.2/24";
                hostBridge = "cbr0";
              };
            }
            // args
          )).assertions;
      inputGuardsWork =
        mkFail {
          cfg = {
            hostBridge = "cbr0";
          };
        }
        && mkFail {
          cfg = {
            ip = "10.233.8.2/24";
          };
        }
        && mkFail { enableGPU = true; }
        && mkFail { usesPodman = true; }
        && mkFail {
          cfg = {
            ip = "10.233.8.2/24";
            hostBridge = "cbr0";
            hostDataDir = "/var/lib/bad";
          };
          subDirs = [ "nested/dir" ];
        };
    in
    pkgs.runCommandLocal "nix-gantry-option-helpers-check" { } ''
      ${
        if evaluated.demo.oidc.clientId == "demo-app" then
          ""
        else
          throw "oidcOptions: default clientId mismatch"
      }
      ${
        if evaluated.demo.egress.restrictLan then
          ""
        else
          throw "egressOptions: restrictLan must default to true"
      }
      ${
        if c.bindMounts ? "/etc/demo.env" then "" else throw "mkContainer: custom secretsFilePath missing"
      }
      ${
        if
          c.bindMounts ? "/dev/dri"
          && c.bindMounts ? "/dev/snd"
          && c.bindMounts ? "/dev/video0"
          && c.bindMounts ? "/dev/bus/usb"
        then
          ""
        else
          throw "mkContainer: hardware bindMounts missing"
      }
      ${
        if svc.MemoryMax == "2G" && svc.MemorySwapMax == "0" && svc.CPUQuota == "200%" then
          ""
        else
          throw "mkContainer: resource limits mismatch"
      }
      ${
        if c.config.systemd.timers."demo-healthcheck".timerConfig.OnUnitActiveSec == "30s" then
          ""
        else
          throw "mkContainer: healthCheck timer interval mismatch"
      }
      ${
        if pos "ip daddr 10.0.0.53 accept" < pos "} drop" then
          ""
        else
          throw "egress: lanAllowlist must precede drop"
      }
      ${
        if dupPortFails && inboundCollisionFails && clientsWithoutServerFails then
          ""
        else
          throw "tls assertions failed to catch invalid port/client config"
      }
      ${if inputGuardsWork then "" else throw "mkContainer input assertions failed to reject bad args"}
      touch $out
    '';

  module-options =
    let
      hostEval =
        (inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            self.nixosModules.default
            shimModule
            (
              { config, ... }:
              lib.mkMerge [
                {
                  services.nix-gantry = {
                    host = {
                      enable = true;
                      subnet = "10.233.7.0/24";
                      hostAddress = "10.233.7.1";
                      manifestUrl = "https://example.invalid/manifest.json";
                      excludeFromUpdater = [ "manual" ];
                    };
                    updater.activateLast = [ "cache" ];
                  };
                  system.stateVersion = "25.11";
                }
                (self.lib.mkContainer {
                  inherit config;
                  name = "app";
                  cfg = {
                    ip = "10.233.7.2/24";
                    hostBridge = "cbr0";
                  };
                })
                (self.lib.mkContainer {
                  inherit config;
                  name = "cache";
                  cfg = {
                    ip = "10.233.7.3/24";
                    hostBridge = "cbr0";
                  };
                })
                (self.lib.mkContainer {
                  inherit config;
                  name = "manual";
                  cfg = {
                    ip = "10.233.7.4/24";
                    hostBridge = "cbr0";
                  };
                })
              ]
            )
          ];
        }).config;

      customGuestEval =
        (inputs.nixpkgs.lib.nixosSystem {
          inherit system;
          modules = [
            (
              { config, ... }:
              {
                inherit
                  (self.lib.mkContainer {
                    inherit config;
                    name = "custom";
                    cfg = {
                      ip = "10.233.7.9/24";
                      hostBridge = "cbr0";
                      nameservers = [ "9.9.9.9" ];
                      gateway = "10.233.7.254";
                      enableAvahi = false;
                      tls = {
                        enable = true;
                        pkiDir = "/etc/custom-pki";
                        serverPort = 8080;
                      };
                    };
                  })
                  containers
                  ;
                system.stateVersion = "25.11";
              }
            )
          ];
        }).config.containers.custom;

      bulkScript = hostEval.systemd.services.update-containers.script;
    in
    pkgs.runCommandLocal "nix-gantry-module-options-check" { } ''
      ${
        if
          hostEval.services.nix-gantry.host.enable
          && hostEval.my.network.subnet == "10.233.7.0/24"
          && hostEval.networking.nftables.enable
          &&
            hostEval.services.nix-gantry.updater.containers == [
              "app"
              "cache"
              "manual"
            ]
          && hostEval.services.nix-gantry.updater.excludeFromNightly == [ "manual" ]
          && hostEval.services.nix-gantry.updater.activateLast == [ "cache" ]
        then
          ""
        else
          throw "module-options: services.nix-gantry.host / updater wiring failed"
      }
      ${
        if
          lib.hasInfix "PHASE2_CONTAINERS=(app)" bulkScript
          && lib.hasInfix "PHASE3_CONTAINERS=(cache)" bulkScript
          && !(lib.hasInfix "manual" bulkScript)
        then
          ""
        else
          throw "module-options: activateLast / excludeFromUpdater partitioning mismatch: ${bulkScript}"
      }
      ${
        if !(customGuestEval.config.nixpkgs.config.allowUnfree or false) then
          ""
        else
          throw "module-options: mkContainer must not force allowUnfree inside guests"
      }
      ${
        if
          customGuestEval.config.networking.nameservers == [ "9.9.9.9" ]
          && customGuestEval.config.networking.defaultGateway.address == "10.233.7.254"
          && !customGuestEval.config.services.avahi.enable
          && customGuestEval.bindMounts."/etc/pki/internal/ca.crt".hostPath == "/etc/custom-pki/ca.crt"
        then
          ""
        else
          throw "module-options: custom guest overrides (DNS/gateway/avahi/pkiDir) failed"
      }
      touch $out
    '';

  publish-manifest-cli =
    let
      pkg = self.packages.${system}.nix-gantry;
      mockNix = pkgs.writeShellScriptBin "nix" ''
        set -euo pipefail
        case "$1 $2" in
          "eval --json")
            if [[ "$3" == *"standalone-host"* ]]; then
              echo '["standalone"]'
            else
              echo '["good","broken-build","uncached"]'
            fi
            ;;
          "eval --raw")
            case "$3" in
              *'"standalone"'*) echo "/var/lib/machines/standalone/current" ;;
              *'"good"'*) echo "/nix/store/00000000000000000000000000000001-good" ;;
              *'"broken-build"'*) echo "/nix/store/00000000000000000000000000000004-broken" ;;
              *'"uncached"'*) echo "/nix/store/00000000000000000000000000000003-uncached" ;;
              *) exit 1 ;;
            esac
            ;;
          "build --no-link")
            case "$3" in
              *'"standalone"'* | *'"broken-build"'*) exit 1 ;;
              *) exit 0 ;;
            esac
            ;;
          "path-info --recursive")
            case "$3" in
              *-good)
                printf '%s\n' \
                  "/nix/store/00000000000000000000000000000001-good" \
                  "/nix/store/00000000000000000000000000000002-dep"
                ;;
              *-uncached)
                echo "/nix/store/00000000000000000000000000000003-uncached"
                ;;
            esac
            ;;
          "path-info --store")
            store=$3
            shift 4
            case "$store" in
              https://down.invalid) exit 1 ;;
              https://cache-a.example)
                printf '[{"path":"/nix/store/00000000000000000000000000000001-good","valid":true}]'
                ;;
              https://cache-b.example)
                printf '{"/nix/store/00000000000000000000000000000002-dep":{"narSize":1},"%s":null}' \
                  "/nix/store/00000000000000000000000000000003-uncached"
                ;;
            esac
            ;;
          "store verify")
            if [[ "$*" == *"trusted:good"* ]]; then
              exit 0
            fi
            exit 1
            ;;
          *)
            echo "unexpected mock nix call: $*" >&2
            exit 99
            ;;
        esac
      '';
    in
    pkgs.runCommandLocal "nix-gantry-publish-manifest-cli-check"
      {
        nativeBuildInputs = [
          mockNix
          pkgs.bash
          pkgs.coreutils
          pkgs.jq
        ];
      }
      ''
        SCRIPT=${../bin/nix-gantry.sh}

        # 1. Packaged CLI binaries: --version, --help, missing flag value, and `status --root`.
        ${pkg}/bin/nix-gantry --version | grep -qx "nix-gantry ${pkg.version}"
        ${pkg}/bin/nix-gantry --help | grep -q "publish-manifest"
        ${pkg}/bin/publish-manifest --version | grep -qx "nix-gantry ${pkg.version}"
        ${pkg}/bin/publish-manifest --help | grep -q -- "--flake-ref"
        if ${pkg}/bin/publish-manifest --flake-ref >/dev/null 2>&1; then
          echo "dangling --flake-ref unexpectedly succeeded" >&2
          exit 1
        fi

        mkdir -p root/nix/var/nix/profiles/containers root/var/lib/machines/app root/run/container-updater
        mkdir -p root/target-cur root/target-prev
        ln -s "$PWD/root/target-cur" root/nix/var/nix/profiles/containers/app-1-link
        ln -s app-1-link root/nix/var/nix/profiles/containers/app
        ln -s "$PWD/root/nix/var/nix/profiles/containers/app" root/var/lib/machines/app/current
        ln -s "$PWD/root/target-prev" root/var/lib/machines/app/previous
        touch root/run/container-updater/changed-app
        ${pkg}/bin/nix-gantry status --json --root root > status.json
        jq -e 'length == 1 and .[0].name == "app" and .[0].pendingRestart == true and (.[0].current | endswith("/target-cur")) and (.[0].previous | endswith("/target-prev"))' status.json

        # 2. Missing required flags and unknown flags must fail.
        if bash "$SCRIPT" publish-manifest --flake-ref . >/dev/null 2>&1; then
          echo "missing required args unexpectedly succeeded" >&2
          exit 1
        fi
        if bash "$SCRIPT" publish-manifest --unknown-flag >/dev/null 2>&1; then
          echo "unknown flag unexpectedly succeeded" >&2
          exit 1
        fi

        # 3. Passing a standalone host config (whose .path is /var/lib/machines/*) must fail loudly.
        if bash "$SCRIPT" publish-manifest --flake-ref . --config standalone-host --system x86_64-linux >/dev/null 2>standalone.err; then
          echo "standalone host .path unexpectedly succeeded" >&2
          exit 1
        fi
        grep -q "not a /nix/store path" standalone.err

        # 4. Multi-substituter union + trusted key passes `good`, skips `broken-build` and `uncached`.
        bash "$SCRIPT" publish-manifest --flake-ref . --config factory --system x86_64-linux \
          --substituter https://cache-a.example \
          --substituter https://cache-b.example \
          --trusted-public-keys "trusted:good" > out.json
        jq -e '.["x86_64-linux"] == {"good": "/nix/store/00000000000000000000000000000001-good"}' out.json

        # 5. Untrusted key drops `good` too.
        bash "$SCRIPT" publish-manifest --flake-ref . --config factory --system x86_64-linux \
          --substituter https://cache-a.example \
          --substituter https://cache-b.example \
          --trusted-public-keys "trusted:wrong" > untrusted.json
        jq -e '.["x86_64-linux"] == {}' untrusted.json

        # 6. Unreachable substituter with unaccounted paths must exit non-zero (never publish {}).
        if bash "$SCRIPT" publish-manifest --flake-ref . --config factory --system x86_64-linux \
          --substituter https://down.invalid > down.json 2>/dev/null; then
          echo "unreachable substituter unexpectedly succeeded" >&2
          exit 1
        fi

        touch $out
      '';

  options-doc-freshness =
    pkgs.runCommandLocal "nix-gantry-options-doc-freshness-check"
      { nativeBuildInputs = [ pkgs.diffutils ]; }
      ''
        diff -u ${../docs/OPTIONS.md} ${self.packages.${system}.options-doc}
        touch $out
      '';
}
