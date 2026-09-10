# ocserv-manager

`ocserv-manager` 是一个面向 **ocserv / ocserv-docker** 的单文件服务器网络管理工具（当前版本见脚本内 `VERSION`），整合以下功能：

- VPN NAT 与 FORWARD 自动恢复
- 默认公网出口网卡自动识别
- `vpns0、vpns1、vpns2...` 自动限速
- 宽松 BT/P2P 风险控制
- 公网端口映射到指定 VPN 用户
- NAT 历史映射审计（SQLite）
- VPN 内网 IP 与用户名会话关联
- 31 天自动清理
- systemd 开机启动与故障恢复
- 统一交互式管理菜单

本项目适合解决以下问题：

- VPS 重启后 VPN 已连接但无法访问互联网
- Docker 重启后 iptables NAT 规则丢失
- 新生成的 `vpnsN` 接口没有自动限速
- 需要降低 BT/P2P 版权投诉风险
- 需要将 VPS 公网端口转发给指定 VPN 用户
- 收到投诉后，根据时间、公网源端口和协议定位历史 VPN 用户

> 本工具只保存连接元数据，不保存网页内容、密码、聊天内容、下载文件或完整数据包。

---

## 项目结构

```text
ocserv-manager/
├── ocserv-manager.sh
├── README.md
└── LICENSE
```

安装后主要文件：

```text
/usr/local/sbin/ocserv-manager
/etc/ocserv-manager/config
/etc/ocserv-manager/port-mappings.tsv
/var/lib/ocserv-manager/audit.db
/var/lib/ocserv-manager/active-sessions.tsv
/var/log/ocserv-manager/sessions/
```

---

## 适用环境

建议使用：

- Debian 11 / 12 / 13
- Ubuntu 20.04 / 22.04 / 24.04
- systemd
- iptables
- ocserv 或 ocserv-docker
- VPN 接口名称为 `vpns0、vpns1、vpns2...`

内核需要支持：

```text
HTB
IFB
conntrack
connlimit
hashlimit
mirred
xt_string（可选）
```

---

## 安装依赖

```bash
apt update
apt install -y \
  iproute2 \
  iptables \
  kmod \
  conntrack \
  jq \
  coreutils \
  python3 \
  logrotate \
  sqlite3
```

---

## 一键下载安装

```bash
mkdir -p /root/ocserv-manager && \
wget -N --no-check-certificate \
  -P /root/ocserv-manager \
  https://raw.githubusercontent.com/jackzhang-superman/ocserv-manager/main/ocserv-manager.sh && \
chmod +x /root/ocserv-manager/ocserv-manager.sh && \
/root/ocserv-manager/ocserv-manager.sh install
```

强制重新下载最新版：

```bash
rm -f /root/ocserv-manager/ocserv-manager.sh

wget --no-cache --no-check-certificate \
  -O /root/ocserv-manager/ocserv-manager.sh \
  https://raw.githubusercontent.com/jackzhang-superman/ocserv-manager/main/ocserv-manager.sh

chmod +x /root/ocserv-manager/ocserv-manager.sh
/root/ocserv-manager/ocserv-manager.sh install
```

安装完成后直接运行：

```bash
ocserv-manager
```

---

## 默认配置

安装后配置文件：

```text
/etc/ocserv-manager/config
```

默认配置示例：

```bash
VPN_SUBNET="192.168.1.0/24"
VPN_INTERFACE_GLOB="vpns+"
VPN_INTERFACE_REGEX="^vpns[0-9]+$"
WAN_INTERFACE="auto"

RATE="50mbit"
IFB_DEVICE="ifb0"
LIMIT_SCAN_INTERVAL="1"

NETWORK_CHECK_INTERVAL="60"

BT_GUARD_ENABLED="yes"
BT_CONN_LIMIT="350"
BT_NEW_RATE="80/second"
BT_NEW_BURST="160"
BT_BLOCK_CLASSIC_PORTS="yes"
BT_STRING_MATCH="yes"

AUDIT_ENABLED="yes"
AUDIT_RETENTION_DAYS="31"
AUDIT_IGNORE_NONPUBLIC_DESTINATIONS="yes"
AUDIT_IGNORE_DNS="yes"
AUDIT_DNS_SERVERS="8.8.8.8,8.8.4.4"

SESSION_AUDIT_ENABLED="yes"
SESSION_SCAN_INTERVAL="30"
OCCTL_COMMAND="docker exec ocserv occtl -j show users"

IPTABLES_BIN="/usr/sbin/iptables"
```

修改配置：

```bash
nano /etc/ocserv-manager/config
```

应用配置：

```bash
systemctl restart ocserv-network.service
systemctl restart ocserv-limit.service
systemctl restart ocserv-audit.service
systemctl restart ocserv-session-audit.service
```

---

# 功能说明

## 1. NAT 与转发自动恢复

脚本自动识别默认 IPv4 公网出口网卡，也可手动指定 `WAN_INTERFACE`。只管理本项目的 iptables 链（`OCSERV_*`），不会清空整张 FORWARD/NAT 表。

```bash
ocserv-manager network-apply
```

## 2. VPN 用户自动限速

持续识别 `vpnsN` 并应用 HTB + IFB。默认 `50mbit`。

```bash
ocserv-manager set-rate 80mbit
```

## 3. 宽松 BT/P2P 风险控制

并发/新建连接限制，并拦截常见 BT 端口与协议握手特征。只能降低风险，不能保证识别全部 P2P。

```bash
ocserv-manager bt enable
ocserv-manager bt disable
```

## 4. 公网端口映射

```bash
ocserv-manager port add tcp 33891 192.168.1.129 3389
ocserv-manager port list
ocserv-manager port delete tcp 33891
```

配置：`/etc/ocserv-manager/port-mappings.tsv`

## 5. NAT 历史审计

使用 `conntrack` 写入 SQLite（`/var/lib/ocserv-manager/audit.db`，表 `nat_sessions`）。一条连接一行：建立时插入，结束时更新结束时间。

## 6. VPN 用户名会话关联

默认 `docker exec ocserv occtl -j show users`，映射写入 `/var/lib/ocserv-manager/active-sessions.tsv`。

## 7. 历史投诉查询

```bash
ocserv-manager audit lookup \
  --time "2026-08-02 15:50:00 +0800" \
  --public-port 49758 \
  --protocol tcp
```

可加 `--destination` / `--destination-port` / `--tolerance`。

## 8. 审计库状态与维护

```bash
ocserv-manager audit stats
ocserv-manager audit maintenance
```

若本地有历史 CSV 需导入当前库：

```bash
ocserv-manager audit migrate-csv
```

保留天数：`AUDIT_RETENTION_DAYS`（默认 31），由 `ocserv-audit-maintenance.timer` 执行。

---

# 统一管理菜单

```bash
ocserv-manager
```

```text
========== ocserv-manager ==========
1. 查看状态
2. 修改全局限速
3. 立即恢复全部网络规则
4. 添加端口映射
5. 查看端口映射
6. 删除端口映射
7. 启用宽松 BT 风险控制
8. 停用 BT 风险控制
9. 查询历史 NAT 记录
10. 编辑配置
11. 查看日志
12. 卸载
0. 退出
====================================
```

---

# systemd 服务

| 用途 | 单元 |
|---|---|
| 网络规则 | `ocserv-network.service` / `ocserv-network.timer` |
| 限速 | `ocserv-limit.service` |
| NAT 审计 | `ocserv-audit.service` |
| 用户名会话 | `ocserv-session-audit.service` |
| 库维护 | `ocserv-audit-maintenance.timer` |

---

# 常见问题

## `Change operation not supported by specified qdisc`

停止限速服务后清理 `vpns*` / `ifb0` 的 qdisc，再重启 `ocserv-limit.service`。

## `Exclusivity flag on, cannot modify`

有其他进程同时改 qdisc。确认仅运行：

```bash
pgrep -af 'ocserv-manager limit-daemon'
```

## `OCCTL_COMMAND 执行失败`

测试 `docker exec ocserv occtl -j show users`，核对配置后重启 `ocserv-session-audit.service`。

## 当前端口映射列表为空

只有表头表示没有固定公网映射；不影响用户上网（临时 NAT 源端口）。

## 如何查看用户当前 NAT 端口

```bash
docker exec ocserv occtl -j show users |
jq -r '.[] | [.Username, .IPv4] | @tsv'

conntrack -L -s 192.168.1.129 -o extended
```

## 为什么公网端口与 VPN 源端口相同

MASQUERADE 通常优先保留原始源端口；冲突时才可能换端口。

---

# 更新

```bash
rm -f /root/ocserv-manager/ocserv-manager.sh

wget --no-cache --no-check-certificate \
  -O /root/ocserv-manager/ocserv-manager.sh \
  https://raw.githubusercontent.com/jackzhang-superman/ocserv-manager/main/ocserv-manager.sh

chmod +x /root/ocserv-manager/ocserv-manager.sh
/root/ocserv-manager/ocserv-manager.sh install
```

```bash
grep '^VERSION=' /usr/local/sbin/ocserv-manager
```

更新不会主动删除 `/etc|/var/lib|/var/log/ocserv-manager/`。

---

# 卸载

```bash
ocserv-manager uninstall
```

卸载会删除 systemd 单元、可执行文件、本项目 iptables 链、tc 规则、sysctl 与 logrotate。默认保留配置与审计数据；确认不需要后再手动删除上述目录。

---

# 安全与合规说明

本工具保存连接时间、协议、VPN/公网 NAT 地址端口、目标地址端口、VPN 用户名会话映射。

不保存网页内容、密码、聊天内容、HTTPS 明文、下载文件或完整数据包。

审计结果应结合投诉时间、公网 IP、公网源端口、协议、目标等信息复核，不应仅依赖单一字段。

---

# License

MIT License
