<!-- Generated via `nix build .#options-doc`. Do not hand-edit -- see CONTRIBUTING.md. -->
## services\.nix-gantry\.host\.enable



Whether to enable container host bridge networking and updater wiring\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.enablePersistence



Whether to enable impermanence wiring for container host data directories\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.bridge

Container bridge interface name\.



*Type:*
string



*Default:*

```nix
"cbr0"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.excludeFromStandalone



Containers built embedded on this host and never pulled from the
manifest — for structural evaluation conflicts, not merely skipping
unattended restarts (use ` excludeFromUpdater ` for that)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.excludeFromUpdater



Containers still built standalone and pulled from the CI manifest, but
excluded from the automatic nightly bulk update — e\.g\. a reverse proxy
you do not want restarted unattended\. Still updatable manually via
` nix-gantry update <name> ` or ` systemctl start update-container@<name> `\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "attic"
  "caddy"
  "crowdsec"
]
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.hostAddress



Host bridge IP on the container subnet\.



*Type:*
string



*Example:*

```nix
"10.85.48.1"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.journal\.forward



Stream each container’s journal to ` /var/log/containers/<name> ` on the
host (` nspawn --forward-journal `, requires host systemd >= 261 and
guest systemd >= 256)\. Readable by the ` systemd-journal ` group via
` journalctl -D ` across container restarts\.



*Type:*
boolean



*Default:*

```nix
lib.versionAtLeast config.systemd.package.version "261"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.journal\.maxUse



Disk cap per container for the forwarded journal\.



*Type:*
string



*Default:*

```nix
"256M"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.journal\.maxUseFor



Per-container overrides of ` maxUse `, keyed by container name\.



*Type:*
attribute set of string



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  caddy = "1G";
}
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.manifestUrl



Forwarded to ` services.nix-gantry.updater.manifestUrl `\.



*Type:*
string



*Example:*

```nix
"https://github.com/you/your-flake/releases/download/container-manifest/manifest.json"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.persistPath



Impermanence mount root under ` environment.persistence ` when ` enablePersistence ` is enabled\.



*Type:*
string



*Default:*

```nix
"/nix/persist"
```



*Example:*

```nix
"/persist"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.host\.subnet



Container subnet CIDR\.



*Type:*
string



*Example:*

```nix
"10.85.48.0/24"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## services\.nix-gantry\.updater\.enable



Whether to enable automated container closures updater via Nix profiles\.



*Type:*
boolean



*Default:*

```nix
false
```



*Example:*

```nix
true
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## services\.nix-gantry\.updater\.package



The ` nix-gantry ` CLI package installed on the host, or ` null ` to omit it\.



*Type:*
null or package



*Default:*

```nix
pkgs.nix-gantry
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## services\.nix-gantry\.updater\.activateLast



Containers activated sequentially in Phase 3 after all other changed
containers finish Phase 2 — e\.g\. a self-hosted binary cache container
that should keep serving while peers stage and restart\.



*Type:*
list of string



*Default:*

```nix
[
  "attic"
]
```



*Example:*

```nix
[
  "attic"
]
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## services\.nix-gantry\.updater\.autoRollback



Automatically roll back to the previous container generation when a
container fails to start or fails its healthcheck after activation\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## services\.nix-gantry\.updater\.containers



Standalone containers managed by the updater\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "caddy"
  "gatus"
]
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## services\.nix-gantry\.updater\.excludeFromNightly



Containers from ` containers ` skipped by the automatic nightly bulk
update\. Still standalone, bootstrapped on first boot if never staged,
and updatable manually via ` nix-gantry update <name> ` or
` systemctl start update-container@<name> `\.



*Type:*
list of string



*Default:*

```nix
[ ]
```



*Example:*

```nix
[
  "caddy"
]
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## services\.nix-gantry\.updater\.healthcheckTimeoutSec



Maximum time (seconds) to wait for a container to reach active state
and pass any configured healthcheck after restart\. A healthcheck still
running at the deadline is killed and counts as failed\.



*Type:*
positive integer, meaning >0



*Default:*

```nix
60
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## services\.nix-gantry\.updater\.healthchecks



Optional host-side shell command per container name to verify health\.
Executed with systemd, nix, coreutils and curl on PATH and the
container name in ` $CONTAINER `; retried until ` healthcheckTimeoutSec `\.



*Type:*
attribute set of string



*Default:*

```nix
{ }
```



*Example:*

```nix
{
  caddy = "curl -fsS http://10.85.46.107:80/health";
}
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## services\.nix-gantry\.updater\.manifestUrl



URL of the CI-published container manifest: a JSON map of
system -> container name -> store path\. Consuming the manifest
instead of evaluating a flake keeps updates evaluation-free on the host\.



*Type:*
string



*Example:*

```nix
"https://github.com/you/your-flake/releases/download/container-manifest/manifest.json"
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)


