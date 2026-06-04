# Linux-Native Dune Dedicated Server

This directory contains a first Linux-native conversion path for the Dune:
Awakening self-hosted server package.

The shipped package is a Hyper-V VM wrapper around a small Alpine Linux guest.
The useful guest state is:

- k3s `v1.34.5+k3s1`
- Steam app `4754530` ("Dune: Awakening Self-Hosted Server"), downloaded with SteamCMD into `/home/dune/.dune/download`
- the vendor `scripts/setup.sh` and `scripts/battlegroup.sh` tools from that app
- `/home/dune/.dune/settings.conf`, whose fourth line is the player-facing IP
- a k3s scheduler profile named `memory-focused-scheduler`
- k3s node IP flags generated dynamically at service start

`dune-native.sh` recreates those pieces directly on a systemd Linux host, without
booting the Hyper-V VHDX.

## Warnings

This script installs and owns a local k3s service. Do not run it on a machine
that already has a Kubernetes installation you care about unless you understand
the `--force-existing-k3s` path.

The official distribution still targets Windows Pro with Hyper-V. Funcom's FAQ
says direct Linux hosting is technically possible but not streamlined/supported
yet, so this is an experimental native conversion.

For compatibility with the vendor scripts, the default setup creates a `dune`
user and grants it passwordless sudo, matching the shipped VM. Use
`--no-sudoers` only if you are prepared to fix any vendor setup failures caused
by missing sudo permissions.

## Requirements

The native script checks the host for the same practical requirements called out
by the official documentation:

- x86_64 Linux with systemd and cgroups
- CPU with AVX2 support
- at least 20 GB RAM, or use the vendor experimental swap option later
- at least 100 GB free for both k3s/container storage and the Dune download/home
- SSD-backed storage when detectable
- broadband/network access and router control if players outside the LAN will join

For external players, forward these ports to the Linux host:

- `7777-7810/udp` for game servers
- `31982/tcp` for RMQ

The default server config starts game ports at `7777`. If you edit
`UserEngine.ini` and change `Port` or `IGWPort`, adjust forwarding to match.

## Setup

Run from this Steam package directory:

```bash
./linux/dune-native.sh setup
```

Useful options:

```bash
./linux/dune-native.sh setup --public-ip example.com
./linux/dune-native.sh setup --interface eno1 --public-ip 203.0.113.10
./linux/dune-native.sh setup --internal-ip 10.0.0.50 --public-ip 10.0.0.50
./linux/dune-native.sh setup --yes
```

The script installs dependencies where it knows how, installs SteamCMD if needed,
downloads the Linux depot for Steam app `4754530`, starts k3s, installs a
containerd socket symlink for vendor script compatibility, installs cert-manager,
recreates the Funcom operator base resources, imports the packaged container
images, and scales the core/operator deployments.

World creation is separate unless you provide all required world inputs. This
avoids the vendor `world.sh` prompt loop when setup is run unattended.

```bash
DUNE_SELF_HOSTED_TOKEN_FILE=/path/to/dune-selfhost.txt ./linux/dune-native.sh setup \
  --world-name 'My Dune World' \
  --world-region Europe \
  --pghero-port 10099
```

Or create the world after core setup:

```bash
DUNE_SELF_HOSTED_TOKEN_FILE=/path/to/dune-selfhost.txt ./linux/dune-native.sh create-world \
  --world-name 'My Dune World' \
  --world-region Europe \
  --pghero-port 10099
```

The token file must be mode `0600`. You can also pass
`--self-hosted-token-file FILE` explicitly. Passing `--self-hosted-token TOKEN`
or setting `DUNE_SELF_HOSTED_TOKEN` still works, but those approaches are easier
to leak through shell history or process listings.

PgHero defaults to the vendor port `9999`. If that port is already occupied
when world creation runs, the script automatically uses `10099` when available.
You can set the port explicitly with `--pghero-port PORT` or `DUNE_PGHERO_PORT`.

Accepted regions match the vendor self-host menu: `Europe`, `North America`,
`Asia`, `Oceania`, `South America`. Numeric selections `1`–`5` also match that
menu.

## Management

```bash
./linux/dune-native.sh start
./linux/dune-native.sh status
./linux/dune-native.sh doctor
./linux/dune-native.sh doctor --external
./linux/dune-native.sh doctor --json
./linux/dune-native.sh update
./linux/dune-native.sh stop
./linux/dune-native.sh backup
./linux/dune-native.sh scheduled-backup
./linux/dune-native.sh install-backup-timer --daily-at 03:30 --retention-days 14 --max-age-hours 30
./linux/dune-native.sh set-backup-copy-target /mnt/backups/dune
./linux/dune-native.sh backup-prune --retention-days 14
./linux/dune-native.sh restore-check
./linux/dune-native.sh restore-latest
./linux/dune-native.sh import
./linux/dune-native.sh logs-export
```

Monitoring and access helpers:

```bash
./linux/dune-native.sh director-url
./linux/dune-native.sh open-director
./linux/dune-native.sh file-browser-url
./linux/dune-native.sh open-file-browser
./linux/dune-native.sh shell
./linux/dune-native.sh shell-pod
```

`doctor` checks host prerequisites, k3s/node health, cert-manager, Funcom
operators, battlegroup status, exposed service ports, token placement without
printing token values, generated YAML permissions, database backup presence, and
whether the BGD has fired a populated `DeclareBattlegroupUpdates` call (the
mechanism that makes the server visible in the in-game browser).
Run `./linux/dune-native.sh backup` after world creation to establish the first
restore point and clear the backup warning.

`doctor --external` adds outside-in checks for router/NAT forwarding. A check
run on the game host cannot prove internet reachability by itself unless the
router supports hairpin NAT, so configure an SSH-accessible machine outside the
LAN first:

```bash
export DUNE_EXTERNAL_PROBE_SSH=user@vps.example.com
./linux/dune-native.sh doctor --external
```

The external probe checks the TCP RMQ game NodePort directly. If `nmap` is
installed on the probe host, it also runs a UDP check for port `7777`; UDP game
protocols may not answer generic probes, so `open|filtered` means the port is
not reported closed rather than a full gameplay handshake.

`doctor --json` emits all checks as structured JSON — useful for the manager
service API or scripted monitoring.

`install-backup-timer` creates:

- `/etc/systemd/system/dune-native-backup.service`
- `/etc/systemd/system/dune-native-backup.timer`
- `/etc/dune-native-backup.env`
- `/var/log/dune-native/backup.log`

The timer runs `scheduled-backup`, which creates a timestamped database backup,
checks that a new backup appeared, and prunes backups older than the configured
retention period. Remove it with:

```bash
./linux/dune-native.sh uninstall-backup-timer
```

Configure a backup copy target so scheduled backups are copied away from the
primary backup directory:

```bash
./linux/dune-native.sh set-backup-copy-target /mnt/backups/dune
./linux/dune-native.sh scheduled-backup
```

`DUNE_BACKUP_COPY_TARGET` also supports `rclone:` targets when `rclone` is
installed and configured:

```bash
./linux/dune-native.sh set-backup-copy-target rclone:remote:dune-backups
```

Disable backup copies with:

```bash
./linux/dune-native.sh set-backup-copy-target none
```

## Game Configuration

Apply game settings idempotently after world creation (or to re-apply after a
Funcom image update resets the defaults):

```bash
./linux/dune-native.sh apply-canonical \
  --sietch-name "My Sietch" \
  --pvp-partition 8
```

All flags are optional; only the ones you pass are changed. Common options:

| Flag | What it sets |
|---|---|
| `--sietch-name NAME` | In-game server browser display name (`Bgd.ServerDisplayName` in `UserEngine.ini`) |
| `--pvp-partition ID` | Which partition ID is the PvP instance in `UserGame.ini` (default: `8` = `DeepDesert_1`) |
| `--mem-survival GiB` | Hagga Basin pod memory limit (e.g. `24Gi`) |
| `--mem-deep-desert GiB` | Deep Desert pod memory limit |
| `--mem-overmap GiB` | Overmap pod memory limit |
| `--mem-sietch GiB` | Sietch hub pod memory limit |
| `--always-on-deep-desert` | Keep Deep Desert always-running (`dedicatedScaling=false`) |
| `--always-on-sietches` | Keep sietch hubs always-running |
| `--mining-multiplier FLOAT` | `Dune.GlobalMiningOutputMultiplier` in `UserEngine.ini` |
| `--server-password PASS` | Join password (`Bgd.ServerLoginPassword`); pass empty string to remove |
| `--no-stop` | Apply without stopping/restarting the battlegroup |

The command stops the battlegroup, patches the BattleGroup CR and the
`UserGame.ini`/`UserEngine.ini` files on the server PVC, then restarts. It is
idempotent — safe to run repeatedly after Funcom updates reset the ini defaults.

Memory limit and always-on flags have no defaults and are only applied when
explicitly passed, so they cannot accidentally break a 20 GB host.

## Manager Service

`install-manager-service` installs the
[dune-server-service](https://github.com/adainrivers/dune-dedicated-server-manager)
daemon — a Rust HTTP API that runs alongside k3s and provides in-game GM tools
(item grants, vehicle spawns, teleports, broadcasts via RabbitMQ), real-time
player location queries (via PostgreSQL), and scheduled maintenance (daily
restarts, auto-backups).

```bash
./linux/dune-native.sh install-manager-service --timezone Europe/London
./linux/dune-native.sh uninstall-manager-service
```

The daemon listens on `localhost:29187` and is accessed securely through an SSH
tunnel from the companion desktop app. `doctor` will check its health when
installed.

The daemon's `/api/admin/player-location` and `/api/admin/players` endpoints are
also the data source for a future real-time web map of Hagga Basin and Deep Desert.

## Firewall And Admin Exposure

The only player-facing ports that should be internet reachable are:

- `7777-7810/udp` for game servers
- `31982/tcp` for RMQ game traffic

Admin surfaces such as the Kubernetes API, kubelet API, PgHero, file browser,
Director NodePort, RabbitMQ admin NodePorts, and host-network PostgreSQL should
be reachable only from loopback, a VPN, or trusted admin CIDRs.

Recommended workflow:

1. Inspect current exposure:

```bash
./linux/dune-native.sh exposure-report
```

2. Configure trusted admin source networks:

```bash
./linux/dune-native.sh set-admin-allowed-cidrs 10.0.0.0/24,100.64.0.0/10
```

Use your LAN, VPN, or both. The example allows the local `10.0.0.0/24`
network and Tailscale's `100.64.0.0/10` range.

3. Print a reviewable firewall plan without applying changes:

```bash
./linux/dune-native.sh firewall-plan
```

4. Apply the dedicated nftables table:

```bash
./linux/dune-native.sh install-firewall --admin-cidrs 10.0.0.0/24,100.64.0.0/10
```

You can omit `--admin-cidrs` if they were already configured with
`set-admin-allowed-cidrs`.

5. Verify:

```bash
./linux/dune-native.sh exposure-report
./linux/dune-native.sh doctor
sudo nft list table inet dune_native
sudo systemctl status dune-native-firewall.service --no-pager
```

This creates:

- `/etc/dune-native-firewall.nft`
- `/etc/systemd/system/dune-native-firewall.service`
- `/etc/dune-native-firewall.env`

The table is named `inet dune_native`. It drops only the discovered Dune admin
TCP ports, after allowing loopback and the configured trusted admin CIDRs. It
does not set a default-drop policy and does not modify unrelated services.

Remove it:

```bash
./linux/dune-native.sh uninstall-firewall
```

Reinstall or refresh it after ports change:

```bash
./linux/dune-native.sh install-firewall
./linux/dune-native.sh doctor
```

`install-firewall` regenerates `/etc/dune-native-firewall.nft` from the current
battlegroup services, deletes the old `inet dune_native` table if present, and
loads the refreshed table through systemd.

## Clean Teardown

Use `teardown` to remove the native deployment and return the host as close as
practical to its pre-install state:

```bash
./linux/dune-native.sh teardown --dry-run
./linux/dune-native.sh teardown
```

It removes:

- the manager service (`dune-server-service`) if installed
- the dedicated `inet dune_native` nftables table and firewall unit
- backup timer/service/env and `/var/log/dune-native`
- containerd socket symlink config (`/etc/tmpfiles.d/k3s-containerd-symlink.conf`)
- native k3s service, cluster state, CNI state, and Dune k3s runner
- `/etc/sudoers.d/dune-native`
- Dune-created `rc-service` and `rc-update` compatibility wrappers when their
  contents match this script
- the tarball SteamCMD install at `/opt/steamcmd` when `/usr/local/bin/steamcmd`
  points there
- the `dune` user and `/home/dune`
- local Funcom artifact storage under `/funcom`

It does not remove this Steam package directory or off-host backup copy targets.
To preserve local server backups/artifacts or the service user home:

```bash
./linux/dune-native.sh teardown --keep-backups
./linux/dune-native.sh teardown --keep-user
```

The command requires typing `TEARDOWN dune` unless `--yes` is supplied.

## Test Harness

Run the local harness with:

```bash
./linux/run-tests.sh
```

The tests do not require a live Dune server or a real k3s cluster. They run
`dune-native.sh` against a temporary root with stubbed `systemctl`, `nft`, `k3s`,
`ss`, `id`, `pkill`, `userdel`, and `systemd-tmpfiles` commands.

Covered behavior:

- shell syntax stays valid
- firewall install refuses to apply without trusted admin CIDRs
- firewall install generates only the dedicated `inet dune_native` table
- player-facing `31982/tcp` and unrelated ports such as SSH are not dropped
- firewall uninstall removes only Dune firewall artifacts
- containerd socket symlink config is created by setup and removed by teardown
- `apply-canonical` sets sietch name and PvP partition idempotently
- `doctor --json` produces valid JSON with the expected schema
- teardown `--dry-run` does not remove owned state
- teardown `--yes` removes owned state while preserving unrelated files and
  off-host backup targets
- teardown `--keep-user` and `--keep-backups` preserve the requested state

## Restore

Run a non-destructive restore preflight before importing a backup:

```bash
./linux/dune-native.sh restore-check
./linux/dune-native.sh restore-check sh-example-YYYYMMDD-HHMMSS.backup
```

The check verifies that the backup exists, the companion `.yaml` spec exists,
the battlegroup/database resources exist, and the server PVC host path used by
the vendor import flow is available.

Import is destructive. Stop the battlegroup first:

```bash
./linux/dune-native.sh stop
./linux/dune-native.sh import sh-example-YYYYMMDD-HHMMSS.backup
./linux/dune-native.sh start
./linux/dune-native.sh doctor
```

For the newest backup, use the guarded helper:

```bash
./linux/dune-native.sh restore-latest
```

It runs `restore-check`, prints the exact backup selected, requires typing
`RESTORE <backup-file-name>`, then stops, imports, starts, and runs `doctor`.

Anything not wrapped explicitly can be passed to the vendor tool:

```bash
./linux/dune-native.sh battlegroup status
./linux/dune-native.sh battlegroup enable-experimental-swap
```

Network settings can be adjusted after setup:

```bash
./linux/dune-native.sh set-public-ip example.com
./linux/dune-native.sh set-interface eno1
./linux/dune-native.sh set-pghero-port 10099
```

Self-hosting token rotation should use a prompt or a locked-down file, not a
command-line argument:

```bash
./linux/dune-native.sh set-self-hosted-token --restart
```

Or:

```bash
install -m 0600 /dev/stdin /tmp/dune-token
./linux/dune-native.sh set-self-hosted-token --token-file /tmp/dune-token --restart
rm -f /tmp/dune-token
```

The command patches the BattleGroup, generated child resources, the
`server-gateway-secret`, and local generated world spec files. Funcom's CRDs
still place the token into Kubernetes specs/env fields, so keep kubeconfig,
cluster-admin access, and `/home/dune/.dune/sh-*.yaml` access restricted.

For only the Kubernetes service:

```bash
./linux/dune-native.sh k3s-status
./linux/dune-native.sh k3s-start
./linux/dune-native.sh k3s-stop
```

## Recreated VM Behavior

The Windows and Alpine VM packaging do more than start Kubernetes. The native
script recreates the parts that matter on a normal systemd Linux host:

- k3s service configuration and node IP/public IP handling
- the `dune` service user, `/home/dune/.dune` layout, and `settings.conf`
- SteamCMD download of app `4754530` forced to the Linux depot
- `kubectl`, `rc-service`, and `rc-update` compatibility expected by vendor scripts
- cert-manager manifests, which are not shipped as plain Kubernetes YAML
- Funcom operator namespace, CRDs, RBAC, leader-election RBAC, deployments, and webhook TLS secret
- symlinks for the vendor `battlegroup` and `bg-util` tools
- management wrappers matching the shipped PowerShell/batch commands

## Notes

This is a native host install, not a converted KVM VM. The original VHDX is only
used as a reference for the k3s version and guest configuration.

The GA Steam product is app `4754530`. The older PTC app `3104830` is out of
date; running it causes the Battlegroup Director to silently skip the
`Battlegroups_DeclareBattlegroupUpdates` FLS call, making the server invisible in
the in-game browser despite reporting `Healthy`. `doctor` will flag this as a
warning if the BGD logs show no populated Declare calls.
