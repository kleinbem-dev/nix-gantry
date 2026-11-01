# mkContainer: build a NixOS containers.<name> block, either embedded in the
# host's generation (default) or standalone: `.path` is the symlink
# /var/lib/machines/<name>/current, which modules/updater.nix swaps atomically.
# `cfg.hostBridge` (and `cfg.gpuRenderNode` with enableGPU) are required on cfg;
# a wrapper can default them from its own config at the call site.
{ lib }:
{
  name,
  cfg,
  config,
  innerConfig ? { },
  bindMounts ? { },
  timeout ? null,
  enableNesting ? false,
  # Podman-in-nspawn: implies enableNesting, a 15m start timeout (image pulls
  # outlast 90s), unqualified-search-registries, and podman storage on host
  # disk instead of the ephemeral tmpfs root (needs cfg.hostDataDir).
  usesPodman ? false,
  # Subdirectories of cfg.hostDataDir created on the host before nspawn starts
  # (bind mounts don't create a missing host dir), e.g. [ "postgresql" ].
  subDirs ? [ ],
  # Host-side env/secrets file, bind-mounted read-only at /run/secrets/<name>.env
  # (or secretsFilePath). Wiring it into the service's environmentFile stays
  # with the caller.
  secretsFile ? null,
  secretsFilePath ? null,
  enableGPU ? false,
  enableAudio ? false,
  enableVideo ? false,
  enableUSB ? false,
  additionalCapabilities ? [ ],
  # Optional in-container periodic healthcheck probe.
  # Takes an attrset: { cmd = "..."; interval = "1m"; timeout = "15s"; } or a string command.
  healthCheck ? null,
}:
let
  inherit (lib) mkIf mkDefault;

  # usesPodman implies enableNesting.
  nesting = enableNesting || usesPodman;
  effectiveTimeout = if timeout != null then timeout else (if usesPodman then "15m" else "90s");
  # usesPodman's own storage dir rides the same subDirs mechanism instead
  # of a bespoke tmpfiles rule.
  effectiveSubDirs = subDirs ++ (lib.optional usesPodman "containers");
  effectiveSecretsFilePath =
    if secretsFilePath != null then secretsFilePath else "/run/secrets/${name}.env";

  # ─── mTLS Sidecar Configuration ─────────────────────────────
  hasTls = cfg ? tls && cfg.tls ? enable && cfg.tls.enable;
  tlsCfg = if hasTls then cfg.tls else { };
  serverPort = if hasTls then tlsCfg.serverPort else 0;
  upstreams = if hasTls && tlsCfg ? upstreams then tlsCfg.upstreams else [ ];

  pkiDir = "/nix/persist/pki/internal";

  # Outbound: localhost:<port> -> <target>:443 over mTLS. The server cert is
  # checked against the internal CA by its SAN (the upstream's name, hence
  # tls_server_name); this container presents the shared client cert.
  mkUpstreamBlock = upstream: ''
    :${toString upstream.port} {
      reverse_proxy ${upstream.target}:443 {
        header_up Host ${upstream.name}
        transport http {
          tls
          tls_server_name ${upstream.name}
          tls_client_auth /etc/pki/internal/client.crt /etc/pki/internal/client.key
          tls_trust_pool file {
            pem_file /etc/pki/internal/ca.crt
          }
        }
      }
    }
  '';

  upstreamBlocks = lib.concatMapStringsSep "\n" mkUpstreamBlock upstreams;

  # Inbound: :443 terminates mTLS with this container's cert, requires a client
  # cert from the internal CA, then proxies to the local service.
  inboundBlock =
    if serverPort > 0 then
      ''
        :443 {
          tls /etc/pki/internal/${name}.crt /etc/pki/internal/${name}.key {
            client_auth {
              mode require_and_verify
              trust_pool file {
                pem_file /etc/pki/internal/ca.crt
              }
            }
          }
          reverse_proxy localhost:${toString serverPort} {
            header_up Host {upstream_hostport}
          }
        }
      ''
    else
      "";

  sidecarCaddyfile = ''
    {
      auto_https off
      admin off
    }

    ${inboundBlock}
    ${upstreamBlocks}
  '';

  # Firewall exceptions: allow outbound to each upstream (nftables)
  mkFwRule = upstream: "ip daddr ${upstream.target} tcp dport 443 accept";
  fwUpstreamRules = lib.concatMapStringsSep "\n            " mkFwRule upstreams;

  updaterList = config.my.services.container-updater.containers or [ ];
  isStandalone =
    (builtins.elem name updaterList)
    || (cfg.standaloneRunner or config.my.containers.standaloneRunner or false);

  # The container's own /24, from cfg.ip. A standalone closure is built once and
  # runs on any host, so nothing may come from the build host's subnet.
  containerOctets = lib.splitString "." (lib.head (lib.splitString "/" cfg.ip));
  containerSubnetCidr = lib.concatStringsSep "." (lib.take 3 containerOctets ++ [ "0" ]) + "/24";

  # ─── Host-side Egress Containment ───────────────────────────
  hasEgress = cfg ? egress && cfg.egress ? restrictLan && cfg.egress.restrictLan;
  containerIp = lib.head (lib.splitString "/" cfg.ip);
  lanAllowlist = if cfg ? egress && cfg.egress ? lanAllowlist then cfg.egress.lanAllowlist else [ ];
  allowlistRules = lib.concatMapStringsSep "\n          " (
    ip: "ip saddr ${containerIp} ip daddr ${ip} accept"
  ) lanAllowlist;
in
{
  containers.${name} = {
    ephemeral = true;
    autoStart = cfg.autoStart or true;
    privateNetwork = true;
    hostBridge = cfg.hostBridge;
    localAddress = cfg.ip;
    privateUsers = cfg.privateUsers or "no";
    # Set the timeout here: nixos-containers assigns TimeoutStartSec from this
    # option, and a serviceConfig.TimeoutStartSec override on container@ never wins.
    timeoutStartSec = effectiveTimeout;

    # Conditionally allow hardware device pass-through
    allowedDevices =
      (lib.optionals enableGPU [
        {
          node = cfg.gpuRenderNode;
          modifier = "rw";
        }
      ])
      ++ (lib.optionals enableAudio [
        {
          node = "/dev/snd";
          modifier = "rw";
        }
      ])
      ++ (lib.optionals enableVideo [
        {
          node = "/dev/video0";
          modifier = "rw";
        }
        {
          node = "/dev/video1";
          modifier = "rw";
        }
      ])
      ++ (lib.optionals enableUSB [
        {
          node = "/dev/bus/usb";
          modifier = "rw";
        }
      ])
      ++ (lib.optionals nesting [
        {
          node = "/dev/fuse";
          modifier = "rw";
        }
      ])
      ++ (cfg.extraAllowedDevices or [ ]);

    additionalCapabilities =
      (lib.optionals nesting [
        "CAP_SYS_ADMIN"
        "CAP_MKNOD"
        "CAP_SETFCAP"
        # crun's cgroup-v2 device control uses eBPF; without CAP_BPF it fails with
        # "crun: bpf create ``: Operation not permitted".
        "CAP_BPF"
      ])
      ++ additionalCapabilities
      ++ (cfg.extraCapabilities or [ ]);

    path = lib.mkIf isStandalone (lib.mkForce "/var/lib/machines/${name}/current");

    config = lib.mkMerge [
      {
        # Even if standalone, we must set stateVersion to avoid NixOS evaluation warnings
        # when the module system evaluates the empty config.
        system.stateVersion = mkDefault "25.11";
      }
      (lib.mkIf (!isStandalone) (
        { pkgs, ... }@args:
        {
          imports = [
            ({ options, ... }: {
              networking = {
                hostName = cfg.hostName or name;
                # .1 of the container's own /24, not the build host's bridge IP:
                # a standalone closure runs on hosts other than the one that built
                # it. Assumes the host is .1 of its container /24.
                defaultGateway = lib.mkForce (lib.concatStringsSep "." (lib.take 3 containerOctets ++ [ "1" ]));
                # Public resolvers, not the bridge gateway: nothing answers DNS on
                # the host's bridge address (systemd-resolved binds loopback and
                # NetBird only).
                nameservers = lib.mkForce [
                  "1.1.1.1"
                  "8.8.8.8"
                ];
                resolvconf.extraConfig = lib.mkForce ''
                  name_servers='1.1.1.1 8.8.8.8'
                  resolv_conf_local_only=NO
                '';
                firewall.enable = mkDefault true;
                nftables.enable = mkDefault true;

                # Zero Trust: restrict outbound to bridge subnet (defense-in-depth)
                nftables.tables.zt-factory = {
                  family = "inet";
                  content = ''
                    chain output {
                      type filter hook output priority filter; policy accept;
                      ct state { established, related } accept
                      ip daddr ${containerSubnetCidr} accept
                      oifname "lo" accept
                      ${fwUpstreamRules}
                    }
                  '';
                };
              };

              services.avahi = {
                enable = true;
                nssmdns4 = true;
                openFirewall = true;
              }
              // (
                if (options.services.avahi ? settings) then
                  {
                    settings.publish = {
                      "disable-publishing" = false;
                      publish-addresses = true;
                      publish-workstation = true;
                    };
                  }
                else
                  {
                    publish = {
                      enable = true;
                      addresses = true;
                      workstation = true;
                    };
                  }
              );

              system.stateVersion = mkDefault "25.11";

              # Prevent broken services from restarting endlessly:
              # Trips the burst limit after 5 failures in 15 minutes, transitioning
              # the unit into "failed" state so crash-loops don't run silently.
              systemd.settings.Manager = {
                DefaultStartLimitIntervalSec = "15m";
                DefaultStartLimitBurst = 5;
              };
              nixpkgs.config = {
                allowUnfree = true;
                allowUnfreePredicate = _: true;
                allowInsecurePredicate =
                  pkg:
                  builtins.elem (lib.getName pkg) [
                    # Advisory marking (prompt injection by design), not a CVE;
                    # the factory builds it as an isolated container.
                    # Using predicate to allow automatic updates across version bumps.
                    "openclaw"
                  ];
              };
            })

            # mTLS Sidecar (only when there's inbound/outbound to proxy)
            (mkIf (hasTls && (serverPort > 0 || upstreams != [ ])) {
              networking.firewall.allowedTCPPorts = lib.mkIf (serverPort > 0) [ 443 ];

              environment.systemPackages = [ pkgs.caddy ];

              systemd.services.mtls-sidecar = {
                description = "mTLS Sidecar Proxy (Caddy)";
                after = [ "network.target" ];
                wantedBy = [ "multi-user.target" ];

                serviceConfig = {
                  Type = "simple";
                  ExecStart = "${pkgs.caddy}/bin/caddy run --config /etc/caddy-sidecar/Caddyfile --adapter caddyfile";
                  Restart = "on-failure";
                  RestartSec = "5s";
                  AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
                };
              };

              environment.etc."caddy-sidecar/Caddyfile".text = sidecarCaddyfile;
            })

            # usesPodman boilerplate: podman itself + its own
            # registries.conf (separate from the outer host's — without
            # this, a short/unqualified image name fails to pull outright
            # with "no unqualified-search registries are defined").
            (mkIf usesPodman {
              virtualisation.podman = {
                enable = true;
                dockerCompat = mkDefault true;
              };
              virtualisation.containers.registries.settings.unqualified-search-registries = [
                "docker.io"
              ];
            })

            # In-container periodic healthcheck probe
            (mkIf (healthCheck != null) {
              systemd.services."${name}-healthcheck" = {
                description = "Healthcheck probe for ${name}";
                serviceConfig = {
                  Type = "oneshot";
                  ExecStart =
                    let
                      hcCmd = if builtins.isString healthCheck then healthCheck else healthCheck.cmd;
                    in
                    "${pkgs.writeShellScript "${name}-healthcheck" hcCmd}";
                  TimeoutSec =
                    if builtins.isAttrs healthCheck && healthCheck ? timeout then healthCheck.timeout else "15s";
                };
              };
              systemd.timers."${name}-healthcheck" = {
                description = "Periodic healthcheck timer for ${name}";
                wantedBy = [ "timers.target" ];
                timerConfig = {
                  OnBootSec = "30s";
                  OnUnitActiveSec =
                    if builtins.isAttrs healthCheck && healthCheck ? interval then healthCheck.interval else "1m";
                };
              };
            })

            # Inject the user-provided config
            (if builtins.isFunction innerConfig then innerConfig args else innerConfig)
          ];
        }
      ))
    ];

    bindMounts =
      bindMounts
      // (lib.optionalAttrs isStandalone {
        "/var/lib/machines/${name}/current" = {
          hostPath = "/var/lib/machines/${name}/current";
          isReadOnly = true;
        };
      })
      // (lib.optionalAttrs hasTls {
        # Bind-mount PKI certificates into the container
        "/etc/pki/internal/ca.crt" = {
          hostPath = "${pkiDir}/ca.crt";
          isReadOnly = true;
        };
        "/etc/pki/internal/${name}.crt" = {
          hostPath = "${pkiDir}/certs/${name}.crt";
          isReadOnly = true;
        };
        "/etc/pki/internal/${name}.key" = {
          hostPath = "${pkiDir}/certs/${name}.key";
          isReadOnly = true;
        };
        "/etc/pki/internal/client.crt" = {
          hostPath = "${pkiDir}/certs/client.crt";
          isReadOnly = true;
        };
        "/etc/pki/internal/client.key" = {
          hostPath = "${pkiDir}/certs/client.key";
          isReadOnly = true;
        };
      })
      // (lib.optionalAttrs nesting {
        "/dev/fuse" = {
          hostPath = "/dev/fuse";
          isReadOnly = false;
        };
      })
      // (lib.optionalAttrs enableGPU {
        "/dev/dri" = {
          hostPath = "/dev/dri";
          isReadOnly = false;
        };
      })
      // (lib.optionalAttrs enableAudio {
        "/dev/snd" = {
          hostPath = "/dev/snd";
          isReadOnly = false;
        };
      })
      // (lib.optionalAttrs enableVideo {
        "/dev/video0" = {
          hostPath = "/dev/video0";
          isReadOnly = false;
        };
        "/dev/video1" = {
          hostPath = "/dev/video1";
          isReadOnly = false;
        };
      })
      // (lib.optionalAttrs enableUSB {
        "/dev/bus/usb" = {
          hostPath = "/dev/bus/usb";
          isReadOnly = false;
        };
      })
      // (lib.optionalAttrs usesPodman {
        # Podman image/layer storage on host disk. On the ephemeral tmpfs root,
        # image pulls fill it ("no space left on device") and crash-loop.
        # Requires cfg.hostDataDir.
        "/var/lib/containers" = {
          hostPath = "${cfg.hostDataDir}/containers";
          isReadOnly = false;
        };
      })
      // (lib.optionalAttrs (secretsFile != null) {
        ${effectiveSecretsFilePath} = {
          hostPath = secretsFile;
          isReadOnly = true;
        };
      });
  };

  # hostDataDir defaults to 1000:100. A service without CAP_DAC_OVERRIDE (e.g.
  # crowdsec, whose module drops all capabilities) must own the dir: pass
  # cfg.dataDirOwner/dataDirGroup.
  systemd.tmpfiles.rules =
    (lib.optionals (cfg ? hostDataDir && cfg.hostDataDir != null) [
      "d ${cfg.hostDataDir} 0755 ${toString (cfg.dataDirOwner or 1000)} ${
        toString (cfg.dataDirGroup or 100)
      } - -"
    ])
    ++ (map (
      d:
      # Must pre-exist on the host before nspawn starts — bind mounts
      # don't auto-create missing host-side directories.
      "d ${cfg.hostDataDir}/${d} 0755 ${toString (cfg.dataDirOwner or 1000)} ${
        toString (cfg.dataDirGroup or 100)
      } - -"
    ) effectiveSubDirs);

  # Resource limits, plus Restart=on-failure (nixos-containers leaves container@
  # at Restart=no). The StartLimit guard stops a broken container looping forever.
  systemd.services."container@${name}" = {
    unitConfig = {
      StartLimitIntervalSec = 900;
      StartLimitBurst = 5;
    }
    // (lib.optionalAttrs isStandalone {
      ConditionPathExists = "/var/lib/machines/${name}/current";
    });
    serviceConfig = lib.mkMerge [
      {
        Restart = "on-failure";
        RestartSec = "10s";
        RestartSteps = 5;
        RestartMaxDelaySec = "5m";
      }
      (mkIf
        (
          (cfg ? memoryLimit && cfg.memoryLimit != null)
          || (cfg ? memorySwapMax && cfg.memorySwapMax != null)
          || (cfg ? cpuLimit && cfg.cpuLimit != null)
        )
        {
          MemoryMax = mkIf (cfg ? memoryLimit && cfg.memoryLimit != null) (cfg.memoryLimit or null);
          MemorySwapMax = mkIf (cfg ? memorySwapMax && cfg.memorySwapMax != null) (cfg.memorySwapMax or null);
          CPUQuota = mkIf (cfg ? cpuLimit && cfg.cpuLimit != null) (cfg.cpuLimit or null);
        }
      )
    ];
  };

  # Host-side egress containment (restricts outbound LAN access for untrusted/DMZ containers)
  networking.nftables.tables = lib.optionalAttrs hasEgress {
    "zt-${name}-egress" = {
      family = "inet";
      content = ''
        chain forward {
          type filter hook forward priority filter; policy accept;
          # Replies to connections from outside (Caddy on another host) must
          # pass, or the drops below cut every inbound request.
          ip saddr ${containerIp} ct state { established, related } accept
          ${allowlistRules}
          ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } limit rate 6/minute log prefix "zt-${name}-egress drop: "
          ip saddr ${containerIp} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } drop
        }
      '';
    };
  };
}
