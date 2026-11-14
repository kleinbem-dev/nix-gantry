# mkContainer: build a NixOS containers.<name> block, either embedded in the
# host's generation (default) or standalone (.path -> /var/lib/machines/<name>/current,
# swapped atomically by modules/updater.nix).
{ lib }:
{
  name,
  cfg,
  config,
  innerConfig ? { },
  bindMounts ? { },
  timeout ? null,
  enableNesting ? false,
  # Podman-in-nspawn: implies enableNesting, 15m start timeout (image pulls
  # outlast 90s), docker.io search registry, and podman storage on host disk.
  usesPodman ? false,
  # One-level subdirectories of cfg.hostDataDir pre-created on the host.
  # Once a guest re-owns "a", host tmpfiles refuses "a/b" as an unsafe transition.
  subDirs ? [ ],
  secretsFile ? null,
  secretsFilePath ? null,
  enableGPU ? false,
  enableAudio ? false,
  enableVideo ? false,
  enableUSB ? false,
  additionalCapabilities ? [ ],
  healthCheck ? null,
}:
let
  inherit (lib) mkIf mkDefault;

  nesting = enableNesting || usesPodman;
  effectiveTimeout = if timeout != null then timeout else (if usesPodman then "15m" else "90s");
  effectiveSubDirs = subDirs ++ lib.optional usesPodman "containers";
  effectiveSecretsFilePath =
    if secretsFilePath != null then secretsFilePath else "/run/secrets/${name}.env";
  hasDataDir = (cfg.hostDataDir or null) != null;

  # ─── mTLS Sidecar Configuration ─────────────────────────────
  tlsCfg = cfg.tls or { };
  hasTls = tlsCfg.enable or false;
  pkiDir = tlsCfg.pkiDir or "/nix/persist/pki/internal";
  serverPort = if hasTls then (tlsCfg.serverPort or 0) else 0;
  upstreams = if hasTls then (tlsCfg.upstreams or [ ]) else [ ];
  allowedClients = tlsCfg.allowedClients or [ ];
  airlock = tlsCfg.airlock or false;

  # Outbound: localhost:<port> -> <target>:443 over mTLS, presenting this
  # container's cert and verifying the upstream SAN against the internal CA.
  # Loopback-only so external peers cannot borrow this container's identity;
  # [::1] only with IPv6 because Caddy aborts on a failed bind.
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

  allowedClientsMatcher = lib.optionalString (allowedClients != [ ]) ''
    @unlisted not expression `{http.request.tls.client.san.dns_names.0} in ${builtins.toJSON allowedClients}`
    respond @unlisted 403
  '';
  inboundBlock = lib.optionalString (serverPort > 0) ''
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
  '';

  sidecarCaddyfile = ipv6: ''
    {
      auto_https off
      admin off
    }

    ${inboundBlock}
    ${upstreamBlocks ipv6}
  '';

  fwUpstreamRules = lib.concatMapStringsSep "\n            " (
    u: "ip daddr ${u.target} tcp dport 443 accept"
  ) upstreams;

  # Ephemeral roots lose the guest journal on restart and nixpkgs skips
  # --link-journal for them, so stream it to the host instead (systemd >= 261).
  # no-link: by design, an ephemeral root has no journal directory to link.
  journalCfg = config.services.nix-gantry.host.journal or { };
  forwardJournal =
    journalCfg.forward or (lib.versionAtLeast (config.systemd.package.version or "0") "261");
  journalDir = "/var/log/containers/${name}";

  # ":" applies mode/owner only on creation (tmpfiles.d(5)) so host activations
  # never reset dirs already owned by guest services (postgres, StateDirectory, podman).
  dataDirRule =
    path:
    "d ${path} :0755 :${toString (cfg.dataDirOwner or 1000)} :${
      toString (cfg.dataDirGroup or 100)
    } - -";

  updaterList = config.services.nix-gantry.updater.containers or [ ];
  isStandalone =
    builtins.elem name updaterList
    || (cfg.standaloneRunner or config.my.containers.standaloneRunner or false);

  # Derive network values from cfg.ip so standalone closures remain host-agnostic.
  containerIp = lib.head (lib.splitString "/" cfg.ip);
  containerOctets = lib.splitString "." containerIp;
  containerSubnetCidr = lib.concatStringsSep "." (lib.take 3 containerOctets ++ [ "0" ]) + "/24";
  nameservers =
    cfg.nameservers or [
      "1.1.1.1"
      "8.8.8.8"
    ];
  enableAvahi = cfg.enableAvahi or true;

  # ─── Host-side Egress Containment ───────────────────────────
  egressCfg = cfg.egress or { };
  hasEgress = egressCfg.restrictLan or false;
  lanAllowlist = egressCfg.lanAllowlist or [ ];
  allowlistRules = lib.concatMapStringsSep "\n          " (
    ip: "ip saddr ${containerIp} ip daddr ${ip} accept"
  ) lanAllowlist;
  privateCidrs = "10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16";

  rwBind = path: {
    ${path} = {
      hostPath = path;
      isReadOnly = false;
    };
  };
  rwDev = node: {
    inherit node;
    modifier = "rw";
  };
in
{
  # Keep top-level attrset keys independent of `cfg`/`config` so callers can
  # merge `mkContainer { cfg = config.<ns>.<name>; ... }` inside `lib.mkMerge`
  # without triggering module-argument recursion.
  assertions = [
    {
      assertion = (cfg.ip or "") != "" && lib.hasInfix "/" cfg.ip && lib.length containerOctets == 4;
      message = "nix-gantry (${name}): cfg.ip must be an IPv4 CIDR (e.g. \"10.233.1.2/24\")";
    }
    {
      assertion = (cfg.hostBridge or "") != "";
      message = "nix-gantry (${name}): cfg.hostBridge is required";
    }
    {
      assertion = !enableGPU || (cfg.gpuRenderNode or "") != "";
      message = "nix-gantry (${name}): cfg.gpuRenderNode is required when enableGPU = true";
    }
    {
      assertion = effectiveSubDirs == [ ] || hasDataDir;
      message = "nix-gantry (${name}): cfg.hostDataDir is required when usesPodman = true or subDirs is non-empty";
    }
    {
      assertion = builtins.all (
        d: d != "" && d != "." && d != ".." && !(lib.hasInfix "/" d)
      ) effectiveSubDirs;
      message = "nix-gantry (${name}): subDirs entries must be single-level directory names without '/'";
    }
  ];

  containers.${name} = {
    ephemeral = true;
    autoStart = cfg.autoStart or true;
    privateNetwork = true;
    inherit (cfg) hostBridge;
    localAddress = cfg.ip;
    privateUsers = cfg.privateUsers or "no";
    # nixos-containers assigns TimeoutStartSec from this option, overriding serviceConfig.
    timeoutStartSec = effectiveTimeout;

    extraFlags = lib.optionals forwardJournal [
      "--forward-journal=${journalDir}/"
      "--forward-journal-max-use=${journalCfg.maxUseFor.${name} or journalCfg.maxUse or "256M"}"
    ];

    allowedDevices =
      lib.optional enableGPU (rwDev cfg.gpuRenderNode)
      ++ lib.optional enableAudio (rwDev "/dev/snd")
      ++ lib.optionals enableVideo [
        (rwDev "/dev/video0")
        (rwDev "/dev/video1")
      ]
      ++ lib.optional enableUSB (rwDev "/dev/bus/usb")
      ++ lib.optional nesting (rwDev "/dev/fuse")
      ++ (cfg.extraAllowedDevices or [ ]);

    additionalCapabilities =
      lib.optionals nesting [
        "CAP_SYS_ADMIN"
        "CAP_MKNOD"
        "CAP_SETFCAP"
        # crun's cgroup-v2 device control uses eBPF.
        "CAP_BPF"
      ]
      ++ additionalCapabilities
      ++ (cfg.extraCapabilities or [ ]);

    path = mkIf isStandalone (lib.mkForce "/var/lib/machines/${name}/current");

    config = lib.mkMerge [
      {
        # Needed even when standalone so the empty stub config evaluates without warning.
        system.stateVersion = mkDefault "25.11";
      }
      (mkIf (!isStandalone) (
        { pkgs, ... }@args:
        {
          imports = [
            (
              { options, ... }:
              {
                networking = {
                  hostName = cfg.hostName or name;
                  defaultGateway = lib.mkForce (
                    cfg.gateway or (lib.concatStringsSep "." (lib.take 3 containerOctets ++ [ "1" ]))
                  );
                  nameservers = lib.mkForce nameservers;
                  resolvconf.extraConfig = lib.mkForce ''
                    name_servers='${lib.concatStringsSep " " nameservers}'
                    resolv_conf_local_only=NO
                  '';
                  firewall.enable = mkDefault true;
                  nftables = {
                    enable = mkDefault true;
                    tables.zt-factory = {
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
                          # Routed traffic from nested (podman) containers skips output.
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
                };

                services.avahi = mkIf enableAvahi (
                  {
                    enable = true;
                    nssmdns4 = true;
                    openFirewall = true;
                  }
                  // (
                    if options.services.avahi ? settings then
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
                  )
                );

                system.stateVersion = mkDefault "25.11";

                # WORKAROUND(systemd/systemd#36455): SIGKILLed systemd-nspawn leaks unix-export
                # mountpoints; stop hung guest units inside container@'s 150s TimeoutStopSec —
                # remove when systemd/systemd#36455 is fixed.
                systemd.settings.Manager = {
                  DefaultStartLimitIntervalSec = "15m";
                  DefaultStartLimitBurst = 5;
                  DefaultTimeoutStopSec = mkDefault "45s";
                };
              }
            )

            (mkIf (hasTls && (serverPort > 0 || upstreams != [ ])) {
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
              networking.firewall.allowedTCPPorts = mkIf (serverPort > 0) [ 443 ];

              systemd.services.mtls-sidecar = {
                description = "mTLS Sidecar Proxy (Caddy)";
                after = [ "network.target" ];
                wantedBy = [ "multi-user.target" ];
                serviceConfig = {
                  Type = "simple";
                  ExecStart = "${lib.getExe pkgs.caddy} run --config /etc/caddy-sidecar/Caddyfile --adapter caddyfile";
                  Restart = "on-failure";
                  RestartSec = "5s";
                  AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
                };
              };

              environment.etc."caddy-sidecar/Caddyfile".text = sidecarCaddyfile args.config.networking.enableIPv6;
            })

            (mkIf usesPodman {
              virtualisation.podman = {
                enable = true;
                dockerCompat = mkDefault true;
              };
              virtualisation.containers.registries.settings.unqualified-search-registries = [
                "docker.io"
              ];
            })

            (mkIf (healthCheck != null) {
              systemd.services."${name}-healthcheck" = {
                description = "Healthcheck probe for ${name}";
                serviceConfig = {
                  Type = "oneshot";
                  ExecStart = "${pkgs.writeShellScript "${name}-healthcheck" (
                    if builtins.isString healthCheck then healthCheck else healthCheck.cmd
                  )}";
                  TimeoutSec = if builtins.isAttrs healthCheck then (healthCheck.timeout or "15s") else "15s";
                };
              };
              systemd.timers."${name}-healthcheck" = {
                description = "Periodic healthcheck timer for ${name}";
                wantedBy = [ "timers.target" ];
                timerConfig = {
                  OnBootSec = "30s";
                  OnUnitActiveSec = if builtins.isAttrs healthCheck then (healthCheck.interval or "1m") else "1m";
                };
              };
            })

            (if builtins.isFunction innerConfig then innerConfig args else innerConfig)
          ];
        }
      ))
    ];

    bindMounts =
      bindMounts
      // lib.optionalAttrs isStandalone {
        "/var/lib/machines/${name}/current" = {
          hostPath = "/var/lib/machines/${name}/current";
          isReadOnly = true;
        };
      }
      # Mount the container's pair whenever TLS is on so standalone guest and host
      # generations can add/remove upstreams or listeners independently.
      // lib.optionalAttrs hasTls {
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
      }
      // lib.optionalAttrs nesting (rwBind "/dev/fuse")
      // lib.optionalAttrs enableGPU (rwBind "/dev/dri")
      // lib.optionalAttrs enableAudio (rwBind "/dev/snd")
      // lib.optionalAttrs enableVideo (rwBind "/dev/video0" // rwBind "/dev/video1")
      // lib.optionalAttrs enableUSB (rwBind "/dev/bus/usb")
      // lib.optionalAttrs usesPodman {
        "/var/lib/containers" = {
          hostPath = "${cfg.hostDataDir}/containers";
          isReadOnly = false;
        };
      }
      // lib.optionalAttrs (secretsFile != null) {
        ${effectiveSecretsFilePath} = {
          hostPath = secretsFile;
          isReadOnly = true;
        };
      };
  };

  systemd = {
    tmpfiles.rules =
      lib.optional forwardJournal "d ${journalDir} 2750 root systemd-journal - -"
      ++ lib.optional hasDataDir (dataDirRule cfg.hostDataDir)
      ++ map (d: dataDirRule "${cfg.hostDataDir}/${d}") effectiveSubDirs;

    services."container@${name}" = {
      unitConfig = {
        StartLimitIntervalSec = 900;
        StartLimitBurst = 5;
        ConditionPathExists = mkIf isStandalone "/var/lib/machines/${name}/current";
      };
      serviceConfig = {
        Restart = "on-failure";
        RestartSec = "10s";
        RestartSteps = 5;
        RestartMaxDelaySec = "5m";
        # WORKAROUND(systemd/systemd#36455): keep above guest stop timeouts (postgresql: 120s)
        # so nspawn isn't SIGKILLed with leaked unix-export mounts — remove when systemd/systemd#36455 is fixed.
        TimeoutStopSec = mkDefault "150s";
        # WORKAROUND(NixOS/nixpkgs#583993): keep --forward-journal's journal-remote out of the
        # top cgroup so nspawn can delegate controllers (pids, memory) — remove when NixOS/nixpkgs#583993 merges.
        DelegateSubgroup = "supervisor";
        MemoryMax = mkIf ((cfg.memoryLimit or null) != null) cfg.memoryLimit;
        MemorySwapMax = mkIf ((cfg.memorySwapMax or null) != null) cfg.memorySwapMax;
        CPUQuota = mkIf ((cfg.cpuLimit or null) != null) cfg.cpuLimit;
      };
    };
  };

  # Enable host nftables when egress containment is requested so zt-<name>-egress
  # is actually loaded on stock NixOS hosts (where nftables defaults to false).
  networking.nftables = {
    enable = mkIf hasEgress (mkDefault true);
    tables = lib.optionalAttrs hasEgress {
      "zt-${name}-egress" = {
        family = "inet";
        content = ''
          chain forward {
            type filter hook forward priority filter; policy accept;
            ip saddr ${containerIp} ct state { established, related } accept
            ${allowlistRules}
            ip saddr ${containerIp} ip daddr { ${privateCidrs} } limit rate 6/minute log prefix "zt-${name}-egress drop: "
            ip saddr ${containerIp} ip daddr { ${privateCidrs} } drop
          }
        '';
      };
    };
  };
}
