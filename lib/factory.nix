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
  allowedClients = tlsCfg.allowedClients or [ ];

  pkiDir = "/nix/persist/pki/internal";

  # Outbound: localhost:<port> -> <target>:443 over mTLS. The server cert is
  # checked against the internal CA by its SAN (the upstream's name, hence
  # tls_server_name). This container presents its own cert, so a listener can
  # tell callers apart; anyone reaching the port gets that identity, so it stays
  # on loopback. [::1] only with IPv6: Caddy aborts on a failed bind.
  mkUpstreamBlock = ipv6: upstream: ''
    :${toString upstream.port} {
      bind 127.0.0.1${lib.optionalString ipv6 " [::1]"}
      reverse_proxy ${upstream.target}:443 {
        header_up Host ${upstream.name}
        transport http {
          tls
          tls_server_name ${upstream.name}
          tls_client_auth /etc/pki/internal/${name}.crt /etc/pki/internal/${name}.key
          tls_trust_pool file {
            pem_file /etc/pki/internal/ca.crt
          }
        }
      }
    }
  '';

  upstreamBlocks = ipv6: lib.concatMapStringsSep "\n" (mkUpstreamBlock ipv6) upstreams;
  upstreamPorts = map (u: u.port) upstreams;

  # Inbound: :443 terminates mTLS with this container's cert, requires a client
  # cert from the internal CA, then proxies to the local service. With
  # allowedClients, only those names get through: each fleet cert's first DNS
  # SAN is its container's name, and matching the name survives a renewal.
  allowedClientsMatcher = lib.optionalString (allowedClients != [ ]) ''
    @unlisted not expression `{http.request.tls.client.san.dns_names.0} in ${builtins.toJSON allowedClients}`
    respond @unlisted 403
  '';
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
          ${allowedClientsMatcher}
          reverse_proxy localhost:${toString serverPort} {
            header_up Host {upstream_hostport}
          }
        }
      ''
    else
      "";

  sidecarCaddyfile = ipv6: ''
    {
      auto_https off
      admin off
    }

    ${inboundBlock}
    ${upstreamBlocks ipv6}
  '';

  # Firewall exceptions: allow outbound to each upstream (nftables)
  mkFwRule = upstream: "ip daddr ${upstream.target} tcp dport 443 accept";
  fwUpstreamRules = lib.concatMapStringsSep "\n            " mkFwRule upstreams;

  # airlock: drop all other egress. Upstream targets are IPs, so no DNS.
  airlock = (cfg.tls or { }).airlock or false;

  # Ephemeral roots lose the guest journal on every restart and nixpkgs skips
  # --link-journal for them, so stream it to the host instead (systemd >= 261).
  # no-link: by design, an ephemeral root has no journal directory to link.
  journalCfg = config.my.container-host.journal or { };
  forwardJournal =
    journalCfg.forward or (lib.versionAtLeast (config.systemd.package.version or "0") "261");
  journalDir = "/var/log/containers/${name}";

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

    extraFlags = lib.optionals forwardJournal [
      "--forward-journal=${journalDir}/"
      "--forward-journal-max-use=${journalCfg.maxUseFor.${name} or journalCfg.maxUse or "256M"}"
    ];

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

                # Outbound allowlist: only enforced with tls.airlock; otherwise
                # the chain accepts everything.
                nftables.tables.zt-factory = {
                  family = "inet";
                  content = ''
                    chain output {
                      type filter hook output priority filter; policy accept;
                      ct state { established, related } accept
                      ip daddr ${containerSubnetCidr} accept
                      oifname "lo" accept
                      ${fwUpstreamRules}
                      ${lib.optionalString airlock ''
                        ip daddr 224.0.0.251 udp dport 5353 accept
                        ip6 daddr { fe80::/10, ff02::/16 } accept
                        reject with icmpx type admin-prohibited
                      ''}
                    }
                    ${lib.optionalString airlock ''
                      # Routed traffic from nested (podman) containers skips
                      # output; same allowlist, plus DNAT'd inbound connections.
                      chain forward {
                        type filter hook forward priority filter; policy accept;
                        ct state { established, related } accept
                        ct status dnat accept
                        ip daddr ${containerSubnetCidr} accept
                        ${fwUpstreamRules}
                        reject with icmpx type admin-prohibited
                      }
                    ''}
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
              # A hung service is killed by the guest's own systemd, well inside
              # container@'s TimeoutStopSec, so the guest still shuts down cleanly.
              # upstream: systemd/systemd#36455
              systemd.settings.Manager = {
                DefaultStartLimitIntervalSec = "15m";
                DefaultStartLimitBurst = 5;
                DefaultTimeoutStopSec = mkDefault "45s";
              };
              nixpkgs.config = {
                allowUnfree = true;
                allowUnfreePredicate = _: true;
                # no-link: nixpkgs marks openclaw insecure by design (prompt
                # injection), not a bug awaiting a fix. A predicate, so bumps
                # don't need a new version string.
                allowInsecurePredicate =
                  pkg:
                  builtins.elem (lib.getName pkg) [
                    "openclaw"
                  ];
              };
            })

            # mTLS Sidecar (only when there's inbound/outbound to proxy)
            (mkIf (hasTls && (serverPort > 0 || upstreams != [ ])) {
              # Two site blocks on one port make Caddy refuse the whole config.
              assertions = [
                {
                  assertion = lib.unique upstreamPorts == upstreamPorts;
                  message = "${name}: tls.upstreams use the same port twice.";
                }
                {
                  assertion =
                    serverPort == 0 || !(builtins.elem 443 upstreamPorts || builtins.elem serverPort upstreamPorts);
                  message = "${name}: a tls.upstreams port collides with the inbound :443 listener or serverPort; set upstreams.*.port to a free local port.";
                }
                {
                  assertion = allowedClients == [ ] || serverPort > 0;
                  message = "${name}: tls.allowedClients needs an inbound listener (tls.serverPort > 0).";
                }
              ];
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

              environment.etc."caddy-sidecar/Caddyfile".text = sidecarCaddyfile args.config.networking.enableIPv6;
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
      # Both key pairs whenever TLS is on: a standalone guest updates apart from
      # the host, so its closure can need a pair this host generation wouldn't
      # use. client.* only serves guests built before upstreams used ${name}.*.
      // (lib.optionalAttrs hasTls {
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
    # setgid: journal files inherit systemd-journal, readable without root.
    (lib.optional forwardJournal "d ${journalDir} 2750 root systemd-journal - -")
    ++ (lib.optionals (cfg ? hostDataDir && cfg.hostDataDir != null) [
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

  # Resource limits, plus a backoff for container@'s own Restart=on-failure.
  # The StartLimit guard stops a broken container looping forever.
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
        # Above every guest unit's stop timeout (postgresql sets 120s): a SIGKILLed
        # nspawn leaves its unix-export mount, and the next start refuses it.
        # upstream: systemd/systemd#36455
        TimeoutStopSec = lib.mkDefault "150s";
        # As systemd-nspawn@.service does; nixpkgs' container@ lacks it. Without
        # it --forward-journal's journal-remote stays in the unit's top cgroup,
        # nspawn can't delegate controllers to payload/, and podman fails
        # ("controller pids is not available").
        # upstream: NixOS/nixpkgs#583993
        DelegateSubgroup = "supervisor";
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
