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

脚本自动识别默认 IPv4 公网出口网卡：

```bash
ip -4 route show default
```

例如：

```text
default via 172.238.12.1 dev eth0
```

会自动使用：

```text
eth0
```

对应配置：

```bash
WAN_INTERFACE="auto"
```

也可以手动指定：

```bash
WAN_INTERFACE="eth0"
```

脚本永久开启：

```text
net.ipv4.ip_forward = 1
```

并只管理自己的 iptables 链：

```text
OCSERV_FORWARD
OCSERV_NAT
OCSERV_BT_GUARD
OCSERV_DNAT
OCSERV_DNAT_FORWARD
```

不会执行危险操作：

```bash
iptables -t nat -F POSTROUTING
iptables -F FORWARD
iptables -P FORWARD ACCEPT
```

立即恢复网络规则：

```bash
ocserv-manager network-apply
```

查看：

```bash
iptables -nvL OCSERV_FORWARD
iptables -t nat -nvL OCSERV_NAT
```

---

## 2. VPN 用户自动限速

脚本持续识别：

```text
vpns0
vpns1
vpns2
...
```

并自动应用 HTB + IFB。

默认限速：

```text
50mbit
```

修改限速：

```bash
ocserv-manager set-rate 80mbit
```

支持格式：

```text
500kbit
20mbit
50mbit
100mbit
1gbit
```

查看规则：

```bash
tc -s qdisc show dev vpns0
tc -s class show dev vpns0
tc -s qdisc show dev ifb0
tc -s class show dev ifb0
```

正常应看到：

```text
qdisc htb 1: root
class htb 1:10 root rate 50Mbit ceil 50Mbit
qdisc ingress ffff:
```

### 限速架构说明

每个 `vpnsN` 的 root HTB 是独立的。

所有入口流量会重定向到共享 `ifb0`，因此：

- `vpnsN` root HTB：逐接口限速
- `ifb0`：共享入口总量限制

---

## 3. 宽松 BT/P2P 风险控制

默认参数：

```text
单个 VPN IP 最大并发 TCP：350
单个 VPN IP TCP 新建连接：80 次/秒
突发允许：160
```

还会拦截：

```text
6881-6999
1337
2710
4444
6969
8999
16881
51413
BitTorrent protocol 握手
```

启用：

```bash
ocserv-manager bt enable
```

停用：

```bash
ocserv-manager bt disable
```

查看命中数量：

```bash
iptables -nvL OCSERV_BT_GUARD
```

### 注意

现代 BT 可以使用随机端口、加密连接、UDP DHT、HTTPS、端口复用等。该模块只能降低风险，不能保证完全识别所有 P2P 流量。

---

## 4. 公网端口映射

端口映射是把 VPS 的固定公网端口转发给某个 VPN 用户。

例如：

```text
172.238.12.241:33891
        ↓
192.168.1.129:3389
```

添加 TCP 映射：

```bash
ocserv-manager port add tcp 33891 192.168.1.129 3389
```

添加 UDP：

```bash
ocserv-manager port add udp 40001 192.168.1.129 40001
```

添加 TCP + UDP：

```bash
ocserv-manager port add both 40001 192.168.1.129 40001
```

限制来源 IP：

```bash
ocserv-manager port add tcp 50001 192.168.1.129 22 \
  203.0.113.10/32 "管理员 SSH"
```

查看 / 删除：

```bash
ocserv-manager port list
ocserv-manager port delete tcp 33891
```

配置文件：

```text
/etc/ocserv-manager/port-mappings.tsv
```

字段：状态、协议、公网端口、VPN IP、目标端口、来源 CIDR、备注。

当前没有映射时，列表只显示表头，没有数据行。这不影响 VPN 用户正常上网（上网使用临时 NAT 源端口）。

---

## 5. NAT 历史审计

审计模块使用 `conntrack` 记录 NAT 会话元数据，写入 SQLite。

保存字段：

```text
连接开始时间
连接结束时间
协议
VPN 内网 IP
VPN 内网源端口
公网出口 IP
公网 NAT 源端口
目标 IP
目标端口
```

数据库：

```text
/var/lib/ocserv-manager/audit.db
```

表：

```text
nat_sessions
```

一条连接只保存一行：连接建立时插入，结束时更新结束时间。

### 默认过滤

默认过滤私网/广播/组播/环回/链路本地目标，以及配置中的 DNS 服务器 53/853 流量。不会过滤公网 `443`。

关闭 DNS 过滤：

```bash
sed -i 's/^AUDIT_IGNORE_DNS=.*/AUDIT_IGNORE_DNS="no"/' \
  /etc/ocserv-manager/config
systemctl restart ocserv-audit.service
```

关闭私网目标过滤：

```bash
sed -i \
  's/^AUDIT_IGNORE_NONPUBLIC_DESTINATIONS=.*/AUDIT_IGNORE_NONPUBLIC_DESTINATIONS="no"/' \
  /etc/ocserv-manager/config
systemctl restart ocserv-audit.service
```

---

## 6. VPN 用户名会话关联

默认命令：

```bash
docker exec ocserv occtl -j show users
```

脚本读取 `Username` / `IPv4`，写入：

```text
/var/lib/ocserv-manager/active-sessions.tsv
```

查看：

```bash
cat /var/lib/ocserv-manager/active-sessions.tsv
```

若容器名不是 `ocserv`，修改配置中的 `OCCTL_COMMAND` 后：

```bash
systemctl restart ocserv-session-audit.service
```

---

## 7. 历史投诉查询

查询至少需要：事件时间、公网源端口、协议。推荐再提供目标 IP / 目标端口。

时间格式建议：

```text
YYYY-MM-DD HH:MM:SS 时区
```

例如北京时间：

```text
2026-08-02 15:50:00 +0800
```

基础查询：

```bash
ocserv-manager audit lookup \
  --time "2026-08-02 15:50:00 +0800" \
  --public-port 49758 \
  --protocol tcp
```

精确查询：

```bash
ocserv-manager audit lookup \
  --time "2026-08-02 15:50:00 +0800" \
  --public-port 49758 \
  --protocol tcp \
  --destination 17.253.71.150 \
  --destination-port 443
```

扩大时间容差（默认前后 120 秒）：

```bash
ocserv-manager audit lookup \
  --time "2026-08-02 15:50:00 +0800" \
  --public-port 49758 \
  --protocol tcp \
  --tolerance 300
```

---

## 8. 查看审计数据库状态

```bash
ocserv-manager audit stats
```

查看最近 20 条：

```bash
sqlite3 -header -column /var/lib/ocserv-manager/audit.db '
SELECT
  datetime(start_epoch,"unixepoch") AS start_utc,
  datetime(end_epoch,"unixepoch") AS end_utc,
  protocol,
  vpn_ip,
  vpn_port,
  public_ip,
  public_port,
  destination_ip,
  destination_port
FROM nat_sessions
ORDER BY id DESC
LIMIT 20;
'
```

若本地仍有历史 CSV 导出需要导入当前库，可使用脚本自带的：

```bash
ocserv-manager audit migrate-csv
```

---

## 9. 自动保留 31 天

服务：

```text
ocserv-audit-maintenance.service
ocserv-audit-maintenance.timer
```

每天自动删除超期记录、WAL checkpoint、优化索引。

手动维护：

```bash
ocserv-manager audit maintenance
```

修改保留天数：`AUDIT_RETENTION_DAYS`（配置文件）。

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

示例：

```bash
systemctl status ocserv-limit.service --no-pager
journalctl -u ocserv-audit.service -n 50 --no-pager
```

---

# 常见问题

## `Change operation not supported by specified qdisc`

可停止限速服务后清理 `vpns*` / `ifb0` 的 qdisc，再重启 `ocserv-limit.service`。

## `Exclusivity flag on, cannot modify`

说明有其他进程同时修改 qdisc。确认仅运行：

```bash
pgrep -af 'ocserv-manager limit-daemon'
```

## `OCCTL_COMMAND 执行失败`

测试：

```bash
docker exec ocserv occtl -j show users
```

并核对配置中的 `OCCTL_COMMAND`，然后重启 `ocserv-session-audit.service`。

## 当前端口映射列表为空

只有表头、没有数据，表示没有固定公网端口映射；不影响用户上网。

## 如何查看用户当前 NAT 端口

```bash
docker exec ocserv occtl -j show users |
jq -r '.[] | [.Username, .IPv4] | @tsv'

conntrack -L -s 192.168.1.129 -o extended
```

## 为什么公网端口与 VPN 源端口相同

MASQUERADE 通常优先保留原始源端口；冲突时系统才可能换端口。

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

确认版本：

```bash
grep '^VERSION=' /usr/local/sbin/ocserv-manager
```

更新不会主动删除：

```text
/etc/ocserv-manager/
/var/lib/ocserv-manager/
/var/log/ocserv-manager/
```

---

# 卸载

```bash
ocserv-manager uninstall
```

卸载会删除 systemd 单元、`/usr/local/sbin/ocserv-manager`、本项目 iptables 链、tc 限速规则、sysctl 与 logrotate 配置。

默认保留配置与审计数据目录；确认不需要后再手动删除：

```bash
rm -rf /etc/ocserv-manager
rm -rf /var/lib/ocserv-manager
rm -rf /var/log/ocserv-manager
```

---

# 安全与合规说明

本工具保存连接时间、协议、VPN/公网 NAT 地址端口、目标地址端口、VPN 用户名会话映射。

不保存网页内容、密码、聊天内容、HTTPS 明文、下载文件或完整数据包。

审计结果应结合投诉时间、公网 IP、公网源端口、协议、目标等信息复核，不应仅依赖单一字段。

---

# License

MIT License
