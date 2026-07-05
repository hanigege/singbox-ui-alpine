#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SING_BOX_BUNDLED_VERSION="${SING_BOX_BUNDLED_VERSION:-1.13.13}"
SING_BOX_ARCH="${SING_BOX_ARCH:-auto}"
INSTALL_DIR="/opt/singbox-rule-ui"
CONFIG_DIR="/etc/sing-box"
MANAGER_DIR="$CONFIG_DIR/manager"
RULE_DIR="$CONFIG_DIR/custom-rules"
INSTALL_STATE_FILE="$MANAGER_DIR/install-state"
RADVD_STATE_FILE="$MANAGER_DIR/radvd-state.before-sing-box"
LOG_DIR="/var/log/sing-box-gateway"
LOGROTATE_CONFIG="/etc/logrotate.d/sing-box-gateway"
ROOT_CRONTAB="/etc/crontabs/root"
RULE_UPDATE_CRON_MARKER_BEGIN="# BEGIN sing-box-gateway-ui rule update"
RULE_UPDATE_CRON_MARKER_END="# END sing-box-gateway-ui rule update"
MONITOR_CRON_MARKER_BEGIN="# BEGIN sing-box-gateway-ui runtime monitor"
MONITOR_CRON_MARKER_END="# END sing-box-gateway-ui runtime monitor"
APK_PACKAGES=(bash curl ca-certificates tar gzip python3 nftables iproute2 rsync util-linux coreutils openrc logrotate)

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

require_alpine() {
  if [ ! -r /etc/alpine-release ] || ! command -v apk >/dev/null 2>&1; then
    echo "This repository is the Alpine/OpenRC build. Please run it on Alpine Linux." >&2
    exit 1
  fi
  if ! command -v rc-service >/dev/null 2>&1 || ! command -v rc-update >/dev/null 2>&1; then
    echo "OpenRC is required on Alpine. Install openrc first." >&2
    exit 1
  fi
}

state_get() {
  local key="$1"
  [ -r "$INSTALL_STATE_FILE" ] || return 0
  awk -F= -v key="$key" '$1 == key { value = substr($0, length(key) + 2) } END { print value }' "$INSTALL_STATE_FILE"
}

state_set() {
  local key="$1" value="$2" tmp
  mkdir -p "$MANAGER_DIR"
  tmp="$(mktemp)"
  if [ -r "$INSTALL_STATE_FILE" ]; then
    awk -F= -v key="$key" '$1 != key { print }' "$INSTALL_STATE_FILE" > "$tmp"
  fi
  printf "%s=%s\n" "$key" "$value" >> "$tmp"
  install -m 0600 "$tmp" "$INSTALL_STATE_FILE"
  rm -f "$tmp"
}

record_preinstall_state() {
  mkdir -p "$MANAGER_DIR"
  if [ "$(state_get state_version)" != "2" ]; then
    : > "$INSTALL_STATE_FILE"
    chmod 0600 "$INSTALL_STATE_FILE"
    state_set state_version 2
    state_set init_system openrc
    if [ -e /usr/local/bin/sing-box ]; then
      state_set sing_box_binary preexisting
    else
      state_set sing_box_binary absent
    fi
    for package in "${APK_PACKAGES[@]}"; do
      if apk info -e "$package" >/dev/null 2>&1; then
        state_set "apk_${package}" preexisting
      else
        state_set "apk_${package}" absent
      fi
    done
    # Alpine 默认没有 systemd-resolved stub；这里仅记录 53 端口现场，卸载不擅自改 DNS。
    state_set port53_owners "$(port53_owners 2>/dev/null || true)"
  fi
}

install_packages() {
  local missing=() package
  for package in "${APK_PACKAGES[@]}"; do
    if ! apk info -e "$package" >/dev/null 2>&1; then
      missing+=("$package")
    fi
  done
  if [ "${#missing[@]}" -eq 0 ]; then
    echo "Alpine dependencies already installed."
    return
  fi
  # 覆盖安装不能因为外部 APK 索引临时 TLS/网络失败而中断；只在确有缺失依赖时联网安装。
  apk add --no-cache "${missing[@]}"
}

enable_radvd_requested() {
  case "${SING_BOX_GATEWAY_ENABLE_RADVD:-${RULE_UI_ENABLE_RADVD:-0}}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

service_exists() {
  [ -x "/etc/init.d/$1" ]
}

service_enabled() {
  local service="$1"
  rc-update show default 2>/dev/null | awk '{ print $1 }' | grep -qx "$service"
}

disable_unrequested_radvd() {
  if enable_radvd_requested; then
    return
  fi
  if service_exists radvd; then
    if [ ! -e "$RADVD_STATE_FILE" ]; then
      {
        if service_enabled radvd; then
          printf "enabled=enabled\n"
        else
          printf "enabled=disabled\n"
        fi
        printf "active=%s\n" "$(rc-service radvd status >/dev/null 2>&1 && echo active || echo inactive)"
      } > "$RADVD_STATE_FILE"
    fi
    # 旁路网关默认不广播 IPv6 RA，避免 Alpine 机器抢走上游路由器的默认网关角色。
    rc-service radvd stop >/dev/null 2>&1 || true
    rc-update del radvd default >/dev/null 2>&1 || true
    echo "IPv6 router advertisement is disabled by default; radvd was stopped and removed from default runlevel."
  fi
}

detect_arch() {
  local arch="${1:-${SING_BOX_ARCH}}"
  if [ "$arch" = "auto" ] || [ -z "$arch" ]; then
    arch="$(uname -m)"
  fi
  case "$arch" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
  esac
}

choose_sing_box_runtime() {
  # 安装阶段不读取终端输入；架构保持 auto，由 uname -m 自动选择仓库内固定版本包。
  SING_BOX_ARCH="${SING_BOX_ARCH:-auto}"
  echo "sing-box binary: bundled ${SING_BOX_BUNDLED_VERSION} (repository-tested, arch: $(detect_arch))"
}

install_sing_box() {
  local arch archive sums archive_name expected actual tmp current_version backup
  arch="$(detect_arch)"
  archive="$PROJECT_DIR/third_party/sing-box/v${SING_BOX_BUNDLED_VERSION}/sing-box-${SING_BOX_BUNDLED_VERSION}-linux-${arch}.tar.gz"
  sums="$PROJECT_DIR/third_party/sing-box/v${SING_BOX_BUNDLED_VERSION}/SHA256SUMS"
  if [ ! -r "$archive" ]; then
    echo "Bundled sing-box archive not found: $archive" >&2
    exit 1
  fi
  if [ -r "$sums" ]; then
    archive_name="$(basename "$archive")"
    expected="$(awk -v name="$archive_name" '$2 == name { print $1 }' "$sums")"
    if [ -z "$expected" ]; then
      echo "No checksum entry for bundled archive: $archive_name" >&2
      exit 1
    fi
    actual="$(sha256sum "$archive" | awk '{ print $1 }')"
    if [ "$actual" != "$expected" ]; then
      echo "Checksum mismatch for bundled archive: $archive_name" >&2
      exit 1
    fi
  fi
  tmp="$(mktemp -d)"
  trap "rm -rf '$tmp'" EXIT
  if command -v /usr/local/bin/sing-box >/dev/null 2>&1; then
    current_version="$(/usr/local/bin/sing-box version 2>/dev/null | head -n 1 || true)"
    if [ -n "$current_version" ] && printf "%s" "$current_version" | grep -q "$SING_BOX_BUNDLED_VERSION"; then
      echo "sing-box already installed: $current_version"
      state_set sing_box_binary installed
      state_set sing_box_bundled_version "$SING_BOX_BUNDLED_VERSION"
      return
    fi
    backup="/usr/local/bin/sing-box.bak-gateway-$(date +%Y%m%d-%H%M%S)"
    # 固定验证 1.13.13；已有其它版本先备份再替换，避免配置语法和二进制版本错配。
    cp -a /usr/local/bin/sing-box "$backup"
    echo "Backed up existing sing-box to $backup"
    state_set sing_box_binary replaced
    state_set sing_box_binary_backup "$backup"
  else
    state_set sing_box_binary installed
  fi
  echo "Installing bundled sing-box ${SING_BOX_BUNDLED_VERSION} (${arch})"
  tar -xzf "$archive" -C "$tmp"
  install -m 0755 "$tmp"/sing-box-*/sing-box /usr/local/bin/sing-box
  state_set sing_box_bundled_version "$SING_BOX_BUNDLED_VERSION"
}

install_files() {
  mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$MANAGER_DIR" "$RULE_DIR" "$LOG_DIR" /etc/init.d /usr/local/bin /usr/local/sbin
  rsync -a --delete "$PROJECT_DIR/singbox-rule-ui/" "$INSTALL_DIR/"
  install -m 0755 "$PROJECT_DIR/scripts/sing-box-gateway-info" /usr/local/bin/sing-box-gateway-info
  install -m 0755 "$PROJECT_DIR/scripts/uninstall.sh" /usr/local/bin/sing-box-gateway-uninstall
  install -m 0755 "$PROJECT_DIR/scripts/refresh_runtime_config.py" /usr/local/sbin/refresh-sing-box-runtime-config
  install -m 0755 "$PROJECT_DIR/scripts/monitor_runtime.py" /usr/local/sbin/monitor-sing-box-runtime
  install -m 0755 "$PROJECT_DIR/scripts/update-sing-box-rules-jsdelivr" /usr/local/sbin/update-sing-box-rules-jsdelivr
  install -m 0755 "$PROJECT_DIR/scripts/sync_tproxy_setup.py" /usr/local/sbin/refresh-sing-box-tproxy-setup
  install -m 0755 "$PROJECT_DIR/openrc/sing-box" /etc/init.d/sing-box
  install -m 0755 "$PROJECT_DIR/openrc/sing-box-tproxy" /etc/init.d/sing-box-tproxy
  install -m 0755 "$PROJECT_DIR/openrc/singbox-rule-ui" /etc/init.d/singbox-rule-ui
}

install_logrotate_config() {
  mkdir -p "$(dirname "$LOGROTATE_CONFIG")"
  # OpenRC 的 output_log/error_log 和 crontab 都会长期追加写入；用 copytruncate 避免重启服务也能收敛日志大小。
  cat > "$LOGROTATE_CONFIG" <<'EOF'
/var/log/sing-box-gateway/*.log {
    size 5M
    rotate 6
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 root root
}
EOF
  chmod 0644 "$LOGROTATE_CONFIG"
}

bootstrap_config() {
  python3 "$PROJECT_DIR/scripts/bootstrap_config.py"
}

install_initial_rules() {
  RULE_UPDATE_RESTART=0 RULE_UPDATE_LOCK_WAIT="${RULE_UPDATE_LOCK_WAIT:-300}" /usr/local/sbin/update-sing-box-rules-jsdelivr
  verify_required_rules
}

verify_required_rules() {
  local missing=0 path
  for path in \
    /etc/sing-box/rules/geosite/speedtest.srs \
    /etc/sing-box/rules/geosite/telegram.srs \
    /etc/sing-box/rules/geosite/geolocation-!cn.srs \
    /etc/sing-box/rules/geosite/cn.srs \
    /etc/sing-box/rules/geosite/icloud@cn.srs \
    /etc/sing-box/rules/geosite/apple@cn.srs \
    /etc/sing-box/rules/geosite/geolocation-cn.srs \
    /etc/sing-box/rules/geoip/cn.srs \
    /etc/sing-box/rules/geoip/telegram.srs; do
    if [ ! -s "$path" ]; then
      echo "Missing required rule file: $path" >&2
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    echo "Required sing-box rule files are missing; installation stopped before enabling services." >&2
    exit 1
  fi
}

port53_conflicts() {
  python3 - <<'PY'
import ipaddress
import json
import re
import subprocess
from pathlib import Path

config = json.loads(Path("/etc/sing-box/config.json").read_text(encoding="utf-8"))
targets = set()
for inbound in config.get("inbounds", []) or []:
    if isinstance(inbound, dict) and inbound.get("listen_port") == 53:
        listen = str(inbound.get("listen") or "").strip()
        if listen:
            targets.add(listen)

if not targets:
    raise SystemExit(0)

def normalize(address):
    address = address.strip("[]")
    if "%" in address:
        address = address.split("%", 1)[0]
    try:
        return str(ipaddress.ip_address(address))
    except ValueError:
        return address

targets = {normalize(item) for item in targets}
wildcards = {"0.0.0.0", "::", "*"}
conflicts = set()
for command in (["ss", "-H", "-lunp", "sport = :53"], ["ss", "-H", "-ltnp", "sport = :53"]):
    result = subprocess.run(command, text=True, capture_output=True)
    for line in result.stdout.splitlines():
        owner_match = re.search(r'users:\(\("([^"]+)"', line)
        owner = owner_match.group(1) if owner_match else "unknown"
        pid_match = re.search(r"pid=(\d+)", line)
        pid = pid_match.group(1) if pid_match else ""
        cmdline = ""
        if pid:
            try:
                cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
            except OSError:
                cmdline = ""
        if owner == "sing-box" or "/usr/local/bin/sing-box" in cmdline or " sing-box run " in cmdline:
            continue
        parts = line.split()
        if len(parts) < 5:
            continue
        local = parts[4]
        if local.startswith("["):
            address = local.rsplit("]:", 1)[0].lstrip("[")
        else:
            address = local.rsplit(":", 1)[0]
        address = normalize(address)
        if address in wildcards or address in targets:
            conflicts.add(owner)

if conflicts:
    print(",".join(sorted(conflicts)))
PY
}

port53_owners() {
  python3 - <<'PY'
import re
import subprocess
from pathlib import Path

owners = set()
result = subprocess.run(["ss", "-H", "-ltnup", "sport = :53"], text=True, capture_output=True)
for line in result.stdout.splitlines():
    owner_match = re.search(r'users:\(\("([^"]+)"', line)
    owner = owner_match.group(1) if owner_match else "unknown"
    pid_match = re.search(r"pid=(\d+)", line)
    pid = pid_match.group(1) if pid_match else ""
    if pid:
        try:
            cmdline = Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode("utf-8", "replace")
            if "/usr/local/bin/sing-box" in cmdline or " sing-box run " in cmdline:
                owner = "sing-box"
        except OSError:
            pass
    owners.add(owner)
print(",".join(sorted(owners)))
PY
}

ensure_dns_port_available() {
  echo "正在检查 53 端口，确保 sing-box DNS 可以启动..."
  all_owners="$(port53_owners)"
  if [ -z "$all_owners" ]; then
    echo "53 端口当前未被占用。"
  else
    echo "53 端口当前占用进程: $all_owners"
  fi
  owner="$(port53_conflicts)"
  if [ -z "$owner" ]; then
    echo "53 端口检查通过。"
    return
  fi
  if printf "%s" "$owner" | grep -q "sing-box"; then
    echo "53 端口已由 sing-box 使用，继续安装。"
    return
  fi
  echo "53 端口仍被占用: $owner" >&2
  echo "Alpine 迁移版不会改写 /etc/resolv.conf，也不会自动停止第三方 DNS 服务。" >&2
  echo "请先用 rc-service/rc-update 禁用占用 53 的服务，或调整它的监听端口；否则重启后仍会再次抢占 53。" >&2
  exit 1
}

install_tproxy_setup() {
  python3 "$PROJECT_DIR/scripts/sync_tproxy_setup.py"
}

update_crontab_block() {
  local begin="$1" end="$2" body="$3" tmp
  tmp="$(mktemp)"
  if [ -r "$ROOT_CRONTAB" ]; then
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip = 1; next }
      $0 == end { skip = 0; next }
      skip != 1 { print }
    ' "$ROOT_CRONTAB" > "$tmp"
  fi
  {
    printf "%s\n" "$begin"
    printf "%s\n" "$body"
    printf "%s\n" "$end"
  } >> "$tmp"
  install -m 0600 "$tmp" "$ROOT_CRONTAB"
  rm -f "$tmp"
}

install_cron_jobs() {
  mkdir -p "$(dirname "$ROOT_CRONTAB")"
  update_crontab_block "$RULE_UPDATE_CRON_MARKER_BEGIN" "$RULE_UPDATE_CRON_MARKER_END" \
    "20 4 * * 0 /usr/local/sbin/update-sing-box-rules-jsdelivr >> /var/log/sing-box-gateway/rule-update.log 2>&1"
  update_crontab_block "$MONITOR_CRON_MARKER_BEGIN" "$MONITOR_CRON_MARKER_END" \
    "*/2 * * * * /usr/local/sbin/monitor-sing-box-runtime >> /var/log/sing-box-gateway/runtime-monitor.log 2>&1"
  # Alpine 用 crond 代替 systemd timer；UI 修改计划时会重写同一个 root crontab 块。
  rc-update add crond default >/dev/null 2>&1 || true
  rc-service crond restart >/dev/null 2>&1 || rc-service crond start >/dev/null 2>&1 || true
}

enable_services() {
  rc-update add sing-box-tproxy default >/dev/null 2>&1 || true
  rc-update add sing-box default >/dev/null 2>&1 || true
  rc-update add singbox-rule-ui default >/dev/null 2>&1 || true
  # OpenRC 没有 daemon-reload；覆盖安装后显式重启，确保新脚本和新二进制立即生效。
  restart_openrc_service sing-box-tproxy
  restart_openrc_service sing-box
  restart_openrc_service singbox-rule-ui
}

refresh_tproxy_after_start() {
  # 安装阶段已经生成过 TProxy 脚本和 sysctl；这里仅重启确认服务状态，避免新机空刷新留下 .bak 垃圾。
  restart_openrc_service sing-box-tproxy
}

restart_openrc_service() {
  local service="$1"
  if rc-service "$service" restart; then
    return 0
  fi
  # 覆盖安装时旧进程可能刚退出，OpenRC pidfile/flock 会短暂返回失败；用 stop/start 收敛到最终状态。
  rc-service "$service" stop >/dev/null 2>&1 || true
  sleep 1
  rc-service "$service" start || true
  if rc-service "$service" status >/dev/null 2>&1; then
    return 0
  fi
  echo "Failed to start OpenRC service: $service" >&2
  return 1
}

main() {
  case "${1:-install}" in
    install|"") ;;
    uninstall|remove)
      exec bash "$PROJECT_DIR/scripts/uninstall.sh" "${@:2}"
      ;;
    purge)
      exec bash "$PROJECT_DIR/scripts/uninstall.sh" --purge "${@:2}"
      ;;
    *)
      echo "Unknown action: $1" >&2
      echo "Usage: sudo bash scripts/install.sh [install|uninstall|purge]" >&2
      exit 1
      ;;
  esac
  need_root
  require_alpine
  record_preinstall_state
  choose_sing_box_runtime
  install_packages
  install_files
  install_logrotate_config
  bootstrap_config
  install_sing_box
  install_initial_rules
  disable_unrequested_radvd
  install_tproxy_setup
  ensure_dns_port_available
  /usr/local/bin/sing-box check -c /etc/sing-box/config.json
  install_cron_jobs
  enable_services
  refresh_tproxy_after_start
  echo
  echo "Installed on Alpine/OpenRC."
  echo "Host resolver was left unchanged. Configure client/router resolver manually if needed."
  echo "IPv6 PPPoE note: set the upstream router LAN RA MTU to the PPPoE actual MTU, usually 1492."
  echo "If this Alpine host still shows MTU 1500, verify with: ip link set dev eth0 mtu 1492"
  echo "RouterOS example: /ipv6/nd/set [find interface=bridge1] mtu=1492"
  sing-box-gateway-info
}

main "$@"
