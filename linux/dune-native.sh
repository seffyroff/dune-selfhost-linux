#!/usr/bin/env bash
set -Eeuo pipefail

# Linux-native Dune: Awakening dedicated server bootstrap.
#
# This recreates the useful parts of the shipped Hyper-V guest directly on a
# Linux host: k3s, the Dune user/home layout, SteamCMD app 4754530, and the
# battlegroup setup/management entrypoint.

APP_ID="${DUNE_STEAM_APP_ID:-4754530}"
K3S_VERSION="v1.34.5+k3s1"
CERT_MANAGER_VERSION="v1.8.0"
DUNE_USER="${DUNE_USER:-dune}"
DUNE_HOME="${DUNE_HOME:-/home/${DUNE_USER}}"
DUNE_ROOT="${DUNE_HOME}/.dune"
DOWNLOAD_PATH="${DUNE_ROOT}/download"
SETTINGS_FILE="${DUNE_ROOT}/settings.conf"
DUNE_NATIVE_TEST_ROOT="${DUNE_NATIVE_TEST_ROOT:-}"
HOST_ETC="${DUNE_NATIVE_ETC_DIR:-${DUNE_NATIVE_TEST_ROOT:+${DUNE_NATIVE_TEST_ROOT}/etc}}"; HOST_ETC="${HOST_ETC:-/etc}"
HOST_VAR="${DUNE_NATIVE_VAR_DIR:-${DUNE_NATIVE_TEST_ROOT:+${DUNE_NATIVE_TEST_ROOT}/var}}"; HOST_VAR="${HOST_VAR:-/var}"
HOST_RUN="${DUNE_NATIVE_RUN_DIR:-${DUNE_NATIVE_TEST_ROOT:+${DUNE_NATIVE_TEST_ROOT}/run}}"; HOST_RUN="${HOST_RUN:-/run}"
HOST_USR_LOCAL="${DUNE_NATIVE_USR_LOCAL_DIR:-${DUNE_NATIVE_TEST_ROOT:+${DUNE_NATIVE_TEST_ROOT}/usr/local}}"; HOST_USR_LOCAL="${HOST_USR_LOCAL:-/usr/local}"
HOST_OPT="${DUNE_NATIVE_OPT_DIR:-${DUNE_NATIVE_TEST_ROOT:+${DUNE_NATIVE_TEST_ROOT}/opt}}"; HOST_OPT="${HOST_OPT:-/opt}"
SYSTEMD_DIR="${DUNE_NATIVE_SYSTEMD_DIR:-${HOST_ETC}/systemd/system}"
FUNCOM_ROOT="${DUNE_NATIVE_FUNCOM_ROOT:-${DUNE_NATIVE_TEST_ROOT:+${DUNE_NATIVE_TEST_ROOT}/funcom}}"; FUNCOM_ROOT="${FUNCOM_ROOT:-/funcom}"
RUNNER="${DUNE_NATIVE_RUNNER:-${HOST_USR_LOCAL}/bin/dune-k3s-runner}"
K3S_CONFIG_DIR="${DUNE_NATIVE_K3S_CONFIG_DIR:-${HOST_ETC}/rancher/k3s}"
K3S_DATA_DIR="${DUNE_NATIVE_K3S_DATA_DIR:-${HOST_VAR}/lib/rancher/k3s}"
K3S_MANIFEST_DIR="${K3S_DATA_DIR}/server/manifests"
POD_RESOLV_CONF="${K3S_CONFIG_DIR}/pod-resolv.conf"
K3S_OVERRIDE_DIR="${SYSTEMD_DIR}/k3s.service.d"
K3S_UNINSTALL="${DUNE_NATIVE_K3S_UNINSTALL:-${HOST_USR_LOCAL}/bin/k3s-uninstall.sh}"
SUDOERS_FILE="${DUNE_NATIVE_SUDOERS_FILE:-${HOST_ETC}/sudoers.d/dune-native}"
STEAMCMD_DIR="${DUNE_NATIVE_STEAMCMD_DIR:-${HOST_OPT}/steamcmd}"
STEAMCMD_BIN="${DUNE_NATIVE_STEAMCMD_BIN:-${HOST_USR_LOCAL}/bin/steamcmd}"
RC_SERVICE_BIN="${DUNE_NATIVE_RC_SERVICE_BIN:-${HOST_USR_LOCAL}/bin/rc-service}"
RC_UPDATE_BIN="${DUNE_NATIVE_RC_UPDATE_BIN:-${HOST_USR_LOCAL}/bin/rc-update}"
BACKUP_SERVICE="${SYSTEMD_DIR}/dune-native-backup.service"
BACKUP_TIMER="${SYSTEMD_DIR}/dune-native-backup.timer"
BACKUP_ENV_FILE="${HOST_ETC}/dune-native-backup.env"
BACKUP_LOG_DIR="${HOST_VAR}/log/dune-native"
FIREWALL_ENV_FILE="${HOST_ETC}/dune-native-firewall.env"
FIREWALL_RULES_FILE="${HOST_ETC}/dune-native-firewall.nft"
FIREWALL_SERVICE="${SYSTEMD_DIR}/dune-native-firewall.service"
DEFAULT_BACKUP_ON_CALENDAR="03:30"
DEFAULT_BACKUP_RETENTION_DAYS=14
DEFAULT_BACKUP_MAX_AGE_HOURS=30
CONTAINERD_SYMLINK_CONF="${HOST_ETC}/tmpfiles.d/k3s-containerd-symlink.conf"
MANAGER_SERVICE_DIR="${HOST_OPT}/dune-server-service"
MANAGER_SERVICE_BIN="${MANAGER_SERVICE_DIR}/dune-server-service"
MANAGER_SERVICE_UNIT="${SYSTEMD_DIR}/dune-server-service.service"
MANAGER_SERVICE_ENV="${HOST_ETC}/dune-server-service.env"
MANAGER_SERVICE_REPO="adainrivers/dune-dedicated-server-manager"

red=$'\033[0;31m'
green=$'\033[0;32m'
yellow=$'\033[0;33m'
cyan=$'\033[0;36m'
nc=$'\033[0m'

usage() {
  cat <<EOF
Usage: $0 <command> [options]

Commands:
  setup                 Install/configure k3s, download the Dune server app, and run native core setup
  create-world          Create the first battlegroup world after setup
  doctor [--external] [--json]
                        Run health checks; --json emits machine-readable output for the manager service API
  start                 Start the battlegroup
  stop                  Stop the battlegroup
  restart               Restart the battlegroup
  status                Show battlegroup status and Kubernetes pods
  update                Download/apply server updates
  edit                  Open the official battlegroup editor
  edit-advanced         Edit battlegroup YAML through the official tool
  backup                Take a battlegroup database backup
  import                Import a battlegroup database backup
  scheduled-backup      Run one timestamped backup and retention prune for systemd timer use
  install-backup-timer [--daily-at HH:MM] [--retention-days N] [--max-age-hours N]
                        Install and start a daily systemd backup timer
  set-backup-copy-target TARGET|none
                        Configure off-host/local copy target for scheduled backups
  uninstall-backup-timer
                        Disable and remove the systemd backup timer/service
  backup-prune [--retention-days N]
                        Delete database backups older than the retention period
  restore-check [BACKUP] Validate that a backup can be staged for import without changing data
  restore-latest        Restore the newest backup after typed destructive confirmation
  apply-canonical       Apply game config: sietch name, PvP partitions, memory limits, game settings
  install-manager-service [--port PORT] [--timezone TZ] [--auth-token-file FILE]
                        Install the dune-server-service daemon (GM tools, player tracking, scheduling)
  update-manager-service
                        Update dune-server-service binary to the latest GitHub release
  uninstall-manager-service
                        Remove the dune-server-service daemon
  exposure-report       Show Dune public/admin listeners and firewall posture
  firewall-plan         Print firewall hardening commands/snippets without applying them
  install-firewall [--admin-cidrs CIDR[,CIDR]]
                        Install/apply dedicated nftables table for Dune admin ports
  uninstall-firewall    Remove the dedicated Dune nftables table and systemd unit
  set-admin-allowed-cidrs CIDR[,CIDR]|none
                        Configure trusted admin source CIDRs for doctor/firewall-plan
  teardown [--dry-run] [--yes] [--keep-user] [--keep-backups]
                        Remove native k3s, Dune user data, units, firewall, and local artifacts
  enable-experimental-swap
                        Enable the vendor experimental swap feature
  shell                 Open a shell as the ${DUNE_USER} service user
  shell-pod             Select a battlegroup pod and open a shell in it
  battlegroup ARGS...   Pass arguments directly to the vendor battlegroup tool
  director-url          Print the battlegroup Director URL
  open-director         Open the battlegroup Director URL with xdg-open
  file-browser-url      Print the battlegroup file browser URL
  open-file-browser     Open the battlegroup file browser URL with xdg-open
  set-public-ip IP      Update player-facing IP/DNS in settings.conf and restart k3s
  set-interface IFACE   Persist host interface for k3s IP detection and restart k3s
  set-pghero-port PORT  Change the host-network PgHero port for the battlegroup database UI
  set-self-hosted-token [--token-file FILE] [--restart]
                        Read a new self-hosting token securely and patch the battlegroup
  k3s-start             Start only the k3s service
  k3s-stop              Stop only the k3s service
  k3s-status            Show only the k3s service status
  logs-export           Export battlegroup logs through the official tool
  operator-logs-export  Export operator logs through the official tool

Setup options:
  --public-ip IP        IP or DNS name players should connect to
  --internal-ip IP      Node internal IP. Defaults to detected host IP
  --interface IFACE     Interface used for detected host IP
  --world-name NAME     World name to create during setup
  --world-region REGION World region: Europe, North America, Asia, Oceania, South America. Numeric selections 1-5 match the vendor menu
  --self-hosted-token TOKEN
                        Self-hosting token from the Dune account page
  --self-hosted-token-file FILE
                        Read self-hosting token from a chmod 600 file
  --pghero-port PORT    PgHero host port to set after world creation
  --force-existing-k3s  Reconfigure an existing k3s install for Dune
  --no-install-deps     Do not install OS packages automatically
  --no-sudoers          Do not grant ${DUNE_USER} passwordless sudo
  --yes                 Accept prompts

Environment:
  DUNE_USER             Service user name. Default: dune
  DUNE_HOME             Service user home. Default: /home/dune
  DUNE_INTERFACE        Network interface to advertise if --interface is omitted
  DUNE_WORLD_NAME       World name for noninteractive setup/create-world
  DUNE_WORLD_REGION     World region for noninteractive setup/create-world
  DUNE_SELF_HOSTED_TOKEN
                        Self-hosting token for noninteractive setup/create-world
  DUNE_SELF_HOSTED_TOKEN_FILE
                        chmod 600 token file for noninteractive setup/create-world/token rotation
  DUNE_PGHERO_PORT      PgHero host port for noninteractive setup/create-world
  DUNE_ALLOW_SPINNING_DISK=1
                        Warn instead of failing if the install path is on rotational storage
  DUNE_BACKUP_RETENTION_DAYS
                        Backup retention for scheduled-backup/backup-prune. Default: 14
  DUNE_BACKUP_MAX_AGE_HOURS
                        Doctor warning threshold for latest backup age. Default: 30
  DUNE_BACKUP_COPY_TARGET
                        Optional local directory or rclone:remote:path for backup copies
  DUNE_SIETCH_NAME      Sietch display name for apply-canonical
  DUNE_PVP_PARTITION    PvP partition ID for apply-canonical (default: 8)
  DUNE_MEM_SURVIVAL     Hagga Basin memory limit for apply-canonical (e.g. 24Gi)
  DUNE_MEM_DEEP_DESERT  Deep Desert memory limit for apply-canonical
  DUNE_MEM_OVERMAP      Overmap memory limit for apply-canonical
  DUNE_MEM_SIETCH       Sietch hub memory limit for apply-canonical
  DUNE_MINING_MULTIPLIER Mining output multiplier for apply-canonical
  DUNE_SERVER_PASSWORD  Join password for apply-canonical
  DUNE_FARM_REGION      Server browser region for apply-canonical
  DUNE_MANAGER_PORT     Manager service HTTP port. Default: 29187
  DUNE_MANAGER_TIMEZONE Manager service timezone. Default: Europe/London
  DUNE_ADMIN_ALLOWED_CIDRS
                        Comma-separated CIDRs allowed to reach admin surfaces
  DUNE_EXTERNAL_PROBE_SSH
                        Optional SSH target used by doctor --external, e.g. user@vps
  DUNE_EXTERNAL_PROBE_TIMEOUT
                        Timeout seconds for doctor --external probes. Default: 6
EOF
}

log() { printf '%s\n' "${cyan}==>${nc} $*"; }
warn() { printf '%s\n' "${yellow}warning:${nc} $*" >&2; }
die() { printf '%s\n' "${red}error:${nc} $*" >&2; exit 1; }
ok() { printf '%s\n' "${green}ok:${nc} $*"; }

is_root() {
  [ "${EUID}" -eq 0 ] || [ "${DUNE_NATIVE_ASSUME_ROOT:-0}" = "1" ]
}

as_root() {
  if is_root; then
    "$@"
  else
    sudo "$@"
  fi
}

confirm() {
  local prompt="$1"
  if [ "${ASSUME_YES:-0}" = "1" ]; then
    return 0
  fi
  read -r -p "${prompt} [y/N] " reply
  case "${reply}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v pacman >/dev/null 2>&1; then echo pacman; return; fi
  if command -v zypper >/dev/null 2>&1; then echo zypper; return; fi
  echo none
}

install_packages() {
  [ "${INSTALL_DEPS:-1}" = "1" ] || return 0

  local missing=()
  for cmd in curl jq tar awk sed ip sudo systemctl; do
    command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
  done
  if [ "${#missing[@]}" -eq 0 ] && command -v steamcmd >/dev/null 2>&1; then
    return 0
  fi

  local pm
  pm="$(detect_pkg_manager)"
  log "Installing host dependencies with ${pm}"
  case "${pm}" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq tar iproute2 sudo procps
      if ! command -v steamcmd >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y steamcmd || {
          install_steamcmd_apt_runtime
          install_steamcmd_tarball
        }
      fi
      ;;
    dnf)
      dnf install -y ca-certificates curl jq tar iproute sudo procps-ng
      if ! command -v steamcmd >/dev/null 2>&1; then
        dnf install -y steamcmd || install_steamcmd_tarball
      fi
      ;;
    pacman)
      pacman -Sy --needed --noconfirm ca-certificates curl jq tar iproute2 sudo procps-ng
      if ! command -v steamcmd >/dev/null 2>&1; then
        pacman -S --needed --noconfirm steamcmd || install_steamcmd_tarball
      fi
      ;;
    zypper)
      zypper --non-interactive install ca-certificates curl jq tar iproute2 sudo procps
      if ! command -v steamcmd >/dev/null 2>&1; then
        zypper --non-interactive install steamcmd || install_steamcmd_tarball
      fi
      ;;
    none)
      warn "No supported package manager found; trying SteamCMD tarball fallback only"
      install_steamcmd_tarball
      ;;
  esac
}

install_steamcmd_apt_runtime() {
  if dpkg --print-foreign-architectures | grep -qx i386; then
    :
  else
    dpkg --add-architecture i386
    apt-get update
  fi

  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    libc6:i386 \
    libstdc++6:i386 \
    libgcc-s1:i386 \
    zlib1g:i386
  DEBIAN_FRONTEND=noninteractive apt-get install -y libcurl4t64:i386 ||
    DEBIAN_FRONTEND=noninteractive apt-get install -y libcurl4:i386
}

install_steamcmd_tarball() {
  log "Installing SteamCMD into ${STEAMCMD_DIR}"
  mkdir -p "${STEAMCMD_DIR}"
  curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" |
    tar -xz -C "${STEAMCMD_DIR}"
  if id "${DUNE_USER}" >/dev/null 2>&1; then
    chown -R "${DUNE_USER}:${DUNE_USER}" "${STEAMCMD_DIR}"
  fi
  chmod -R u+rwX,go+rX "${STEAMCMD_DIR}"
  rm -f "${STEAMCMD_BIN}"
  install -d -m 0755 "$(dirname "${STEAMCMD_BIN}")"
  cat > "${STEAMCMD_BIN}" <<EOF
#!/usr/bin/env bash
cd "${STEAMCMD_DIR}"
exec "${STEAMCMD_DIR}/steamcmd.sh" "\$@"
EOF
  chmod 0755 "${STEAMCMD_BIN}"
}

install_openrc_compat_wrappers() {
  if ! command -v rc-service >/dev/null 2>&1; then
    log "Installing rc-service compatibility wrapper for vendor scripts"
    install -d -m 0755 "$(dirname "${RC_SERVICE_BIN}")"
    cat > "${RC_SERVICE_BIN}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
service="${1:-}"
action="${2:-}"
[ -n "${service}" ] && [ -n "${action}" ] || { echo "Usage: rc-service SERVICE ACTION" >&2; exit 2; }
exec systemctl "${action}" "${service}"
EOF
    chmod 0755 "${RC_SERVICE_BIN}"
  fi

  if ! command -v rc-update >/dev/null 2>&1; then
    log "Installing rc-update compatibility wrapper for vendor scripts"
    install -d -m 0755 "$(dirname "${RC_UPDATE_BIN}")"
    cat > "${RC_UPDATE_BIN}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
action="${1:-}"
service="${2:-}"
case "${action}" in
  add)
    [ -n "${service}" ] || { echo "Usage: rc-update add SERVICE" >&2; exit 2; }
    exec systemctl enable "${service}"
    ;;
  del|delete|remove)
    [ -n "${service}" ] || { echo "Usage: rc-update del SERVICE" >&2; exit 2; }
    exec systemctl disable "${service}"
    ;;
  *)
    echo "Unsupported rc-update action: ${action}" >&2
    exit 2
    ;;
esac
EOF
    chmod 0755 "${RC_UPDATE_BIN}"
  fi
}

install_containerd_socket_symlink() {
  log "Installing containerd socket symlink for vendor script compatibility"
  install -d -m 0755 "${HOST_ETC}/tmpfiles.d"
  printf 'L /run/containerd /run/k3s/containerd\n' | as_root tee "${CONTAINERD_SYMLINK_CONF}" >/dev/null
  as_root systemd-tmpfiles --create "${CONTAINERD_SYMLINK_CONF}" 2>/dev/null || true
  ok "Installed containerd socket symlink"
}

detect_interface() {
  if [ -n "${SETUP_INTERFACE:-}" ]; then
    echo "${SETUP_INTERFACE}"
    return
  fi
  if [ -n "${DUNE_INTERFACE:-}" ]; then
    echo "${DUNE_INTERFACE}"
    return
  fi
  ip route show default 0.0.0.0/0 | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

detect_host_ip() {
  local iface="$1"
  [ -n "${iface}" ] || die "Could not detect default network interface. Re-run with --interface IFACE."
  ip -4 -o addr show dev "${iface}" scope global | awk '{split($4,a,"/"); print a[1]; exit}'
}

detect_public_ip() {
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
}

write_settings() {
  local internal_ip="$1"
  local public_ip="$2"

  install -d -m 0755 -o "${DUNE_USER}" -g "${DUNE_USER}" "${DUNE_ROOT}"
  printf '\n\n%s\n%s\n' "${internal_ip}" "${public_ip}" > "${SETTINGS_FILE}"
  chown "${DUNE_USER}:${DUNE_USER}" "${SETTINGS_FILE}"
  chmod 0644 "${SETTINGS_FILE}"
}

create_dune_user() {
  if ! id "${DUNE_USER}" >/dev/null 2>&1; then
    log "Creating ${DUNE_USER} service user"
    useradd --create-home --home-dir "${DUNE_HOME}" --shell /bin/bash "${DUNE_USER}"
  fi

  install -d -m 0755 -o "${DUNE_USER}" -g "${DUNE_USER}" "${DUNE_ROOT}" "${DUNE_ROOT}/bin" "${DOWNLOAD_PATH}"
  if [ "${GRANT_SUDOERS:-1}" = "1" ]; then
    cat > "${SUDOERS_FILE}" <<EOF
${DUNE_USER} ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 0440 "${SUDOERS_FILE}"
  fi
}

write_k3s_files() {
  install -d -m 0755 "${K3S_CONFIG_DIR}" "${K3S_MANIFEST_DIR}"

  cat > "${POD_RESOLV_CONF}" <<'EOF'
nameserver 1.1.1.1
nameserver 9.9.9.9
options timeout:2 attempts:2
EOF

  cat > "${K3S_CONFIG_DIR}/config.yaml" <<EOF
kubelet-arg:
- "eviction-hard=memory.available<100Mi,nodefs.available<1%,nodefs.inodesFree<1%,imagefs.available<1%,imagefs.inodesFree<1%"
- image-gc-high-threshold=99
- image-gc-low-threshold=98
- "resolv-conf=${POD_RESOLV_CONF}"
disable:
- traefik
EOF

  cat > "${K3S_CONFIG_DIR}/scheduler.yaml" <<EOF
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: ${K3S_DATA_DIR}/server/cred/scheduler.kubeconfig
profiles:
  - schedulerName: default-scheduler
  - schedulerName: memory-focused-scheduler
    plugins:
      score:
        enabled:
        - name: NodeResourcesFit
          weight: 2
EOF

  cat > "${K3S_MANIFEST_DIR}/dune-rolebindings.yaml" <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-apiserver-kubelet-admin
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kubelet-api-admin
subjects:
- apiGroup: rbac.authorization.k8s.io
  kind: User
  name: kube-apiserver
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: clustercidrs-node
rules:
- apiGroups:
  - networking.k8s.io
  resources:
  - clustercidrs
  verbs:
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: clustercidrs-node
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: clustercidrs-node
subjects:
  - kind: Group
    name: system:nodes
    apiGroup: rbac.authorization.k8s.io
EOF

  cat > "${K3S_MANIFEST_DIR}/dune-runtimes.yaml" <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
---
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia-experimental
handler: nvidia-experimental
EOF

  cat > "${RUNNER}" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

settings="\${DUNE_SETTINGS_FILE:-${SETTINGS_FILE}}"
iface="\${DUNE_INTERFACE:-}"

if [ -z "\${iface}" ]; then
  iface="\$(ip route show default 0.0.0.0/0 | awk '{for (i=1;i<=NF;i++) if (\$i=="dev") {print \$(i+1); exit}}')"
fi
[ -n "\${iface}" ] || { echo "Could not detect default interface" >&2; exit 1; }

dynamic_ip="\$(ip -4 -o addr show dev "\${iface}" scope global | awk '{split(\$4,a,"/"); print a[1]; exit}')"
[ -n "\${dynamic_ip}" ] || { echo "Could not detect IPv4 address for \${iface}" >&2; exit 1; }

bg_name=""
image=""
internal_ip="\${dynamic_ip}"
external_ip="\${dynamic_ip}"
if [ -f "\${settings}" ]; then
  {
    IFS= read -r bg_name || true
    IFS= read -r image || true
    IFS= read -r internal_ip || true
    IFS= read -r external_ip || true
  } < "\${settings}"
fi

[ -n "\${internal_ip}" ] || internal_ip="\${dynamic_ip}"
[ -n "\${external_ip}" ] || external_ip="\${dynamic_ip}"
if [ "\${internal_ip}" = "\${external_ip}" ]; then
  external_ip="\${dynamic_ip}"
fi

exec k3s server \\
  --disable=traefik \
  --tls-san="\${dynamic_ip}" \
  --tls-san=127.0.0.1 \
  --node-external-ip="\${external_ip}" \
  --node-ip="\${dynamic_ip}" \
  --advertise-address="\${dynamic_ip}" \
  --kube-scheduler-arg=config=${K3S_CONFIG_DIR}/scheduler.yaml
EOF
  chmod 0755 "${RUNNER}"
}

install_k3s() {
  local existing=0
  systemctl cat k3s >/dev/null 2>&1 && existing=1
  if [ "${existing}" = "1" ] && [ "${FORCE_EXISTING_K3S:-0}" != "1" ]; then
    die "k3s is already installed. Re-run with --force-existing-k3s to let this script own it."
  fi

  write_k3s_files

  if ! command -v k3s >/dev/null 2>&1 || [ "${existing}" != "1" ]; then
    log "Installing k3s ${K3S_VERSION}"
    curl -sfL https://get.k3s.io |
      INSTALL_K3S_VERSION="${K3S_VERSION}" INSTALL_K3S_SKIP_START=true sh -
  fi

  log "Installing Dune k3s systemd override"
  install -d -m 0755 "${K3S_OVERRIDE_DIR}"
  cat > "${K3S_OVERRIDE_DIR}/10-dune-native.conf" <<EOF
[Service]
ExecStart=
ExecStart=${RUNNER}
Environment=DUNE_SETTINGS_FILE=${SETTINGS_FILE}
EOF
  if [ -n "${SETUP_INTERFACE:-}" ]; then
    printf 'Environment=DUNE_INTERFACE=%s\n' "${SETUP_INTERFACE}" >> "${K3S_OVERRIDE_DIR}/10-dune-native.conf"
  fi

  systemctl daemon-reload
  systemctl enable k3s
  systemctl restart k3s
}

wait_for_k3s() {
  log "Waiting for k3s API"
  local i
  for i in $(seq 1 90); do
    if k3s kubectl get nodes >/dev/null 2>&1; then
      ok "k3s is ready"
      return 0
    fi
    sleep 2
  done
  systemctl status k3s --no-pager || true
  die "k3s did not become ready"
}

install_cert_manager_manifest() {
  if k3s kubectl get deployment -n cert-manager cert-manager >/dev/null 2>&1; then
    return 0
  fi

  log "Installing cert-manager ${CERT_MANAGER_VERSION} manifests"
  k3s kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  k3s kubectl -n cert-manager rollout status deployment/cert-manager --timeout=180s
  k3s kubectl -n cert-manager rollout status deployment/cert-manager-cainjector --timeout=180s
  k3s kubectl -n cert-manager rollout status deployment/cert-manager-webhook --timeout=180s
}

download_steam_app() {
  log "Downloading Steam app ${APP_ID}"
  local attempt max_attempts
  max_attempts=4
  for attempt in $(seq 1 "${max_attempts}"); do
    if sudo -u "${DUNE_USER}" -H env HOME="${DUNE_HOME}" steamcmd \
      +@sSteamCmdForcePlatformType linux \
      +set_spew_level 1 1 \
      +force_install_dir "${DOWNLOAD_PATH}" \
      +login anonymous \
      +app_info_update 1 \
      +app_update "${APP_ID}" \
      +logoff \
      +quit; then
      break
    fi
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      die "Steam app ${APP_ID} failed to install after ${max_attempts} attempts"
    fi
    warn "Steam app ${APP_ID} install failed; retrying after appinfo refresh (${attempt}/${max_attempts})"
    sleep $((attempt * 10))
  done

  [ -f "${DOWNLOAD_PATH}/scripts/setup.sh" ] || die "Steam download completed but ${DOWNLOAD_PATH}/scripts/setup.sh is missing"
  [ -f "${DOWNLOAD_PATH}/scripts/battlegroup.sh" ] || die "Steam download completed but ${DOWNLOAD_PATH}/scripts/battlegroup.sh is missing"
}

import_operator_images() {
  local image
  log "Importing Funcom operator images into k3s"
  for image in \
    "${DOWNLOAD_PATH}/images/operators/battlegroup-operator.tar" \
    "${DOWNLOAD_PATH}/images/operators/database-operator.tar" \
    "${DOWNLOAD_PATH}/images/operators/server-operator.tar" \
    "${DOWNLOAD_PATH}/images/operators/utilities-operator.tar"; do
    [ -f "${image}" ] || die "Operator image archive is missing: ${image}"
    as_root k3s ctr -n k8s.io images import "${image}"
  done
}

run_vendor_setup() {
  log "Running vendor setup.sh"
  chmod +x "${DOWNLOAD_PATH}/scripts/setup.sh"
  sudo -u "${DUNE_USER}" -H env \
    HOME="${DUNE_HOME}" \
    PATH="${HOST_USR_LOCAL}/bin:/usr/local/bin:/usr/bin:/bin:${DUNE_ROOT}/bin" \
    KUBECONFIG="${K3S_CONFIG_DIR}/k3s.yaml" \
    "${DOWNLOAD_PATH}/scripts/setup.sh"
}

run_as_dune() {
  sudo -u "${DUNE_USER}" -H env \
    HOME="${DUNE_HOME}" \
    PATH="${HOST_USR_LOCAL}/bin:/usr/local/bin:/usr/bin:/bin:${DUNE_ROOT}/bin" \
    KUBECONFIG="${K3S_CONFIG_DIR}/k3s.yaml" \
    "$@"
}

run_bash_as_dune() {
  sudo -u "${DUNE_USER}" -H env \
    HOME="${DUNE_HOME}" \
    PATH="${HOST_USR_LOCAL}/bin:/usr/local/bin:/usr/bin:/bin:${DUNE_ROOT}/bin" \
    KUBECONFIG="${K3S_CONFIG_DIR}/k3s.yaml" \
    bash "$@"
}

prepare_vendor_scripts() {
  chmod +x "${DOWNLOAD_PATH}/scripts/setup.sh" \
    "${DOWNLOAD_PATH}/scripts/setup/k3s.sh" \
    "${DOWNLOAD_PATH}/scripts/setup/system.sh" \
    "${DOWNLOAD_PATH}/scripts/setup/world.sh" \
    "${DOWNLOAD_PATH}/scripts/battlegroup.sh"
  [ ! -f "${DOWNLOAD_PATH}/scripts/bg-util" ] || chmod +x "${DOWNLOAD_PATH}/scripts/bg-util"
}

link_vendor_tools() {
  install -d -m 0755 -o "${DUNE_USER}" -g "${DUNE_USER}" "${DUNE_ROOT}/bin"
  ln -sfn "${DOWNLOAD_PATH}/scripts/battlegroup.sh" "${DUNE_ROOT}/bin/battlegroup"
  if [ -f "${DOWNLOAD_PATH}/scripts/bg-util" ]; then
    ln -sfn "${DOWNLOAD_PATH}/scripts/bg-util" "${DUNE_ROOT}/bin/bg-util"
  fi
}

run_vendor_core_setup() {
  prepare_vendor_scripts
  install_openrc_compat_wrappers

  log "Running vendor k3s/image/operator setup"
  run_bash_as_dune "${DOWNLOAD_PATH}/scripts/setup/k3s.sh"
  link_vendor_tools
}

world_region_selection() {
  local region
  region="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "${region}" in
    1|europe|europe\ test|europe-test|europe_test) echo 1 ;;
    2|north\ america|north-america|north_america|north\ america\ test|north-america-test|north_america_test) echo 2 ;;
    3|asia) echo 3 ;;
    4|oceania) echo 4 ;;
    5|south\ america|south-america|south_america) echo 5 ;;
    *) die "Unsupported world region: $1" ;;
  esac
}

have_world_inputs() {
  [ -n "${SETUP_WORLD_NAME:-}" ] && [ -n "${SETUP_WORLD_REGION:-}" ] && [ -n "${SETUP_SELF_HOSTED_TOKEN:-}" ]
}

wait_for_filebrowser_pod() {
  log "Waiting for battlegroup filebrowser pod"
  local i
  for i in $(seq 1 120); do
    if run_kubectl get pods -A -l role=igw-filebrowser --field-selector=status.phase=Running --no-headers 2>/dev/null | awk 'NF {found=1} END {exit found ? 0 : 1}'; then
      ok "filebrowser pod is running"
      return 0
    fi
    sleep 5
  done
  die "Timed out waiting for battlegroup filebrowser pod"
}

run_vendor_world_setup() {
  prepare_vendor_scripts
  link_vendor_tools

  if have_world_inputs; then
    local region_choice
    region_choice="$(world_region_selection "${SETUP_WORLD_REGION}")"
    log "Creating Dune world '${SETUP_WORLD_NAME}' in ${SETUP_WORLD_REGION}"
    printf '%s\n%s\n%s\n' "${SETUP_WORLD_NAME}" "${region_choice}" "${SETUP_SELF_HOSTED_TOKEN}" |
      run_bash_as_dune "${DOWNLOAD_PATH}/scripts/setup/world.sh"
  elif [ -t 0 ]; then
    log "Running interactive world setup"
    run_bash_as_dune "${DOWNLOAD_PATH}/scripts/setup/world.sh"
  else
    die "World creation requires --world-name, --world-region, and --self-hosted-token/--self-hosted-token-file, or an interactive terminal."
  fi

  run_battlegroup update-from-downloads
  run_battlegroup start
  wait_for_filebrowser_pod
  run_battlegroup apply-default-usersettings
}

secure_local_world_specs() {
  local files=()
  while IFS= read -r -d '' file; do
    files+=("${file}")
  done < <(
    as_root find "${DUNE_ROOT}" -maxdepth 1 -type f \( -name 'sh-*.yaml' -o -name 'sh-*-fls-secret.yaml' \) \
      ! -name '*-dump-*.yaml' ! -name '*-import-*.yaml' ! -name '*-restore-*.yaml' ! -name '*-backup-*.yaml' \
      -print0 2>/dev/null
  )
  [ "${#files[@]}" -gt 0 ] || return 0

  as_root chown "${DUNE_USER}:${DUNE_USER}" "${files[@]}" 2>/dev/null || true
  as_root chmod 0600 "${files[@]}" 2>/dev/null || true
}

bootstrap_funcom_operators() {
  local version_file version tmp file out
  version_file="${DOWNLOAD_PATH}/images/operators/version.txt"
  [ -f "${version_file}" ] || die "Operator version file is missing: ${version_file}"
  version="$(tr -d '[:space:]' < "${version_file}")"
  [ -n "${version}" ] || die "Operator version file is empty: ${version_file}"

  log "Bootstrapping Funcom operator namespace/deployments (${version})"
  k3s kubectl create namespace funcom-operators --dry-run=client -o yaml | k3s kubectl apply -f -
  for file in "${DOWNLOAD_PATH}"/images/operators/crds/*.yaml; do
    out="$(mktemp)"
    if ! k3s kubectl create -f "${file}" >"${out}" 2>&1; then
      if grep -q 'AlreadyExists' "${out}"; then
        k3s kubectl replace -f "${file}"
      else
        cat "${out}" >&2
        rm -f "${out}"
        return 1
      fi
    else
      cat "${out}"
    fi
    rm -f "${out}"
  done
  if ! k3s kubectl -n funcom-operators get secret operator-webhook-cert >/dev/null 2>&1; then
    local cert_dir
    cert_dir="$(mktemp -d)"
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout "${cert_dir}/tls.key" \
      -out "${cert_dir}/tls.crt" \
      -subj "/CN=funcom-operator-webhook" \
      -addext "subjectAltName=DNS:funcom-operator-webhook.funcom-operators.svc,DNS:funcom-operator-webhook.funcom-operators.svc.cluster.local" >/dev/null 2>&1
    k3s kubectl -n funcom-operators create secret tls operator-webhook-cert \
      --cert="${cert_dir}/tls.crt" \
      --key="${cert_dir}/tls.key"
    rm -rf "${cert_dir}"
  fi

  tmp="$(mktemp)"
  cat > "${tmp}" <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: battlegroupoperator-controller-manager
  namespace: funcom-operators
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: databaseoperator-controller-manager
  namespace: funcom-operators
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: serveroperator-controller-manager
  namespace: funcom-operators
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: utilitiesoperator-controller-manager
  namespace: funcom-operators
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: funcom-operator-leader-election
  namespace: funcom-operators
rules:
- apiGroups:
  - coordination.k8s.io
  resources:
  - leases
  verbs:
  - get
  - list
  - watch
  - create
  - update
  - patch
  - delete
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: battlegroupoperator-leader-election
  namespace: funcom-operators
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: funcom-operator-leader-election
subjects:
- kind: ServiceAccount
  name: battlegroupoperator-controller-manager
  namespace: funcom-operators
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: databaseoperator-leader-election
  namespace: funcom-operators
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: funcom-operator-leader-election
subjects:
- kind: ServiceAccount
  name: databaseoperator-controller-manager
  namespace: funcom-operators
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: serveroperator-leader-election
  namespace: funcom-operators
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: funcom-operator-leader-election
subjects:
- kind: ServiceAccount
  name: serveroperator-controller-manager
  namespace: funcom-operators
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: utilitiesoperator-leader-election
  namespace: funcom-operators
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: funcom-operator-leader-election
subjects:
- kind: ServiceAccount
  name: utilitiesoperator-controller-manager
  namespace: funcom-operators
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: battlegroupoperator-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: battlegroupoperator-manager-role
subjects:
- kind: ServiceAccount
  name: battlegroupoperator-controller-manager
  namespace: funcom-operators
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: databaseoperator-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: databaseoperator-manager-role
subjects:
- kind: ServiceAccount
  name: databaseoperator-controller-manager
  namespace: funcom-operators
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: serveroperator-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: serveroperator-manager-role
subjects:
- kind: ServiceAccount
  name: serveroperator-controller-manager
  namespace: funcom-operators
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: utilitiesoperator-manager-rolebinding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: utilitiesoperator-manager-role
subjects:
- kind: ServiceAccount
  name: utilitiesoperator-controller-manager
  namespace: funcom-operators
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: battlegroupoperator-controller-manager
  namespace: funcom-operators
spec:
  replicas: 0
  selector:
    matchLabels:
      control-plane: battlegroupoperator-controller-manager
  template:
    metadata:
      labels:
        control-plane: battlegroupoperator-controller-manager
    spec:
      serviceAccountName: battlegroupoperator-controller-manager
      terminationGracePeriodSeconds: 10
      containers:
      - name: manager
        image: registry.funcom.com/funcom/self-hosting/igw-k8s-battlegroup-operator:${version}
        imagePullPolicy: IfNotPresent
        volumeMounts:
        - name: webhook-certs
          mountPath: /tmp/k8s-webhook-server/serving-certs
          readOnly: true
        args:
        - --leader-elect
        - --zap-devel=false
        - --zap-log-level=debug
        - --zap-time-encoding=iso8601
      volumes:
      - name: webhook-certs
        secret:
          secretName: operator-webhook-cert
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: databaseoperator-controller-manager
  namespace: funcom-operators
spec:
  replicas: 0
  selector:
    matchLabels:
      control-plane: databaseoperator-controller-manager
  template:
    metadata:
      labels:
        control-plane: databaseoperator-controller-manager
    spec:
      serviceAccountName: databaseoperator-controller-manager
      terminationGracePeriodSeconds: 10
      containers:
      - name: manager
        image: registry.funcom.com/funcom/self-hosting/igw-k8s-database-operator:${version}
        imagePullPolicy: IfNotPresent
        volumeMounts:
        - name: webhook-certs
          mountPath: /tmp/k8s-webhook-server/serving-certs
          readOnly: true
        args:
        - --leader-elect
        - --zap-devel=false
        - --zap-log-level=debug
        - --zap-time-encoding=iso8601
        - --db-max-concurrent=1
        - --dbdepl-max-concurrent=1
        - --dbutil-max-concurrent=1
        - --dbop-max-concurrent=1
        - --dbb-max-concurrent=1
        - --dbbs-max-concurrent=1
        - --dbr-max-concurrent=1
        - --dbm-max-concurrent=1
        - --dbutil-supports-prometheus=false
      volumes:
      - name: webhook-certs
        secret:
          secretName: operator-webhook-cert
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: serveroperator-controller-manager
  namespace: funcom-operators
spec:
  replicas: 0
  selector:
    matchLabels:
      control-plane: serveroperator-controller-manager
  template:
    metadata:
      labels:
        control-plane: serveroperator-controller-manager
    spec:
      serviceAccountName: serveroperator-controller-manager
      terminationGracePeriodSeconds: 10
      containers:
      - name: manager
        image: registry.funcom.com/funcom/self-hosting/igw-k8s-server-operator:${version}
        imagePullPolicy: IfNotPresent
        volumeMounts:
        - name: webhook-certs
          mountPath: /tmp/k8s-webhook-server/serving-certs
          readOnly: true
        args:
        - --leader-elect
        - --zap-devel=false
        - --zap-log-level=debug
        - --zap-time-encoding=iso8601
      volumes:
      - name: webhook-certs
        secret:
          secretName: operator-webhook-cert
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: utilitiesoperator-controller-manager
  namespace: funcom-operators
spec:
  replicas: 0
  selector:
    matchLabels:
      control-plane: utilitiesoperator-controller-manager
  template:
    metadata:
      labels:
        control-plane: utilitiesoperator-controller-manager
    spec:
      serviceAccountName: utilitiesoperator-controller-manager
      terminationGracePeriodSeconds: 10
      containers:
      - name: manager
        image: registry.funcom.com/funcom/self-hosting/igw-k8s-utilities-operator:${version}
        imagePullPolicy: IfNotPresent
        volumeMounts:
        - name: webhook-certs
          mountPath: /tmp/k8s-webhook-server/serving-certs
          readOnly: true
        args:
        - --leader-elect
        - --zap-devel=false
        - --zap-log-level=debug
        - --zap-time-encoding=iso8601
      volumes:
      - name: webhook-certs
        secret:
          secretName: operator-webhook-cert
EOF
  k3s kubectl apply -f "${tmp}"
  rm -f "${tmp}"
}

check_ssd_path() {
  local path="$1"
  local label="$2"
  local source disk rota

  command -v findmnt >/dev/null 2>&1 || return 0
  command -v lsblk >/dev/null 2>&1 || return 0
  source="$(findmnt -n -o SOURCE --target "${path}" 2>/dev/null || true)"
  [[ "${source}" == /dev/* ]] || return 0
  disk="$(lsblk -no PKNAME "${source}" 2>/dev/null | head -n1 || true)"
  [ -n "${disk}" ] || disk="$(basename "${source}")"
  rota="$(lsblk -ndo ROTA "/dev/${disk}" 2>/dev/null | awk 'NR==1 {print $1}')"
  case "${rota}" in
    0) return 0 ;;
    1)
      if [ "${DUNE_ALLOW_SPINNING_DISK:-0}" = "1" ]; then
        warn "${label} path ${path} appears to be on rotational storage; the official guidance requires SSD."
      else
        die "${label} path ${path} appears to be on rotational storage. Set DUNE_ALLOW_SPINNING_DISK=1 to continue anyway."
      fi
      ;;
  esac
}

preflight() {
  [ "$(uname -s)" = "Linux" ] || die "This script only supports Linux"
  [ "$(uname -m)" = "x86_64" ] || die "Dune dedicated server currently requires x86_64 Linux"
  command -v systemctl >/dev/null 2>&1 || die "This script expects a systemd host"
  [ -d /sys/fs/cgroup ] || die "cgroups are not mounted"
  if ! awk '/^flags[ \t]*:/ && /(^| )avx2( |$)/ {found=1} END {exit found ? 0 : 1}' /proc/cpuinfo; then
    die "CPU does not report AVX2 support, which the official server requirements call for."
  fi

  local root_free_gb home_parent home_free_gb mem_gb
  root_free_gb="$(df -BG --output=avail / | awk 'NR==2 {gsub(/G/,""); print $1}')"
  home_parent="$(dirname "${DUNE_HOME}")"
  while [ ! -e "${home_parent}" ] && [ "${home_parent}" != "/" ]; do
    home_parent="$(dirname "${home_parent}")"
  done
  home_free_gb="$(df -BG --output=avail "${home_parent}" | awk 'NR==2 {gsub(/G/,""); print $1}')"
  mem_gb="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"
  [ "${root_free_gb}" -ge 100 ] || die "At least 100 GB free on / is required by the official server storage guidance; found ${root_free_gb} GB"
  [ "${home_free_gb}" -ge 100 ] || die "At least 100 GB free where ${DUNE_HOME} will live is required; found ${home_free_gb} GB on ${home_parent}"
  if [ "${mem_gb}" -lt 20 ]; then
    warn "Host has about ${mem_gb} GB RAM. The vendor recommends 20 GB or more unless using experimental swap."
  fi
  check_ssd_path "/" "k3s/container storage"
  check_ssd_path "${home_parent}" "Steam download and Dune home"
}

setup_native() {
  preflight

  local iface internal_ip public_ip detected_public
  iface="$(detect_interface)"
  internal_ip="${SETUP_INTERNAL_IP:-$(detect_host_ip "${iface}")}"
  [ -n "${internal_ip}" ] || die "Could not detect internal IPv4 address. Re-run with --internal-ip IP."

  detected_public="$(detect_public_ip)"
  public_ip="${SETUP_PUBLIC_IP:-${detected_public:-${internal_ip}}}"

  log "Using interface: ${iface}"
  log "Using internal node IP: ${internal_ip}"
  log "Using player-facing IP/name: ${public_ip}"
  if ! confirm "This will install/reconfigure k3s and create ${DUNE_HOME}. Continue?"; then
    die "Aborted"
  fi

  create_dune_user
  install_packages
  install_openrc_compat_wrappers
  write_settings "${internal_ip}" "${public_ip}"
  install_k3s
  install_containerd_socket_symlink
  wait_for_k3s
  install_cert_manager_manifest
  download_steam_app
  import_operator_images
  bootstrap_funcom_operators
  run_vendor_core_setup

  if have_world_inputs; then
    run_vendor_world_setup
    secure_local_world_specs
    configure_pghero_after_world
    cleanup_stale_database_util_pods
    ok "Linux-native Dune setup complete"
    printf 'Run %s start to start the battlegroup.\n' "$0"
  else
    ok "Linux-native Dune core setup complete"
    warn "World creation was skipped because no self-hosting token was provided."
    printf 'Run %s create-world --world-name NAME --world-region Europe --self-hosted-token TOKEN when you are ready.\n' "$0"
  fi
  print_port_forwarding_requirements "${public_ip}"
}

run_battlegroup() {
  local cmd="$1"
  shift || true
  as_root test -x "${DUNE_ROOT}/bin/battlegroup" || as_root test -x "${DOWNLOAD_PATH}/scripts/battlegroup.sh" || die "Battlegroup tools not found. Run setup first."
  as_root systemctl start k3s
  if as_root test -x "${DUNE_ROOT}/bin/battlegroup"; then
    as_root sudo -u "${DUNE_USER}" -H env HOME="${DUNE_HOME}" PATH="${HOST_USR_LOCAL}/bin:/usr/local/bin:/usr/bin:/bin:${DUNE_ROOT}/bin" KUBECONFIG="${K3S_CONFIG_DIR}/k3s.yaml" bash "${DUNE_ROOT}/bin/battlegroup" "${cmd}" "$@"
  else
    as_root sudo -u "${DUNE_USER}" -H env HOME="${DUNE_HOME}" PATH="${HOST_USR_LOCAL}/bin:/usr/local/bin:/usr/bin:/bin:${DUNE_ROOT}/bin" KUBECONFIG="${K3S_CONFIG_DIR}/k3s.yaml" bash "${DOWNLOAD_PATH}/scripts/battlegroup.sh" "${cmd}" "$@"
  fi
}

run_kubectl() {
  as_root k3s kubectl "$@"
}

settings_line() {
  local line="$1"
  [ -f "${SETTINGS_FILE}" ] || return 0
  sed -n "${line}p" "${SETTINGS_FILE}"
}

node_url_host() {
  local host iface
  host="$(settings_line 3)"
  if [ -z "${host}" ]; then
    iface="$(detect_interface)"
    host="$(detect_host_ip "${iface}")"
  fi
  [ -n "${host}" ] || die "Could not determine host IP"
  echo "${host}"
}

director_url() {
  local host port
  host="$(node_url_host)"
  port="$(run_kubectl get svc -A -o jsonpath='{.items[*].spec.ports[?(@.port==11717)].nodePort}' 2>/dev/null | awk '{print $1}')"
  [ -n "${port}" ] || die "Could not determine Director NodePort. Is the battlegroup running?"
  printf 'http://%s:%s/\n' "${host}" "${port}"
}

file_browser_url() {
  printf 'http://%s:18888/\n' "$(node_url_host)"
}

open_url() {
  local url="$1"
  printf '%s\n' "${url}"
  if command -v xdg-open >/dev/null 2>&1 && { [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; }; then
    xdg-open "${url}" >/dev/null 2>&1 &
  else
    warn "xdg-open is unavailable or no desktop session was detected; open the URL manually"
  fi
}

print_port_forwarding_requirements() {
  local public_ip="${1:-}"
  printf '\nPort forwarding for external players:\n'
  printf '  7777-7810/udp -> this host, for game servers\n'
  printf '  31982/tcp     -> this host, for RMQ\n'
  if [ -n "${public_ip}" ]; then
    printf 'Player-facing IP/DNS currently configured as: %s\n' "${public_ip}"
  fi
  printf 'If you change UserEngine.ini Port or IGWPort ranges, update forwarding to match.\n\n'
}

shell_pod() {
  local bg_prefix="funcom-seabass-"
  local ns pod namespaces pods choice

  mapfile -t namespaces < <(run_kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name | awk -v prefix="${bg_prefix}" 'index($1,prefix)==1 {print $1}')
  [ "${#namespaces[@]}" -gt 0 ] || die "No battlegroup namespace found"

  if [ "${#namespaces[@]}" -eq 1 ]; then
    ns="${namespaces[0]}"
  else
    printf 'Battlegroups:\n'
    local i
    for i in "${!namespaces[@]}"; do
      printf '  %2d. %s\n' "$((i + 1))" "${namespaces[$i]#${bg_prefix}}"
    done
    read -r -p "Select battlegroup: " choice
    [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#namespaces[@]}" ] || die "Invalid selection"
    ns="${namespaces[$((choice - 1))]}"
  fi

  mapfile -t pods < <(run_kubectl get pods -n "${ns}" --no-headers -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.role)
  [ "${#pods[@]}" -gt 0 ] || die "No pods found in namespace ${ns}"

  printf 'Pods in %s:\n' "${ns}"
  local i name role
  for i in "${!pods[@]}"; do
    name="$(awk '{print $1}' <<<"${pods[$i]}")"
    role="$(awk '{$1=""; sub(/^ /,""); print}' <<<"${pods[$i]}")"
    [ "${role}" = "<none>" ] && role=""
    printf '  %2d. %-48s %s\n' "$((i + 1))" "${name#${ns#${bg_prefix}}-}" "${role}"
  done
  read -r -p "Select pod: " choice
  [[ "${choice}" =~ ^[0-9]+$ ]] && [ "${choice}" -ge 1 ] && [ "${choice}" -le "${#pods[@]}" ] || die "Invalid selection"
  pod="$(awk '{print $1}' <<<"${pods[$((choice - 1))]}")"

  run_kubectl exec -it "${pod}" -n "${ns}" -- /bin/bash || run_kubectl exec -it "${pod}" -n "${ns}" -- /bin/sh
}

export_logs() {
  local cmd="$1"
  local src dest_parent label timestamp dest

  case "${cmd}" in
    logs-export)
      src="/tmp/dune-bg-logs"
      dest_parent="${HOME}/Documents/BattlegroupLogs"
      label="Battlegroup"
      ;;
    operator-logs-export)
      src="/tmp/dune-operator-logs"
      dest_parent="${HOME}/Documents/OperatorLogs"
      label="Operators"
      ;;
    *) die "Unsupported log export command: ${cmd}" ;;
  esac

  run_battlegroup "${cmd}"
  [ -d "${src}" ] || die "Expected log directory was not created: ${src}"
  timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
  dest="${dest_parent}/${label}_${timestamp}"
  mkdir -p "${dest}"
  cp -a "${src}/." "${dest}/"
  ok "Logs saved to: ${dest}"
}

set_public_ip() {
  local public_ip="$1"
  [ -n "${public_ip}" ] || die "Usage: $0 set-public-ip IP_OR_DNS"
  local internal_ip
  internal_ip="$(settings_line 3)"
  [ -n "${internal_ip}" ] || internal_ip="$(node_url_host)"
  as_root install -d -m 0755 -o "${DUNE_USER}" -g "${DUNE_USER}" "${DUNE_ROOT}"
  printf '\n\n%s\n%s\n' "${internal_ip}" "${public_ip}" | as_root tee "${SETTINGS_FILE}" >/dev/null
  as_root chown "${DUNE_USER}:${DUNE_USER}" "${SETTINGS_FILE}"
  as_root systemctl restart k3s
  ok "Updated player-facing IP/DNS to ${public_ip} and restarted k3s"
}

set_interface() {
  local iface="$1"
  [ -n "${iface}" ] || die "Usage: $0 set-interface IFACE"
  ip link show "${iface}" >/dev/null 2>&1 || die "Interface does not exist: ${iface}"
  as_root install -d -m 0755 "${K3S_OVERRIDE_DIR}"
  if as_root test -f "${K3S_OVERRIDE_DIR}/10-dune-native.conf"; then
    as_root sed -i '/^Environment=DUNE_INTERFACE=/d' "${K3S_OVERRIDE_DIR}/10-dune-native.conf"
    printf 'Environment=DUNE_INTERFACE=%s\n' "${iface}" | as_root tee -a "${K3S_OVERRIDE_DIR}/10-dune-native.conf" >/dev/null
  else
    die "Dune k3s override is missing. Run setup first."
  fi
  as_root systemctl daemon-reload
  as_root systemctl restart k3s
  ok "Updated k3s interface to ${iface}"
}

single_battlegroup_namespace() {
  local bg_prefix="funcom-seabass-"
  local namespaces
  mapfile -t namespaces < <(run_kubectl get ns --no-headers -o custom-columns=NAME:.metadata.name | awk -v prefix="${bg_prefix}" 'index($1,prefix)==1 {print $1}')
  [ "${#namespaces[@]}" -gt 0 ] || die "No battlegroup namespace found"
  [ "${#namespaces[@]}" -eq 1 ] || die "Multiple battlegroups found; use the vendor battlegroup tool or patch the intended namespace directly"
  echo "${namespaces[0]}"
}

set_pghero_port() {
  local port="$1"
  validate_tcp_port "${port}" "PgHero port"

  local ns bg patch
  ns="$(single_battlegroup_namespace)"
  bg="${ns#funcom-seabass-}"
  patch="{\"spec\":{\"database\":{\"template\":{\"spec\":{\"utilities\":{\"spec\":{\"pgHero\":{\"port\":${port}}}}}}}}}"

  run_kubectl patch battlegroup -n "${ns}" "${bg}" --type=merge -p "${patch}"
  run_kubectl patch database -n "${ns}" "${bg}-db" --type=merge -p "{\"spec\":{\"utilities\":{\"spec\":{\"pgHero\":{\"port\":${port}}}}}}"
  run_kubectl rollout status "deployment/${bg}-db-util-pghero" -n "${ns}" --timeout=180s
  ok "PgHero is configured on port ${port}"
  printf 'PgHero URL: http://%s:%s/\n' "$(node_url_host)" "${port}"
}

validate_tcp_port() {
  local port="$1"
  local label="${2:-TCP port}"
  [[ "${port}" =~ ^[0-9]+$ ]] || die "${label} must be a number"
  [ "${port}" -ge 1 ] && [ "${port}" -le 65535 ] || die "${label} must be between 1 and 65535"
}

tcp_port_has_listener() {
  local port="$1"
  [ -n "$(tcp_listeners_for_port "${port}" | head -n 1)" ]
}

desired_pghero_port_after_world() {
  local requested="${SETUP_PGHERO_PORT:-}"
  if [ -n "${requested}" ]; then
    validate_tcp_port "${requested}" "PgHero port"
    printf '%s\n' "${requested}"
    return 0
  fi

  if tcp_port_has_listener 9999; then
    if tcp_port_has_listener 10099; then
      warn "PgHero default port 9999 is already in use, and fallback port 10099 is also in use; leaving vendor default unchanged"
      return 0
    fi
    warn "PgHero default port 9999 is already in use; using fallback port 10099"
    printf '10099\n'
  fi
}

configure_pghero_after_world() {
  local port
  port="$(desired_pghero_port_after_world)"
  [ -n "${port}" ] || return 0
  set_pghero_port "${port}"
}

cleanup_stale_database_util_pods() {
  local ns bg db_phase pods pod
  ns="$(single_battlegroup_namespace 2>/dev/null)" || return 0
  bg="${ns#funcom-seabass-}"
  db_phase="$(run_kubectl get databasedeployment -n "${ns}" "${bg}-db-dbdepl" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [ "${db_phase}" = "Ready" ] || return 0
  pods="$(run_kubectl get pods -n "${ns}" -o json 2>/dev/null |
    jq -r --arg prefix "${bg}-db-dbdepl-util-" '
      .items[] |
      select(.metadata.name | startswith($prefix)) |
      select(.status.phase == "Failed") |
      .metadata.name
    ' || true)"
  [ -n "${pods}" ] || return 0
  while read -r pod; do
    [ -n "${pod}" ] || continue
    run_kubectl delete pod -n "${ns}" "${pod}" --ignore-not-found >/dev/null || true
  done <<<"${pods}"
  ok "Removed stale failed database utility pod(s)"
}

read_self_hosted_token() {
  local source_file="${1:-}"
  local token

  if [ -n "${source_file}" ]; then
    [ -f "${source_file}" ] || die "Token file does not exist: ${source_file}"
    local mode
    mode="$(stat -c '%a' "${source_file}")"
    if [ $((8#${mode} & 077)) -ne 0 ]; then
      die "Token file must not be group/world readable. Run: chmod 600 ${source_file}"
    fi
    token="$(tr -d '\r\n' < "${source_file}")"
  else
    [ -t 0 ] || die "No terminal available for token prompt. Use --token-file FILE."
    printf 'Enter new Dune self-hosting token: ' >&2
    IFS= read -rs token
    printf '\n' >&2
  fi

  [[ "${token}" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || die "Token does not look like a JWT"
  printf '%s' "${token}"
}

validate_self_hosted_token_file() {
  local token_file="$1"
  local payload payload_padded
  payload="$(cut -d. -f2 < "${token_file}")"
  payload_padded="${payload}"
  while [ $(( ${#payload_padded} % 4 )) -ne 0 ]; do
    payload_padded="${payload_padded}="
  done
  printf '%s' "${payload_padded}" | tr '_-' '/+' | base64 -d 2>/dev/null |
    jq -e '.HostId and .ServiceAuthKey and .exp' >/dev/null ||
    die "Token payload does not contain the expected self-hosting fields"
}

patch_token_in_resource() {
  local resource="$1"
  local token_file="$2"
  local ns="$3"

  run_kubectl get "${resource}" -n "${ns}" -o json |
    jq --rawfile token "${token_file}" '
      ($token | gsub("[\r\n]+$"; "")) as $nt |
      def walk(f):
        . as $in |
        if type == "object" then
          reduce keys[] as $key ({}; . + {($key): ($in[$key] | walk(f))}) | f
        elif type == "array" then
          map(walk(f)) | f
        else
          f
        end;
      def replace_token:
        if type == "string" then
          if test("^eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+$") then
            $nt
          else
            gsub("ServiceAuthToken=eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"; "ServiceAuthToken=" + $nt)
          end
        else
          .
        end;
      del(.metadata.managedFields, .status) |
      .spec = (.spec | walk(replace_token))
    ' |
    run_kubectl replace -f - >/dev/null
}

patch_secret_token() {
  local ns="$1"
  local token_file="$2"
  [ -n "$(run_kubectl get secret -n "${ns}" server-gateway-secret -o name 2>/dev/null || true)" ] || return 0
  run_kubectl get secret -n "${ns}" server-gateway-secret -o json |
    jq --rawfile token "${token_file}" \
      '($token | gsub("[\r\n]+$"; "") | @base64) as $nt |
       del(.metadata.managedFields) |
       .data["FuncomLiveServices__ServiceAuthToken"] = $nt' |
    run_kubectl replace -f - >/dev/null
}

patch_local_world_specs_token() {
  local token_file="$1"
  local files=()
  while IFS= read -r -d '' file; do
    files+=("${file}")
  done < <(as_root find "${DUNE_ROOT}" -maxdepth 1 -type f \( -name 'sh-*.yaml' -o -name 'sh-*-fls-secret.yaml' \) -print0 2>/dev/null)
  [ "${#files[@]}" -gt 0 ] || return 0

  as_root env TOKEN_FILE="${token_file}" perl -0pi -e '
    BEGIN {
      open my $fh, "<", $ENV{"TOKEN_FILE"} or die "open token file: $!";
      chomp($token = <$fh>);
    }
    s/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/$token/g;
  ' "${files[@]}"
  secure_local_world_specs
}

set_self_hosted_token() {
  local token_file="${DUNE_SELF_HOSTED_TOKEN_FILE:-}"
  local restart=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --token-file) token_file="${2:-}"; shift 2 ;;
      --restart) restart=1; shift ;;
      --help|-h)
        printf 'Usage: %s set-self-hosted-token [--token-file FILE] [--restart]\n' "$0"
        return 0
        ;;
      *) die "Unknown set-self-hosted-token option: $1" ;;
    esac
  done

  local tmp_token ns bg resource resources kind resource_count=0
  tmp_token="$(mktemp)"
  chmod 0600 "${tmp_token}"
  trap 'rm -f "${tmp_token:-}"' RETURN
  read_self_hosted_token "${token_file}" > "${tmp_token}"
  validate_self_hosted_token_file "${tmp_token}"

  ns="$(single_battlegroup_namespace)"
  bg="${ns#funcom-seabass-}"

  log "Patching self-hosting token in battlegroup resources without printing token values"
  patch_token_in_resource "battlegroup/${bg}" "${tmp_token}" "${ns}"
  for kind in servergroups battlegroupdirectors servergateways textrouters; do
    while IFS= read -r resource; do
      [ -n "${resource}" ] || continue
      patch_token_in_resource "${resource}" "${tmp_token}" "${ns}"
      resource_count=$((resource_count + 1))
    done < <(run_kubectl get "${kind}" -n "${ns}" -l "battlegroup=${bg}" -o name 2>/dev/null || true)
  done
  patch_secret_token "${ns}" "${tmp_token}"
  patch_local_world_specs_token "${tmp_token}"

  ok "Updated self-hosting token in BattleGroup, ${resource_count} generated resources, server-gateway-secret, and local world spec files"
  warn "The Funcom CRDs still store this token in Kubernetes specs/env fields. Keep kubeconfig/admin access restricted."
  if [ "${restart}" = "1" ]; then
    run_battlegroup restart
  else
    warn "Restart the battlegroup after revoking the old token so running pods pick up the new value: $0 restart"
  fi
}

backup_dir_for_bg() {
  local bg="$1"
  printf '%s/artifacts/database-dumps/%s\n' "${FUNCOM_ROOT}" "${bg}"
}

load_backup_env() {
  if as_root test -f "${BACKUP_ENV_FILE}"; then
    # shellcheck disable=SC1090
    set -a
    source "${BACKUP_ENV_FILE}"
    set +a
  fi
}

backup_latest_for_bg() {
  local bg="$1"
  local dir
  dir="$(backup_dir_for_bg "${bg}")"
  { as_root find "${dir}" -maxdepth 1 -type f ! -name '*.yaml' -printf '%T@ %p\n' 2>/dev/null || true; } |
    sort -nr | awk 'NR==1 {print $2}'
}

backup_select_for_bg() {
  local bg="$1"
  local requested="${2:-}"
  local dir
  dir="$(backup_dir_for_bg "${bg}")"
  if [ -n "${requested}" ]; then
    if [[ "${requested}" = /* ]]; then
      printf '%s\n' "${requested}"
    else
      printf '%s/%s\n' "${dir}" "${requested}"
    fi
  else
    backup_latest_for_bg "${bg}"
  fi
}

backup_copy_target_configured() {
  [ -n "${DUNE_BACKUP_COPY_TARGET:-}" ]
}

backup_copy_path_for() {
  local source_file="$1"
  local bg="$2"
  local target="$3"
  local base
  base="$(basename "${source_file}")"
  case "${target}" in
    rclone:*) printf '%s/%s/%s\n' "${target#rclone:}" "${bg}" "${base}" ;;
    *) printf '%s/%s/%s\n' "${target}" "${bg}" "${base}" ;;
  esac
}

backup_copy_file() {
  local source_file="$1"
  local bg="$2"
  local target="${DUNE_BACKUP_COPY_TARGET:-}"
  [ -n "${target}" ] || return 0
  [ -f "${source_file}" ] || return 0

  local dest
  dest="$(backup_copy_path_for "${source_file}" "${bg}" "${target}")"
  case "${target}" in
    rclone:*)
      command -v rclone >/dev/null 2>&1 || die "DUNE_BACKUP_COPY_TARGET uses rclone but rclone is not installed"
      rclone copyto "${source_file}" "${dest}"
      ;;
    *)
      as_root install -d -m 0750 "$(dirname "${dest}")"
      as_root cp -a "${source_file}" "${dest}"
      ;;
  esac
}

backup_copy_latest() {
  local backup_file="$1"
  local bg="$2"
  [ -n "${DUNE_BACKUP_COPY_TARGET:-}" ] || return 0
  log "Copying backup to ${DUNE_BACKUP_COPY_TARGET}"
  backup_copy_file "${backup_file}" "${bg}"
  backup_copy_file "${backup_file}.yaml" "${bg}"
  ok "Backup copy complete"
}

backup_copy_exists_for() {
  local backup_file="$1"
  local bg="$2"
  local target="${DUNE_BACKUP_COPY_TARGET:-}"
  [ -n "${target}" ] || return 1
  local dest
  dest="$(backup_copy_path_for "${backup_file}" "${bg}" "${target}")"
  case "${target}" in
    rclone:*)
      command -v rclone >/dev/null 2>&1 || return 2
      rclone lsf "$(dirname "${dest}")" --files-only 2>/dev/null | awk -v base="$(basename "${dest}")" '$0 == base {found=1} END {exit found ? 0 : 1}'
      ;;
    *)
      as_root test -f "${dest}"
      ;;
  esac
}

backup_prune() {
  load_backup_env
  local retention_days="${DUNE_BACKUP_RETENTION_DAYS:-${DEFAULT_BACKUP_RETENTION_DAYS}}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --retention-days) retention_days="${2:-}"; shift 2 ;;
      --help|-h)
        printf 'Usage: %s backup-prune [--retention-days N]\n' "$0"
        return 0
        ;;
      *) die "Unknown backup-prune option: $1" ;;
    esac
  done
  [[ "${retention_days}" =~ ^[0-9]+$ ]] || die "Retention days must be a number"
  [ "${retention_days}" -ge 1 ] || die "Retention days must be at least 1"

  local ns bg dir
  ns="$(single_battlegroup_namespace)"
  bg="${ns#funcom-seabass-}"
  dir="$(backup_dir_for_bg "${bg}")"
  if ! as_root test -d "${dir}"; then
    warn "Backup directory does not exist yet: ${dir}"
    return 0
  fi

  log "Pruning database backups older than ${retention_days} day(s) in ${dir}"
  as_root find "${dir}" -maxdepth 1 -type f ! -name '*.yaml' -mtime "+${retention_days}" -print -delete
  ok "Backup prune complete"
}

find_server_pv_path() {
  local ns="$1"
  local pvc_name pv_name pv_path
  pvc_name="$(run_kubectl get pvc -n "${ns}" -l role=igw-server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  [ -n "${pvc_name}" ] || die "Could not find server PVC (label role=igw-server) in ${ns}"
  pv_name="$(run_kubectl get pvc "${pvc_name}" -n "${ns}" \
    -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  [ -n "${pv_name}" ] || die "PVC ${pvc_name} has no bound PV"
  pv_path="$(run_kubectl get pv "${pv_name}" \
    -o jsonpath='{.spec.local.path}{.spec.hostPath.path}' 2>/dev/null || true)"
  [ -n "${pv_path}" ] || die "Could not resolve host path for PV ${pv_name}"
  printf '%s\n' "${pv_path}"
}

patch_bg_set_field() {
  local ns="$1" bg="$2" map="$3" field_path="$4" json_value="$5"
  local idx
  idx="$(run_kubectl get igwbg -n "${ns}" "${bg}" -o json 2>/dev/null |
    jq -r --arg m "${map}" \
    '.spec.serverGroup.template.spec.sets | to_entries[] | select(.value.map == $m) | .key' \
    2>/dev/null | head -n1)"
  if [ -z "${idx}" ]; then
    warn "No ServerSet found for map ${map}; skipping ${field_path} patch"
    return 0
  fi
  run_kubectl patch igwbg -n "${ns}" "${bg}" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/serverGroup/template/spec/sets/${idx}/${field_path}\",\"value\":${json_value}}]"
}

restore_check() {
  local requested="${1:-}"
  local ns bg backup_file backup_name backup_spec pv_path pvc_dumps_dir size
  ns="$(single_battlegroup_namespace)"
  bg="${ns#funcom-seabass-}"
  backup_file="$(backup_select_for_bg "${bg}" "${requested}")"

  [ -n "${backup_file}" ] || die "No backup found. Run: $0 backup"
  as_root test -f "${backup_file}" || die "Backup file not found: ${backup_file}"
  backup_name="$(basename "${backup_file}")"
  backup_spec="${backup_file}.yaml"
  size="$(as_root stat -c '%s' "${backup_file}")"
  [ "${size}" -gt 0 ] || die "Backup file is empty: ${backup_file}"
  if as_root test -f "${backup_spec}"; then
    ok "Found backup metadata spec: ${backup_spec}"
  else
    warn "No backup metadata spec found beside backup: ${backup_spec}"
  fi

  log "Checking restore prerequisites for ${backup_name}"
  run_kubectl get battlegroup -n "${ns}" "${bg}" >/dev/null
  run_kubectl get database -n "${ns}" "${bg}-db" >/dev/null
  pv_path="$(find_server_pv_path "${ns}")"
  as_root test -d "${pv_path}" || die "PV host path does not exist: ${pv_path}"
  pvc_dumps_dir="${pv_path}/Saved/DatabaseDumps"
  if as_root test -d "${pvc_dumps_dir}"; then
    doctor_ok "restore staging directory exists: ${pvc_dumps_dir}"
  else
    doctor_warn "restore staging directory will be created during import: ${pvc_dumps_dir}"
  fi

  if run_kubectl get pods -n "${ns}" -l role=igw-server --no-headers 2>/dev/null | awk 'NF {found=1} END {exit found ? 0 : 1}'; then
    warn "Game server pods are currently present. Stop the battlegroup before importing."
  else
    ok "No game server pods found"
  fi
  ok "Restore check passed for ${backup_file}"
  printf 'Restore runbook:\n'
  printf '  1. %s stop\n' "$0"
  printf '  2. %s import %s\n' "$0" "${backup_name}"
  printf '  3. %s start\n' "$0"
  printf '  4. %s doctor\n' "$0"
}

wait_for_game_server_pods_stopped() {
  local ns="$1"
  local i
  log "Waiting for game server pods to stop"
  for i in $(seq 1 120); do
    if ! run_kubectl get pods -n "${ns}" -l role=igw-server --no-headers 2>/dev/null | awk 'NF {found=1} END {exit found ? 0 : 1}'; then
      ok "game server pods are stopped"
      return 0
    fi
    sleep 5
  done
  die "Timed out waiting for game server pods to stop"
}

wait_for_battlegroup_healthy() {
  local ns="$1"
  local bg="$2"
  local i phase bad_pods
  log "Waiting for battlegroup to become healthy"
  for i in $(seq 1 120); do
    phase="$(run_kubectl get battlegroup -n "${ns}" "${bg}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    bad_pods="$(run_kubectl get pods -n "${ns}" -o json 2>/dev/null |
      jq -r '.items[] |
        select(.status.phase != "Succeeded") |
        select((.status.containerStatuses // []) | any(.ready != true)) |
        .metadata.name' || true)"
    if [ "${phase}" = "Healthy" ] && [ -z "${bad_pods}" ]; then
      ok "battlegroup is healthy"
      return 0
    fi
    sleep 5
  done
  die "Timed out waiting for battlegroup to become healthy"
}

restore_latest() {
  local ns bg backup_file backup_name title confirm
  ns="$(single_battlegroup_namespace)"
  bg="${ns#funcom-seabass-}"
  title="$(run_kubectl get battlegroup -n "${ns}" "${bg}" -o jsonpath='{.spec.title}' 2>/dev/null || echo "${bg}")"
  backup_file="$(backup_latest_for_bg "${bg}")"
  [ -n "${backup_file}" ] || die "No backup found. Run: $0 backup"
  backup_name="$(basename "${backup_file}")"

  restore_check "${backup_name}"
  printf '\n%s\n' "${red}DESTRUCTIVE RESTORE WARNING${nc}"
  printf 'This will stop battlegroup "%s", import backup "%s", overwrite current database data, then start the battlegroup again.\n' "${title}" "${backup_name}"
  printf 'Type RESTORE %s to continue: ' "${backup_name}"
  IFS= read -r confirm
  if [ "${confirm}" != "RESTORE ${backup_name}" ]; then
    die "Restore aborted"
  fi

  run_battlegroup stop
  wait_for_game_server_pods_stopped "${ns}"
  printf 'yes\n' | run_battlegroup import "${backup_name}"
  run_battlegroup start
  wait_for_battlegroup_healthy "${ns}" "${bg}"
  doctor_native
}

scheduled_backup() {
  load_backup_env
  local ns bg backup_name latest_before latest_after retention_days
  retention_days="${DUNE_BACKUP_RETENTION_DAYS:-${DEFAULT_BACKUP_RETENTION_DAYS}}"
  ns="$(single_battlegroup_namespace)"
  bg="${ns#funcom-seabass-}"
  backup_name="${bg}-$(date +%Y%m%d-%H%M%S).backup"
  latest_before="$(backup_latest_for_bg "${bg}")"

  log "Running scheduled backup ${backup_name}"
  run_battlegroup backup "${backup_name}"
  latest_after="$(backup_latest_for_bg "${bg}")"
  if [ -z "${latest_after}" ] || [ "${latest_after}" = "${latest_before}" ]; then
    die "Scheduled backup did not produce a new backup file"
  fi
  ok "Scheduled backup created: ${latest_after}"
  backup_copy_latest "${latest_after}" "${bg}"
  backup_prune --retention-days "${retention_days}"
}

install_backup_timer() {
  local daily_at="${DEFAULT_BACKUP_ON_CALENDAR}"
  local retention_days="${DUNE_BACKUP_RETENTION_DAYS:-${DEFAULT_BACKUP_RETENTION_DAYS}}"
  local max_age_hours="${DUNE_BACKUP_MAX_AGE_HOURS:-${DEFAULT_BACKUP_MAX_AGE_HOURS}}"
  local copy_target="${DUNE_BACKUP_COPY_TARGET:-}"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --daily-at) daily_at="${2:-}"; shift 2 ;;
      --retention-days) retention_days="${2:-}"; shift 2 ;;
      --max-age-hours) max_age_hours="${2:-}"; shift 2 ;;
      --copy-target) copy_target="${2:-}"; shift 2 ;;
      --help|-h)
        printf 'Usage: %s install-backup-timer [--daily-at HH:MM] [--retention-days N] [--max-age-hours N]\n' "$0"
        return 0
        ;;
      *) die "Unknown install-backup-timer option: $1" ;;
    esac
  done

  [[ "${daily_at}" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || die "--daily-at must be HH:MM"
  [[ "${retention_days}" =~ ^[0-9]+$ ]] && [ "${retention_days}" -ge 1 ] || die "--retention-days must be >= 1"
  [[ "${max_age_hours}" =~ ^[0-9]+$ ]] && [ "${max_age_hours}" -ge 1 ] || die "--max-age-hours must be >= 1"

  local script_path
  script_path="$(readlink -f "$0")"
  as_root install -d -m 0755 "$(dirname "${BACKUP_ENV_FILE}")" "${BACKUP_LOG_DIR}"
  as_root install -d -m 0755 "$(dirname "${BACKUP_SERVICE}")"
  {
    printf 'DUNE_BACKUP_RETENTION_DAYS=%s\n' "${retention_days}"
    printf 'DUNE_BACKUP_MAX_AGE_HOURS=%s\n' "${max_age_hours}"
    [ -z "${copy_target}" ] || printf 'DUNE_BACKUP_COPY_TARGET=%s\n' "${copy_target}"
  } | as_root tee "${BACKUP_ENV_FILE}" >/dev/null
  as_root chmod 0644 "${BACKUP_ENV_FILE}"

  cat <<EOF | as_root tee "${BACKUP_SERVICE}" >/dev/null
[Unit]
Description=Dune native scheduled database backup
Wants=k3s.service
After=k3s.service

[Service]
Type=oneshot
EnvironmentFile=${BACKUP_ENV_FILE}
WorkingDirectory=$(pwd)
ExecStart=/usr/bin/env bash "${script_path}" scheduled-backup
StandardOutput=append:${BACKUP_LOG_DIR}/backup.log
StandardError=append:${BACKUP_LOG_DIR}/backup.log
EOF

  cat <<EOF | as_root tee "${BACKUP_TIMER}" >/dev/null
[Unit]
Description=Daily Dune native database backup

[Timer]
OnCalendar=*-*-* ${daily_at}:00
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
EOF

  as_root systemctl daemon-reload
  as_root systemctl enable --now "$(basename "${BACKUP_TIMER}")"
  ok "Installed backup timer at ${daily_at} daily with ${retention_days} day retention"
  as_root systemctl list-timers --no-pager "$(basename "${BACKUP_TIMER}")" || true
}

set_backup_copy_target() {
  local target="${1:-}"
  [ -n "${target}" ] || die "Usage: $0 set-backup-copy-target TARGET|none"
  if ! as_root test -f "${BACKUP_ENV_FILE}"; then
    as_root install -d -m 0755 "$(dirname "${BACKUP_ENV_FILE}")"
    {
      printf 'DUNE_BACKUP_RETENTION_DAYS=%s\n' "${DEFAULT_BACKUP_RETENTION_DAYS}"
      printf 'DUNE_BACKUP_MAX_AGE_HOURS=%s\n' "${DEFAULT_BACKUP_MAX_AGE_HOURS}"
    } | as_root tee "${BACKUP_ENV_FILE}" >/dev/null
  fi
  if [ "${target}" = "none" ]; then
    as_root sed -i '/^DUNE_BACKUP_COPY_TARGET=/d' "${BACKUP_ENV_FILE}"
    ok "Removed backup copy target"
    return 0
  fi
  if [[ "${target}" != rclone:* ]]; then
    as_root install -d -m 0750 "${target}"
  fi
  if as_root grep -q '^DUNE_BACKUP_COPY_TARGET=' "${BACKUP_ENV_FILE}"; then
    as_root sed -i "s|^DUNE_BACKUP_COPY_TARGET=.*|DUNE_BACKUP_COPY_TARGET=${target}|" "${BACKUP_ENV_FILE}"
  else
    printf 'DUNE_BACKUP_COPY_TARGET=%s\n' "${target}" | as_root tee -a "${BACKUP_ENV_FILE}" >/dev/null
  fi
  ok "Configured backup copy target: ${target}"
}

uninstall_backup_timer() {
  as_root systemctl disable --now "$(basename "${BACKUP_TIMER}")" >/dev/null 2>&1 || true
  as_root rm -f "${BACKUP_TIMER}" "${BACKUP_SERVICE}" "${BACKUP_ENV_FILE}"
  as_root systemctl daemon-reload
  ok "Removed backup timer/service"
}

apply_canonical() {
  local sietch_name="${DUNE_SIETCH_NAME:-}"
  local pvp_partition="${DUNE_PVP_PARTITION:-}"
  local mem_survival="${DUNE_MEM_SURVIVAL:-}"
  local mem_deep_desert="${DUNE_MEM_DEEP_DESERT:-}"
  local mem_overmap="${DUNE_MEM_OVERMAP:-}"
  local mem_sietch="${DUNE_MEM_SIETCH:-}"
  local always_on_deep_desert="${DUNE_ALWAYS_ON_DEEP_DESERT:-0}"
  local always_on_sietches="${DUNE_ALWAYS_ON_SIETCHES:-0}"
  local mining_multiplier="${DUNE_MINING_MULTIPLIER:-}"
  local server_password="${DUNE_SERVER_PASSWORD:-}"
  local farm_region="${DUNE_FARM_REGION:-}"
  local no_stop=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sietch-name) sietch_name="${2:-}"; shift 2 ;;
      --pvp-partition) pvp_partition="${2:-}"; shift 2 ;;
      --mem-survival) mem_survival="${2:-}"; shift 2 ;;
      --mem-deep-desert) mem_deep_desert="${2:-}"; shift 2 ;;
      --mem-overmap) mem_overmap="${2:-}"; shift 2 ;;
      --mem-sietch) mem_sietch="${2:-}"; shift 2 ;;
      --always-on-deep-desert) always_on_deep_desert=1; shift ;;
      --always-on-sietches) always_on_sietches=1; shift ;;
      --mining-multiplier) mining_multiplier="${2:-}"; shift 2 ;;
      --server-password) server_password="${2:-}"; shift 2 ;;
      --farm-region) farm_region="${2:-}"; shift 2 ;;
      --no-stop) no_stop=1; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --help|-h)
        printf 'Usage: %s apply-canonical [options]\n' "$0"
        printf '  --sietch-name NAME         In-game server browser display name\n'
        printf '  --pvp-partition ID         PvP partition ID (default: 8 = DeepDesert_1)\n'
        printf '  --mem-survival GiB         Hagga Basin pod memory limit (e.g. 24Gi)\n'
        printf '  --mem-deep-desert GiB      Deep Desert pod memory limit\n'
        printf '  --mem-overmap GiB          Overmap pod memory limit\n'
        printf '  --mem-sietch GiB           Sietch hub pod memory limit\n'
        printf '  --always-on-deep-desert    Set Deep Desert dedicatedScaling=false (always-on)\n'
        printf '  --always-on-sietches       Set SH_Arrakeen + SH_HarkoVillage to always-on\n'
        printf '  --mining-multiplier FLOAT  GlobalMiningOutputMultiplier (e.g. 1.5)\n'
        printf '  --server-password PASS     Join password (empty string clears it)\n'
        printf '  --farm-region REGION       Server browser region: Europe, North America, Asia, Oceania, South America\n'
        printf '  --no-stop                  Do not stop/start battlegroup around changes\n'
        return 0
        ;;
      *) die "Unknown apply-canonical option: $1" ;;
    esac
  done

  local ns bg pv_path usersettings
  ns="$(single_battlegroup_namespace)"
  bg="${ns#funcom-seabass-}"

  if [ "${no_stop}" != "1" ]; then
    log "Stopping battlegroup before applying canonical config"
    run_battlegroup stop || true
  fi

  if [ -n "${mem_survival}" ]; then
    log "Patching Survival_1 (Hagga Basin) memory limit to ${mem_survival}"
    patch_bg_set_field "${ns}" "${bg}" "Survival_1" "resources/limits/memory" "\"${mem_survival}\""
  fi
  if [ -n "${mem_deep_desert}" ]; then
    log "Patching DeepDesert_1 memory limit to ${mem_deep_desert}"
    patch_bg_set_field "${ns}" "${bg}" "DeepDesert_1" "resources/limits/memory" "\"${mem_deep_desert}\""
  fi
  if [ -n "${mem_overmap}" ]; then
    log "Patching Overmap memory limit to ${mem_overmap}"
    patch_bg_set_field "${ns}" "${bg}" "Overmap" "resources/limits/memory" "\"${mem_overmap}\""
  fi
  if [ -n "${mem_sietch}" ]; then
    log "Patching SH_Arrakeen memory limit to ${mem_sietch}"
    patch_bg_set_field "${ns}" "${bg}" "SH_Arrakeen" "resources/limits/memory" "\"${mem_sietch}\""
    log "Patching SH_HarkoVillage memory limit to ${mem_sietch}"
    patch_bg_set_field "${ns}" "${bg}" "SH_HarkoVillage" "resources/limits/memory" "\"${mem_sietch}\""
  fi
  if [ "${always_on_deep_desert}" = "1" ]; then
    log "Setting DeepDesert_1 to always-on (dedicatedScaling=false)"
    patch_bg_set_field "${ns}" "${bg}" "DeepDesert_1" "dedicatedScaling" "false"
  fi
  if [ "${always_on_sietches}" = "1" ]; then
    log "Setting SH_Arrakeen and SH_HarkoVillage to always-on"
    patch_bg_set_field "${ns}" "${bg}" "SH_Arrakeen" "dedicatedScaling" "false"
    patch_bg_set_field "${ns}" "${bg}" "SH_HarkoVillage" "dedicatedScaling" "false"
  fi

  pv_path="$(find_server_pv_path "${ns}")"
  usersettings="${pv_path}/Saved/UserSettings"
  as_root test -d "${usersettings}" || die "UserSettings directory not found: ${usersettings}"

  if [ -n "${sietch_name}" ]; then
    log "Setting sietch display name in UserEngine.ini"
    as_root sed -i '/^Bgd\.ServerDisplayName=/d' "${usersettings}/UserEngine.ini"
    as_root sed -i "/^\[ConsoleVariables\]/a Bgd.ServerDisplayName=\"${sietch_name}\"" \
      "${usersettings}/UserEngine.ini"
    ok "Set Bgd.ServerDisplayName=\"${sietch_name}\""
  fi

  if [ -n "${mining_multiplier}" ]; then
    log "Setting mining multiplier in UserEngine.ini"
    as_root sed -i '/^Dune\.GlobalMiningOutputMultiplier=/d' "${usersettings}/UserEngine.ini"
    as_root sed -i "/^\[ConsoleVariables\]/a Dune.GlobalMiningOutputMultiplier=${mining_multiplier}" \
      "${usersettings}/UserEngine.ini"
    ok "Set Dune.GlobalMiningOutputMultiplier=${mining_multiplier}"
  fi

  if [ -n "${server_password}" ]; then
    log "Setting server login password in UserEngine.ini"
    as_root sed -i '/^Bgd\.ServerLoginPassword=/d' "${usersettings}/UserEngine.ini"
    as_root sed -i "/^\[ConsoleVariables\]/a Bgd.ServerLoginPassword=\"${server_password}\"" \
      "${usersettings}/UserEngine.ini"
    ok "Set Bgd.ServerLoginPassword (password not echoed)"
  elif as_root grep -q '^Bgd\.ServerLoginPassword=' "${usersettings}/UserEngine.ini" 2>/dev/null; then
    log "Clearing server login password from UserEngine.ini"
    as_root sed -i '/^Bgd\.ServerLoginPassword=/d' "${usersettings}/UserEngine.ini"
    ok "Cleared Bgd.ServerLoginPassword"
  fi

  if [ -n "${farm_region}" ]; then
    log "Patching -FarmRegion to ${farm_region} in BattleGroup spec"
    local farm_patch
    farm_patch="$(run_kubectl get igwbg -n "${ns}" "${bg}" -o json |
      jq -r --arg r "${farm_region}" '
        [
          .spec.serverGroup.template.spec.sets | to_entries[] |
          . as $set |
          (.value.extraArgs // []) | to_entries[] |
          select(.value | test("-FarmRegion=")) |
          {
            op: "replace",
            path: ("/spec/serverGroup/template/spec/sets/" + ($set.key | tostring) + "/extraArgs/" + (.key | tostring)),
            value: ("-FarmRegion=" + $r)
          }
        ]
      ')"
    if [ "$(printf '%s' "${farm_patch}" | jq 'length')" -eq 0 ]; then
      warn "No -FarmRegion entries found in BattleGroup spec; skipping"
    else
      run_kubectl patch igwbg -n "${ns}" "${bg}" --type=json -p="${farm_patch}"
      ok "Patched -FarmRegion=${farm_region} in BattleGroup spec"
    fi
  fi

  if [ -n "${pvp_partition}" ]; then
    log "Setting PvP partition in UserGame.ini"
    as_root sed -i '/^\+m_PvpEnabledPartitions=/d' "${usersettings}/UserGame.ini"
    as_root sed -i "/^\[\/Script\/DuneSandbox\.PvpPveSettings\]/a +m_PvpEnabledPartitions=${pvp_partition}" \
      "${usersettings}/UserGame.ini"
    ok "Set +m_PvpEnabledPartitions=${pvp_partition}"
  fi

  if [ "${no_stop}" != "1" ]; then
    log "Starting battlegroup"
    run_battlegroup start
  fi

  ok "Canonical config applied. Run: $0 doctor to verify."
}

install_manager_service() {
  local port="${DUNE_MANAGER_PORT:-29187}"
  local timezone="${DUNE_MANAGER_TIMEZONE:-Europe/London}"
  local auth_token_file=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port) port="${2:-}"; shift 2 ;;
      --timezone) timezone="${2:-}"; shift 2 ;;
      --auth-token-file) auth_token_file="${2:-}"; shift 2 ;;
      --help|-h)
        printf 'Usage: %s install-manager-service [--port PORT] [--timezone TZ] [--auth-token-file FILE]\n' "$0"
        return 0
        ;;
      *) die "Unknown install-manager-service option: $1" ;;
    esac
  done

  validate_tcp_port "${port}" "manager service port"
  command -v curl >/dev/null 2>&1 || die "curl is required to download the manager service binary"

  log "Fetching latest release info for ${MANAGER_SERVICE_REPO}"
  local release_json release_tag download_url
  release_json="$(curl -fsSL "https://api.github.com/repos/${MANAGER_SERVICE_REPO}/releases/latest")"
  release_tag="$(printf '%s' "${release_json}" | jq -r '.tag_name')"
  [ -n "${release_tag}" ] || die "Could not determine latest release tag for ${MANAGER_SERVICE_REPO}"

  download_url="$(printf '%s' "${release_json}" |
    jq -r '.assets[] | select(.name == "dune-server-service") | .browser_download_url' | head -n1)"
  [ -n "${download_url}" ] || die "Could not find dune-server-service Linux binary in release ${release_tag}; check https://github.com/${MANAGER_SERVICE_REPO}/releases"

  log "Installing dune-server-service ${release_tag} to ${MANAGER_SERVICE_DIR}"
  as_root install -d -m 0755 "${MANAGER_SERVICE_DIR}"
  curl -fsSL "${download_url}" | as_root tee "${MANAGER_SERVICE_BIN}" >/dev/null
  as_root chmod 0755 "${MANAGER_SERVICE_BIN}"

  local ns
  ns="$(single_battlegroup_namespace 2>/dev/null || true)"
  as_root install -d -m 0755 "$(dirname "${MANAGER_SERVICE_ENV}")"
  {
    printf 'DUNE_DASHBOARD_PORT=%s\n' "${port}"
    printf 'DUNE_SERVICE_HOME=%s\n' "${DUNE_HOME}"
    printf 'DUNE_SERVICE_TIME_ZONE=%s\n' "${timezone}"
    [ -z "${ns}" ] || printf 'DUNE_NAMESPACE=%s\n' "${ns}"
    [ -z "${auth_token_file}" ] || printf 'DUNE_COMMAND_AUTH_TOKEN_FILE=%s\n' "${auth_token_file}"
  } | as_root tee "${MANAGER_SERVICE_ENV}" >/dev/null
  as_root chmod 0640 "${MANAGER_SERVICE_ENV}"

  as_root install -d -m 0755 "$(dirname "${MANAGER_SERVICE_UNIT}")"
  cat <<EOF | as_root tee "${MANAGER_SERVICE_UNIT}" >/dev/null
[Unit]
Description=Dune server management service
After=network-online.target k3s.service
Wants=network-online.target

[Service]
Type=simple
User=${DUNE_USER}
Group=${DUNE_USER}
ExecStart=${MANAGER_SERVICE_BIN}
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${DUNE_ROOT}/bin"
EnvironmentFile=-${MANAGER_SERVICE_ENV}
Restart=on-failure
RestartSec=10
ReadWritePaths=${DUNE_HOME}/.dune -${DUNE_HOME}/.local /tmp
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
NoNewPrivileges=false
MemoryDenyWriteExecute=false

[Install]
WantedBy=multi-user.target
EOF

  as_root systemctl daemon-reload
  as_root systemctl enable --now "$(basename "${MANAGER_SERVICE_UNIT}")"
  ok "Manager service installed and started on port ${port}"
  printf 'Connect via the dune-dedicated-server-manager desktop app (SSH tunnel to localhost:%s)\n' "${port}"
  printf 'Desktop app: https://github.com/%s/releases\n' "${MANAGER_SERVICE_REPO}"
}

update_manager_service() {
  command -v curl >/dev/null 2>&1 || die "curl is required to download the manager service binary"

  log "Fetching latest release info for ${MANAGER_SERVICE_REPO}"
  local release_json release_tag download_url current_version
  release_json="$(curl -fsSL "https://api.github.com/repos/${MANAGER_SERVICE_REPO}/releases/latest")"
  release_tag="$(printf '%s' "${release_json}" | jq -r '.tag_name')"
  [ -n "${release_tag}" ] || die "Could not determine latest release tag for ${MANAGER_SERVICE_REPO}"

  download_url="$(printf '%s' "${release_json}" |
    jq -r '.assets[] | select(.name == "dune-server-service") | .browser_download_url' | head -n1)"
  [ -n "${download_url}" ] || die "Could not find dune-server-service Linux binary in release ${release_tag}"

  if [ -x "${MANAGER_SERVICE_BIN}" ]; then
    current_version="$("${MANAGER_SERVICE_BIN}" --version 2>/dev/null | awk '{print $NF}' || true)"
    [ -n "${current_version}" ] && log "Current version: ${current_version}"
  fi
  log "Latest version:  ${release_tag}"

  log "Stopping dune-server-service"
  as_root systemctl stop "$(basename "${MANAGER_SERVICE_UNIT}")" || true

  log "Downloading dune-server-service ${release_tag}"
  curl -fsSL "${download_url}" | as_root tee "${MANAGER_SERVICE_BIN}" >/dev/null
  as_root chmod 0755 "${MANAGER_SERVICE_BIN}"

  as_root systemctl start "$(basename "${MANAGER_SERVICE_UNIT}")"
  ok "Updated to ${release_tag} and restarted"
}

uninstall_manager_service() {
  as_root systemctl disable --now "$(basename "${MANAGER_SERVICE_UNIT}")" >/dev/null 2>&1 || true
  as_root rm -f "${MANAGER_SERVICE_UNIT}" "${MANAGER_SERVICE_ENV}"
  as_root rm -rf "${MANAGER_SERVICE_DIR}"
  as_root systemctl daemon-reload
  ok "Removed manager service"
}

load_firewall_env() {
  if as_root test -f "${FIREWALL_ENV_FILE}"; then
    # shellcheck source=/dev/null
    source <(as_root cat "${FIREWALL_ENV_FILE}")
  fi
}

normalize_cidr_list() {
  tr ',' ' ' <<<"${1:-}" | awk '{for (i=1; i<=NF; i++) print $i}'
}

join_csv() {
  awk 'NF {items[++n]=$0} END {for (i=1; i<=n; i++) printf "%s%s", (i>1 ? ", " : ""), items[i]}'
}

set_admin_allowed_cidrs() {
  local cidrs="${1:-}"
  [ -n "${cidrs}" ] || die "Usage: $0 set-admin-allowed-cidrs CIDR[,CIDR]|none"

  as_root install -d -m 0755 "$(dirname "${FIREWALL_ENV_FILE}")"
  if ! as_root test -f "${FIREWALL_ENV_FILE}"; then
    : | as_root tee "${FIREWALL_ENV_FILE}" >/dev/null
  fi

  if [ "${cidrs}" = "none" ]; then
    as_root sed -i '/^DUNE_ADMIN_ALLOWED_CIDRS=/d' "${FIREWALL_ENV_FILE}"
    ok "Removed trusted admin CIDRs"
    return 0
  fi

  [[ "${cidrs}" =~ ^[0-9A-Fa-f:.,/_-]+$ ]] || die "CIDR list contains unsupported characters"
  local cidr
  while read -r cidr; do
    [ -n "${cidr}" ] || continue
    [[ "${cidr}" =~ /[0-9]+$ ]] || die "Admin source must be CIDR notation: ${cidr}"
  done < <(normalize_cidr_list "${cidrs}")

  if as_root grep -q '^DUNE_ADMIN_ALLOWED_CIDRS=' "${FIREWALL_ENV_FILE}"; then
    as_root sed -i "s|^DUNE_ADMIN_ALLOWED_CIDRS=.*|DUNE_ADMIN_ALLOWED_CIDRS=${cidrs}|" "${FIREWALL_ENV_FILE}"
  else
    printf 'DUNE_ADMIN_ALLOWED_CIDRS=%s\n' "${cidrs}" | as_root tee -a "${FIREWALL_ENV_FILE}" >/dev/null
  fi
  as_root chmod 0644 "${FIREWALL_ENV_FILE}"
  ok "Configured trusted admin CIDRs: ${cidrs}"
}

admin_surface_ports() {
  local ns bg pghero_port
  {
    printf '6443\tKubernetes API\n'
    printf '10250\tkubelet API\n'
    printf '5432\thost-network PostgreSQL\n'
    printf '8888\tfile browser\n'
    printf '18888\tfile browser published URL\n'

    if ns="$(single_battlegroup_namespace 2>/dev/null)"; then
      bg="${ns#funcom-seabass-}"
      pghero_port="$(run_kubectl get databaseutility -n "${ns}" "${bg}-db-util" -o jsonpath='{.spec.pgHero.port}' 2>/dev/null || true)"
      [ -n "${pghero_port}" ] && printf '%s\tPgHero\n' "${pghero_port}"
      run_kubectl get svc -n "${ns}" -o json 2>/dev/null |
        jq -r '
          .items[] as $svc |
          select($svc.spec.type == "NodePort") |
          $svc.spec.ports[] |
          select(.nodePort != null) |
          select(((($svc.metadata.name | test("-mq-game-svc$")) and (.port == 5672)) | not)) |
          "\(.nodePort)\tKubernetes NodePort \($svc.metadata.name):\(.port)"
        ' || true
    fi
  } | awk -F '\t' 'NF && !seen[$1]++ {print $1 "\t" $2}'
}

public_surface_ports() {
  local ns bg rmq_port
  printf '7777-7810/udp\tgame servers\n'
  if ns="$(single_battlegroup_namespace 2>/dev/null)"; then
    bg="${ns#funcom-seabass-}"
    rmq_port="$(run_kubectl get svc -n "${ns}" -l "app=${bg}-mq-game-sts" -o jsonpath='{.items[0].spec.ports[?(@.port==5672)].nodePort}' 2>/dev/null || true)"
    [ -n "${rmq_port}" ] && printf '%s/tcp\tRMQ game NodePort\n' "${rmq_port}"
  else
    printf '31982/tcp\tRMQ game NodePort\n'
  fi
}

player_facing_host() {
  local host
  host="$(settings_line 4)"
  if [ -z "${host}" ]; then
    host="$(detect_public_ip)"
  fi
  printf '%s\n' "${host}"
}

tcp_listeners_for_port() {
  local port="$1"
  as_root ss -ltnH 2>/dev/null | awk -v port="${port}" '$4 ~ ":" port "$" {print $4}'
}

tcp_port_has_non_loopback_listener() {
  local port="$1"
  tcp_listeners_for_port "${port}" | awk -v port="${port}" '
    {
      host=$0
      sub(":" port "$", "", host)
      gsub(/^\[/, "", host)
      gsub(/\]$/, "", host)
      sub(/%.*/, "", host)
      if (host != "127.0.0.1" && host !~ /^127\./ && host != "::1" && host != "localhost") found=1
    }
    END {exit found ? 0 : 1}
  '
}

dune_firewall_active() {
  command -v nft >/dev/null 2>&1 && as_root nft list table inet dune_native >/dev/null 2>&1
}

active_firewall_summary() {
  if command -v firewall-cmd >/dev/null 2>&1 && as_root firewall-cmd --state >/dev/null 2>&1; then
    printf 'firewalld running'
    return 0
  fi
  if command -v nft >/dev/null 2>&1; then
    if dune_firewall_active; then
      printf 'nftables dune_native table present'
      return 0
    fi
    printf 'nftables present, no dune_native table detected'
    return 1
  fi
  printf 'no supported host firewall tool detected'
  return 1
}

exposure_report() {
  load_firewall_env
  local port label listeners cidrs firewall_active
  cidrs="$(normalize_cidr_list "${DUNE_ADMIN_ALLOWED_CIDRS:-}" | join_csv)"
  firewall_active=0
  dune_firewall_active && firewall_active=1

  printf 'Dune native exposure report\n\n'
  printf 'Firewall posture: '
  active_firewall_summary || true
  printf '\n'
  printf 'Trusted admin CIDRs: %s\n\n' "${cidrs:-not configured}"

  printf 'Player-facing surfaces expected to be reachable from the internet:\n'
  public_surface_ports | while IFS=$'\t' read -r port label; do
    printf '  %-16s %s\n' "${port}" "${label}"
  done
  printf '  Note: if UserEngine.ini changes Port or IGWPort ranges, match those ranges instead.\n\n'

  printf 'Admin surfaces that should be restricted to loopback/VPN/trusted CIDRs:\n'
  admin_surface_ports | while IFS=$'\t' read -r port label; do
    listeners="$(tcp_listeners_for_port "${port}" | join_csv)"
    if [ "${firewall_active}" = "1" ] && [ -n "${cidrs}" ]; then
      if [[ "${label}" == Kubernetes\ NodePort* ]]; then
        printf '  FILTERED %-6s %-48s trusted CIDRs only\n' "${port}" "${label}"
      elif tcp_port_has_non_loopback_listener "${port}"; then
        printf '  FILTERED %-6s %-48s listeners: %s\n' "${port}" "${label}" "${listeners:-unknown}"
      else
        printf '  OK       %-6s %-48s listeners: %s\n' "${port}" "${label}" "${listeners:-none}"
      fi
    elif [[ "${label}" == Kubernetes\ NodePort* ]]; then
      printf '  WARN %-6s %-48s kube-proxy NodePort; restrict with host firewall\n' "${port}" "${label}"
    elif tcp_port_has_non_loopback_listener "${port}"; then
      printf '  WARN %-6s %-48s listeners: %s\n' "${port}" "${label}" "${listeners:-unknown}"
    else
      printf '  OK   %-6s %-48s listeners: %s\n' "${port}" "${label}" "${listeners:-none}"
    fi
  done
}

firewall_plan() {
  load_firewall_env
  local admin_ports admin_ports_nft ipv4_cidrs ipv6_cidrs cidr rmq_port cluster_cidrs
  admin_ports="$(admin_surface_ports | awk -F '\t' '{print $1}' | sort -n | uniq | join_csv)"
  admin_ports_nft="{ ${admin_ports} }"
  ipv4_cidrs="$(firewall_allowed_cidrs | awk 'index($0,":")==0' | join_csv)"
  ipv6_cidrs="$(firewall_allowed_cidrs | awk 'index($0,":")>0' | join_csv)"
  cluster_cidrs="$(cluster_internal_cidrs | join_csv)"
  rmq_port="$(public_surface_ports | awk -F '[/\t]' '$2 == "tcp" {print $1; exit}')"
  [ -n "${rmq_port}" ] || rmq_port=31982

  printf 'Dune native firewall hardening plan\n\n'
  printf 'Keep public/player traffic reachable:\n'
  printf '  7777-7810/udp\n'
  printf '  %s/tcp\n\n' "${rmq_port}"

  printf 'Restrict these admin TCP ports to trusted admin sources:\n'
  admin_surface_ports | while IFS=$'\t' read -r port label; do
    printf '  %-6s %s\n' "${port}" "${label}"
  done
  printf '\n'
  if [ -n "${cluster_cidrs}" ]; then
    printf 'Also allow cluster-internal sources needed by Dune operators and database utilities:\n'
    printf '  %s\n\n' "${cluster_cidrs}"
  fi

  if [ -z "${DUNE_ADMIN_ALLOWED_CIDRS:-}" ]; then
    warn "No trusted admin CIDRs configured. Run: $0 set-admin-allowed-cidrs 10.0.0.0/24,100.64.0.0/10"
  fi

  printf 'nftables snippet, review before applying:\n'
  printf 'table inet dune_native {\n'
  printf '  chain input {\n'
  printf '    type filter hook input priority -5; policy accept;\n'
  printf '    ct state established,related accept\n'
  printf '    iifname "lo" accept\n'
  [ -n "${ipv4_cidrs}" ] && printf '    ip saddr { %s } tcp dport %s accept\n' "${ipv4_cidrs}" "${admin_ports_nft}"
  [ -n "${ipv6_cidrs}" ] && printf '    ip6 saddr { %s } tcp dport %s accept\n' "${ipv6_cidrs}" "${admin_ports_nft}"
  printf '    tcp dport %s drop\n' "${admin_ports_nft}"
  printf '  }\n'
  printf '}\n\n'

  if command -v firewall-cmd >/dev/null 2>&1; then
    printf 'firewalld public allows, if you choose firewalld instead:\n'
    printf '  sudo firewall-cmd --permanent --add-port=7777-7810/udp\n'
    printf '  sudo firewall-cmd --permanent --add-port=%s/tcp\n' "${rmq_port}"
    while read -r cidr; do
      [ -n "${cidr}" ] || continue
      printf '  # Add rich allow/drop rules for admin CIDR %s and ports: %s\n' "${cidr}" "${admin_ports}"
    done < <(normalize_cidr_list "${DUNE_ADMIN_ALLOWED_CIDRS:-}")
    printf '  sudo firewall-cmd --reload\n'
  fi
}

nft_admin_ports_expr() {
  admin_surface_ports | awk -F '\t' '{print $1}' | sort -n | uniq | join_csv | awk '{print "{ " $0 " }"}'
}

cluster_internal_cidrs() {
  run_kubectl get nodes -o json 2>/dev/null |
    jq -r '.items[] | (.spec.podCIDRs[]?, .spec.podCIDR?)' 2>/dev/null |
    awk 'NF' | sort -u || true
}

firewall_allowed_cidrs() {
  {
    normalize_cidr_list "${DUNE_ADMIN_ALLOWED_CIDRS:-}"
    cluster_internal_cidrs
  } | awk 'NF && !seen[$0]++'
}

nft_cidr_expr() {
  local family="$1"
  firewall_allowed_cidrs |
    awk -v family="${family}" '
      family == "ip" && index($0,":") == 0 {print}
      family == "ip6" && index($0,":") > 0 {print}
    ' | join_csv | awk 'NF {print "{ " $0 " }"}'
}

write_firewall_rules_file() {
  load_firewall_env
  [ -n "${DUNE_ADMIN_ALLOWED_CIDRS:-}" ] || die "Trusted admin CIDRs are required. Run: $0 install-firewall --admin-cidrs CIDR[,CIDR]"
  command -v nft >/dev/null 2>&1 || die "nft is required for install-firewall"

  local admin_ports ipv4_cidrs ipv6_cidrs
  admin_ports="$(nft_admin_ports_expr)"
  [ -n "${admin_ports}" ] || die "No Dune admin ports discovered"
  ipv4_cidrs="$(nft_cidr_expr ip)"
  ipv6_cidrs="$(nft_cidr_expr ip6)"
  [ -n "${ipv4_cidrs}${ipv6_cidrs}" ] || die "No valid trusted admin CIDRs found"

  {
    printf '# Generated by dune-native.sh install-firewall. Do not edit by hand.\n'
    printf 'table inet dune_native {\n'
    printf '  chain input {\n'
    printf '    type filter hook input priority -5; policy accept;\n'
    printf '    ct state established,related accept\n'
    printf '    iifname "lo" accept\n'
    [ -n "${ipv4_cidrs}" ] && printf '    ip saddr %s tcp dport %s accept\n' "${ipv4_cidrs}" "${admin_ports}"
    [ -n "${ipv6_cidrs}" ] && printf '    ip6 saddr %s tcp dport %s accept\n' "${ipv6_cidrs}" "${admin_ports}"
    printf '    tcp dport %s drop\n' "${admin_ports}"
    printf '  }\n'
    printf '}\n'
  } | as_root tee "${FIREWALL_RULES_FILE}" >/dev/null
  as_root chmod 0644 "${FIREWALL_RULES_FILE}"
}

install_firewall() {
  local cidrs="" nft_path sh_path
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --admin-cidrs) cidrs="${2:-}"; shift 2 ;;
      --help|-h)
        printf 'Usage: %s install-firewall [--admin-cidrs CIDR[,CIDR]]\n' "$0"
        return 0
        ;;
      *) die "Unknown install-firewall option: $1" ;;
    esac
  done

  [ -z "${cidrs}" ] || set_admin_allowed_cidrs "${cidrs}"
  load_firewall_env
  write_firewall_rules_file
  nft_path="$(command -v nft)"
  sh_path="$(command -v sh)"

  as_root install -d -m 0755 "$(dirname "${FIREWALL_SERVICE}")"
  cat <<EOF | as_root tee "${FIREWALL_SERVICE}" >/dev/null
[Unit]
Description=Dune native admin-port firewall
Wants=k3s.service
After=network-online.target k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=${sh_path} -c '${nft_path} delete table inet dune_native >/dev/null 2>&1 || true'
ExecStart=${nft_path} -f ${FIREWALL_RULES_FILE}
ExecStop=${sh_path} -c '${nft_path} delete table inet dune_native >/dev/null 2>&1 || true'

[Install]
WantedBy=multi-user.target
EOF

  as_root systemctl daemon-reload
  as_root systemctl enable "$(basename "${FIREWALL_SERVICE}")"
  as_root systemctl restart "$(basename "${FIREWALL_SERVICE}")"
  ok "Installed and applied dedicated Dune nftables table"
  exposure_report
}

uninstall_firewall() {
  as_root systemctl disable --now "$(basename "${FIREWALL_SERVICE}")" >/dev/null 2>&1 || true
  if command -v nft >/dev/null 2>&1; then
    as_root nft delete table inet dune_native >/dev/null 2>&1 || true
  fi
  as_root rm -f "${FIREWALL_SERVICE}" "${FIREWALL_RULES_FILE}" "${FIREWALL_ENV_FILE}"
  as_root systemctl daemon-reload
  ok "Removed dedicated Dune nftables table and systemd unit"
}

teardown_show_plan() {
  local keep_user="$1"
  local keep_backups="$2"

  printf 'Dune native teardown plan\n\n'
  printf 'Will remove/disable:\n'
  printf '  - manager service (dune-server-service) if installed\n'
  printf '  - dedicated Dune nftables table and firewall systemd unit\n'
  printf '  - scheduled backup timer/service and %s\n' "${BACKUP_ENV_FILE}"
  printf '  - containerd socket symlink tmpfiles.d config: %s\n' "${CONTAINERD_SYMLINK_CONF}"
  printf '  - native k3s service, cluster state, CNI state, and Dune k3s runner\n'
  printf '  - Dune sudoers file: %s\n' "${SUDOERS_FILE}"
  printf '  - Dune-created OpenRC compatibility wrappers when their contents match this script\n'
  printf '  - SteamCMD tarball install at %s when %s points there\n' "${STEAMCMD_DIR}" "${STEAMCMD_BIN}"
  if [ "${keep_user}" = "1" ]; then
    printf '  - keep %s user and %s\n' "${DUNE_USER}" "${DUNE_HOME}"
  else
    printf '  - %s user and home: %s\n' "${DUNE_USER}" "${DUNE_HOME}"
  fi
  if [ "${keep_backups}" = "1" ]; then
    printf '  - keep local Funcom artifact/backups directory: %s\n' "${FUNCOM_ROOT}"
  else
    printf '  - local Funcom artifact/backups directory: %s\n' "${FUNCOM_ROOT}"
  fi
  printf '\nWill not remove this Steam package directory or off-host backup copy targets.\n'
}

remove_file_if_contains() {
  local file="$1"
  local pattern="$2"
  if as_root test -f "${file}" && as_root grep -q "${pattern}" "${file}" 2>/dev/null; then
    as_root rm -f "${file}"
  fi
}

teardown_native() {
  local dry_run=0
  local assume_yes=0
  local keep_user=0
  local keep_backups=0
  local confirm_text

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dry-run) dry_run=1; shift ;;
      --yes|-y) assume_yes=1; shift ;;
      --keep-user) keep_user=1; shift ;;
      --keep-backups) keep_backups=1; shift ;;
      --help|-h)
        printf 'Usage: %s teardown [--dry-run] [--yes] [--keep-user] [--keep-backups]\n' "$0"
        return 0
        ;;
      *) die "Unknown teardown option: $1" ;;
    esac
  done

  teardown_show_plan "${keep_user}" "${keep_backups}"
  if [ "${dry_run}" = "1" ]; then
    return 0
  fi

  if [ "${assume_yes}" != "1" ]; then
    printf '\n%s\n' "${red}DESTRUCTIVE TEARDOWN WARNING${nc}"
    printf 'This removes the native Kubernetes cluster and local Dune server state from this host.\n'
    printf 'Type TEARDOWN %s to continue: ' "${DUNE_USER}"
    IFS= read -r confirm_text
    [ "${confirm_text}" = "TEARDOWN ${DUNE_USER}" ] || die "Teardown aborted"
  fi

  if as_root test -f "${MANAGER_SERVICE_UNIT}"; then
    log "Removing manager service"
    uninstall_manager_service || true
  fi

  log "Removing Dune firewall"
  uninstall_firewall || true

  log "Removing scheduled backup timer"
  uninstall_backup_timer || true
  as_root rm -rf "${BACKUP_LOG_DIR}"

  log "Stopping battlegroup and k3s services"
  if as_root test -x "${DUNE_ROOT}/bin/battlegroup" || as_root test -x "${DOWNLOAD_PATH}/scripts/battlegroup.sh"; then
    run_battlegroup stop >/dev/null 2>&1 || true
  fi
  as_root systemctl stop k3s >/dev/null 2>&1 || true

  log "Uninstalling k3s"
  if as_root test -x "${K3S_UNINSTALL}"; then
    as_root "${K3S_UNINSTALL}" || true
  fi
  as_root rm -f "${RUNNER}"
  as_root rm -f "${K3S_MANIFEST_DIR}/dune-rolebindings.yaml" "${K3S_MANIFEST_DIR}/dune-runtimes.yaml"
  as_root rm -f "${K3S_CONFIG_DIR}/config.yaml" "${K3S_CONFIG_DIR}/scheduler.yaml" "${POD_RESOLV_CONF}"
  as_root rm -rf "${K3S_OVERRIDE_DIR}"
  as_root rm -rf "${K3S_DATA_DIR}" "${K3S_CONFIG_DIR}" "${HOST_RUN}/k3s" "${HOST_VAR}/lib/cni" "${HOST_ETC}/cni/net.d/10-flannel.conflist"

  log "Removing Dune host integration files"
  as_root rm -f "${CONTAINERD_SYMLINK_CONF}"
  as_root rm -f "${SUDOERS_FILE}"
  remove_file_if_contains "${RC_SERVICE_BIN}" 'exec systemctl'
  remove_file_if_contains "${RC_UPDATE_BIN}" 'Unsupported rc-update action'
  if as_root test -f "${STEAMCMD_BIN}" && as_root grep -q "cd \"${STEAMCMD_DIR}\"" "${STEAMCMD_BIN}" 2>/dev/null; then
    as_root rm -f "${STEAMCMD_BIN}"
    as_root rm -rf "${STEAMCMD_DIR}"
  fi

  if [ "${keep_backups}" != "1" ]; then
    log "Removing local Funcom artifact storage"
    as_root rm -rf "${FUNCOM_ROOT}"
  fi

  if [ "${keep_user}" != "1" ]; then
    log "Removing ${DUNE_USER} user and home"
    if id "${DUNE_USER}" >/dev/null 2>&1; then
      as_root pkill -u "${DUNE_USER}" >/dev/null 2>&1 || true
      as_root userdel -r "${DUNE_USER}" >/dev/null 2>&1 || true
    fi
    as_root rm -rf "${DUNE_HOME}"
  fi

  as_root systemctl daemon-reload
  ok "Dune native teardown complete"
}

DOCTOR_FAILS=0
DOCTOR_WARNS=0
DOCTOR_JSON_MODE=0
DOCTOR_JSON_CHECKS=()
DOCTOR_CURRENT_SECTION=""

doctor_section() {
  if [ "${DOCTOR_JSON_MODE}" = "1" ]; then
    DOCTOR_CURRENT_SECTION="$1"
  else
    printf '\n%s\n' "$1"
  fi
}
doctor_ok() {
  if [ "${DOCTOR_JSON_MODE}" = "1" ]; then
    DOCTOR_JSON_CHECKS+=("$(jq -n --arg s "${DOCTOR_CURRENT_SECTION}" --arg m "$*" \
      '{"section":$s,"status":"ok","message":$m}')")
  else
    printf '%s\n' "${green}OK${nc}   $*"
  fi
}
doctor_warn() {
  DOCTOR_WARNS=$((DOCTOR_WARNS + 1))
  if [ "${DOCTOR_JSON_MODE}" = "1" ]; then
    DOCTOR_JSON_CHECKS+=("$(jq -n --arg s "${DOCTOR_CURRENT_SECTION}" --arg m "$*" \
      '{"section":$s,"status":"warn","message":$m}')")
  else
    printf '%s\n' "${yellow}WARN${nc} $*"
  fi
}
doctor_fail() {
  DOCTOR_FAILS=$((DOCTOR_FAILS + 1))
  if [ "${DOCTOR_JSON_MODE}" = "1" ]; then
    DOCTOR_JSON_CHECKS+=("$(jq -n --arg s "${DOCTOR_CURRENT_SECTION}" --arg m "$*" \
      '{"section":$s,"status":"fail","message":$m}')")
  else
    printf '%s\n' "${red}FAIL${nc} $*"
  fi
}

doctor_require_command() {
  local cmd="$1"
  if command -v "${cmd}" >/dev/null 2>&1; then
    doctor_ok "command available: ${cmd}"
  else
    doctor_fail "missing required command: ${cmd}"
  fi
}

doctor_deployments_available() {
  local ns="$1"
  local label="$2"
  local bad
  if ! bad="$(run_kubectl get deploy -n "${ns}" -o json 2>/dev/null |
    jq -r '.items[] | select((.spec.replicas // 0) > (.status.availableReplicas // 0)) | .metadata.name')"; then
    doctor_fail "cannot read deployments in ${ns}"
    return
  fi
  if [ -z "${bad}" ]; then
    doctor_ok "${label} deployments available"
  else
    doctor_fail "${label} deployments unavailable: ${bad//$'\n'/, }"
  fi
}

doctor_check_host() {
  doctor_section "Host"
  [ "$(uname -s)" = "Linux" ] && doctor_ok "host OS is Linux" || doctor_fail "host OS is not Linux"
  [ "$(uname -m)" = "x86_64" ] && doctor_ok "architecture is x86_64" || doctor_fail "architecture is not x86_64"
  if awk '/^flags[ \t]*:/ && /(^| )avx2( |$)/ {found=1} END {exit found ? 0 : 1}' /proc/cpuinfo; then
    doctor_ok "CPU reports AVX2"
  else
    doctor_fail "CPU does not report AVX2"
  fi

  local mem_gb root_free_gb home_parent home_free_gb
  mem_gb="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"
  [ "${mem_gb}" -ge 20 ] && doctor_ok "memory: ${mem_gb} GB" || doctor_warn "memory is ${mem_gb} GB; vendor recommends 20 GB or experimental swap"
  root_free_gb="$(df -BG --output=avail / | awk 'NR==2 {gsub(/G/,""); print $1}')"
  [ "${root_free_gb}" -ge 100 ] && doctor_ok "free space on /: ${root_free_gb} GB" || doctor_fail "free space on / is ${root_free_gb} GB; expected at least 100 GB"
  home_parent="$(dirname "${DUNE_HOME}")"
  while [ ! -e "${home_parent}" ] && [ "${home_parent}" != "/" ]; do
    home_parent="$(dirname "${home_parent}")"
  done
  home_free_gb="$(df -BG --output=avail "${home_parent}" | awk 'NR==2 {gsub(/G/,""); print $1}')"
  [ "${home_free_gb}" -ge 100 ] && doctor_ok "free space for ${DUNE_HOME}: ${home_free_gb} GB" || doctor_fail "free space for ${DUNE_HOME} is ${home_free_gb} GB; expected at least 100 GB"

  doctor_require_command systemctl
  doctor_require_command jq
  doctor_require_command curl
  doctor_require_command ss
  if as_root systemctl is-active --quiet k3s; then
    doctor_ok "k3s systemd service is active"
  else
    doctor_fail "k3s systemd service is not active"
  fi
}

doctor_check_cluster() {
  doctor_section "Cluster"
  local nodes not_ready bad_pods
  if ! nodes="$(run_kubectl get nodes --no-headers 2>/dev/null)"; then
    doctor_fail "cannot query Kubernetes nodes"
    return
  fi
  if [ -n "${nodes}" ]; then
    doctor_ok "Kubernetes API reachable"
  else
    doctor_fail "no Kubernetes nodes found"
  fi

  not_ready="$(awk '$2 != "Ready" {print $1 ":" $2}' <<<"${nodes}")"
  [ -z "${not_ready}" ] && doctor_ok "all nodes Ready" || doctor_fail "nodes not Ready: ${not_ready//$'\n'/, }"

  doctor_deployments_available cert-manager "cert-manager"
  doctor_deployments_available funcom-operators "Funcom operator"

  bad_pods="$(run_kubectl get pods -A -o json 2>/dev/null |
    jq -r '.items[] |
      select(.status.phase != "Succeeded") |
      select((.status.containerStatuses // []) | any(.ready != true)) |
      "\(.metadata.namespace)/\(.metadata.name) phase=\(.status.phase) reasons=\([.status.containerStatuses[]? | select(.ready != true) | (.state.waiting.reason // .state.terminated.reason // "NotReady")] | unique | join(","))"')"
  [ -z "${bad_pods}" ] && doctor_ok "all non-completed pods are Ready" || doctor_fail "pods not Ready: ${bad_pods//$'\n'/; }"
}

doctor_check_battlegroup() {
  doctor_section "Battlegroup"
  local ns bg title phase stopped status backups latest_backup backup_age_hours max_age_hours mode_bad token_count rmq_port director_port pghero_port pod_name pod_dns search_extra
  if ! ns="$(single_battlegroup_namespace 2>/dev/null)"; then
    doctor_warn "no single battlegroup namespace found"
    return
  fi
  bg="${ns#funcom-seabass-}"

  title="$(run_kubectl get battlegroup -n "${ns}" "${bg}" -o jsonpath='{.spec.title}' 2>/dev/null || true)"
  phase="$(run_kubectl get battlegroup -n "${ns}" "${bg}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  stopped="$(run_kubectl get battlegroup -n "${ns}" "${bg}" -o jsonpath='{.spec.stop}' 2>/dev/null || true)"
  status="$(run_kubectl get battlegroup -n "${ns}" "${bg}" --no-headers 2>/dev/null || true)"
  doctor_ok "found battlegroup ${title:-${bg}} in ${ns}"
  [ "${phase}" = "Healthy" ] && doctor_ok "battlegroup phase is Healthy" || doctor_fail "battlegroup phase is ${phase:-unknown}"
  [ "${stopped}" = "false" ] && doctor_ok "battlegroup is started" || doctor_warn "battlegroup stop flag is ${stopped:-unknown}"
  if awk '$3=="Healthy" && $6=="Ready" && $8=="Healthy" && $9=="Healthy" {found=1} END {exit found ? 0 : 1}' <<<"${status}"; then
    doctor_ok "database, gateway, and director status are healthy"
  else
    doctor_warn "vendor status columns are not all healthy; run: $0 battlegroup status"
  fi

  rmq_port="$(run_kubectl get svc -n "${ns}" -l "app=${bg}-mq-game-sts" -o jsonpath='{.items[0].spec.ports[?(@.port==5672)].nodePort}' 2>/dev/null || true)"
  [ "${rmq_port}" = "31982" ] && doctor_ok "RMQ game NodePort is 31982/tcp" || doctor_fail "RMQ game NodePort is ${rmq_port:-missing}; expected 31982"
  director_port="$(run_kubectl get svc -n "${ns}" "${bg}-bgd-svc" -o jsonpath='{.spec.ports[?(@.port==11717)].nodePort}' 2>/dev/null || true)"
  [ -n "${director_port}" ] && doctor_ok "Director NodePort is ${director_port}/tcp" || doctor_fail "Director NodePort missing"
  pghero_port="$(run_kubectl get databaseutility -n "${ns}" "${bg}-db-util" -o jsonpath='{.spec.pgHero.port}' 2>/dev/null || true)"
  [ -n "${pghero_port}" ] && doctor_ok "PgHero configured on ${pghero_port}/tcp" || doctor_warn "PgHero port is not configured"

  if as_root ss -lun | awk '$4 ~ /:7777$/ {found=1} END {exit found ? 0 : 1}'; then
    doctor_ok "game UDP listener found on 7777"
  else
    doctor_warn "no local UDP listener found on 7777; game servers may still be starting or configured differently"
  fi
  doctor_ok "RMQ exposure is represented by Kubernetes NodePort ${rmq_port}; kube-proxy may not show a listening process in ss"

  token_count="$(run_kubectl get battlegroup -n "${ns}" "${bg}" -o json 2>/dev/null |
    jq '[paths(scalars) as $p | select(getpath($p)|tostring|test("eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+"))] | length')"
  [ "${token_count}" -gt 0 ] && doctor_ok "self-host token references present without printing values (${token_count} fields)" || doctor_warn "no token-looking values found in BattleGroup"
  if run_kubectl get secret -n "${ns}" server-gateway-secret >/dev/null 2>&1; then
    doctor_ok "server-gateway-secret exists"
  else
    doctor_fail "server-gateway-secret missing"
  fi

  mode_bad="$(as_root find "${DUNE_ROOT}" -maxdepth 1 -type f \( -name 'sh-*.yaml' -o -name 'sh-*-fls-secret.yaml' \) \
    ! -name '*-dump-*.yaml' ! -name '*-import-*.yaml' ! -name '*-restore-*.yaml' ! -name '*-backup-*.yaml' \
    ! -perm 0600 -printf '%p ' 2>/dev/null || true)"
  [ -z "${mode_bad}" ] && doctor_ok "local generated world YAML files are mode 0600" || doctor_warn "local generated world YAML files need chmod 600: ${mode_bad}"

  if grep -q "resolv-conf=${POD_RESOLV_CONF}" "${K3S_CONFIG_DIR}/config.yaml" 2>/dev/null && [ -f "${POD_RESOLV_CONF}" ]; then
    doctor_ok "k3s pod DNS resolver is pinned to ${POD_RESOLV_CONF}"
  else
    doctor_warn "k3s pod DNS resolver is not pinned; host search domains can break Funcom backend registration"
  fi
  pod_name="$(run_kubectl get pods -n "${ns}" -o name 2>/dev/null | grep -- '-sgw-deploy-' | head -n 1 || true)"
  if [ -n "${pod_name}" ] && pod_dns="$(run_kubectl exec -n "${ns}" "${pod_name}" -- cat /etc/resolv.conf 2>/dev/null)"; then
    search_extra="$(awk '/^search / {for (i=2; i<=NF; i++) if ($i !~ /(^|\.)svc\.cluster\.local$/ && $i != "cluster.local") print $i}' <<<"${pod_dns}" | paste -sd, -)"
    [ -z "${search_extra}" ] && doctor_ok "battlegroup pod DNS search path contains only cluster-local domains" || doctor_warn "battlegroup pod DNS includes host search domains (${search_extra}); restart k3s and battlegroup after applying the pod resolver fix"
  else
    doctor_warn "could not inspect battlegroup pod DNS search path"
  fi

  backups="${FUNCOM_ROOT}/artifacts/database-dumps/${bg}"
  latest_backup="$(backup_latest_for_bg "${bg}")"
  if [ -n "${latest_backup}" ]; then
    doctor_ok "latest database backup: ${latest_backup}"
    max_age_hours="${DUNE_BACKUP_MAX_AGE_HOURS:-${DEFAULT_BACKUP_MAX_AGE_HOURS}}"
    backup_age_hours="$(( ( $(date +%s) - $(as_root stat -c '%Y' "${latest_backup}") ) / 3600 ))"
    [ "${backup_age_hours}" -le "${max_age_hours}" ] && doctor_ok "latest backup age: ${backup_age_hours}h" || doctor_warn "latest backup is ${backup_age_hours}h old; threshold is ${max_age_hours}h"
    if backup_copy_target_configured; then
      if backup_copy_exists_for "${latest_backup}" "${bg}"; then
        doctor_ok "latest backup exists at copy target: ${DUNE_BACKUP_COPY_TARGET}"
      else
        doctor_warn "latest backup has not been copied to ${DUNE_BACKUP_COPY_TARGET}"
      fi
    else
      doctor_warn "off-host backup copy target is not configured; run: $0 set-backup-copy-target TARGET"
    fi
  else
    doctor_warn "no database backups found in ${backups}; run: $0 backup"
  fi

  local bgd_pod declare_total declare_empty declare_populated bgd_logs
  bgd_pod="$(run_kubectl get pods -n "${ns}" -l role=igw-battlegroup-director \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -n "${bgd_pod}" ]; then
    bgd_logs="$(run_kubectl logs -n "${ns}" "${bgd_pod}" 2>/dev/null)" || bgd_logs=""
    declare_total=$(printf '%s\n' "${bgd_logs}" | grep -c "DeclareBattlegroupUpdates") || declare_total=0
    declare_empty=$(printf '%s\n' "${bgd_logs}" | grep "DeclareBattlegroupUpdates" \
      | grep -c 'UpDeclarationsByPartitionId":{}') || declare_empty=0
    declare_populated=$(( declare_total - declare_empty ))
    if [ "${declare_populated}" -gt 0 ]; then
      doctor_ok "BGD has fired ${declare_populated} populated DeclareBattlegroupUpdates — server should be visible in browser"
    elif [ "${declare_total}" -gt 0 ]; then
      doctor_warn "BGD fired ${declare_total} DeclareBattlegroupUpdates but all had empty payloads — server not visible; check --node-external-ip and game pod readiness"
    else
      doctor_warn "no DeclareBattlegroupUpdates in BGD logs — possible build skew; run: $0 update"
    fi
  else
    doctor_warn "BGD pod not found; cannot check browser visibility"
  fi
}

doctor_check_backup_timer() {
  doctor_section "Scheduled Backups"
  if as_root systemctl list-unit-files "$(basename "${BACKUP_TIMER}")" --no-legend 2>/dev/null | awk 'NF {found=1} END {exit found ? 0 : 1}'; then
    doctor_ok "backup timer unit is installed"
    if as_root systemctl is-enabled --quiet "$(basename "${BACKUP_TIMER}")"; then
      doctor_ok "backup timer is enabled"
    else
      doctor_warn "backup timer is installed but not enabled"
    fi
    if as_root systemctl is-active --quiet "$(basename "${BACKUP_TIMER}")"; then
      doctor_ok "backup timer is active"
    else
      doctor_warn "backup timer is not active"
    fi
    local next
    next="$(as_root systemctl list-timers --no-pager --no-legend "$(basename "${BACKUP_TIMER}")" 2>/dev/null | awk '{print $1, $2, $3, $4}')"
    [ -n "${next}" ] && doctor_ok "next scheduled backup: ${next}" || doctor_warn "could not determine next scheduled backup time"
  else
    doctor_warn "backup timer is not installed; run: $0 install-backup-timer"
  fi
}

doctor_check_firewall() {
  doctor_section "Firewall And Admin Exposure"
  load_firewall_env

  local firewall_summary exposed port label listeners cidrs firewall_active
  firewall_summary="$(active_firewall_summary || true)"
  firewall_active=0
  dune_firewall_active && firewall_active=1
  case "${firewall_summary}" in
    firewalld\ running|nftables\ dune_native\ table\ present)
      doctor_ok "host firewall posture: ${firewall_summary}"
      ;;
    *)
      doctor_warn "host firewall posture: ${firewall_summary}; run: $0 firewall-plan"
      ;;
  esac

  cidrs="$(normalize_cidr_list "${DUNE_ADMIN_ALLOWED_CIDRS:-}" | join_csv)"
  if [ -n "${cidrs}" ]; then
    doctor_ok "trusted admin CIDRs configured: ${cidrs}"
  else
    doctor_warn "trusted admin CIDRs are not configured; run: $0 set-admin-allowed-cidrs CIDR[,CIDR]"
  fi

  exposed=""
  while IFS=$'\t' read -r port label; do
    if [[ "${label}" == Kubernetes\ NodePort* ]]; then
      exposed+="${port} ${label} (kube-proxy NodePort); "
    elif tcp_port_has_non_loopback_listener "${port}"; then
      listeners="$(tcp_listeners_for_port "${port}" | join_csv)"
      exposed+="${port} ${label} (${listeners:-unknown}); "
    fi
  done < <(admin_surface_ports)

  if [ -n "${exposed}" ]; then
    if [ "${firewall_active}" = "1" ] && [ -n "${cidrs}" ]; then
      doctor_ok "admin TCP surfaces are restricted by dune_native firewall table: ${exposed}"
    else
      doctor_warn "admin TCP surfaces have non-loopback listeners: ${exposed}"
    fi
  else
    doctor_ok "admin TCP surfaces are loopback-only or not listening"
  fi

  doctor_ok "player-facing ports to allow are $(public_surface_ports | awk -F '\t' '{print $1}' | join_csv)"
}

doctor_check_manager_service() {
  as_root test -f "${MANAGER_SERVICE_UNIT}" || return 0
  doctor_section "Manager Service"
  local port
  port="$(as_root awk -F= '/^DUNE_DASHBOARD_PORT=/{print $2; exit}' "${MANAGER_SERVICE_ENV}" 2>/dev/null || echo 29187)"
  if as_root systemctl is-active --quiet "$(basename "${MANAGER_SERVICE_UNIT}")"; then
    doctor_ok "dune-server-service is active"
  else
    doctor_fail "dune-server-service is installed but not active; run: systemctl start dune-server-service"
  fi
  if curl -sf --max-time 3 "http://localhost:${port}/api/cluster" >/dev/null 2>&1; then
    doctor_ok "dune-server-service HTTP API is reachable on port ${port}"
  else
    doctor_warn "dune-server-service HTTP API is not responding on port ${port}; service may still be starting"
  fi
}

shell_quote() {
  local quoted
  printf -v quoted '%q' "$1"
  printf '%s\n' "${quoted}"
}

external_ssh() {
  local target="$1"
  shift
  ssh -o BatchMode=yes -o ConnectTimeout="${DUNE_EXTERNAL_PROBE_TIMEOUT:-6}" "${target}" "$@"
}

external_ssh_command() {
  local target="$1"
  local command="$2"
  ssh -o BatchMode=yes -o ConnectTimeout="${DUNE_EXTERNAL_PROBE_TIMEOUT:-6}" "${target}" "${command}"
}

external_tcp_probe() {
  local target="$1"
  local host="$2"
  local port="$3"
  local timeout="${DUNE_EXTERNAL_PROBE_TIMEOUT:-6}"
  local py q_py q_host q_port q_timeout
  py='import socket,sys; s=socket.create_connection((sys.argv[1], int(sys.argv[2])), float(sys.argv[3])); s.close()'
  q_py="$(shell_quote "${py}")"
  q_host="$(shell_quote "${host}")"
  q_port="$(shell_quote "${port}")"
  q_timeout="$(shell_quote "${timeout}")"
  external_ssh_command "${target}" "python3 -c ${q_py} ${q_host} ${q_port} ${q_timeout}" >/dev/null 2>&1
}

external_udp_nmap_status() {
  local target="$1"
  local host="$2"
  local port="$3"
  local timeout="${DUNE_EXTERNAL_PROBE_TIMEOUT:-6}"
  local q_host q_port q_timeout
  q_host="$(shell_quote "${host}")"
  q_port="$(shell_quote "${port}")"
  q_timeout="$(shell_quote "${timeout}")"
  external_ssh_command "${target}" "nmap -Pn -sU -p ${q_port} --host-timeout ${q_timeout}s ${q_host}" 2>/dev/null |
    awk '/\/udp/ {print $2; exit}'
}

doctor_check_external_reachability() {
  doctor_section "External Reachability"
  local host target timeout detected_public rmq_port udp_status
  host="$(player_facing_host)"
  target="${DUNE_EXTERNAL_PROBE_SSH:-}"
  timeout="${DUNE_EXTERNAL_PROBE_TIMEOUT:-6}"
  rmq_port="$(public_surface_ports | awk -F '[/\t]' '$2 == "tcp" {print $1; exit}')"
  [ -n "${rmq_port}" ] || rmq_port=31982

  if [ -z "${host}" ]; then
    doctor_fail "could not determine player-facing public IP/DNS"
    return
  fi
  doctor_ok "player-facing public IP/DNS is ${host}"

  detected_public="$(detect_public_ip)"
  if [ -n "${detected_public}" ]; then
    if [ "${host}" = "${detected_public}" ]; then
      doctor_ok "configured public IP matches this host's detected egress IP (${detected_public})"
    else
      doctor_warn "configured public IP/DNS is ${host}, but this host's detected egress IP is ${detected_public}"
    fi
  else
    doctor_warn "could not detect this host's public egress IP"
  fi

  if [ -z "${target}" ]; then
    doctor_warn "external probe SSH target is not configured; set DUNE_EXTERNAL_PROBE_SSH=user@offhost and run: $0 doctor --external"
    doctor_warn "same-host checks cannot prove router/NAT forwarding unless your router supports hairpin NAT"
    return
  fi
  command -v ssh >/dev/null 2>&1 || { doctor_fail "ssh command is required for external probe"; return; }
  if ! external_ssh "${target}" true >/dev/null 2>&1; then
    doctor_fail "external probe SSH target is not reachable with BatchMode auth: ${target}"
    return
  fi
  doctor_ok "external probe SSH target reachable: ${target}"

  if external_tcp_probe "${target}" "${host}" "${rmq_port}"; then
    doctor_ok "external TCP probe reached RMQ game NodePort ${host}:${rmq_port}"
  else
    doctor_fail "external TCP probe could not reach RMQ game NodePort ${host}:${rmq_port}"
  fi

  if external_ssh "${target}" command -v nmap >/dev/null 2>&1; then
    udp_status="$(external_udp_nmap_status "${target}" "${host}" 7777)"
    case "${udp_status}" in
      open|open\|filtered)
        doctor_ok "external UDP probe for ${host}:7777 returned ${udp_status}; UDP is not reported closed"
        ;;
      closed)
        doctor_fail "external UDP probe for ${host}:7777 returned closed"
        ;;
      filtered)
        doctor_warn "external UDP probe for ${host}:7777 returned filtered; forwarding/firewall may still be blocking replies"
        ;;
      *)
        doctor_warn "external UDP probe for ${host}:7777 was inconclusive; UDP game protocols may not answer generic probes"
        ;;
    esac
  else
    doctor_warn "external probe host does not have nmap; skipped UDP 7777 outside-in check"
  fi
}

doctor_native() {
  DOCTOR_FAILS=0
  DOCTOR_WARNS=0
  DOCTOR_JSON_MODE=0
  DOCTOR_JSON_CHECKS=()
  DOCTOR_CURRENT_SECTION=""
  local external_check="${DUNE_DOCTOR_EXTERNAL_CHECK:-0}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --external) external_check=1; shift ;;
      --json) DOCTOR_JSON_MODE=1; shift ;;
      --help|-h)
        printf 'Usage: %s doctor [--external] [--json]\n' "$0"
        return 0
        ;;
      *) die "Unknown doctor option: $1" ;;
    esac
  done
  load_backup_env
  load_firewall_env
  [ "${DOCTOR_JSON_MODE}" = "0" ] && printf 'Dune native server doctor\n'
  doctor_check_host
  doctor_check_cluster
  doctor_check_battlegroup
  doctor_check_backup_timer
  doctor_check_firewall
  doctor_check_manager_service
  [ "${external_check}" = "1" ] && doctor_check_external_reachability
  if [ "${DOCTOR_JSON_MODE}" = "1" ]; then
    local checks_json
    if [ "${#DOCTOR_JSON_CHECKS[@]}" -gt 0 ]; then
      checks_json="$(printf '%s\n' "${DOCTOR_JSON_CHECKS[@]}" | jq -s '.')"
    else
      checks_json="[]"
    fi
    jq -n \
      --argjson fails "${DOCTOR_FAILS}" \
      --argjson warns "${DOCTOR_WARNS}" \
      --argjson checks "${checks_json}" \
      '{"summary":{"failures":$fails,"warnings":$warns},"checks":$checks}'
  else
    printf '\nSummary: %d failure(s), %d warning(s)\n' "${DOCTOR_FAILS}" "${DOCTOR_WARNS}"
  fi
  [ "${DOCTOR_FAILS}" -eq 0 ]
}

status_native() {
  as_root systemctl --no-pager status k3s || true
  if command -v k3s >/dev/null 2>&1; then
    run_kubectl get nodes -o wide || true
    run_kubectl get pods -A || true
  fi
  if [ -x "${DUNE_ROOT}/bin/battlegroup" ] || [ -x "${DOWNLOAD_PATH}/scripts/battlegroup.sh" ]; then
    run_battlegroup status || true
  fi
}

parse_setup_args() {
  ASSUME_YES=0
  INSTALL_DEPS=1
  GRANT_SUDOERS=1
  FORCE_EXISTING_K3S=0
  SETUP_PUBLIC_IP=""
  SETUP_INTERNAL_IP=""
  SETUP_INTERFACE=""
  SETUP_WORLD_NAME="${DUNE_WORLD_NAME:-}"
  SETUP_WORLD_REGION="${DUNE_WORLD_REGION:-}"
  SETUP_SELF_HOSTED_TOKEN="${DUNE_SELF_HOSTED_TOKEN:-}"
  SETUP_SELF_HOSTED_TOKEN_FILE="${DUNE_SELF_HOSTED_TOKEN_FILE:-}"
  SETUP_PGHERO_PORT="${DUNE_PGHERO_PORT:-}"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --public-ip) SETUP_PUBLIC_IP="${2:-}"; shift 2 ;;
      --internal-ip) SETUP_INTERNAL_IP="${2:-}"; shift 2 ;;
      --interface) SETUP_INTERFACE="${2:-}"; shift 2 ;;
      --world-name) SETUP_WORLD_NAME="${2:-}"; shift 2 ;;
      --world-region) SETUP_WORLD_REGION="${2:-}"; shift 2 ;;
      --self-hosted-token) SETUP_SELF_HOSTED_TOKEN="${2:-}"; shift 2 ;;
      --self-hosted-token-file) SETUP_SELF_HOSTED_TOKEN_FILE="${2:-}"; shift 2 ;;
      --pghero-port) SETUP_PGHERO_PORT="${2:-}"; shift 2 ;;
      --force-existing-k3s) FORCE_EXISTING_K3S=1; shift ;;
      --no-install-deps) INSTALL_DEPS=0; shift ;;
      --no-sudoers) GRANT_SUDOERS=0; shift ;;
      --yes|-y) ASSUME_YES=1; shift ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown setup option: $1" ;;
    esac
  done
  if [ -z "${SETUP_SELF_HOSTED_TOKEN}" ] && [ -n "${SETUP_SELF_HOSTED_TOKEN_FILE}" ]; then
    SETUP_SELF_HOSTED_TOKEN="$(read_self_hosted_token "${SETUP_SELF_HOSTED_TOKEN_FILE}")"
  fi
}

parse_world_args() {
  SETUP_WORLD_NAME="${DUNE_WORLD_NAME:-}"
  SETUP_WORLD_REGION="${DUNE_WORLD_REGION:-}"
  SETUP_SELF_HOSTED_TOKEN="${DUNE_SELF_HOSTED_TOKEN:-}"
  SETUP_SELF_HOSTED_TOKEN_FILE="${DUNE_SELF_HOSTED_TOKEN_FILE:-}"
  SETUP_PGHERO_PORT="${DUNE_PGHERO_PORT:-}"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --world-name) SETUP_WORLD_NAME="${2:-}"; shift 2 ;;
      --world-region) SETUP_WORLD_REGION="${2:-}"; shift 2 ;;
      --self-hosted-token) SETUP_SELF_HOSTED_TOKEN="${2:-}"; shift 2 ;;
      --self-hosted-token-file) SETUP_SELF_HOSTED_TOKEN_FILE="${2:-}"; shift 2 ;;
      --pghero-port) SETUP_PGHERO_PORT="${2:-}"; shift 2 ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown create-world option: $1" ;;
    esac
  done
  if [ -z "${SETUP_SELF_HOSTED_TOKEN}" ] && [ -n "${SETUP_SELF_HOSTED_TOKEN_FILE}" ]; then
    SETUP_SELF_HOSTED_TOKEN="$(read_self_hosted_token "${SETUP_SELF_HOSTED_TOKEN_FILE}")"
  fi
}

main() {
  local command="${1:-}"
  shift || true

  case "${command}" in
    setup)
      local setup_args=("$@")
      parse_setup_args "$@"
      if ! is_root; then
        exec sudo -E bash "$0" setup "${setup_args[@]}"
      fi
      setup_native "$@"
      ;;
    create-world)
      local world_args=("$@")
      parse_world_args "$@"
      if ! is_root; then
        exec sudo -E bash "$0" create-world "${world_args[@]}"
      fi
      as_root systemctl start k3s
      wait_for_k3s
      run_vendor_world_setup
      secure_local_world_specs
      configure_pghero_after_world
      cleanup_stale_database_util_pods
      ok "World creation complete"
      print_port_forwarding_requirements "$(settings_line 4)"
      ;;
    start|stop|restart|update|edit|edit-advanced|backup|import|enable-experimental-swap)
      run_battlegroup "${command}" "$@"
      ;;
    battlegroup)
      [ "$#" -gt 0 ] || die "Usage: $0 battlegroup ARGS..."
      run_battlegroup "$@"
      ;;
    logs-export|operator-logs-export)
      export_logs "${command}"
      ;;
    status)
      status_native
      ;;
    doctor)
      doctor_native "$@"
      ;;
    shell)
      as_root sudo -u "${DUNE_USER}" -H bash
      ;;
    shell-pod)
      shell_pod
      ;;
    director-url)
      director_url
      ;;
    open-director)
      open_url "$(director_url)"
      ;;
    file-browser-url)
      file_browser_url
      ;;
    open-file-browser)
      open_url "$(file_browser_url)"
      ;;
    set-public-ip)
      set_public_ip "${1:-}"
      ;;
    set-interface)
      set_interface "${1:-}"
      ;;
    set-pghero-port)
      set_pghero_port "${1:-}"
      ;;
    set-backup-copy-target)
      if ! is_root; then
        exec sudo -E bash "$0" set-backup-copy-target "$@"
      fi
      set_backup_copy_target "${1:-}"
      ;;
    set-admin-allowed-cidrs)
      if ! is_root; then
        exec sudo -E bash "$0" set-admin-allowed-cidrs "$@"
      fi
      set_admin_allowed_cidrs "${1:-}"
      ;;
    exposure-report)
      exposure_report
      ;;
    firewall-plan)
      firewall_plan
      ;;
    install-firewall)
      if ! is_root; then
        exec sudo -E bash "$0" install-firewall "$@"
      fi
      install_firewall "$@"
      ;;
    uninstall-firewall)
      if ! is_root; then
        exec sudo -E bash "$0" uninstall-firewall "$@"
      fi
      uninstall_firewall
      ;;
    teardown)
      if ! is_root; then
        exec sudo -E bash "$0" teardown "$@"
      fi
      teardown_native "$@"
      ;;
    set-self-hosted-token)
      set_self_hosted_token "$@"
      ;;
    scheduled-backup)
      scheduled_backup
      ;;
    install-backup-timer)
      if ! is_root; then
        exec sudo -E bash "$0" install-backup-timer "$@"
      fi
      install_backup_timer "$@"
      ;;
    uninstall-backup-timer)
      if ! is_root; then
        exec sudo -E bash "$0" uninstall-backup-timer "$@"
      fi
      uninstall_backup_timer
      ;;
    backup-prune)
      backup_prune "$@"
      ;;
    restore-check)
      restore_check "${1:-}"
      ;;
    restore-latest)
      restore_latest
      ;;
    apply-canonical)
      if ! is_root; then exec sudo -E bash "$0" apply-canonical "$@"; fi
      apply_canonical "$@"
      ;;
    install-manager-service)
      if ! is_root; then exec sudo -E bash "$0" install-manager-service "$@"; fi
      install_manager_service "$@"
      ;;
    update-manager-service)
      if ! is_root; then exec sudo -E bash "$0" update-manager-service "$@"; fi
      update_manager_service
      ;;
    uninstall-manager-service)
      if ! is_root; then exec sudo -E bash "$0" uninstall-manager-service "$@"; fi
      uninstall_manager_service
      ;;
    k3s-start)
      as_root systemctl start k3s
      ;;
    k3s-stop)
      as_root systemctl stop k3s
      ;;
    k3s-status)
      as_root systemctl --no-pager status k3s
      ;;
    ""|--help|-h|help)
      usage
      ;;
    *)
      die "Unknown command: ${command}"
      ;;
  esac
}

if [ "${DUNE_NATIVE_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
