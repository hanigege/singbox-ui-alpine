#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SING_BOX_BUNDLED_VERSION="${SING_BOX_BUNDLED_VERSION:-1.13.18}"
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
APK_PACKAGES=(bash curl ca-certificates tar gzip python3 nftables iproute2 rsync util-linux coreutils openrc logrotate gcompat iputils busybox-openrc)

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

# 检测「内核已升级但未重启」：apk 升级 linux-virt/linux-lts 后旧内核的
# /lib/modules/<旧版本> 目录会被清理，运行中的旧内核没有 nf_tables 模块，
# nft 会报 src/mnl.c: Unable to initialize Netlink socket: Protocol not supported，
# TProxy 必然起不来。预检只提示不阻断（覆盖安装/已有规则场景仍可继续），
# 但新装用户会看到明确中文指引先 reboot 再跑。
check_kernel_reboot_needed() {
  # LXC 容器与宿主机共享内核，/lib/modules 在容器内通常为空，跳过。
  # environ 是 NUL 分隔的二进制文件，用 grep -a 按文本匹配子串即可。
  if [ -e /proc/1/environ ] && grep -aq 'container=lxc' /proc/1/environ 2>/dev/null; then
    return 0
  fi
  local running_kernel installed_kernels
  running_kernel="$(uname -r)"
  if [ -d "/lib/modules/$running_kernel" ]; then
    return 0
  fi
  # busybox find 不支持 -printf；用 sed 取目录名，兼容 Alpine 默认工具集。
  # || true 必带：/lib/modules 不存在或为空时（容器/最小化安装），
  # grep -v '^$' 空输入返回 1，pipefail+set -e 会把整个安装器静默杀死
  # （2026-08-30 Docker 容器一键安装实测：零输出 exit 1）。
  installed_kernels="$(find /lib/modules -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sed 's#.*/##' | grep -v '^$' | tr '\n' ' ' || true)"
  if [ -z "$installed_kernels" ]; then
    return 0
  fi
  echo
  echo "⚠️  检测到系统内核已升级，但尚未重启！" >&2
  echo "    当前运行内核: $running_kernel" >&2
  echo "    已安装内核:   $installed_kernels" >&2
  echo "    apk 升级内核后，旧内核的模块目录已被清理。现在运行的旧内核没有" >&2
  echo "    nf_tables 等模块，sing-box-tproxy 将无法启动（nft 报" >&2
  echo "    \"Protocol not supported\"）。" >&2
  echo "    请先执行 reboot 重启加载新内核，然后再重新运行本安装脚本。" >&2
  echo
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
  local arch singbox_dir binary tmp current_version backup sums
  arch="$(detect_arch)"
  singbox_dir="$PROJECT_DIR/third_party/sing-box/v${SING_BOX_BUNDLED_VERSION}"
  binary="$singbox_dir/sing-box-official-linux-${arch}"
  if [ ! -r "$binary" ]; then
    echo "Bundled sing-box binary not found: $binary" >&2
    exit 1
  fi
  # 完整性校验：quick-install 通过第三方 gh 镜像下载 tar.gz，二进制可能被
  # 截断或篡改。仓库内随附 SHA256SUMS，不匹配就拒装(宁可装不上也不装坏的)。
  sums="$singbox_dir/SHA256SUMS"
  if [ -r "$sums" ]; then
    if ! (cd "$singbox_dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1); then
      echo "ERROR: bundled sing-box binary failed sha256 verification (corrupted download or tampered mirror)." >&2
      echo "       Re-run the installer, or try a different proxy: quick-install-proxy.sh" >&2
      exit 1
    fi
    echo "sing-box binary sha256 verified."
  else
    echo "WARN: $sums missing; skipping binary integrity verification." >&2
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
    cp -a /usr/local/bin/sing-box "$backup"
    echo "Backed up existing sing-box to $backup"
    state_set sing_box_binary replaced
    state_set sing_box_binary_backup "$backup"
  else
    state_set sing_box_binary installed
  fi
  echo "Installing bundled sing-box ${SING_BOX_BUNDLED_VERSION} (${arch})"
  install -m 0755 "$binary" /usr/local/bin/sing-box
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
  # 网关并发连接数直接吃 fd，OpenRC 默认 soft nofile=4095 偏低（高并发 + mux 时会被顶满，
  # 表现为 accept 失败、tproxy 假死）。写进 /etc/conf.d（OpenRC 会 source）而不是改
  # init.d 脚本，重装/升级时可覆盖，用户自定义过 rc_ulimit 则不动。
  if ! grep -qs '^rc_ulimit=' /etc/conf.d/sing-box 2>/dev/null; then
    cat > /etc/conf.d/sing-box <<'RC_ULIMIT_CONF'
# sing-box 是全屋内网网关，并发连接数直接吃 fd；Alpine/OpenRC 默认 soft nofile=4095。
rc_ulimit="-n 65535"
RC_ULIMIT_CONF
  fi
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
  # logrotate 默认只由 /etc/periodic/daily 触发（一天一次），日志突发时单个文件能在
  # 24 小时内涨到任意大小。挂进 hourly（crond 已有 `0 * * * * run-parts /etc/periodic/hourly`），
  # 最坏增量从 24 小时缩到 1 小时；size 条件保证空跑无副作用。
  if [ -d /etc/periodic/hourly ]; then
    ln -sf /etc/periodic/daily/logrotate /etc/periodic/hourly/logrotate
  fi
}

bootstrap_config() {
  python3 "$PROJECT_DIR/scripts/bootstrap_config.py"
}

install_initial_rules() {
  RULE_UPDATE_RESTART=0 RULE_UPDATE_LOCK_WAIT="${RULE_UPDATE_LOCK_WAIT:-300}" /usr/local/sbin/update-sing-box-rules-jsdelivr || true
  verify_required_rules || true
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
      echo "WARN: missing rule file: $path — will retry via cron" >&2
      missing=1
    fi
  done
  if [ "$missing" -ne 0 ]; then
    echo "WARN: some rule files are missing; cron will retry the update. Services are still being enabled." >&2
  fi
  return 0
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

setup_timezone_cn() {
  # 时区固定为北京时间(Asia/Shanghai)：网关面向国内用户，日志时间戳与
  # 用户本地时间一致才便于排障；tzdata 缺失时不阻断安装，仅告警。
  # 这只改时区显示，不碰 NTP 源与 ntpd 服务。
  if [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    echo "Asia/Shanghai" > /etc/timezone
  else
    apk add --no-cache tzdata >/dev/null 2>&1 || true
    if [ -f /usr/share/zoneinfo/Asia/Shanghai ]; then
      ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
      echo "Asia/Shanghai" > /etc/timezone
    else
      echo "WARN: tzdata 不可用，时区保持系统默认" >&2
    fi
  fi
}

# ⚠️ 安装器刻意完全不介入 NTP（2026-08-13 决策，原实现已整体撤除）
#
# 曾经写过「写 /etc/conf.d/ntpd 换国内源 + rc-update add ntpd」的逻辑，全部撤掉：
#  1. NTP 是系统时间子系统，不属于本网关的职责范围。改用户的 ntpd 配置、
#     替他决定开机自启，会与用户自己的 chrony/openntpd 选择打架。
#  2. 同样的逻辑在 UD 仓要适配 timesyncd/chrony × 各发行版 conf 布局，
#     维护面持续膨胀且每个新版本都可能再变（Ubuntu 26.04 已改成 ucf 生成）。
#  3. 收益（国内源快一点）远小于误改用户系统配置的风险。
# 时钟准确性对 Shadowsocks AEAD-2022 是硬依赖（两端差 >30 秒直接拒连，表现为
# 节点「能连但 0 B/s」），但这属于运行环境前提，改由 Rule UI 在节点表单处提示
# 用户自行保证，安装器不代劳。

enable_services() {
  # 时区固定北京时间，便于日志排障。
  # ⚠️ 注意这里刻意不动 ntpd 与 NTP 上游源（理由见上方大段注释）：
  # Shadowsocks AEAD-2022 要求两端时钟差 <30 秒，属运行环境前提，
  # 由 Rule UI 节点表单提示用户自行保证，安装器不介入系统时间子系统。
  setup_timezone_cn
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

detect_optimal_mtu() {
  local gw="$1"
  # Probe path MTU to gateway with DF bit (requires iputils ping)
  # ICMP payload = MTU - 28 (20B IP + 8B ICMP)
  for mtu in 1500 1492 1464 1440 1400; do
    if ping -c 1 -M do -s "$((mtu - 28))" -W 2 "$gw" >/dev/null 2>&1; then
      echo "$mtu"
      return 0
    fi
  done
  # 探测全部失败(网关不回 ICMP / 防火墙拦截)时返回空串——
  # 调用方必须把"探测失败"和"探测出 1500"区分开，绝不能拿 1500 当兜底值
  # 去覆盖用户可能有意配置的 jumbo/overlay MTU。
  echo ""
}

ensure_mtu_standard() {
  local iface current detected gw mtu_script
  # 逃生门：与 sysctl 一致，用户可显式禁止安装器碰 MTU。
  case "${SING_BOX_SKIP_MTU:-0}" in
    1|true|TRUE|yes|YES|on|ON)
      echo "MTU adjustment skipped by SING_BOX_SKIP_MTU."
      return 0
      ;;
  esac
  iface="$(ip -4 route show default 2>/dev/null | awk '/default/ { print $5; exit }')"
  [ -z "$iface" ] && { echo "No default route — skip MTU adjustment."; return 0; }
  current="$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo "1500")"
  gw="$(ip -4 route show default 2>/dev/null | awk '/default/ { print $3; exit }')"

  # 用户可通过环境变量 SING_BOX_MTU 强制指定
  if [ -n "${SING_BOX_MTU:-}" ]; then
    detected="$SING_BOX_MTU"
    echo "Using SING_BOX_MTU=$detected (from environment)."
  elif [ "$current" -gt 1500 ]; then
    # MTU > 1500 可能是管理员有意配置的 jumbo frame / overlay 网络。
    # 探测确认路径连 1500 都过不了才收紧；探测失败(空串)时保持现状不动手——
    # 改错 MTU 会断网，这里必须保守。
    echo "Detected $iface MTU=$current (>1500) — validating path MTU before any change..."
    if [ -n "$gw" ] && command -v ping >/dev/null && ping -c 1 -M do -s 1472 -W 2 "$gw" >/dev/null 2>&1; then
      echo "  Path MTU >= 1500 validated; keeping administrator-configured MTU $current."
      return 0
    fi
    detected="$(detect_optimal_mtu "$gw")"
    if [ -z "$detected" ]; then
      echo "  WARN: path MTU probe failed (gateway may block ICMP); keeping MTU $current unchanged." >&2
      echo "  If you know the correct value, set SING_BOX_MTU=<value> and re-run." >&2
      return 0
    fi
  elif command -v ping >/dev/null && [ -n "$gw" ] && ping -c 1 -M do -s 1472 -W 2 "$gw" >/dev/null 2>&1; then
    # 快速检测：1500 能直达网关 → 保持当前 MTU
    echo "$iface MTU $current — path MTU 1500 validated, no change needed."
    return 0
  else
    # 1500 不通 → 路径上有小 MTU 链路（如 PPPoE），自动探测最佳值
    echo "$iface MTU $current — probing path MTU (likely PPPoE)..."
    detected="$(detect_optimal_mtu "$gw")"
    if [ -z "$detected" ]; then
      echo "  WARN: path MTU probe failed; keeping MTU $current unchanged. Set SING_BOX_MTU=<value> to override." >&2
      return 0
    fi
  fi

  [ "$current" = "$detected" ] && { echo "$iface MTU already $detected — no change needed."; return 0; }

  echo "Adjusting $iface MTU: $current → $detected"
  if ip link set dev "$iface" mtu "$detected" 2>/dev/null; then
    echo "  MTU adjusted immediately."
  else
    echo "  WARN: could not adjust MTU immediately (will retry at boot)." >&2
  fi
  # Persist across reboot via OpenRC local.d
  mtu_script="/etc/local.d/set-mtu-$iface.start"
  cat > "$mtu_script" <<-LOCALEOF
#!/bin/sh
ip link set dev $iface mtu $detected
LOCALEOF
  chmod +x "$mtu_script"
  rc-update add local boot 2>/dev/null || true
  echo "  Persisted via $mtu_script (local service enabled at boot)."
}

detect_container_env() {
  # 识别运行环境：LXC/其它容器与 VM/裸机的 sysctl 语义完全不同。
  # LXC 与宿主机共享内核，容器内写 bbr/buffer 等参数可能只读、可能白写，
  # 真正生效点在 PVE 宿主机——所以必须区别对待，不能一锅炖硬写。
  if [ -r /proc/1/environ ] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container=lxc'; then
    echo "lxc"
  elif [ -r /run/systemd/container ] || grep -qs 'lxc\|docker' /proc/1/cgroup 2>/dev/null; then
    echo "container"
  else
    echo "vm"
  fi
}

apply_sysctl_verified() {
  # 逐条应用并回读验证：成功打 ✓，失败打 ⚠ 并说明——绝不静默吞错，
  # 避免用户在 LXC 里以为优化生效了、实际半生效的"假省心"。
  local param key value actual ok=0 fail=0
  for param in "$@"; do
    key="${param%% = *}"
    value="${param#* = }"
    if sysctl -w "$key=$value" >/dev/null 2>&1; then
      actual="$(sysctl -n "$key" 2>/dev/null || echo '?')"
      echo "  ✓ $key = $actual"
      ok=$((ok + 1))
    else
      echo "  ⚠ $key 在当前环境不可写(容器内只读或内核不支持)，跳过."
      fail=$((fail + 1))
    fi
  done
  echo "  应用结果: 成功 $ok 项，跳过 $fail 项。"
}

apply_sysctl_conf_verified() {
  # 按持久化文件逐行应用+验证：运行态与 /etc/sysctl.d 文件保持一致，
  # 管理员手动改过文件时应用的就是改过的值，不会被安装器的默认值顶掉。
  local conf="$1" line key value params=()
  [ -r "$conf" ] || { echo "  ⚠ $conf 不可读，跳过."; return 0; }
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) ;;
      *) continue ;;
    esac
    key="$(printf '%s' "$line" | cut -d= -f1 | tr -d '[:space:]')"
    value="$(printf '%s' "$line" | cut -d= -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    # set -e 下不能用裸 && 链(为假时整条语句非零会中止安装器)。
    if [ -n "$key" ] && [ -n "$value" ]; then
      params+=("$key = $value")
    fi
  done < "$conf"
  # 注意 set -e：空文件时短路表达式返回非零会中止安装器，必须用显式 if。
  if [ "${#params[@]}" -gt 0 ]; then
    apply_sysctl_verified "${params[@]}"
  fi
}

print_pve_host_guidance() {
  cat <<'GUIDE'
  ────────────────────────────────────────────────────────
  检测到 LXC 容器环境。容器与宿主机共享内核，BBR/缓冲区等
  性能参数需要在 Proxmox VE 宿主机上配置才能真正生效。
  请在 PVE 宿主机执行(只需一次)：

  cat > /etc/sysctl.d/98-pve-lxc-singbox.conf <<'EOF'
  net.core.default_qdisc = fq
  net.ipv4.tcp_congestion_control = bbr
  net.ipv4.tcp_slow_start_after_idle = 0
  net.ipv4.tcp_notsent_lowat = 16384
  net.ipv4.tcp_rmem = 4096 131072 67108864
  net.ipv4.tcp_wmem = 4096 65536 67108864
  net.core.rmem_max = 67108864
  net.core.wmem_max = 67108864
  net.core.somaxconn = 16384
  net.ipv4.tcp_max_syn_backlog = 8192
  EOF
  sysctl -p /etc/sysctl.d/98-pve-lxc-singbox.conf
  ────────────────────────────────────────────────────────
GUIDE
}

setup_performance_qdisc() {
  local iface env_type
  # 逃生门：不想让安装器碰内核参数的用户可显式跳过。
  case "${SING_BOX_SKIP_SYSCTL:-0}" in
    1|true|TRUE|yes|YES|on|ON)
      echo "=== TCP 性能优化: 已按 SING_BOX_SKIP_SYSCTL 跳过 ==="
      return 0
      ;;
  esac
  env_type="$(detect_container_env)"
  echo "=== TCP 性能优化 (环境: $env_type) ==="

  if [ "$env_type" = "vm" ]; then
    # VM/裸机：独立内核，全套参数安全生效(生产验证过的组合)。
    # 文件已存在时不重写——尊重管理员对该文件的手动修改(覆盖安装不重置)。
    mkdir -p /etc/sysctl.d
    if [ ! -f /etc/sysctl.d/98-sing-box-performance.conf ]; then
      cat > /etc/sysctl.d/98-sing-box-performance.conf << 'EOF'
# sing-box gateway 性能参数 (由安装器写入; SING_BOX_SKIP_SYSCTL=1 可跳过)
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
EOF
      echo "  sysctl 性能配置已写入 /etc/sysctl.d/98-sing-box-performance.conf"
    else
      echo "  /etc/sysctl.d/98-sing-box-performance.conf 已存在，保留现有内容(不覆盖手动修改)."
    fi
    # 运行态按持久化文件逐条应用+回读验证，✓/⚠ 逐条打印，不静默吞错。
    apply_sysctl_conf_verified /etc/sysctl.d/98-sing-box-performance.conf
  else
    # LXC/容器：只尝试容器内通常可写、且不依赖宿主机模块加载状态的参数。
    # bbr/大缓冲这类共享内核参数不在容器内强写(写了也未必生效，还会误导)，
    # 统一改为提示用户在宿主机配置。也不写 sysctl.d 持久化文件——
    # 开机时容器内 sysctl 服务对只读键报错会制造噪声。
    apply_sysctl_verified \
      "net.ipv4.tcp_notsent_lowat = 16384" \
      "net.ipv4.tcp_fastopen = 3" \
      "net.ipv4.tcp_mtu_probing = 1"
    print_pve_host_guidance
  fi

  # tc qdisc: fq — 条件启用，需要内核支持(容器内一般不可用，探测失败自动跳过)
  iface="$(ip -4 route show default 2>/dev/null | awk '/default/ { print $5; exit }')"
  if [ -z "$iface" ]; then
    echo "  ⚠ 未检测到 IPv4 默认路由，跳过 fq qdisc 配置."
    return 0
  fi
  if tc qdisc show dev "$iface" 2>/dev/null | grep -qE 'qdisc (fq|cake|htb|hfsc|tbf) '; then
    # fq 已生效，或管理员配置了自定义流控(cake/htb 等)——绝不覆盖用户的 qdisc 策略。
    echo "  qdisc 已配置 ($(tc qdisc show dev "$iface" 2>/dev/null | head -1 | awk '{print $2}'))，不改动."
  elif tc qdisc replace dev "$iface" root fq 2>/dev/null; then
    echo "  ✓ fq qdisc 已附加到 $iface"
    # 持久化
    local lscript="/etc/local.d/singbox-qdisc.start"
    cat > "$lscript" <<-LOCALEOF
#!/bin/sh
# sing-box gateway: 确保 $iface 上启用 fq qdisc（BBR pacing）
[ -x /sbin/tc ] || [ -x /usr/sbin/tc ] || exit 0
/sbin/tc qdisc replace dev $iface root fq 2>/dev/null || /usr/sbin/tc qdisc replace dev $iface root fq 2>/dev/null || true
LOCALEOF
    chmod +x "$lscript"
    rc-update add local boot 2>/dev/null || true
    echo "  已持久化到 $lscript"
  else
    echo "  ⚠ 当前环境不支持配置 fq qdisc，跳过 (BBR 使用软件 pacing)."
  fi
}

pre_upgrade_cleanup() {
  # 停止旧服务、清理旧文件，确保新版本文件覆盖不受残留影响。
  # 原则：不炸网络（不删 nftables/路由）、不阻断安装（全部 || true）。
  echo "Stopping existing services for clean upgrade..."
  for s in singbox-rule-ui sing-box sing-box-tproxy; do
    rc-service "$s" stop >/dev/null 2>&1 || true
  done
  # 移除旧版 init.d 脚本（install_files 会重新装新的）
  rm -f /etc/init.d/sing-box /etc/init.d/sing-box-tproxy /etc/init.d/singbox-rule-ui
  # 清理旧的 local.d MTU 持久化脚本（ensure_mtu_standard 会重新生成）
  rm -f /etc/local.d/set-mtu-*.start
  # 清理旧 sysctl 和 logrotate 配置（后续步骤会重新生成）
  rm -f /etc/sysctl.d/99-sing-box-tproxy.conf "$LOGROTATE_CONFIG"
  echo "Cleanup done."
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
  check_kernel_reboot_needed
  record_preinstall_state
  choose_sing_box_runtime
  install_packages
  pre_upgrade_cleanup
  install_files
  install_logrotate_config
  bootstrap_config
  install_sing_box
  install_initial_rules
  disable_unrequested_radvd
  install_tproxy_setup
  ensure_dns_port_available
  /usr/local/bin/sing-box check -c /etc/sing-box/config.json || echo "WARN: config check had issues (likely missing rule files); cron will retry the update." >&2
  install_cron_jobs
  enable_services
  refresh_tproxy_after_start
  ensure_mtu_standard
  setup_performance_qdisc
  echo
  echo "Installed on Alpine/OpenRC."
  echo "Host resolver was left unchanged. Configure client/router resolver manually if needed."
  echo "Interface MTU was auto-detected; set via SING_BOX_MTU env var to override."
  sing-box-gateway-info
}

main "$@"
