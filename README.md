# sing-box1.13.13-alpine-ui

> **醒目说明：本 Alpine 小白网关仓库固定使用 `sing-box 1.13.13` 正式版，不使用 latest 或上游自动升级版本。**

这是从 `hanigege/sing-box1.13.13-gateway-ui` 迁移出的 Alpine/OpenRC 版本，面向旁路代理/旁路网关场景，集成 `sing-box`、TProxy、分流规则自动更新、规则管理 UI 和受 token 保护的运行状态面板。

设计目标是：**高效、简洁、sing-box 不死、Alpine 下可预估零维护**。所有配置保存、规则更新和 TProxy 同步都先检查、可回滚；安装器不改宿主机 DNS，不写公共 DNS，不启用 IPv6 RA 广播，避免把旁路机变成不可预期的默认网关。

## 功能

- 一键安装 `sing-box` 二进制、OpenRC 服务、TProxy、crond 定时任务和 Web UI
- 默认使用仓库内置并校验过的 Alpine/musl 静态构建版 `sing-box 1.13.13`，包含 `amd64` 和 `arm64`
- 9091 规则 UI 管理白名单、黑名单、灰名单、DDNS、代理节点、实时连接、日志和运行规则
- 保存前执行 `sing-box check`，失败不覆盖正式配置；规则和主配置使用原子替换
- 重启失败自动回滚上一份可用配置，优先保证正在运行的 `sing-box` 可恢复
- Auto 默认每 30 秒自动测速并重选可用节点，urltest 选中节点变化时中断旧连接
- TProxy 自动检测默认网卡、本机网段和 IPv6 前缀
- 节点服务器 IP 自动加入 TProxy bypass，避免代理链路被透明代理套住
- Telegram 官方 IP 捕获列表支持在线更新和手动校验编辑
- LAN 侧 TCP/UDP 53 会被重定向到 sing-box DNS，降低 IPv4/IPv6 明文 DNS 泄漏
- 安装器默认不改 `/etc/resolv.conf`，不把宿主机 DNS 指向本机，不启用 `radvd`
- 安装器会在网关机自身写入温和的 TCP/UDP 性能 sysctl；如果内核支持 BBR，则启用 BBR
- 规则更新由 Alpine `crond` 管理，运行状态自愈每 2 分钟检查一次
- `sing-box-gateway-info` 一键查看 9091 访问地址和 Rule UI token

## 支持系统

当前安装器只面向 Alpine Linux + OpenRC：

- Alpine 3.19+
- `x86_64/amd64`
- `aarch64/arm64`

需要 root 权限。不要在 Debian/Ubuntu 上使用这个仓库；Debian/Ubuntu 请继续用原 systemd 版本。

## 一键安装

推荐使用反代入口：

```sh
curl -fsSL https://scg.jgaga.tk/https://raw.githubusercontent.com/hanigege/sing-box1.13.13-alpine-ui/main/scripts/quick-install.sh | sh
```

如果当前机器直连 GitHub 稳定，也可以使用官方入口：

```sh
curl -fsSL https://github.com/hanigege/sing-box1.13.13-alpine-ui/raw/refs/heads/main/scripts/quick-install.sh | sh
```

裸 Alpine 默认有 BusyBox `wget`，没有 `curl` 也可以用这个入口：

```sh
wget -O- https://github.com/hanigege/sing-box1.13.13-alpine-ui/raw/refs/heads/main/scripts/quick-install.sh | sh
```

安装器会自动安装 Alpine 依赖：`bash`、`curl`、`ca-certificates`、`tar`、`gzip`、`python3`、`nftables`、`iproute2`、`rsync`、`util-linux`、`coreutils`、`openrc`。仓库内置的 `sing-box` 是从官方 `v1.13.13` 标签构建的 Alpine/musl 静态二进制，不需要 `gcompat`。卸载时默认保留 apk 包，避免连带移除系统基础依赖。

如需指定架构：

```bash
SING_BOX_ARCH=arm64 bash scripts/install.sh
```

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

## 自动维护

安装器会写入 root crontab：

- 每周日 04:20 更新分流规则
- 每 2 分钟运行 `/usr/local/sbin/monitor-sing-box-runtime`

Rule UI 的维护页可以调整分流规则自动更新周期和执行时间。保存后 UI 会更新 `/etc/crontabs/root` 中由本项目标记包围的规则更新块，并重启 `crond`。这只改变触发计划，不改变 `/usr/local/sbin/update-sing-box-rules-jsdelivr` 更新脚本，也不会修改 sing-box 主配置。

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

## 网关性能参数

安装器会写入 `/etc/sysctl.d/98-sing-box-performance.conf` 并立即应用。旁路网关跑在 PVE、LXC 或 VM 里时，真正发起代理 TCP/UDP 出站连接的是网关机里的 `sing-box` 进程，只优化宿主机内核参数不一定会作用到容器或虚拟机内的出站连接。

默认参数包括：

- 内核支持 BBR 时启用 `net.ipv4.tcp_congestion_control = bbr`
- 放大 `tcp_rmem` / `tcp_wmem` 自动调优上限
- 提高 `udp_rmem_min`
- 关闭 `tcp_slow_start_after_idle`

如果当前内核不支持 BBR，安装器会自动保留系统默认拥塞控制，只应用其它缓冲参数，安装不会因此失败。

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
git clone https://github.com/hanigege/sing-box1.13.13-alpine-ui.git
cd sing-box1.13.13-alpine-ui
bash scripts/install.sh
```

本地卸载：

```bash
bash scripts/install.sh uninstall
bash scripts/install.sh purge
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
