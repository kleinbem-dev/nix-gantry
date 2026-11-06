<!-- Generated via `nix build .#options-doc`. Do not hand-edit -- see CONTRIBUTING.md. -->
## my\.container-host\.enable



Whether to enable Container Host (LXD networking, persistence, auto-update)\.



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



## my\.container-host\.enablePersistence



Whether to enable Impermanence for container host\.



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



## my\.container-host\.bridge

Container bridge name



*Type:*
string



*Default:*

```nix
"cbr0"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## my\.container-host\.excludeFromStandalone



Containers that must build embedded on this host and never be
treated as standalone/pulled at all — for a container-factory
structural conflict (e\.g\. an attrsOf option that recurses in the
factory’s eval), not merely “don’t auto-restart” (use
excludeFromUpdater for that)\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## my\.container-host\.excludeFromUpdater



Containers still built by container-factory and pulled/cached from the
CI manifest, but excluded from the automatic nightly bulk update —
e\.g\. a reverse proxy you don’t want unattended-restarted\. Still
stageable/updatable any time via
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
  "attic"
  "caddy"
  "crowdsec"
]
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## my\.container-host\.hostAddress



Host bridge IP on container subnet



*Type:*
string



*Example:*

```nix
"10.85.48.1"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## my\.container-host\.journal\.forward



Stream each container’s journal to /var/log/containers/\<name> on the
host (nspawn --forward-journal, needs systemd 261 or newer)\. Readable by the
systemd-journal group with ` journalctl -D `, and it survives container
restarts\. Guests need systemd 256 or newer; an older guest ignores the
forwarding and keeps its journal inside the container\. With
enablePersistence, nixosModules\.host-persistence persists the directory\.



*Type:*
boolean



*Default:*

```nix
lib.versionAtLeast config.systemd.package.version "261"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## my\.container-host\.journal\.maxUse



Disk cap per container for the forwarded journal\.



*Type:*
string



*Default:*

```nix
"256M"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## my\.container-host\.journal\.maxUseFor



Per-container overrides of ` maxUse `, by container name\.



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



## my\.container-host\.manifestUrl



Forwarded to my\.services\.container-updater\.manifestUrl\. Set here
(once, alongside subnet/hostAddress) instead of separately
importing nixosModules\.updater just to set one string\.



*Type:*
string



*Example:*

```nix
"https://github.com/you/your-flake/releases/download/container-manifest/manifest.json"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## my\.container-host\.subnet



Container subnet (e\.g\., 10\.85\.48\.0/24)



*Type:*
string



*Example:*

```nix
"10.85.48.0/24"
```

*Declared by:*
 - [modules/host\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/host.nix)



## my\.services\.container-updater\.enable



Whether to enable Automated container closures updater via Nix Profiles\.



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



## my\.services\.container-updater\.autoRollback



Automatically roll back to the previous container generation if the
container fails to start or fails its healthcheck after activation\.



*Type:*
boolean



*Default:*

```nix
true
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## my\.services\.container-updater\.containers



List of standalone containers to auto-update\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## my\.services\.container-updater\.excludeFromNightly



Containers from ` containers ` (above) to skip in the automatic nightly
bulk update (e\.g\. a reverse proxy you don’t want unattended-restarted)\.
They’re still built by container-factory, cached from the CI manifest,
staged automatically on first boot if never staged
(container-updater-bootstrap), and updatable any time via
` systemctl start update-container@<name> ` — this only opts them out
of the automatic 03:00 timer\.



*Type:*
list of string



*Default:*

```nix
[ ]
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## my\.services\.container-updater\.healthcheckTimeoutSec



Maximum time (seconds) to wait for a container to reach active state
and pass any configured healthcheck after restart\.



*Type:*
positive integer, meaning >0



*Default:*

```nix
60
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## my\.services\.container-updater\.healthchecks



Optional custom healthcheck shell command per container name to verify service health\.
Executed on the host, with systemd, nix, coreutils and curl on PATH;
must exit 0 when healthy\.
Example: { “caddy” = “curl -fsS http://10\.85\.46\.107:80/health”; }



*Type:*
attribute set of string



*Default:*

```nix
{ }
```

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)



## my\.services\.container-updater\.manifestUrl



URL of the CI-published container manifest: a JSON map of
system → container name → store path, generated by the
promote-production workflow for the exact SHA the ` production `
tag points at\. Consuming the manifest instead of evaluating the
flake keeps the nightly update eval-free on the device — an
RPi-class host only fetches a JSON file and substitutes a store
path from the binary cache\.



*Type:*
string

*Declared by:*
 - [modules/updater\.nix](https://github.com/kleinbem-dev/nix-gantry/blob/main/modules/updater.nix)


