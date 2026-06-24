# 维护约束

本仓库是 Alpine/OpenRC 环境下的 sing-box 网关和 Rule UI。任何代码修改都必须以生产系统维护标准处理，稳定性优先于功能速度。

## 第一原则

1. `sing-box` 不死是第一前提。
   - 不管用户在 Rule UI 里如何新增、删除、导入、切换或保存配置，都不能因为 UI 操作导致 `sing-box` 无法启动。
   - 所有会影响 `/etc/sing-box/config.json`、节点、分组、规则集、TProxy 或 DNS 监听的改动，都必须先生成临时配置并执行 `sing-box check`。
   - 只有 `sing-box check` 通过后，才允许把新配置落盘到正式路径。
   - 如果运行态重启、同步 TProxy、测速或后续应用失败，必须保留或恢复到上一个可启动状态。

2. 不能用“先写入再试试看”的方式改配置。
   - 配置写入必须具备可验证、可回滚的流程。
   - 对导入备份、批量修改、节点生成这类高风险入口，必须特别确认失败路径不会破坏现有服务。

3. 不能为了修一个点东打补丁。
   - 修改前先理解现有调用链、服务依赖、安装脚本、OpenRC 行为、前端刷新逻辑和回滚语义。
   - 如果一个问题会影响多个入口，要统一修复共享逻辑，不要只修当前触发路径。
   - 修改一个文件前，要评估它和 `scripts/`、`openrc/`、`singbox-rule-ui/`、`templates/` 之间的联动。

## 修改要求

1. 先理解，再修改。
   - 先读相关代码和脚本，确认真实根因。
   - 不凭猜测改生产路径、服务启动顺序、防火墙/TProxy、DNS 监听或 sing-box 配置结构。

2. 先收敛，再验证。
   - 改动范围要收敛到解决问题所需的最小集合。
   - 不做无关重构，不顺手改变既有行为。
   - 修改后必须至少做语法检查；涉及服务和安装流程时，还要在 Alpine/OpenRC 上实测安装、重启、接口和卸载路径。

3. 先校验，再落盘。
   - 影响 sing-box 配置的代码必须沿用或补齐 staged check、backup、rollback 机制。
   - 禁止绕过 `staged_check`、`check_config`、`rollback_apply` 等保护逻辑直接写正式配置。
   - 新增入口如果会写配置，必须接入同等级别的校验和回滚。

4. 稳定性第一。
   - UI 请求不能因为 OpenRC 重启链路被中途打断。
   - 服务依赖要避免不必要的级联停止；Rule UI 可以依赖网络和启动顺序，但不应让 `sing-box restart` 直接拖死 UI 请求。
   - 53 端口、TProxy、规则集下载、定时任务和运行态刷新都要以可预期、可恢复为目标。

5. 可读、可追踪。
   - 关键行为改变要加中文注释，解释为什么这样做，尤其是回滚、延迟重启、端口冲突和 OpenRC 依赖相关逻辑。
   - 注释要解释维护意图，不写空泛描述。
   - 提交信息要说明真实修复点，不掩盖行为变化。

## 验证基线

修改后根据影响范围选择验证项，不能跳过明显相关的检查：

```sh
PYTHONPYCACHEPREFIX=/private/tmp/sb-alpine-pycache python3 -m py_compile \
  singbox-rule-ui/app.py \
  scripts/monitor_runtime.py \
  scripts/refresh_runtime_config.py \
  scripts/sync_tproxy_setup.py \
  scripts/bootstrap_config.py

bash -n \
  scripts/install.sh \
  scripts/uninstall.sh \
  scripts/update-sing-box-rules-jsdelivr \
  scripts/sing-box-gateway-info

sh -n \
  scripts/quick-install.sh \
  openrc/sing-box \
  openrc/sing-box-tproxy \
  openrc/singbox-rule-ui
```

涉及安装、卸载、OpenRC、DNS 53 端口、TProxy、备份导入、规则更新或运行态重启时，还必须在 Alpine 测试机上做端到端验证：

1. 安装脚本可以完整跑通。
2. `sing-box`、`sing-box-tproxy`、`singbox-rule-ui` 都是 `started`。
3. `/api/state`、`/api/proxy`、`/api/maintenance` 返回 200。
4. 备份导出和导入不会中断 HTTP 响应，不会让服务进入 `stopping`。
5. 卸载脚本行为符合预期，不残留会影响下次安装的服务状态。

## 禁止事项

1. 禁止绕过 `sing-box check` 直接覆盖正式配置。
2. 禁止用临时 sleep、忽略错误、吞掉失败来假装成功。
3. 禁止只修前端提示而不修后端真实失败路径。
4. 禁止让第三方 DNS、TProxy、规则更新冲突在重启后反复出现却没有明确处理策略。
5. 禁止为了快速通过测试而移除回滚、校验、服务状态检查。
6. 禁止改动不相关文件或重排大段代码制造不可追踪 diff。


---

## 三个 GitHub 仓库区分

| 仓库 | 本地路径 | 说明 |
|------|---------|------|
| `hanigege/sing-box1.13.13-alpine-ui` | `/Users/mana/Documents/codex/sb-alpine` | 当前工作仓库（sb-alpine）。Alpine OpenRC 环境，sing-box 1.13.13 网关 + Rule UI。生产部署在 10.20.20.6。 |
| `hanigege/sing-box1.14x-gateway-ui` | `/Users/mana/Documents/codex/sing-box1.14x-gateway-ui` | sing-box 1.14.x 网关 + Rule UI。代码结构和 alpine-ui 基本一致。 |
| `hanigege/sing-box1.13.13-gateway-ui` | `/Users/mana/Documents/codex/sing-box1.13.13-gateway-ui` | 另一个 sing-box 1.13.13 网关仓库。代码结构和前两个一致。 |

前端的 textarea 批量编辑改造三个仓库已同步（2026-06-24）。
修改前端静态文件（index.html、styles.css、app.js）时，如果需要同步到其他仓库，三个路径分别改。
