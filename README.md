# ocserv-manager

一个面向 **ocserv / ocserv-docker** 的单文件服务器网络管理器，整合：

- VPN NAT 与 FORWARD 自动修复
- 默认公网出口网卡自动识别
- `vpns0、vpns1...` 自动限速
- 宽松 BT/P2P 风险控制
- 公网端口映射到指定 VPN 用户
- 历史 NAT 映射审计
- VPN 内网 IP 与用户名会话记录
- 31 天日志轮转与压缩
- systemd 自动启动和故障恢复

限速部分保留了原 [`limit_manager`](https://github.com/jackzhang-superman/limit_manager) 的 HTB + IFB 思路，但统一改为 systemd 管理。

> 这是网络运维与滥用投诉追溯工具，不保存数据包内容、访问内容、密码或下载文件，只保存连接元数据。

## 目录结构

```text
ocserv-manager/
├── ocserv-manager.sh
├── README.md
└── LICENSE
```

## 功能模块

### 1. NAT 和转发自动恢复

解决以下情况下 VPN 已连接但无法访问互联网的问题：

- VPS 重启
- Docker 重启
- 网络断开后恢复
- iptables 规则被其他服务重载
- 默认公网网卡重新出现

脚本自动读取：

```bash
ip -4 route show default
```

并从默认路由的 `dev` 字段识别公网出口网卡。

脚本只维护独立链：

```text
OCSERV_FORWARD
OCSERV_NAT
OCSERV_BT_GUARD
OCSERV_DNAT
OCSERV_DNAT_FORWARD
```

不会执行：

```bash
iptables -t nat -F POSTROUTING
iptables -F FORWARD
iptables -P FORWARD ACCEPT
```

### 2. 自动限速

持续发现：

```text
vpns0
vpns1
vpns2
...
```

并为新接口自动应用 HTB + IFB 限速。

默认：

```text
50mbit
```

注意：每个 `vpnsN` 的 root HTB 是独立的，但所有入口流量重定向到共享 `ifb0`，因此 IFB 方向是共享总上限。这与旧版 `limit_manager` 的设计一致。

### 3. 宽松 BT 风险控制

默认启用：

```text
单个 VPN IP 最大并发 TCP：350
单个 VPN IP TCP 新建连接：80/秒
突发允许：160
```

并拦截：

```text
传统 BT 端口 6881-6999
常见 BT/Tracker 端口
标准 BitTorrent protocol 握手特征
```

这不是“封禁所有 UDP”或“封禁所有高端口”，目的是降低 BT 版权投诉风险，同时尽量减少对网页、直播、视频和普通下载的影响。

现代 BT 可以使用随机端口和加密协议，因此此模块只能降低风险，不能保证识别全部 P2P 流量。

### 4. 历史 NAT 审计

使用 `conntrack` 事件记录：

```text
事件时间
TCP/UDP
VPN 内网 IP 和源端口
公网出口 IP 和 NAT 源端口
远程目标 IP 和端口
```

日志示例：

```text
epoch,event,protocol,vpn_ip,vpn_port,public_ip,public_port,destination_ip,destination_port
1785637831,NEW,tcp,192.168.1.37,51413,45.59.184.29,42671,198.51.100.20,51413
```

收到投诉后，可以通过：

```text
事件时间 + 公网源端口 + 协议
```

反查 VPN 内网 IP。

最好同时提供：

```text
目标 IP + 目标端口
```

因为公网 NAT 源端口会被重复使用，仅凭端口无法可靠定位历史用户。

### 5. 用户名会话审计

脚本定期运行 `occtl -j show users`，保存：

```text
开始时间
结束时间
VPN 内网 IP
用户名
```

然后把 NAT 日志中的 VPN IP 与当时在线用户关联。

如果 ocserv 在 Docker 容器中，需要修改：

```bash
OCCTL_COMMAND="docker exec 容器名 occtl -j show users"
```

例如：

```bash
OCCTL_COMMAND="docker exec ocserv occtl -j show users"
```

不同 ocserv 版本的 JSON 字段可能不同。安装后务必先测试该命令能否正常输出用户名和 VPN IP。

## 系统要求

建议系统：

- Debian 11/12/13
- Ubuntu 20.04/22.04/24.04
- systemd
- iptables
- ocserv 或 ocserv-docker

安装依赖：

```bash
apt update
apt install -y \
  iproute2 iptables kmod conntrack jq coreutils \
  python3 logrotate
```

内核需要支持：

```text
HTB
IFB
connlimit
hashlimit
xt_string（可选）
conntrack events
```

检查 conntrack 事件支持：

```bash
conntrack -E
```

按 `Ctrl+C` 退出。

## 一键下载安装

推荐直接从 GitHub Raw 地址下载到 `/root/ocserv-manager`：

```bash
mkdir -p /root/ocserv-manager && wget -N --no-check-certificate   -P /root/ocserv-manager   https://raw.githubusercontent.com/jackzhang-superman/ocserv-manager/main/ocserv-manager.sh && chmod +x /root/ocserv-manager/ocserv-manager.sh && /root/ocserv-manager/ocserv-manager.sh install
```

也可以使用更短的一行命令：

```bash
wget -N --no-check-certificate   -P /root   https://raw.githubusercontent.com/jackzhang-superman/ocserv-manager/main/ocserv-manager.sh && chmod +x /root/ocserv-manager.sh && /root/ocserv-manager.sh install
```

> GitHub 仓库中的脚本文件名必须是 `ocserv-manager.sh`，分支必须是 `main`。如果你的默认分支是 `master`，请把 URL 中的 `main` 改为 `master`。

安装完成后，脚本会复制为：

```text
/usr/local/sbin/ocserv-manager
```

以后直接运行：

```bash
ocserv-manager
```

### 更新脚本

重新执行下载命令即可利用 `wget -N` 检查远程文件是否更新：

```bash
wget -N --no-check-certificate   -P /root/ocserv-manager   https://raw.githubusercontent.com/jackzhang-superman/ocserv-manager/main/ocserv-manager.sh
```

下载完成后重新安装，以更新 `/usr/local/sbin/ocserv-manager` 和 systemd 服务：

```bash
chmod +x /root/ocserv-manager/ocserv-manager.sh
/root/ocserv-manager/ocserv-manager.sh install
```

现有配置文件和历史日志不会因为重新安装而被删除。

默认配置：

```text
VPN 网段：192.168.1.0/24
VPN 接口：vpns0、vpns1...
公网网卡：自动识别
用户限速：50mbit
网络规则自检：60 秒
BT 风险控制：启用
NAT 审计：启用
用户名会话审计：启用
日志保留：31 天
```

## 自定义安装

```bash
sudo \
VPN_SUBNET=192.168.1.0/24 \
WAN_INTERFACE=auto \
RATE=50mbit \
BT_CONN_LIMIT=350 \
BT_NEW_RATE=80/second \
BT_NEW_BURST=160 \
OCCTL_COMMAND='docker exec ocserv occtl -j show users' \
/root/ocserv-manager/ocserv-manager.sh install
```

## 从旧版 limit_manager 迁移

安装前先停止旧守护程序，避免两个进程同时修改 `tc`：

```bash
supervisorctl stop watch_vpns_limit 2>/dev/null || true
systemctl disable --now vpns-limit.service 2>/dev/null || true
pkill -f watch_vpns_limit.sh 2>/dev/null || true
```

确认：

```bash
ps aux | grep '[w]atch_vpns_limit'
```

无输出后安装新版。

## 管理菜单

```bash
sudo ocserv-manager
```

菜单：

```text
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
```

## 配置文件

```text
/etc/ocserv-manager/config
```

关键配置：

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

SESSION_AUDIT_ENABLED="yes"
SESSION_SCAN_INTERVAL="30"
OCCTL_COMMAND="docker exec ocserv occtl -j show users"
```

修改后执行：

```bash
systemctl daemon-reload
systemctl restart ocserv-network.service
systemctl restart ocserv-limit.service
systemctl restart ocserv-audit.service
systemctl restart ocserv-session-audit.service
```

如果修改了定时器间隔，需要重新运行安装命令，或者手动修改：

```text
/etc/systemd/system/ocserv-network.timer
```

## 端口映射

添加 TCP 映射：

```bash
ocserv-manager port add tcp 33891 192.168.1.10 3389
```

含来源限制：

```bash
ocserv-manager port add tcp 50001 192.168.1.11 22 \
  203.0.113.10/32 "管理员 SSH"
```

添加 TCP + UDP：

```bash
ocserv-manager port add both 40001 192.168.1.12 40001
```

查看：

```bash
ocserv-manager port list
```

删除：

```bash
ocserv-manager port delete tcp 33891
```

配置保存在：

```text
/etc/ocserv-manager/port-mappings.tsv
```

字段：

```text
状态  协议  公网端口  VPN_IP  目标端口  来源CIDR  备注
```

## 修改限速

```bash
ocserv-manager set-rate 80mbit
```

查看 tc：

```bash
tc -s qdisc show dev vpns0
tc -s class show dev vpns0
tc -s qdisc show dev ifb0
tc -s class show dev ifb0
```

## BT 风险控制

启用：

```bash
ocserv-manager bt enable
```

停用：

```bash
ocserv-manager bt disable
```

查看命中数：

```bash
iptables -nvL OCSERV_BT_GUARD
```

## 历史审计查询

版权投诉中通常会提供：

- 事件时间
- 你的服务器公网 IP
- 公网源端口
- TCP 或 UDP
- 目标 IP
- 目标端口

查询：

```bash
ocserv-manager audit lookup \
  --time "2026-08-02 10:30:00 +0800" \
  --public-port 42671 \
  --protocol tcp
```

更精确：

```bash
ocserv-manager audit lookup \
  --time "2026-08-02 10:30:00 +0800" \
  --public-port 42671 \
  --protocol tcp \
  --destination 198.51.100.20 \
  --destination-port 51413
```

默认时间容差为前后 120 秒。可扩大：

```bash
ocserv-manager audit lookup \
  --time "2026-08-02 10:30:00 +0800" \
  --public-port 42671 \
  --protocol tcp \
  --tolerance 300
```

查询结果会显示：

```text
记录时间
协议
公网 IP:端口
VPN 内网 IP:端口
远程目标 IP:端口
当时的 VPN 用户名
```

## 时区说明

审计日志内部统一保存 Unix epoch 和 UTC，避免服务器时区变化导致歧义。

查询时应明确包含投诉时间的时区：

```text
2026-08-02 10:30:00 +0800
2026-08-01 18:30:00 -0800
```

不要只输入模糊的“晚上十点”。

## 日志位置与保留

NAT 日志：

```text
/var/log/ocserv-manager/audit/
```

用户会话日志：

```text
/var/log/ocserv-manager/sessions/
```

默认使用 logrotate：

```text
每天轮转
保留 31 份
gzip 压缩
超过保留期自动删除
```

注意：Linux `logrotate rotate 31` 表示保留 31 个轮转文件。由于脚本本身按 UTC 日期生成文件，通常相当于约一个月，但并非严格到秒的 31 天删除策略。

## 审计限制

1. 只能查询安装并启动审计服务之后发生的连接，无法恢复安装前已经消失的 NAT 映射。
2. 投诉时间若不准确，应增大时间容差并结合目标 IP/端口筛选。
3. 用户名关联依赖 `OCCTL_COMMAND` 正常输出。
4. ocserv 或服务器重启期间，用户名会话开始时间可能存在一个扫描周期的误差。
5. 如果多个出口、公网 IP、策略路由或多级 NAT 同时存在，应进行专门测试。
6. conntrack 表满、内核未开启事件通知或审计服务停止，都会造成记录缺失。
7. 此工具用于辅助定位，不应把单一日志结果当作无需复核的绝对证据。

## 检查服务

```bash
systemctl status ocserv-network.timer --no-pager
systemctl status ocserv-limit.service --no-pager
systemctl status ocserv-audit.service --no-pager
systemctl status ocserv-session-audit.service --no-pager
```

查看日志：

```bash
journalctl -u ocserv-network.service -n 50 --no-pager
journalctl -u ocserv-limit.service -n 50 --no-pager
journalctl -u ocserv-audit.service -n 50 --no-pager
journalctl -u ocserv-session-audit.service -n 50 --no-pager
```

## 验证用户名读取

Docker 示例：

```bash
docker exec ocserv occtl -j show users | jq .
```

确认输出中包含用户名和 VPN IP 后，再检查：

```bash
tail -f /var/lib/ocserv-manager/active-sessions.tsv
```

如果为空，编辑：

```bash
nano /etc/ocserv-manager/config
```

调整：

```bash
OCCTL_COMMAND="docker exec 正确的容器名 occtl -j show users"
```

然后：

```bash
systemctl restart ocserv-session-audit.service
journalctl -u ocserv-session-audit.service -n 50 --no-pager
```

## 安全建议

端口映射 SSH、RDP 等管理端口时，尽量限制来源 CIDR：

```bash
ocserv-manager port add tcp 50001 192.168.1.10 22 \
  203.0.113.10/32 "仅管理员访问"
```

不要将管理端口无条件开放给整个互联网。

## 卸载

```bash
ocserv-manager uninstall
```

卸载会删除：

- systemd 服务
- 管理脚本
- 项目 iptables 链
- tc 限速规则
- sysctl 和 logrotate 配置

为了避免误删审计证据，默认保留：

```text
/etc/ocserv-manager/
/var/log/ocserv-manager/
/var/lib/ocserv-manager/
```

确认不再需要后可手动删除。

## License

MIT

## `Change operation not supported by specified qdisc`

如果日志出现：

```text
Error: Change operation not supported by specified qdisc.
ocserv-limit.service: Main process exited
```

这是因为部分内核或 `iproute2` 版本不允许对 `ingress` qdisc 执行 `replace`。新版脚本已经改为：

```bash
tc qdisc del dev vpnsN ingress 2>/dev/null || true
tc qdisc add dev vpnsN handle ffff: ingress
```

更新脚本后执行：

```bash
systemctl stop ocserv-limit.service

wget -N --no-check-certificate \
  -P /root/ocserv-manager \
  https://raw.githubusercontent.com/jackzhang-superman/limit_manager/main/ocserv-manager.sh

chmod +x /root/ocserv-manager/ocserv-manager.sh
/root/ocserv-manager/ocserv-manager.sh install

systemctl reset-failed ocserv-limit.service
systemctl restart ocserv-limit.service
systemctl status ocserv-limit.service --no-pager
```

检查限速规则：

```bash
tc -s qdisc show dev vpns0
tc -s class show dev vpns0
tc -s qdisc show dev ifb0
tc -s class show dev ifb0
```


## 限速服务仍循环报 qdisc 错误

如果修复 `ingress replace` 后仍出现：

```text
Error: Change operation not supported by specified qdisc.
```

通常说明 `vpnsN` 或 `ifb0` 上残留了旧脚本创建的其他 root qdisc，导致 HTB class 无法挂载。

v2.0.1 开始不再对 root qdisc 和 class 使用 `replace`，而是删除旧层级并重新创建：

```bash
tc qdisc del dev vpnsN root
tc qdisc add dev vpnsN root handle 1: htb default 10
tc class add dev vpnsN parent 1: classid 1:10 htb rate 50mbit ceil 50mbit
```

IFB 同样会重新创建。更新前先停止旧服务：

```bash
systemctl stop ocserv-limit.service
pkill -f 'ocserv-manager limit-daemon' 2>/dev/null || true
```

确认下载的源文件与安装文件都已更新：

```bash
grep '^VERSION=' /root/ocserv-manager/ocserv-manager.sh
grep '^VERSION=' /usr/local/sbin/ocserv-manager
```

两处都应显示：

```text
VERSION="2.0.1"
```

重新安装并清理旧 qdisc：

```bash
/root/ocserv-manager/ocserv-manager.sh install

for dev in $(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -E '^vpns[0-9]+$'); do
  tc qdisc del dev "$dev" root 2>/dev/null || true
  tc qdisc del dev "$dev" ingress 2>/dev/null || true
done

tc qdisc del dev ifb0 root 2>/dev/null || true

systemctl reset-failed ocserv-limit.service
systemctl restart ocserv-limit.service
```
