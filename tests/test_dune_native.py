import os
import shlex
import stat
import subprocess
from pathlib import Path

import pytest


REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "linux" / "dune-native.sh"


def write_executable(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def make_harness(tmp_path: Path) -> tuple[dict[str, str], Path]:
    root = tmp_path / "root"
    bin_dir = tmp_path / "bin"
    log = tmp_path / "commands.log"
    bin_dir.mkdir()
    log.write_text("")

    common_header = f"""#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\\n' "$(basename "$0") $*" >> {log}
"""

    write_executable(
        bin_dir / "systemctl",
        common_header
        + """
case "${1:-}" in
  status)
    exit 4
    ;;
  list-unit-files)
    exit 1
    ;;
  is-active|is-enabled)
    exit 1
    ;;
esac
exit 0
""",
    )

    write_executable(
        bin_dir / "nft",
        common_header
        + """
rules="${DUNE_NATIVE_TEST_ROOT}/etc/dune-native-firewall.nft"
if [ "${1:-}" = "list" ] && [ "${2:-}" = "table" ] && [ "${3:-}" = "inet" ] && [ "${4:-}" = "dune_native" ]; then
  [ -f "${rules}" ] || exit 1
  cat "${rules}"
  exit 0
fi
if [ "${1:-}" = "delete" ] && [ "${2:-}" = "table" ]; then
  rm -f "${rules}"
  exit 0
fi
if [ "${1:-}" = "-f" ]; then
  cat "${2:-/dev/null}" >/dev/null
  exit 0
fi
exit 0
""",
    )

    write_executable(
        bin_dir / "k3s",
        common_header
        + r'''
shift # kubectl
if [ "${1:-}" = "get" ] && [ "${2:-}" = "ns" ]; then
  printf 'funcom-seabass-sh-test\n'
  exit 0
fi
if [ "${1:-}" = "get" ] && [ "${2:-}" = "nodes" ] && [[ "$*" == *"-o json"* ]]; then
  cat <<'JSON'
{
  "items": [
    {
      "spec": {
        "podCIDR": "10.42.0.0/24",
        "podCIDRs": ["10.42.0.0/24"]
      }
    }
  ]
}
JSON
  exit 0
fi
if [ "${1:-}" = "get" ] && [ "${2:-}" = "databaseutility" ]; then
  printf '10099'
  exit 0
fi
if [ "${1:-}" = "get" ] && [ "${2:-}" = "svc" ] && [[ "$*" == *"-l app=sh-test-mq-game-sts"* ]]; then
  printf '31982'
  exit 0
fi
if [ "${1:-}" = "get" ] && [ "${2:-}" = "svc" ] && [[ "$*" == *"-o json"* ]]; then
  cat <<'JSON'
{
  "items": [
    {
      "metadata": {"name": "sh-test-bgd-svc"},
      "spec": {"type": "NodePort", "ports": [{"port": 11717, "nodePort": 31097}]}
    },
    {
      "metadata": {"name": "sh-test-mq-admin-svc"},
      "spec": {"type": "NodePort", "ports": [{"port": 15672, "nodePort": 30312}, {"port": 5672, "nodePort": 30663}]}
    },
    {
      "metadata": {"name": "sh-test-mq-game-svc"},
      "spec": {"type": "NodePort", "ports": [{"port": 15672, "nodePort": 32658}, {"port": 5672, "nodePort": 31982}]}
    }
  ]
}
JSON
  exit 0
fi
if [ "${1:-}" = "get" ] && [ "${2:-}" = "pvc" ] && [[ "$*" == *"-l role=igw-server"* ]]; then
  printf 'sh-test-server-pvc\n'
  exit 0
fi
if [ "${1:-}" = "get" ] && [ "${2:-}" = "pvc" ] && [ "${3:-}" = "sh-test-server-pvc" ]; then
  printf 'pv-sh-test-server\n'
  exit 0
fi
if [ "${1:-}" = "get" ] && [ "${2:-}" = "pv" ]; then
  printf '%s\n' "${DUNE_NATIVE_TEST_ROOT}/var/lib/rancher/k3s/storage/pvc-test"
  exit 0
fi
if [ "${1:-}" = "get" ] && [ "${2:-}" = "igwbg" ] && [[ "$*" == *"-o json"* ]]; then
  cat <<'JSON'
{"spec":{"serverGroup":{"template":{"spec":{"sets":[
  {"map":"Survival_1","resources":{"limits":{"memory":"12Gi"}},"dedicatedScaling":false},
  {"map":"Overmap","resources":{"limits":{"memory":"2Gi"}},"dedicatedScaling":false},
  {"map":"DeepDesert_1","resources":{"limits":{"memory":"15Gi"}},"dedicatedScaling":true}
]}}}}}
JSON
  exit 0
fi
if [ "${1:-}" = "patch" ] && [ "${2:-}" = "igwbg" ]; then
  exit 0
fi
exit 0
''',
    )

    write_executable(bin_dir / "systemd-tmpfiles", common_header + "exit 0\n")

    write_executable(
        bin_dir / "curl",
        common_header
        + r"""
if [[ "$*" == *"api.github.com"* ]]; then
  printf '{"tag_name":"v0.3.15","assets":[{"name":"dune-server-service","browser_download_url":"https://fake.example.com/binary"}]}\n'
  exit 0
fi
printf '#!/bin/sh\necho fake-dune-server-service\n'
exit 0
""",
    )

    write_executable(
        bin_dir / "ss",
        common_header
        + """
if [[ "$*" == *"-ltnH"* ]]; then
  cat <<'SS'
LISTEN 0 4096 *:6443 *:*
LISTEN 0 4096 *:10250 *:*
LISTEN 0 4096 0.0.0.0:5432 0.0.0.0:*
LISTEN 0 4096 *:8888 *:*
LISTEN 0 4096 0.0.0.0:10099 0.0.0.0:*
SS
fi
""",
    )

    write_executable(bin_dir / "id", common_header + "exit 0\n")
    write_executable(bin_dir / "pkill", common_header + "exit 0\n")
    write_executable(bin_dir / "userdel", common_header + "exit 0\n")

    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{bin_dir}:{env['PATH']}",
            "DUNE_NATIVE_ASSUME_ROOT": "1",
            "DUNE_NATIVE_TEST_ROOT": str(root),
            "DUNE_USER": "testdune",
            "DUNE_HOME": str(root / "home" / "testdune"),
        }
    )
    return env, log


def run_script(args, env, input_text=None):
    return subprocess.run(
        ["bash", str(SCRIPT), *args],
        cwd=REPO,
        env=env,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def source_script_and_run(shell_body: str, env: dict[str, str]):
    return subprocess.run(
        ["bash", "-c", f"source {shlex.quote(str(SCRIPT))}; {shell_body}"],
        cwd=REPO,
        env={**env, "DUNE_NATIVE_SOURCE_ONLY": "1"},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def test_script_has_valid_bash_syntax():
    result = subprocess.run(["bash", "-n", str(SCRIPT)], cwd=REPO, text=True, capture_output=True)
    assert result.returncode == 0, result.stderr


def test_setup_args_read_self_hosted_token_file_from_env(tmp_path):
    env, _log = make_harness(tmp_path)
    token_file = tmp_path / "token.jwt"
    token_file.write_text("aaa.bbb.ccc\n")
    token_file.chmod(0o600)
    env["DUNE_SELF_HOSTED_TOKEN_FILE"] = str(token_file)

    result = source_script_and_run(
        "parse_setup_args --world-name Nerdery --world-region Europe --yes; "
        "printf '%s\\n' \"$SETUP_SELF_HOSTED_TOKEN\"",
        env,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == "aaa.bbb.ccc\n"


def test_create_world_args_accept_explicit_self_hosted_token_file(tmp_path):
    env, _log = make_harness(tmp_path)
    token_file = tmp_path / "token.jwt"
    token_file.write_text("ddd.eee.fff\n")
    token_file.chmod(0o600)

    result = source_script_and_run(
        f"parse_world_args --world-name Nerdery --world-region Europe --self-hosted-token-file {shlex.quote(str(token_file))}; "
        "printf '%s\\n' \"$SETUP_SELF_HOSTED_TOKEN\"",
        env,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == "ddd.eee.fff\n"


def test_setup_args_accept_pghero_port_from_env(tmp_path):
    env, _log = make_harness(tmp_path)
    env["DUNE_PGHERO_PORT"] = "10099"

    result = source_script_and_run(
        "parse_setup_args --world-name Nerdery --world-region Europe --self-hosted-token aaa.bbb.ccc --yes; "
        "printf '%s\\n' \"$SETUP_PGHERO_PORT\"",
        env,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == "10099\n"


def test_world_region_mapping_matches_current_vendor_menu(tmp_path):
    env, _log = make_harness(tmp_path)

    result = source_script_and_run(
        "world_region_selection Europe; world_region_selection 'North America'",
        env,
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == "1\n2\n"


def test_secure_local_world_specs_locks_down_generated_secrets(tmp_path):
    env, _log = make_harness(tmp_path)
    dune_root = Path(env["DUNE_HOME"]) / ".dune"
    dune_root.mkdir(parents=True)

    secret_specs = [
        dune_root / "sh-test.yaml",
        dune_root / "sh-test-rmq-secret.yaml",
        dune_root / "sh-test-fls-secret.yaml",
    ]
    ignored_specs = [
        dune_root / "sh-test-dump-20260520.yaml",
        dune_root / "sh-test-restore-20260520.yaml",
    ]
    for path in secret_specs + ignored_specs:
        path.write_text("token: aaa.bbb.ccc\n")
        path.chmod(0o644)

    result = source_script_and_run("secure_local_world_specs", env)

    assert result.returncode == 0, result.stderr
    for path in secret_specs:
        assert stat.S_IMODE(path.stat().st_mode) == 0o600
    for path in ignored_specs:
        assert stat.S_IMODE(path.stat().st_mode) == 0o644


def test_install_firewall_refuses_to_apply_without_trusted_cidrs(tmp_path):
    env, _log = make_harness(tmp_path)
    result = run_script(["install-firewall"], env)
    assert result.returncode != 0
    assert "Trusted admin CIDRs are required" in result.stderr
    assert not (tmp_path / "root" / "etc" / "dune-native-firewall.nft").exists()


def test_install_firewall_generates_dedicated_table_for_dune_admin_ports_only(tmp_path):
    env, _log = make_harness(tmp_path)
    result = run_script(["install-firewall", "--admin-cidrs", "10.0.0.0/24,100.64.0.0/10"], env)
    assert result.returncode == 0, result.stderr + result.stdout

    rules = (tmp_path / "root" / "etc" / "dune-native-firewall.nft").read_text()
    assert "table inet dune_native" in rules
    assert "policy accept" in rules
    assert "10.0.0.0/24, 100.64.0.0/10, 10.42.0.0/24" in rules
    assert "tcp dport { 5432, 6443, 8888, 10099, 10250, 18888, 30312, 30663, 31097, 32658 } drop" in rules
    assert "31982" not in rules
    assert " 22" not in rules
    assert "policy drop" not in rules

    service = (tmp_path / "root" / "etc" / "systemd" / "system" / "dune-native-firewall.service").read_text()
    assert "ExecStart=" in service
    assert "dune-native-firewall.nft" in service
    assert "FILTERED 6443" in result.stdout


def test_uninstall_firewall_removes_only_dune_firewall_artifacts(tmp_path):
    env, _log = make_harness(tmp_path)
    result = run_script(["install-firewall", "--admin-cidrs", "10.0.0.0/24"], env)
    assert result.returncode == 0, result.stderr

    unrelated = tmp_path / "root" / "etc" / "unrelated.conf"
    unrelated.parent.mkdir(parents=True, exist_ok=True)
    unrelated.write_text("keep me")

    result = run_script(["uninstall-firewall"], env)
    assert result.returncode == 0, result.stderr + result.stdout
    assert not (tmp_path / "root" / "etc" / "dune-native-firewall.nft").exists()
    assert not (tmp_path / "root" / "etc" / "dune-native-firewall.env").exists()
    assert not (tmp_path / "root" / "etc" / "systemd" / "system" / "dune-native-firewall.service").exists()
    assert unrelated.read_text() == "keep me"


def test_teardown_dry_run_does_not_remove_owned_state(tmp_path):
    env, _log = make_harness(tmp_path)
    owned = [
        tmp_path / "root" / "etc" / "dune-native-firewall.env",
        tmp_path / "root" / "var" / "log" / "dune-native" / "backup.log",
        tmp_path / "root" / "funcom" / "artifacts" / "sentinel",
        tmp_path / "root" / "home" / "testdune" / ".dune" / "settings.conf",
    ]
    for path in owned:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("sentinel")

    result = run_script(["teardown", "--dry-run"], env)
    assert result.returncode == 0, result.stderr
    assert "Dune native teardown plan" in result.stdout
    for path in owned:
        assert path.exists(), path


def test_teardown_yes_removes_owned_state_but_preserves_unrelated_files(tmp_path):
    env, log = make_harness(tmp_path)
    root = tmp_path / "root"
    off_host_backup = tmp_path / "off-host-backups" / "backup.copy"
    off_host_backup.parent.mkdir()
    off_host_backup.write_text("keep")

    files_to_remove = {
        root / "etc" / "dune-native-firewall.env": "cidrs",
        root / "etc" / "dune-native-firewall.nft": "rules",
        root / "etc" / "dune-native-backup.env": "backup",
        root / "etc" / "sudoers.d" / "dune-native": "sudoers",
        root / "etc" / "systemd" / "system" / "dune-native-firewall.service": "unit",
        root / "etc" / "systemd" / "system" / "dune-native-backup.timer": "timer",
        root / "etc" / "systemd" / "system" / "dune-native-backup.service": "service",
        root / "usr" / "local" / "bin" / "dune-k3s-runner": "runner",
        root / "usr" / "local" / "bin" / "rc-service": "exec systemctl\n",
        root / "usr" / "local" / "bin" / "rc-update": "Unsupported rc-update action\n",
        root / "usr" / "local" / "bin" / "steamcmd": f'cd "{root / "opt" / "steamcmd"}"\n',
        root / "opt" / "steamcmd" / "steamcmd.sh": "steamcmd",
        root / "funcom" / "artifacts" / "database-dumps" / "backup": "backup",
        root / "home" / "testdune" / ".dune" / "settings.conf": "settings",
        root / "var" / "log" / "dune-native" / "backup.log": "log",
        root / "var" / "lib" / "rancher" / "k3s" / "state": "state",
        root / "etc" / "rancher" / "k3s" / "config.yaml": "config",
        root / "run" / "k3s" / "state": "run",
        root / "etc" / "systemd" / "system" / "dune-server-service.service": "unit",
        root / "etc" / "dune-server-service.env": "env",
        root / "opt" / "dune-server-service" / "dune-server-service": "binary",
    }
    for path, content in files_to_remove.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    unrelated = root / "etc" / "do-not-remove.conf"
    unrelated.write_text("keep")

    result = run_script(["teardown", "--yes"], env)
    assert result.returncode == 0, result.stderr + result.stdout
    assert "Dune native teardown complete" in result.stdout

    for path in files_to_remove:
        assert not path.exists(), path
    assert unrelated.read_text() == "keep"
    assert off_host_backup.read_text() == "keep"
    assert "userdel -r testdune" in log.read_text()


def test_install_containerd_symlink_creates_tmpfiles_conf(tmp_path):
    env, _log = make_harness(tmp_path)
    result = source_script_and_run("install_containerd_socket_symlink", env)
    assert result.returncode == 0, result.stderr
    conf = tmp_path / "root" / "etc" / "tmpfiles.d" / "k3s-containerd-symlink.conf"
    assert conf.exists(), f"tmpfiles.d conf not created: {conf}"
    assert "L /run/containerd /run/k3s/containerd" in conf.read_text()


def test_teardown_yes_removes_containerd_symlink_conf(tmp_path):
    env, _log = make_harness(tmp_path)
    root = tmp_path / "root"
    conf = root / "etc" / "tmpfiles.d" / "k3s-containerd-symlink.conf"
    conf.parent.mkdir(parents=True, exist_ok=True)
    conf.write_text("L /run/containerd /run/k3s/containerd\n")

    result = run_script(["teardown", "--yes"], env)
    assert result.returncode == 0, result.stderr + result.stdout
    assert not conf.exists(), "containerd symlink conf was not removed by teardown"


def test_apply_canonical_sets_sietch_name(tmp_path):
    env, _log = make_harness(tmp_path)
    root = tmp_path / "root"
    usersettings = (
        root
        / "var/lib/rancher/k3s/storage/pvc-test/Saved/UserSettings"
    )
    usersettings.mkdir(parents=True)
    (usersettings / "UserEngine.ini").write_text(
        "[ConsoleVariables]\n;Bgd.ServerDisplayName=\"placeholder\"\n"
    )
    (usersettings / "UserGame.ini").write_text(
        "[/Script/DuneSandbox.PvpPveSettings]\nm_bShouldForceEnablePvpOnAllPartitions=False\n"
    )

    result = run_script(
        ["apply-canonical", "--sietch-name", "Test Sietch", "--no-stop"], env
    )
    assert result.returncode == 0, result.stderr + result.stdout
    engine_ini = (usersettings / "UserEngine.ini").read_text()
    assert 'Bgd.ServerDisplayName="Test Sietch"' in engine_ini


def test_apply_canonical_sets_pvp_partition(tmp_path):
    env, _log = make_harness(tmp_path)
    root = tmp_path / "root"
    usersettings = (
        root
        / "var/lib/rancher/k3s/storage/pvc-test/Saved/UserSettings"
    )
    usersettings.mkdir(parents=True)
    (usersettings / "UserEngine.ini").write_text("[ConsoleVariables]\n")
    (usersettings / "UserGame.ini").write_text(
        "[/Script/DuneSandbox.PvpPveSettings]\nm_bShouldForceEnablePvpOnAllPartitions=False\n"
    )

    result = run_script(
        ["apply-canonical", "--pvp-partition", "8", "--no-stop"], env
    )
    assert result.returncode == 0, result.stderr + result.stdout
    game_ini = (usersettings / "UserGame.ini").read_text()
    assert "+m_PvpEnabledPartitions=8" in game_ini


def test_apply_canonical_idempotent_sietch_name(tmp_path):
    """Running apply-canonical twice should not duplicate the display name."""
    env, _log = make_harness(tmp_path)
    root = tmp_path / "root"
    usersettings = (
        root
        / "var/lib/rancher/k3s/storage/pvc-test/Saved/UserSettings"
    )
    usersettings.mkdir(parents=True)
    (usersettings / "UserEngine.ini").write_text("[ConsoleVariables]\n")
    (usersettings / "UserGame.ini").write_text(
        "[/Script/DuneSandbox.PvpPveSettings]\n"
    )

    for _ in range(2):
        result = run_script(
            ["apply-canonical", "--sietch-name", "My Sietch", "--no-stop"], env
        )
        assert result.returncode == 0, result.stderr

    engine_ini = (usersettings / "UserEngine.ini").read_text()
    assert engine_ini.count('Bgd.ServerDisplayName=') == 1


def test_doctor_json_produces_valid_json_with_expected_shape(tmp_path):
    """doctor --json must emit valid JSON with summary + checks array regardless of check outcomes."""
    import json

    env, _log = make_harness(tmp_path)
    result = run_script(["doctor", "--json"], env)

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        pytest.fail(
            f"doctor --json output is not valid JSON: {exc}\nstdout: {result.stdout!r}\nstderr: {result.stderr!r}"
        )

    assert "summary" in data, "missing top-level 'summary' key"
    assert "failures" in data["summary"]
    assert "warnings" in data["summary"]
    assert isinstance(data["summary"]["failures"], int)
    assert isinstance(data["summary"]["warnings"], int)

    assert "checks" in data, "missing top-level 'checks' key"
    assert isinstance(data["checks"], list)

    for check in data["checks"]:
        assert "section" in check, f"check missing 'section': {check}"
        assert "status" in check, f"check missing 'status': {check}"
        assert check["status"] in ("ok", "warn", "fail"), f"unexpected status: {check['status']}"
        assert "message" in check, f"check missing 'message': {check}"

    # Verify no colored ANSI escape codes leaked into JSON output
    assert "\033[" not in result.stdout, "ANSI escape codes found in JSON output"


def test_apply_canonical_patches_memory_limit_via_kubectl(tmp_path):
    env, log = make_harness(tmp_path)
    root = tmp_path / "root"
    usersettings = root / "var/lib/rancher/k3s/storage/pvc-test/Saved/UserSettings"
    usersettings.mkdir(parents=True)
    (usersettings / "UserEngine.ini").write_text("[ConsoleVariables]\n")
    (usersettings / "UserGame.ini").write_text("[/Script/DuneSandbox.PvpPveSettings]\n")

    result = run_script(
        ["apply-canonical", "--mem-survival", "24Gi", "--no-stop"], env
    )
    assert result.returncode == 0, result.stderr + result.stdout

    commands = log.read_text()
    assert "patch igwbg" in commands, f"kubectl patch igwbg not called;\ncommands:\n{commands}"
    assert "24Gi" in commands, f"memory value not in kubectl patch call;\ncommands:\n{commands}"


def test_install_manager_service_creates_unit_and_env(tmp_path):
    env, _log = make_harness(tmp_path)
    root = tmp_path / "root"

    result = run_script(
        ["install-manager-service", "--port", "29187", "--timezone", "Europe/London"],
        env,
    )
    assert result.returncode == 0, result.stderr + result.stdout

    unit = root / "etc" / "systemd" / "system" / "dune-server-service.service"
    assert unit.exists(), "systemd unit not created"
    unit_text = unit.read_text()
    assert "ExecStart=" in unit_text
    assert "dune-server-service" in unit_text
    assert "WantedBy=multi-user.target" in unit_text

    env_file = root / "etc" / "dune-server-service.env"
    assert env_file.exists(), "env file not created"
    env_text = env_file.read_text()
    assert "DUNE_DASHBOARD_PORT=29187" in env_text
    assert "DUNE_SERVICE_TIME_ZONE=Europe/London" in env_text

    binary = root / "opt" / "dune-server-service" / "dune-server-service"
    assert binary.exists(), "binary not created"
    assert binary.stat().st_mode & stat.S_IXUSR, "binary not executable"


def test_uninstall_manager_service_removes_artifacts(tmp_path):
    env, _log = make_harness(tmp_path)
    root = tmp_path / "root"

    unit = root / "etc" / "systemd" / "system" / "dune-server-service.service"
    env_file = root / "etc" / "dune-server-service.env"
    binary = root / "opt" / "dune-server-service" / "dune-server-service"
    for path in (unit, env_file, binary):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("content")

    result = run_script(["uninstall-manager-service"], env)
    assert result.returncode == 0, result.stderr + result.stdout
    assert not unit.exists(), "unit file not removed"
    assert not env_file.exists(), "env file not removed"
    assert not binary.exists(), "binary not removed"


def test_teardown_keep_flags_preserve_user_and_funcom_artifacts(tmp_path):
    env, _log = make_harness(tmp_path)
    root = tmp_path / "root"
    user_file = root / "home" / "testdune" / ".dune" / "settings.conf"
    backup_file = root / "funcom" / "artifacts" / "database-dumps" / "backup"
    for path in (user_file, backup_file):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("keep")

    result = run_script(["teardown", "--yes", "--keep-user", "--keep-backups"], env)
    assert result.returncode == 0, result.stderr + result.stdout
    assert user_file.read_text() == "keep"
    assert backup_file.read_text() == "keep"
