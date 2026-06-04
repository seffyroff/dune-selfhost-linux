# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Linux-native tooling to run the Dune: Awakening dedicated server without the Windows Hyper-V VM that Funcom ships. The shipped package bundles an Alpine Linux guest running k3s; this repo recreates those pieces directly on a systemd Linux host.

The GA Steam product is app ID `4754530` ("Dune: Awakening Self-Hosted Server"). The old PTC app `3104830` is no longer current; using it causes the BGD to skip `Battlegroups_DeclareBattlegroupUpdates`, making the server invisible in the browser despite showing `Healthy`.

The repo contains **only** the conversion tooling (`linux/dune-native.sh`), tests, and docs. Funcom/Steam server files, VM images, Kubernetes state, and generated secrets are all gitignored and never committed.

## Running tests

```bash
# Full suite (syntax check + pytest)
./linux/run-tests.sh

# Single test
python -m pytest tests/test_dune_native.py::test_install_firewall_generates_dedicated_table_for_dune_admin_ports_only -v

# pytest pass-through (e.g. verbose, filter by keyword)
./linux/run-tests.sh -v -k firewall
```

Tests do not require a live server. They stub out `systemctl`, `nft`, `k3s`, `ss`, `id`, `pkill`, and `userdel` with scripts in a temp `bin/` dir prepended to `PATH`, and redirect all writes to a temp root via `DUNE_NATIVE_TEST_ROOT`.

## Architecture

### `linux/dune-native.sh`

Single ~3000-line Bash script that is the entire entrypoint. All commands (`setup`, `start`, `stop`, `backup`, `firewall`, etc.) are implemented as functions and dispatched from a `main` case statement at the bottom.

**Testability hooks** — every path that touches the real filesystem is controlled by an env var:

| Env var | Defaults to |
|---|---|
| `DUNE_NATIVE_TEST_ROOT` | (empty — real root) |
| `DUNE_NATIVE_ETC_DIR` | `/etc` |
| `DUNE_NATIVE_VAR_DIR` | `/var` |
| `DUNE_NATIVE_RUN_DIR` | `/run` |
| `DUNE_NATIVE_USR_LOCAL_DIR` | `/usr/local` |
| `DUNE_NATIVE_OPT_DIR` | `/opt` |
| `DUNE_NATIVE_FUNCOM_ROOT` | `/funcom` |
| `DUNE_NATIVE_SYSTEMD_DIR` | `$HOST_ETC/systemd/system` |

Setting `DUNE_NATIVE_TEST_ROOT` populates all the above at once.

**Sourcing for unit tests** — individual functions can be tested by setting `DUNE_NATIVE_SOURCE_ONLY=1` and sourcing the script in bash: `source linux/dune-native.sh`. The test harness uses this for `parse_setup_args`, `world_region_selection`, and `secure_local_world_specs`.

**Key layout at runtime:**
- `settings.conf` — 4-line file at `/home/dune/.dune/settings.conf`: lines 3 and 4 are internal IP and public IP respectively
- k3s runner — `/usr/local/bin/dune-k3s-runner` — generated script that detects the host IP dynamically and starts `k3s server` with correct `--node-ip`/`--node-external-ip` flags
- Funcom operators — deployed into the `funcom-operators` k3s namespace; all four operators (battlegroup, database, server, utilities) start at `replicas: 0` and are scaled up by vendor scripts
- Battlegroup namespaces — follow the pattern `funcom-seabass-<world-name>`
- Backups — stored at `/funcom/artifacts/database-dumps/<battlegroup-name>/`

**Firewall design** — `install-firewall` generates a dedicated `inet dune_native` nftables table with `policy accept` (never sets default drop). It only drops the discovered Dune admin TCP ports, after allowing loopback and trusted admin CIDRs. Player-facing ports (`7777-7810/udp`, `31982/tcp`) and unrelated services like SSH are never touched.

### `tests/test_dune_native.py`

pytest test module. `make_harness(tmp_path)` creates:
- a temp root directory (`DUNE_NATIVE_TEST_ROOT`)  
- a temp `bin/` directory with stub commands prepended to `PATH` — stubs: `systemctl`, `nft`, `k3s`, `ss`, `id`, `pkill`, `userdel`, `systemd-tmpfiles`
- a `commands.log` file that stub commands append to (useful for asserting what was invoked)

The k3s stub handles `get pvc`, `get pv`, and `get igwbg -o json` to support `apply-canonical` tests. Tests that need `UserSettings/*.ini` files pre-create them under `root/var/lib/rancher/k3s/storage/pvc-test/Saved/UserSettings/`.

`run_script(args, env)` invokes `dune-native.sh` as a subprocess.  
`source_script_and_run(shell_body, env)` sources the script and runs a shell snippet — used for testing internal functions directly.

## Key operational notes

- `DUNE_ALLOW_SPINNING_DISK=1` overrides the SSD requirement check to a warning
- Token files must be `chmod 600`; passing tokens via `--self-hosted-token` works but is discouraged (shell history)
- After `set-self-hosted-token`, the token is still embedded in Kubernetes specs/env fields by Funcom's CRDs — keep kubeconfig and `/home/dune/.dune/sh-*.yaml` access restricted
- `teardown` requires typing `TEARDOWN dune` unless `--yes` is passed; `restore-latest` requires typing `RESTORE <filename>`
- `doctor --external` needs `DUNE_EXTERNAL_PROBE_SSH=user@host` to check router/NAT forwarding from outside the LAN
- `apply-canonical` is idempotent — safe to re-run after Funcom updates reset `UserSettings/*.ini` to defaults
- `install-manager-service` installs the [adainrivers/dune-dedicated-server-manager](https://github.com/adainrivers/dune-dedicated-server-manager) daemon, which provides in-game GM commands (via RabbitMQ), player position queries (via Postgres), and scheduled maintenance. The daemon listens on `localhost:29187` and is accessed via SSH tunnel from the desktop app. Its HTTP API (`/api/admin/player-location`, `/api/admin/players`, etc.) is also the data source for a future real-time player map.
