# singbox-ui-alpine (stock 1.13.14)

> **醒目说明：本 Alpine 小白网关仓库固定使用 `sing-box 1.13.14` 正式版，不使用 latest 或上游自动升级版本。**

这是从 `hanigege/sing-box1.13.13-gateway-ui` 迁移出的 Alpine/OpenRC 版本，面向旁路代理/旁路网关场景，集成 `sing-box`、TProxy、分流规则自动更新、规则管理 UI 和受 token 保护的运行状态面板。

设计目标是：**高效、简洁、sing-box 不死、Alpine 下可预估零维护**。所有配置保存、规则更新和 TProxy 同步都先检查、可回滚；安装器不改宿主机 DNS，不写公共 DNS，不启用 IPv6 RA 广播，避免把旁路机变成不可预期的默认网关。

## 功能

- 一键安装 `sing-box` 二进制、OpenRC 服务、TProxy、crond 定时任务和 Web UI
- 默认使用仓库内置并校验过的 Alpine/musl 静态构建版 `sing-box 1.13.14`，包含 `amd64` 和 `arm64`
- 9091 规则 UI 管理白名单、黑名单、灰名单、DDNS、代理节点、实时连接、日志和运行规则
- 保存前执行 `sing-box check`，失败不覆盖正式配置；规则和主配置使用原子替换
- 重启失败自动回滚上一份可用配置，优先保证正在运行的 `sing-box` 可恢复
- Auto 默认每 30 秒自动测速并重选可用节点，urltest 选中节点变化时中断旧连接
- TProxy 自动检测默认网卡、本机网段和 IPv6 前缀
- 节点服务器 IP 自动加入 TProxy bypass，避免代理链路被透明代理套住
- Telegram 官方 IP 捕获列表支持在线更新和手动校验编辑
- LAN 侧 DNS 指向本机时，sing-box 监听 53 端口处理 DNS 查询，降低 IPv4/IPv6 明文 DNS 泄漏
- 安装器默认不改 `/etc/resolv.conf`，不把宿主机 DNS 指向本机，不启用 `radvd`
- 安装器默认不调整 TCP/UDP 性能 sysctl，内核调参由管理员按实际链路手动决定
- 规则更新由 Alpine `crond` 管理，运行状态自愈每 2 分钟检查一次
- `sing-box-gateway-info` 一键查看 9091 访问地址和 Rule UI token

## 支持系统

当前安装器只面向 Alpine Linux + OpenRC：

- Alpine 3.19+
- `x86_64/amd64`
- `aarch64/arm64`

需要 root 权限。不要在 Debian/Ubuntu 上使用这个仓库；Debian/Ubuntu 请继续用原 systemd 版本。

## 一键安装

提供两个并行的安装入口，按网络环境选一个即可。两个入口走不同的安装脚本，最终效果一致：

```sh
# 入口一：直连 GitHub（推荐，海外或能直连 GitHub raw 的机器）
# 脚本内部所有下载也保持直连，无任何反代层。
curl -fsSL https://raw.githubusercontent.com/hanigege/singbox-ui-alpine/stock-1.13.14/scripts/quick-install.sh | sh
```

```sh
# 入口二：ghproxy.net 反代（境内或 GitHub 直连不稳定的机器）
# 脚本内置 ghproxy.net、gh-proxy.com、gh.llkk.cc 多级镜像加速
# 和直连回退（压缩包下载和分流规则更新均有多镜像兜底）。
curl -fsSL https://ghproxy.net/https://raw.githubusercontent.com/hanigege/singbox-ui-alpine/stock-1.13.14/scripts/quick-install-proxy.sh | sh
```

安装器自动安装 Alpine 依赖：`bash`、`curl`、`ca-certificates`、`tar`、`gzip`、`python3`、`nftables`、`iproute2`、`rsync`、`util-linux`、`coreutils`、`openrc`。仓库内置的 `sing-box` 是从官方 `v1.13.14` 标签构建的 Alpine/musl 静态二进制，不需要 `gcompat`。卸载时默认保留 apk 包，避免连带移除系统基础依赖。

如需指定架构（仅 Git 安装方式）：

```bash
SING_BOX_ARCH=arm64 bash scripts/install.sh
```

如果安装在 Proxmox VE 的 Alpine LXC 里，一键安装只负责容器内的 sing-box、TProxy、OpenRC 和 Rule UI，不会改 PVE 宿主机配置，也不能替你写 `/etc/pve/lxc/<CTID>.conf`。高并发或高带宽场景建议安装后继续看下面的“Proxmox VE / LXC 可选优化”。

## 53 端口和 DNS

Alpine 默认通常没有 `systemd-resolved` 占用 53 端口。本仓库按 Alpine 预期处理：

- 安装器会检查 sing-box 将要监听的 53 地址
- 53 未占用则继续安装
- 已由 sing-box 占用则认为是覆盖安装，继续
- 被其它进程占用则停止，并提示用户先释放端口
- 安装器不会改写 `/etc/resolv.conf`
- 安装器不会替你关闭其它 DNS 服务
- 安装器不会把宿主机 DNS 指向 sing-box 本机

如果占用者是 `dnsmasq`、`unbound`、`adguardhome` 或其它第三方 DNS，安装器不会自动 kill 或临时 stop。临时停掉不能解决重启后再次抢占 53 的问题，还可能断开当前管理网络。更稳的处理方式是用 `rc-service <服务> stop` 和 `rc-update del <服务> default` 持久禁用，或者把该服务改到其它监听端口后再安装。

客户端 DNS 只有最终进入 sing-box，白名单、黑名单、灰名单、FakeIP 和域名分流规则才会完整生效。实现方式可以是：

- 在客户端手动把 DNS 指向 sing-box 机器的内网 IPv4
- 在前端软路由上把客户端 DNS 转发到 sing-box
- 在前端软路由上劫持客户端 53 端口 DNS 到 sing-box

没有配置真实代理节点前，不建议把客户端 DNS 指向 sing-box，否则国外网站可能解析成 FakeIP 但代理不可用。

## OpenRC 服务

安装后会创建：

- `/etc/init.d/sing-box-tproxy`
- `/etc/init.d/sing-box`
- `/etc/init.d/singbox-rule-ui`

常用检查命令：

```bash
rc-service sing-box status
rc-service sing-box-tproxy status
rc-service singbox-rule-ui status
rc-update show default
sing-box-gateway-info
```

OpenRC 服务日志默认写入：

- `/var/log/sing-box-gateway/sing-box.log`
- `/var/log/sing-box-gateway/rule-ui.log`
- `/var/log/sing-box-gateway/rule-update.log`
- `/var/log/sing-box-gateway/runtime-monitor.log`

安装器会写入 `/etc/logrotate.d/sing-box-gateway`，对上述日志按单文件 5M 触发轮转，保留 6 份压缩归档，避免 OpenRC 和 cron 长期追加导致系统盘被日志撑满。

## 自动维护

安装器会写入 root crontab：

- 每周日 04:20 更新分流规则
- 每 2 分钟运行 `/usr/local/sbin/monitor-sing-box-runtime`

Rule UI 的维护页可以调整分流规则自动更新周期和执行时间。保存后 UI 会更新 `/etc/crontabs/root` 中由本项目标记包围的规则更新块，并重启 `crond`。手动“立即更新分流规则”成功后，也会把下一次自动更新从本次完成时间重新顺延一个周期。这些动作只改变触发计划，不改变 `/usr/local/sbin/update-sing-box-rules-jsdelivr` 更新脚本，也不会修改 sing-box 主配置。

## IPv6 RA

安装器默认不启用 `radvd`，也不会把这台 Alpine 机器广播成 LAN 默认 IPv6 网关。如果目标机之前已经安装并启用了 `radvd`，安装器会在未显式 opt-in 时执行：

```bash
rc-service radvd stop
rc-update del radvd default
```

如果你确实需要让本机广播 IPv6 默认网关，可以自行安装 `radvd`，并在运行安装器、UI 或同步脚本时显式设置：

```bash
SING_BOX_GATEWAY_ENABLE_RADVD=1 /usr/local/sbin/refresh-sing-box-runtime-config
```

生产网络里不建议在多台旁路机上同时启用 RA 广播。一般更稳的做法是：前端软路由继续作为默认网关，只把 FakeIP 网段或指定流量路由到 sing-box 机器。

### PPPoE / RouterOS IPv6 MTU

如果前端软路由通过 PPPoE 拨号，WAN MTU 通常是 `1492`，但 LAN 侧 IPv6 RA 如果不显式广播 MTU，客户端会按以太网默认 `1500` 发送 IPv6。大 TLS ClientHello 或 HTTP/2 请求可能在 PPPoE 出口被 IPv6 分片，部分 CDN/中间网络会丢弃分片，表现为：

- 淘宝、天猫、支付宝等页面主体能打开，但订单、购物车、接口数据或部分图片一直加载
- `ping -6` 正常，普通小页面正常，但某些 HTTPS 接口间歇性超时
- DNS 已经返回真实国内 IPv4/IPv6，不是 FakeIP 或白名单问题

根因修复是在**前端默认 IPv6 网关**上把 LAN RA MTU 设置为实际 WAN MTU。MikroTik RouterOS 示例：

```routeros
/interface/print detail where name~"pppoe|bridge"
/ipv6/nd/print detail
/ipv6/nd/set [find interface=bridge1] mtu=1492
/ipv6/nd/print detail where interface=bridge1
```

如果你的 LAN 接口不是 `bridge1`，请替换成实际接口名；如果 PPPoE MTU 不是 `1492`，请使用 `/interface/print detail` 里 `pppoe-out` 的 `actual-mtu`。改完后，让客户端重新获取 RA：断开/重连 Wi-Fi、重启网卡，或等待下一次 RA。

sing-box 所在的 Alpine 机器本身也是 LAN IPv6 客户端。如果它已经在线并仍显示 `mtu 1500`，可以立即把默认网卡 MTU 调成同一个值来验证：

```bash
ip link show dev eth0
ip link set dev eth0 mtu 1492
ip link show dev eth0
curl -6 -m 6 -o /dev/null -w '%{http_code} %{time_total} %{remote_ip}\n' https://h5api.m.taobao.com/
```

要持久化 Alpine 网卡 MTU，请按实际网络管理方式配置。例如使用 `/etc/network/interfaces` 的系统可在对应网卡下加入：

```interfaces
auto eth0
iface eth0 inet dhcp
    mtu 1492
```

如果网卡名不是 `eth0`，请替换成实际默认出口接口，可用 `ip route get 1.1.1.1` 查看。LXC 场景下也可以在 PVE/上游网络侧统一限制 veth/bridge MTU；原则是 LAN 客户端看到的 IPv6 MTU 不要大于 PPPoE 出口实际 MTU。

这个设置和公网 IPv6 前缀是否动态无关；前缀变了也仍然适用。

## TProxy 转发模式

默认按“非网关 TProxy + FakeIP 入口”部署：上游路由器继续做默认网关，只把 FakeIP 或灰名单 CIDR 路由到这台 Alpine LXC。安装器和 UI 生成的 `/etc/sysctl.d/99-sing-box-tproxy.conf` 只保留 TProxy/FakeIP 必需参数，例如 `ip_nonlocal_bind`、`rp_filter` 和当前网卡的 IPv6 RA 接收项，不会默认开启 `net.ipv4.ip_forward` 或 IPv6 forwarding，也不会写入 TCP 队列、缓冲等性能 sysctl，避免容器内参数和 PVE 宿主机上限不一致。

如果第三方设备的默认网关或明确路由已经指向本机，需要让 LXC 作为代理网关，再显式开启：

```bash
SING_BOX_GATEWAY_ENABLE_FORWARDING=1 rc-service sing-box-tproxy restart
```

如果要持久启用，可以把 `SING_BOX_GATEWAY_ENABLE_FORWARDING=1` 写入 `/etc/conf.d/sing-box-tproxy`，之后再重启服务。这个开关只影响容器内转发类 sysctl。PVE 宿主机上的 BBR、缓冲区、conntrack 和 LXC 的 `lxc.prlimit.nofile` 仍建议按实际链路手动配置。

## Proxmox VE / LXC 可选优化

这部分只适合 Proxmox VE 宿主机上的 Alpine LXC。它不是一键安装器的一部分，因为 PVE 宿主机和 LXC 配置属于容器外部边界，安装脚本不应该从容器内自动修改宿主机。

### PVE 宿主机网络参数

## Proxmox VE / LXC 可选优化 (如果sing-box安装在vm里，下面的就没必要配置了）

这部分只适合 Proxmox VE 宿主机上的 Alpine LXC。它不是一键安装器的一部分，因为 PVE 宿主机和 LXC 配置属于容器外部边界，安装脚本不应该从容器内自动修改宿主机。

### PVE 宿主机网络参数

在 PVE 宿主机上追加或确认 `root@local:/etc/sysctl.d# `
```
cd /etc/sysctl.d
nano 98-pve-lxc-singbox.conf：
```

```conf

# PVE Host sysctl for LXC sing-box gateway
# LXC 与宿主机共享内核，这些参数直接影响容器内 TCP 性能

# Bridge: 让 veth 桥接流量绕过 host iptables，减少开销
net.bridge.bridge-nf-call-iptables = 0
net.bridge.bridge-nf-call-ip6tables = 0

# BBR + fq
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# 高负载 NAPI 轮询预算
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000

# TCP 性能
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_rmem = 4096 131072 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864

# socket 队列（高连接数场景有用，代理网关建议适度提升）
net.core.somaxconn = 16384
net.ipv4.tcp_max_syn_backlog = 8192

```


存到 PVE 宿主机 /etc/sysctl.d/98-pve-lxc-singbox.conf，
然后 sysctl -p 生效。
应用：

```bash
sysctl -p
```

`net.netfilter.nf_conntrack_max` 在部分 PVE 内核上会被已加载的 `nf_conntrack` 模块限制或回退。如果运行态反复回到默认值，可以先不强求；对本项目的 FakeIP/TProxy 入口模式来说，`nofile`、缓冲区和服务稳定性更关键。

### PVE 放宽指定 LXC 的 nofile

在 PVE 宿主机查看容器 ID：

```bash
pct list
```

编辑对应容器配置，例如容器 ID 是 `116`：

```bash
nano /etc/pve/lxc/116.conf
```

追加：

```conf
# 允许容器内 sing-box 使用更高打开文件数上限。
lxc.prlimit.nofile: 1048576:1048576
```

然后重启这个 LXC：

```bash
pct reboot 116
```

进入 Alpine LXC 后验证：

```bash
ulimit -n
cat /proc/1/limits | grep 'Max open files'
cat /proc/$(pidof sing-box)/limits | grep 'Max open files'
```

正常应看到 `1048576`。如果需要提高 `sing-box` 服务进程的打开文件数，请先在 PVE LXC 层放宽 `lxc.prlimit.nofile`，再按现场策略单独配置。

### Alpine LXC 内的 TProxy 参数

安装器和 Rule UI 会生成 `/etc/sysctl.d/99-sing-box-tproxy.conf`，默认是非网关 FakeIP 入口模式，只包含透明代理入口需要的参数，不默认开启 `ip_forward`，也不写 TCP/UDP 性能参数。安装后可以检查：

```bash
cat /etc/sysctl.d/99-sing-box-tproxy.conf
sysctl net.ipv4.ip_nonlocal_bind net.ipv4.conf.all.rp_filter
```

如果这台 LXC 确实作为客户端默认网关，再按上面的“TProxy 转发模式”显式开启 forwarding。

## 通用性能参数

安装器默认不写入 TCP/UDP 性能 sysctl，也不会启用 BBR 或修改缓冲参数。不同 VPS、LXC、PVE 和家庭宽带链路对内核参数的反应差异很大，自动捆绑调参可能让部分环境变慢。

如果确实需要调整 `tcp_congestion_control`、`tcp_rmem`、`tcp_wmem`、`udp_rmem_min` 或 `tcp_slow_start_after_idle`，建议先手动测试当前节点和链路，再自行写入 `/etc/sysctl.d/*.conf`。仓库的安装、覆盖安装和运行态自愈不会改动这些参数。

## 访问入口

安装完成后输出 9091 规则 UI 地址和 Rule UI token。忘记也没关系，在网关机器上运行：

```bash
sing-box-gateway-info
```

默认入口：

```text
http://<网关IP>:9091/
```

9090 Clash API 保留给 9091 后端读取连接、日志和运行规则；浏览器日常管理只需要进入 9091，并使用 Rule UI token 登录。

## 一键卸载

已安装机器优先使用本地卸载器：

```bash
/usr/local/bin/sing-box-gateway-uninstall --yes
```

默认卸载会停止并禁用本项目 OpenRC 服务，清理 TProxy nft/routing 运行规则，移除本项目 crontab 块，按安装前记录恢复 `radvd` 状态，并删除本项目安装的 UI、辅助脚本、运行配置、规则缓存和 `/etc/sing-box`。

如果 `/usr/local/bin/sing-box` 是本安装器新增的，默认会删除；如果安装前已经存在，则默认保留，避免误删用户原有程序。

卸载器默认不删除 apk 依赖包，因为 Alpine 的包依赖关系可能把多个基础工具连带移除。确实要删除安装器新增依赖时，显式设置：

```bash
SING_BOX_GATEWAY_REMOVE_DEPS=1 /usr/local/bin/sing-box-gateway-uninstall --yes
```

如果没有安装状态记录，但你仍然确认要删除 `/usr/local/bin/sing-box`，可以使用 purge：

```bash
/usr/local/bin/sing-box-gateway-uninstall --purge --yes
```

## Git 安装

适合想修改脚本或参与开发的用户：

```bash
apk add --no-cache bash curl ca-certificates
git clone https://github.com/hanigege/singbox-ui-alpine.git
cd sing-box1.13.13-alpine-ui
bash scripts/install.sh
```

本地卸载（交互式确认，静默模式加 `--yes`）：

```bash
bash scripts/install.sh uninstall        # 标准卸载，有确认提示
bash scripts/install.sh uninstall --yes  # 静默卸载
bash scripts/install.sh purge --yes      # 静默强制删除 /usr/local/bin/sing-box
```

## 安全

不要把以下内容提交到公开仓库：

- 节点密码
- UUID
- Reality public key / short id
- UI token
- 真实服务器 IP
- 私有域名

本仓库只保存安装逻辑和通用模板，不包含任何可用代理节点或私人配置。
