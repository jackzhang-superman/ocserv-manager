#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM="ocserv-manager"
VERSION="2.2.0"

INSTALL_PATH="/usr/local/sbin/ocserv-manager"
CONFIG_DIR="/etc/ocserv-manager"
CONFIG_FILE="${CONFIG_DIR}/config"
PORT_MAP_FILE="${CONFIG_DIR}/port-mappings.tsv"
STATE_DIR="/var/lib/ocserv-manager"
SESSION_STATE="${STATE_DIR}/active-sessions.tsv"
AUDIT_DB="${STATE_DIR}/audit.db"
LIMIT_LOCK_FILE="/run/lock/ocserv-manager-limit.lock"
LOG_DIR="/var/log/ocserv-manager"
AUDIT_DIR="${LOG_DIR}/audit"
SESSION_DIR="${LOG_DIR}/sessions"
SYSCTL_FILE="/etc/sysctl.d/99-ocserv-manager.conf"
LOGROTATE_FILE="/etc/logrotate.d/ocserv-manager"

NETWORK_SERVICE="/etc/systemd/system/ocserv-network.service"
NETWORK_TIMER="/etc/systemd/system/ocserv-network.timer"
LIMIT_SERVICE="/etc/systemd/system/ocserv-limit.service"
AUDIT_SERVICE="/etc/systemd/system/ocserv-audit.service"
SESSION_SERVICE="/etc/systemd/system/ocserv-session-audit.service"
AUDIT_MAINT_SERVICE="/etc/systemd/system/ocserv-audit-maintenance.service"
AUDIT_MAINT_TIMER="/etc/systemd/system/ocserv-audit-maintenance.timer"

FORWARD_CHAIN="OCSERV_FORWARD"
BT_CHAIN="OCSERV_BT_GUARD"
DNAT_FILTER_CHAIN="OCSERV_DNAT_FORWARD"
NAT_CHAIN="OCSERV_NAT"
DNAT_CHAIN="OCSERV_DNAT"

log()  { printf '[%s] %s\n' "$PROGRAM" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$PROGRAM" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

require_root() {
    [[ "$EUID" -eq 0 ]] || die "请使用 root 权限运行。"
}

has() { command -v "$1" >/dev/null 2>&1; }

detect_iptables() {
    if has iptables; then command -v iptables
    elif [[ -x /usr/sbin/iptables ]]; then printf '%s\n' /usr/sbin/iptables
    else die "未找到 iptables。"
    fi
}

detect_wan_interface() {
    ip -4 route show default 2>/dev/null |
    awk '$1=="default"{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}'
}

detect_public_ipv4() {
    local wan="$1"
    ip -4 -o addr show dev "$wan" scope global 2>/dev/null |
    awk '{split($4,a,"/"); print a[1]; exit}'
}

load_config() {
    [[ -r "$CONFIG_FILE" ]] || die "配置不存在，请先执行：$PROGRAM install"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    : "${VPN_SUBNET:=192.168.1.0/24}"
    : "${VPN_INTERFACE_GLOB:=vpns+}"
    : "${VPN_INTERFACE_REGEX:=^vpns[0-9]+$}"
    : "${WAN_INTERFACE:=auto}"
    : "${RATE:=50mbit}"
    : "${IFB_DEVICE:=ifb0}"
    : "${LIMIT_SCAN_INTERVAL:=1}"
    : "${NETWORK_CHECK_INTERVAL:=60}"
    : "${BT_GUARD_ENABLED:=yes}"
    : "${BT_CONN_LIMIT:=350}"
    : "${BT_NEW_RATE:=80/second}"
    : "${BT_NEW_BURST:=160}"
    : "${BT_BLOCK_CLASSIC_PORTS:=yes}"
    : "${BT_STRING_MATCH:=yes}"
    : "${AUDIT_ENABLED:=yes}"
    : "${AUDIT_RETENTION_DAYS:=31}"
    : "${AUDIT_IGNORE_NONPUBLIC_DESTINATIONS:=yes}"
    : "${AUDIT_IGNORE_DNS:=yes}"
    : "${AUDIT_DNS_SERVERS:=8.8.8.8,8.8.4.4}"
    : "${SESSION_AUDIT_ENABLED:=yes}"
    : "${SESSION_SCAN_INTERVAL:=30}"
    : "${OCCTL_COMMAND:=docker exec ocserv occtl -j show users}"
    : "${IPTABLES_BIN:=/usr/sbin/iptables}"
}

validate_rate() {
    [[ "$1" =~ ^[1-9][0-9]*(kbit|mbit|gbit)$ ]]
}

list_vpn_interfaces() {
    ip -o link show |
    awk -F': ' '{print $2}' |
    sed 's/@.*//' |
    grep -E "$VPN_INTERFACE_REGEX" || true
}

ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$AUDIT_DIR" "$SESSION_DIR"
    chmod 700 "$CONFIG_DIR" "$STATE_DIR" "$LOG_DIR" "$AUDIT_DIR" "$SESSION_DIR"
    touch "$PORT_MAP_FILE"
    chmod 600 "$PORT_MAP_FILE"
}

resolve_wan() {
    local wan="$WAN_INTERFACE"
    [[ "$wan" == "auto" ]] && wan="$(detect_wan_interface)"
    [[ -n "$wan" ]] || die "无法识别 IPv4 默认公网出口网卡。"
    ip link show "$wan" >/dev/null 2>&1 || die "公网网卡不存在：$wan"
    printf '%s\n' "$wan"
}

ensure_chain_jump() {
    local table="$1" parent="$2" chain="$3" position="${4:-1}"
    local ipt="$IPTABLES_BIN"
    local targs=()
    [[ "$table" != "filter" ]] && targs=(-t "$table")

    while "$ipt" -w "${targs[@]}" -C "$parent" -j "$chain" 2>/dev/null; do
        "$ipt" -w "${targs[@]}" -D "$parent" -j "$chain"
    done
    "$ipt" -w "${targs[@]}" -I "$parent" "$position" -j "$chain"
}

apply_bt_rules() {
    local ipt="$IPTABLES_BIN"

    "$ipt" -w -N "$BT_CHAIN" 2>/dev/null || true
    "$ipt" -w -F "$BT_CHAIN"

    if [[ "$BT_GUARD_ENABLED" != "yes" ]]; then
        "$ipt" -w -A "$BT_CHAIN" -j RETURN
        return
    fi

    if [[ "$BT_BLOCK_CLASSIC_PORTS" == "yes" ]]; then
        "$ipt" -w -A "$BT_CHAIN" -s "$VPN_SUBNET" -p tcp --dport 6881:6999 \
            -j REJECT --reject-with tcp-reset
        "$ipt" -w -A "$BT_CHAIN" -s "$VPN_SUBNET" -p udp --dport 6881:6999 -j DROP

        "$ipt" -w -A "$BT_CHAIN" -s "$VPN_SUBNET" -p tcp \
            -m multiport --dports 1337,2710,4444,6969,8999,16881,51413 \
            -j REJECT --reject-with tcp-reset
        "$ipt" -w -A "$BT_CHAIN" -s "$VPN_SUBNET" -p udp \
            -m multiport --dports 1337,2710,4444,6969,8999,16881,51413 -j DROP
    fi

    if [[ "$BT_STRING_MATCH" == "yes" ]]; then
        if "$ipt" -m string -h >/dev/null 2>&1; then
            "$ipt" -w -A "$BT_CHAIN" -s "$VPN_SUBNET" -p tcp \
                -m string --algo bm --from 0 --to 256 \
                --hex-string '|13|BitTorrent protocol' \
                -j REJECT --reject-with tcp-reset
        else
            warn "内核缺少 xt_string，已跳过 BitTorrent 握手匹配。"
        fi
    fi

    "$ipt" -w -A "$BT_CHAIN" -s "$VPN_SUBNET" -p tcp --syn \
        -m connlimit --connlimit-above "$BT_CONN_LIMIT" --connlimit-mask 32 \
        -j REJECT --reject-with tcp-reset

    "$ipt" -w -A "$BT_CHAIN" -s "$VPN_SUBNET" -p tcp --syn \
        -m hashlimit --hashlimit-above "$BT_NEW_RATE" \
        --hashlimit-burst "$BT_NEW_BURST" \
        --hashlimit-mode srcip --hashlimit-srcmask 32 \
        --hashlimit-name ocserv_tcp_new -j DROP

    "$ipt" -w -A "$BT_CHAIN" -j RETURN
}

valid_mapping_line() {
    local enabled="$1" proto="$2" public_port="$3" vpn_ip="$4" target_port="$5" source_cidr="$6"
    [[ "$enabled" =~ ^(yes|no)$ ]] || return 1
    [[ "$proto" =~ ^(tcp|udp|both)$ ]] || return 1
    [[ "$public_port" =~ ^[0-9]+$ ]] && ((public_port >= 1 && public_port <= 65535)) || return 1
    [[ "$target_port" =~ ^[0-9]+$ ]] && ((target_port >= 1 && target_port <= 65535)) || return 1
    [[ "$vpn_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$source_cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]] || return 1
}

apply_port_mappings() {
    local wan="$1" public_ip="$2" ipt="$IPTABLES_BIN"

    "$ipt" -w -t nat -N "$DNAT_CHAIN" 2>/dev/null || true
    "$ipt" -w -t nat -F "$DNAT_CHAIN"
    "$ipt" -w -N "$DNAT_FILTER_CHAIN" 2>/dev/null || true
    "$ipt" -w -F "$DNAT_FILTER_CHAIN"

    local enabled proto public_port vpn_ip target_port source_cidr comment
    while IFS=$'\t' read -r enabled proto public_port vpn_ip target_port source_cidr comment; do
        [[ -z "${enabled:-}" || "$enabled" == \#* ]] && continue
        valid_mapping_line "$enabled" "$proto" "$public_port" "$vpn_ip" "$target_port" "$source_cidr" || {
            warn "跳过无效端口映射：$enabled $proto $public_port $vpn_ip $target_port $source_cidr"
            continue
        }
        [[ "$enabled" == "yes" ]] || continue

        local protocols=("$proto")
        [[ "$proto" == "both" ]] && protocols=(tcp udp)

        local p
        for p in "${protocols[@]}"; do
            "$ipt" -w -t nat -A "$DNAT_CHAIN" -i "$wan" -p "$p" \
                -s "$source_cidr" --dport "$public_port" \
                -j DNAT --to-destination "${vpn_ip}:${target_port}"

            "$ipt" -w -A "$DNAT_FILTER_CHAIN" -i "$wan" -o "$VPN_INTERFACE_GLOB" \
                -p "$p" -s "$source_cidr" -d "$vpn_ip" --dport "$target_port" \
                -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT

            "$ipt" -w -A "$DNAT_FILTER_CHAIN" -i "$VPN_INTERFACE_GLOB" -o "$wan" \
                -p "$p" -s "$vpn_ip" --sport "$target_port" -d "$source_cidr" \
                -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        done
    done < "$PORT_MAP_FILE"

    [[ -n "$public_ip" ]] || warn "未识别公网 IPv4；DNAT 仍按公网入口网卡工作。"
}

network_apply() {
    require_root
    load_config
    ensure_dirs

    local ipt="$IPTABLES_BIN" wan public_ip
    [[ -x "$ipt" ]] || die "iptables 不可执行：$ipt"
    wan="$(resolve_wan)"
    public_ip="$(detect_public_ipv4 "$wan")"

    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    "$ipt" -w -N "$FORWARD_CHAIN" 2>/dev/null || true
    "$ipt" -w -F "$FORWARD_CHAIN"

    apply_bt_rules
    apply_port_mappings "$wan" "$public_ip"

    # 顺序：BT 风险控制 -> DNAT 放行 -> VPN 普通出站 -> 返回流量。
    "$ipt" -w -A "$FORWARD_CHAIN" -j "$BT_CHAIN"
    "$ipt" -w -A "$FORWARD_CHAIN" -j "$DNAT_FILTER_CHAIN"
    "$ipt" -w -A "$FORWARD_CHAIN" -i "$VPN_INTERFACE_GLOB" -o "$wan" \
        -s "$VPN_SUBNET" -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT
    "$ipt" -w -A "$FORWARD_CHAIN" -i "$wan" -o "$VPN_INTERFACE_GLOB" \
        -d "$VPN_SUBNET" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    "$ipt" -w -t nat -N "$NAT_CHAIN" 2>/dev/null || true
    "$ipt" -w -t nat -F "$NAT_CHAIN"
    "$ipt" -w -t nat -A "$NAT_CHAIN" -s "$VPN_SUBNET" -o "$wan" -j MASQUERADE

    ensure_chain_jump filter FORWARD "$FORWARD_CHAIN" 1
    ensure_chain_jump nat PREROUTING "$DNAT_CHAIN" 1
    ensure_chain_jump nat POSTROUTING "$NAT_CHAIN" 1

    logger -t "$PROGRAM" "network applied vpn=$VPN_SUBNET wan=$wan public=${public_ip:-unknown}"
    log "网络、BT 风险控制和端口映射规则已应用。公网网卡：$wan"
}


network_inputs_fingerprint() {
    local wan="$1" public_ip="$2"
    {
        printf 'VPN_SUBNET=%s\n' "${VPN_SUBNET}"
        printf 'VPN_INTERFACE_GLOB=%s\n' "${VPN_INTERFACE_GLOB}"
        printf 'WAN_INTERFACE=%s\n' "${WAN_INTERFACE}"
        printf 'RESOLVED_WAN=%s\n' "${wan}"
        printf 'PUBLIC_IPV4=%s\n' "${public_ip:-}"
        printf 'BT_GUARD_ENABLED=%s\n' "${BT_GUARD_ENABLED}"
        printf 'BT_CONN_LIMIT=%s\n' "${BT_CONN_LIMIT}"
        printf 'BT_NEW_RATE=%s\n' "${BT_NEW_RATE}"
        printf 'BT_NEW_BURST=%s\n' "${BT_NEW_BURST}"
        printf 'BT_BLOCK_CLASSIC_PORTS=%s\n' "${BT_BLOCK_CLASSIC_PORTS}"
        printf 'BT_STRING_MATCH=%s\n' "${BT_STRING_MATCH}"
        printf '%s\n' '---PORT_MAP---'
        if [[ -r "$PORT_MAP_FILE" ]]; then
            # stable content hash (ignore blank trailing noise)
            sed '/^[[:space:]]*$/d' "$PORT_MAP_FILE"
        fi
    } | sha256sum | awk '{print $1}'
}

network_state_fingerprint() {
    local ipt="$IPTABLES_BIN"
    {
        printf '=== filter %s ===\n' "$FORWARD_CHAIN"
        "$ipt" -w -S "$FORWARD_CHAIN" 2>/dev/null || printf 'MISSING\n'
        printf '=== filter %s ===\n' "$BT_CHAIN"
        "$ipt" -w -S "$BT_CHAIN" 2>/dev/null || printf 'MISSING\n'
        printf '=== filter %s ===\n' "$DNAT_FILTER_CHAIN"
        "$ipt" -w -S "$DNAT_FILTER_CHAIN" 2>/dev/null || printf 'MISSING\n'
        printf '=== nat %s ===\n' "$NAT_CHAIN"
        "$ipt" -w -t nat -S "$NAT_CHAIN" 2>/dev/null || printf 'MISSING\n'
        printf '=== nat %s ===\n' "$DNAT_CHAIN"
        "$ipt" -w -t nat -S "$DNAT_CHAIN" 2>/dev/null || printf 'MISSING\n'
        if "$ipt" -w -C FORWARD -j "$FORWARD_CHAIN" 2>/dev/null; then
            printf 'JUMP filter FORWARD -> %s\n' "$FORWARD_CHAIN"
        else
            printf 'NOJUMP filter FORWARD -> %s\n' "$FORWARD_CHAIN"
        fi
        if "$ipt" -w -t nat -C PREROUTING -j "$DNAT_CHAIN" 2>/dev/null; then
            printf 'JUMP nat PREROUTING -> %s\n' "$DNAT_CHAIN"
        else
            printf 'NOJUMP nat PREROUTING -> %s\n' "$DNAT_CHAIN"
        fi
        if "$ipt" -w -t nat -C POSTROUTING -j "$NAT_CHAIN" 2>/dev/null; then
            printf 'JUMP nat POSTROUTING -> %s\n' "$NAT_CHAIN"
        else
            printf 'NOJUMP nat POSTROUTING -> %s\n' "$NAT_CHAIN"
        fi
    } | sha256sum | awk '{print $1}'
}

network_jumps_healthy() {
    local ipt="$IPTABLES_BIN"
    "$ipt" -w -n -L "$FORWARD_CHAIN" >/dev/null 2>&1 || return 1
    "$ipt" -w -n -L "$BT_CHAIN" >/dev/null 2>&1 || return 1
    "$ipt" -w -n -L "$DNAT_FILTER_CHAIN" >/dev/null 2>&1 || return 1
    "$ipt" -w -t nat -n -L "$NAT_CHAIN" >/dev/null 2>&1 || return 1
    "$ipt" -w -t nat -n -L "$DNAT_CHAIN" >/dev/null 2>&1 || return 1
    "$ipt" -w -C FORWARD -j "$FORWARD_CHAIN" 2>/dev/null || return 1
    "$ipt" -w -t nat -C PREROUTING -j "$DNAT_CHAIN" 2>/dev/null || return 1
    "$ipt" -w -t nat -C POSTROUTING -j "$NAT_CHAIN" 2>/dev/null || return 1
    return 0
}

network_ensure() {
    require_root
    load_config
    ensure_dirs

    local ipt="$IPTABLES_BIN" wan public_ip
    [[ -x "$ipt" ]] || die "iptables 不可执行：$ipt"
    wan="$(resolve_wan)"
    public_ip="$(detect_public_ipv4 "$wan")"

    local inputs_hash state_hash
    inputs_hash="$(network_inputs_fingerprint "$wan" "$public_ip")"
    state_hash="$(network_state_fingerprint)"

    local last_inputs_file="${STATE_DIR}/network-inputs.sha256"
    local last_state_file="${STATE_DIR}/network-state.sha256"
    local last_inputs="" last_state=""
    [[ -r "$last_inputs_file" ]] && last_inputs="$(tr -d '\r\n' < "$last_inputs_file")"
    [[ -r "$last_state_file" ]] && last_state="$(tr -d '\r\n' < "$last_state_file")"

    if [[ "$inputs_hash" == "$last_inputs" && "$state_hash" == "$last_state" ]] && network_jumps_healthy; then
        logger -t "$PROGRAM" "network unchanged skip wan=$wan"
        log "网络规则未变化，跳过重刷。"
        return 0
    fi

    network_apply

    # Re-resolve in case apply/logging path changed nothing material; refresh fingerprints.
    wan="$(resolve_wan)"
    public_ip="$(detect_public_ipv4 "$wan")"
    inputs_hash="$(network_inputs_fingerprint "$wan" "$public_ip")"
    state_hash="$(network_state_fingerprint)"
    printf '%s\n' "$inputs_hash" > "$last_inputs_file"
    printf '%s\n' "$state_hash" > "$last_state_file"
    chmod 600 "$last_inputs_file" "$last_state_file"
    logger -t "$PROGRAM" "network ensure applied wan=$wan"
}

ensure_ifb() {
    modprobe ifb numifbs=1 2>/dev/null || modprobe ifb 2>/dev/null || true
    if ! ip link show "$IFB_DEVICE" >/dev/null 2>&1; then
        ip link add "$IFB_DEVICE" type ifb 2>/dev/null || die "无法创建 $IFB_DEVICE"
    fi
    ip link set "$IFB_DEVICE" up
}

run_tc() {
    local description="$1"
    shift
    if ! "$@"; then
        logger -t "$PROGRAM" "tc failed: $description; command=$*"
        warn "tc 操作失败：$description"
        return 1
    fi
}

configure_ifb() {
    ensure_ifb
    tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
    run_tc "create IFB HTB root on $IFB_DEVICE" \
        tc qdisc add dev "$IFB_DEVICE" root handle 1: htb default 10
    run_tc "create IFB HTB class on $IFB_DEVICE" \
        tc class add dev "$IFB_DEVICE" parent 1: classid 1:10 \
        htb rate "$RATE" ceil "$RATE"
}

limit_interface() {
    local iface="$1"
    ip link show "$iface" >/dev/null 2>&1 || return 0

    mkdir -p "$(dirname "$LIMIT_LOCK_FILE")"
    exec 9>"$LIMIT_LOCK_FILE"
    flock -x 9

    ip link show "$iface" >/dev/null 2>&1 || {
        flock -u 9
        return 0
    }

    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc del dev "$iface" ingress 2>/dev/null || true

    if ! tc qdisc add dev "$iface" root handle 1: htb default 10 2>/tmp/ocserv-tc-error.$$; then
        if ! tc qdisc show dev "$iface" 2>/dev/null | grep -qE 'qdisc htb 1: root'; then
            logger -t "$PROGRAM" "tc failed: create HTB root on $iface; $(cat /tmp/ocserv-tc-error.$$ 2>/dev/null)"
            rm -f /tmp/ocserv-tc-error.$$
            flock -u 9
            return 1
        fi
    fi
    rm -f /tmp/ocserv-tc-error.$$

    run_tc "create HTB class on $iface" \
        tc class replace dev "$iface" parent 1: classid 1:10 \
        htb rate "$RATE" ceil "$RATE" || {
            flock -u 9
            return 1
        }

    tc qdisc del dev "$iface" ingress 2>/dev/null || true
    run_tc "create ingress qdisc on $iface" \
        tc qdisc add dev "$iface" handle ffff: ingress || {
            flock -u 9
            return 1
        }

    run_tc "redirect ingress from $iface to $IFB_DEVICE" \
        tc filter add dev "$iface" parent ffff: protocol all pref 10 u32 \
        match u32 0 0 action mirred egress redirect dev "$IFB_DEVICE" || {
            flock -u 9
            return 1
        }

    flock -u 9
}

limit_apply() {
    require_root
    load_config
    validate_rate "$RATE" || die "RATE 格式无效：$RATE"
    configure_ifb
    local iface
    while IFS= read -r iface; do
        [[ -n "$iface" ]] && limit_interface "$iface"
    done < <(list_vpn_interfaces)
    log "已对当前 vpns 接口应用限速：$RATE"
}

limit_daemon() {
    require_root
    load_config
    validate_rate "$RATE" || die "RATE 格式无效：$RATE"
    configure_ifb

    while true; do
        local iface
        while IFS= read -r iface; do
            [[ -n "$iface" ]] || continue
            if ! tc qdisc show dev "$iface" 2>/dev/null | grep -qE 'qdisc htb 1: root'; then
                limit_interface "$iface"
                logger -t "$PROGRAM" "rate applied iface=$iface rate=$RATE"
            fi
        done < <(list_vpn_interfaces)
        sleep "$LIMIT_SCAN_INTERVAL"
    done
}

limit_clear() {
    require_root
    load_config
    local iface
    while IFS= read -r iface; do
        [[ -n "$iface" ]] || continue
        tc qdisc del dev "$iface" root 2>/dev/null || true
        tc qdisc del dev "$iface" ingress 2>/dev/null || true
    done < <(list_vpn_interfaces)
    tc qdisc del dev "$IFB_DEVICE" root 2>/dev/null || true
    log "已清除 tc 限速规则。"
}

audit_db_init() {
    ensure_dirs
    sqlite3 "$AUDIT_DB" <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS nat_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    start_epoch INTEGER NOT NULL,
    end_epoch INTEGER,
    protocol TEXT NOT NULL CHECK(protocol IN ('tcp','udp')),
    vpn_ip TEXT NOT NULL,
    vpn_port INTEGER NOT NULL,
    public_ip TEXT NOT NULL,
    public_port INTEGER NOT NULL,
    destination_ip TEXT NOT NULL,
    destination_port INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_nat_public_lookup
ON nat_sessions(protocol, public_port, start_epoch, end_epoch);

CREATE INDEX IF NOT EXISTS idx_nat_destination_lookup
ON nat_sessions(destination_ip, destination_port, protocol, public_port);

CREATE INDEX IF NOT EXISTS idx_nat_vpn_lookup
ON nat_sessions(vpn_ip, start_epoch, end_epoch);
SQL
    chmod 600 "$AUDIT_DB" 2>/dev/null || true
}

audit_destination_allowed() {
    local dst_ip="$1" dst_port="$2" proto="$3"

    if [[ "$AUDIT_IGNORE_DNS" == "yes" ]] &&
       [[ "$dst_port" == "53" || "$dst_port" == "853" ]]; then
        local dns
        IFS=',' read -ra _dns_servers <<<"$AUDIT_DNS_SERVERS"
        for dns in "${_dns_servers[@]}"; do
            [[ "$dst_ip" == "$dns" ]] && return 1
        done
    fi

    [[ "$AUDIT_IGNORE_NONPUBLIC_DESTINATIONS" == "yes" ]] || return 0

    python3 - "$dst_ip" <<'PY'
import ipaddress
import sys

ip = ipaddress.ip_address(sys.argv[1])
blocked = (
    ip.is_private
    or ip.is_loopback
    or ip.is_link_local
    or ip.is_multicast
    or ip.is_unspecified
    or ip.is_reserved
)
raise SystemExit(1 if blocked else 0)
PY
}

parse_conntrack_line() {
    local line="$1"
    local proto event
    event="$(grep -oE '\[(NEW|DESTROY|UPDATE)\]' <<<"$line" | head -n1 | tr -d '[]' || true)"
    proto="$(awk '{for(i=1;i<=NF;i++)if($i=="tcp"||$i=="udp"){print $i;exit}}' <<<"$line")"
    [[ -n "$event" && -n "$proto" ]] || return 1

    mapfile -t srcs < <(grep -oE 'src=[^ ]+' <<<"$line" | cut -d= -f2)
    mapfile -t dsts < <(grep -oE 'dst=[^ ]+' <<<"$line" | cut -d= -f2)
    mapfile -t sports < <(grep -oE 'sport=[0-9]+' <<<"$line" | cut -d= -f2)
    mapfile -t dports < <(grep -oE 'dport=[0-9]+' <<<"$line" | cut -d= -f2)

    ((${#srcs[@]} >= 2 && ${#dsts[@]} >= 2 &&
       ${#sports[@]} >= 2 && ${#dports[@]} >= 2)) || return 1

    local vpn_ip="${srcs[0]}" vpn_port="${sports[0]}"
    local dst_ip="${dsts[0]}" dst_port="${dports[0]}"
    local public_ip="${dsts[1]}" public_port="${dports[1]}"

    python3 - "$vpn_ip" "$VPN_SUBNET" <<'PY' >/dev/null 2>&1 || return 1
import ipaddress
import sys
raise SystemExit(
    0 if ipaddress.ip_address(sys.argv[1])
    in ipaddress.ip_network(sys.argv[2], strict=False)
    else 1
)
PY

    [[ "$public_ip" != "$vpn_ip" ]] || return 1
    audit_destination_allowed "$dst_ip" "$dst_port" "$proto" || return 1

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date -u +%s)" "$event" "$proto" "$vpn_ip" "$vpn_port" \
        "$public_ip" "$public_port" "$dst_ip" "$dst_port"
}

audit_store_record() {
    local record="$1"
    local epoch event proto vpn_ip vpn_port public_ip public_port dst_ip dst_port
    IFS=, read -r epoch event proto vpn_ip vpn_port public_ip public_port dst_ip dst_port <<<"$record"

    if [[ "$event" == "NEW" ]]; then
        sqlite3 "$AUDIT_DB" <<SQL
PRAGMA busy_timeout=5000;
INSERT INTO nat_sessions(
    start_epoch, protocol, vpn_ip, vpn_port,
    public_ip, public_port, destination_ip, destination_port
) VALUES (
    $epoch, '$proto', '$vpn_ip', $vpn_port,
    '$public_ip', $public_port, '$dst_ip', $dst_port
);
SQL
    elif [[ "$event" == "DESTROY" ]]; then
        sqlite3 "$AUDIT_DB" <<SQL
PRAGMA busy_timeout=5000;
UPDATE nat_sessions
SET end_epoch=$epoch
WHERE id=(
    SELECT id FROM nat_sessions
    WHERE end_epoch IS NULL
      AND protocol='$proto'
      AND vpn_ip='$vpn_ip'
      AND vpn_port=$vpn_port
      AND public_ip='$public_ip'
      AND public_port=$public_port
      AND destination_ip='$dst_ip'
      AND destination_port=$dst_port
    ORDER BY start_epoch DESC
    LIMIT 1
);
SQL
    fi
}

audit_snapshot_current() {
    conntrack -L -o extended 2>/dev/null |
    while IFS= read -r line; do
        local record
        record="$(parse_conntrack_line "[NEW] $line" || true)"
        [[ -n "$record" ]] && audit_store_record "$record"
    done
}

audit_close_open() {
    require_root
    load_config
    audit_db_init
    sqlite3 "$AUDIT_DB" \
        "UPDATE nat_sessions SET end_epoch=strftime('%s','now') WHERE end_epoch IS NULL;"
}

audit_daemon() {
    require_root
    load_config
    ensure_dirs
    [[ "$AUDIT_ENABLED" == "yes" ]] || { log "审计未启用。"; sleep infinity; }
    has conntrack || die "缺少 conntrack。"
    has sqlite3 || die "缺少 sqlite3。"

    audit_db_init

    # Close uncertain records left by an earlier daemon instance, then take a
    # fresh snapshot of currently active conntrack entries.
    sqlite3 "$AUDIT_DB" \
        "UPDATE nat_sessions SET end_epoch=strftime('%s','now') WHERE end_epoch IS NULL;"
    audit_snapshot_current

    while true; do
        stdbuf -oL conntrack -E -e NEW,DESTROY 2>/dev/null |
        while IFS= read -r line; do
            local record
            record="$(parse_conntrack_line "$line" || true)"
            [[ -n "$record" ]] && audit_store_record "$record"
        done
        warn "conntrack 事件流已结束，5 秒后重启。"
        sleep 5
    done
}

audit_maintenance() {
    require_root
    load_config
    audit_db_init

    local cutoff
    cutoff="$(date -u -d "-${AUDIT_RETENTION_DAYS} days" +%s)"

    sqlite3 "$AUDIT_DB" <<SQL
PRAGMA busy_timeout=5000;
DELETE FROM nat_sessions
WHERE COALESCE(end_epoch,start_epoch) < $cutoff;
PRAGMA wal_checkpoint(TRUNCATE);
PRAGMA optimize;
SQL
    log "审计数据库维护完成，已清理 ${AUDIT_RETENTION_DAYS} 天前记录。"
}

audit_migrate_csv() {
    require_root
    load_config
    audit_db_init

    python3 - "$AUDIT_DIR" "$AUDIT_DB" <<'PY'
import csv
import gzip
import pathlib
import sqlite3
import sys

audit_dir = pathlib.Path(sys.argv[1])
db_path = sys.argv[2]
conn = sqlite3.connect(db_path)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA synchronous=NORMAL")

files = sorted(list(audit_dir.glob("nat-*.csv")) + list(audit_dir.glob("nat-*.csv.gz")))
inserted = closed = 0

for path in files:
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8", errors="replace", newline="") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            try:
                values = (
                    int(row["epoch"]), row["protocol"], row["vpn_ip"],
                    int(row["vpn_port"]), row["public_ip"],
                    int(row["public_port"]), row["destination_ip"],
                    int(row["destination_port"]),
                )
            except (KeyError, TypeError, ValueError):
                continue

            if row.get("event") == "NEW":
                conn.execute(
                    """
                    INSERT INTO nat_sessions(
                        start_epoch,protocol,vpn_ip,vpn_port,
                        public_ip,public_port,destination_ip,destination_port
                    ) VALUES (?,?,?,?,?,?,?,?)
                    """,
                    values,
                )
                inserted += 1
            elif row.get("event") == "DESTROY":
                cur = conn.execute(
                    """
                    SELECT id FROM nat_sessions
                    WHERE end_epoch IS NULL
                      AND protocol=? AND vpn_ip=? AND vpn_port=?
                      AND public_ip=? AND public_port=?
                      AND destination_ip=? AND destination_port=?
                    ORDER BY start_epoch DESC LIMIT 1
                    """,
                    (
                        row["protocol"], row["vpn_ip"], int(row["vpn_port"]),
                        row["public_ip"], int(row["public_port"]),
                        row["destination_ip"], int(row["destination_port"]),
                    ),
                ).fetchone()
                if cur:
                    conn.execute(
                        "UPDATE nat_sessions SET end_epoch=? WHERE id=?",
                        (int(row["epoch"]), cur[0]),
                    )
                    closed += 1

conn.commit()
conn.close()
print(f"CSV migration complete: inserted={inserted}, closed={closed}, files={len(files)}")
PY
}

audit_stats() {
    require_root
    load_config
    audit_db_init
    sqlite3 -header -column "$AUDIT_DB" <<'SQL'
SELECT
    COUNT(*) AS total_sessions,
    SUM(end_epoch IS NULL) AS open_sessions,
    datetime(MIN(start_epoch),'unixepoch') AS oldest_utc,
    datetime(MAX(start_epoch),'unixepoch') AS newest_utc
FROM nat_sessions;
SQL
    du -h "$AUDIT_DB" "$AUDIT_DB-wal" 2>/dev/null || true
}

session_file_today() {
    printf '%s/sessions-%s.csv\n' "$SESSION_DIR" "$(date -u +%F)"
}

parse_conntrack_line() {
    local line="$1"
    local proto event
    event="$(grep -oE '\[(NEW|DESTROY|UPDATE)\]' <<<"$line" | head -n1 | tr -d '[]' || true)"
    proto="$(awk '{for(i=1;i<=NF;i++)if($i=="tcp"||$i=="udp"){print $i;exit}}' <<<"$line")"
    [[ -n "$event" && -n "$proto" ]] || return 1

    mapfile -t srcs < <(grep -oE 'src=[^ ]+' <<<"$line" | cut -d= -f2)
    mapfile -t dsts < <(grep -oE 'dst=[^ ]+' <<<"$line" | cut -d= -f2)
    mapfile -t sports < <(grep -oE 'sport=[0-9]+' <<<"$line" | cut -d= -f2)
    mapfile -t dports < <(grep -oE 'dport=[0-9]+' <<<"$line" | cut -d= -f2)

    ((${#srcs[@]} >= 2 && ${#dsts[@]} >= 2 && ${#sports[@]} >= 2 && ${#dports[@]} >= 2)) || return 1

    local vpn_ip="${srcs[0]}" vpn_port="${sports[0]}"
    local dst_ip="${dsts[0]}" dst_port="${dports[0]}"
    local public_ip="${dsts[1]}" public_port="${dports[1]}"

    # 只保存从 VPN 地址池发起、经过 SNAT 的连接。
    python3 - "$vpn_ip" "$VPN_SUBNET" <<'PY' >/dev/null 2>&1 || return 1
import ipaddress, sys
raise SystemExit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2], strict=False) else 1)
PY

    [[ "$public_ip" != "$vpn_ip" ]] || return 1

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "$(date -u +%s)" "$event" "$proto" "$vpn_ip" "$vpn_port" \
        "$public_ip" "$public_port" "$dst_ip" "$dst_port"
}

audit_daemon() {
    require_root
    load_config
    ensure_dirs
    [[ "$AUDIT_ENABLED" == "yes" ]] || { log "审计未启用。"; sleep infinity; }
    has conntrack || die "缺少 conntrack，请安装 conntrack 包。"
    has stdbuf || die "缺少 stdbuf（coreutils）。"

    while true; do
        stdbuf -oL conntrack -E -e NEW,DESTROY 2>/dev/null |
        while IFS= read -r line; do
            local record file
            record="$(parse_conntrack_line "$line" || true)"
            [[ -n "$record" ]] || continue
            file="$(audit_file_today)"
            if [[ ! -s "$file" ]]; then
                echo "epoch,event,protocol,vpn_ip,vpn_port,public_ip,public_port,destination_ip,destination_port" > "$file"
                chmod 600 "$file"
            fi
            echo "$record" >> "$file"
        done
        warn "conntrack 事件流已结束，5 秒后重启。"
        sleep 5
    done
}

extract_occtl_sessions() {
    local output="$1"
    jq -r '
      def pick($names):
        . as $o | first($names[] as $n | $o[$n]? // empty);
      .. | objects |
      (pick(["Username","username","User","user","Name","name"])) as $u |
      (pick(["VPN IP","vpn_ip","IPv4","ipv4","IP","ip","Assigned IP","assigned_ip"])) as $ip |
      select(($u|type)=="string" and ($ip|type)=="string") |
      [$ip,$u] | @tsv
    ' <<<"$output" | sort -u
}

session_daemon() {
    require_root
    load_config
    ensure_dirs
    [[ "$SESSION_AUDIT_ENABLED" == "yes" ]] || { log "用户会话审计未启用。"; sleep infinity; }
    has jq || die "缺少 jq。"

    touch "$SESSION_STATE"
    chmod 600 "$SESSION_STATE"

    while true; do
        local now output current tmp old_ip old_user old_start ip user start
        now="$(date -u +%s)"
        current="$(mktemp)"
        tmp="$(mktemp)"

        if output="$(timeout 10 bash -c "$OCCTL_COMMAND" 2>/dev/null)"; then
            extract_occtl_sessions "$output" > "$current" || true

            declare -A old_user_by_ip=()
            declare -A old_start_by_ip=()
            while IFS=$'\t' read -r old_ip old_user old_start; do
                [[ -n "${old_ip:-}" ]] || continue
                old_user_by_ip["$old_ip"]="$old_user"
                old_start_by_ip["$old_ip"]="$old_start"
            done < "$SESSION_STATE"

            declare -A seen=()
            while IFS=$'\t' read -r ip user; do
                [[ -n "${ip:-}" && -n "${user:-}" ]] || continue
                seen["$ip"]=1
                if [[ "${old_user_by_ip[$ip]:-}" == "$user" ]]; then
                    start="${old_start_by_ip[$ip]}"
                else
                    start="$now"
                fi
                printf '%s\t%s\t%s\n' "$ip" "$user" "$start" >> "$tmp"
            done < "$current"

            local session_log
            session_log="$(session_file_today)"
            if [[ ! -s "$session_log" ]]; then
                echo "start_epoch,end_epoch,vpn_ip,username" > "$session_log"
                chmod 600 "$session_log"
            fi

            for old_ip in "${!old_user_by_ip[@]}"; do
                if [[ -z "${seen[$old_ip]:-}" ]]; then
                    printf '%s,%s,%s,%s\n' \
                        "${old_start_by_ip[$old_ip]}" "$now" "$old_ip" \
                        "${old_user_by_ip[$old_ip]}" >> "$session_log"
                fi
            done

            mv "$tmp" "$SESSION_STATE"
        else
            warn "OCCTL_COMMAND 执行失败：$OCCTL_COMMAND"
            rm -f "$tmp"
        fi

        rm -f "$current"
        sleep "$SESSION_SCAN_INTERVAL"
    done
}

close_active_sessions() {
    load_config
    ensure_dirs
    [[ -s "$SESSION_STATE" ]] || return 0
    local now logf ip user start
    now="$(date -u +%s)"
    logf="$(session_file_today)"
    [[ -s "$logf" ]] || echo "start_epoch,end_epoch,vpn_ip,username" > "$logf"
    while IFS=$'\t' read -r ip user start; do
        [[ -n "${ip:-}" ]] || continue
        printf '%s,%s,%s,%s\n' "$start" "$now" "$ip" "$user" >> "$logf"
    done < "$SESSION_STATE"
    : > "$SESSION_STATE"
}

read_log_files() {
    local dir="$1" pattern="$2"
    find "$dir" -maxdepth 1 -type f \( -name "$pattern" -o -name "${pattern}.gz" \) -print0 |
    sort -z |
    while IFS= read -r -d '' file; do
        if [[ "$file" == *.gz ]]; then gzip -cd -- "$file"; else cat -- "$file"; fi
    done
}

lookup_username() {
    local epoch="$1" vpn_ip="$2"
    local result

    result="$(
        {
            read_log_files "$SESSION_DIR" 'sessions-*.csv'
            # 当前仍在线的会话。
            if [[ -s "$SESSION_STATE" ]]; then
                awk -F'\t' -v now="$(date -u +%s)" \
                    '{print $3 "," now "," $1 "," $2}' "$SESSION_STATE"
            fi
        } |
        awk -F, -v t="$epoch" -v ip="$vpn_ip" '
            $1 ~ /^[0-9]+$/ && $3==ip && $1<=t && $2>=t {
                print $4 "," $1 "," $2
            }
        ' | tail -n1
    )"

    printf '%s\n' "$result"
}

audit_lookup() {
    require_root
    load_config
    audit_db_init

    local time_text="" public_port="" protocol="" dst_ip="" dst_port="" tolerance=120

    while (($#)); do
        case "$1" in
            --time) time_text="${2:-}"; shift 2 ;;
            --public-port) public_port="${2:-}"; shift 2 ;;
            --protocol) protocol="${2:-}"; shift 2 ;;
            --destination) dst_ip="${2:-}"; shift 2 ;;
            --destination-port) dst_port="${2:-}"; shift 2 ;;
            --tolerance) tolerance="${2:-}"; shift 2 ;;
            *) die "未知查询参数：$1" ;;
        esac
    done

    [[ -n "$time_text" && -n "$public_port" && -n "$protocol" ]] ||
        die "必须提供 --time、--public-port 和 --protocol"

    local target_epoch
    target_epoch="$(date -d "$time_text" +%s 2>/dev/null)" ||
        die "无法解析时间：$time_text"

    protocol="${protocol,,}"
    [[ "$protocol" =~ ^(tcp|udp)$ ]] || die "协议只能是 tcp 或 udp"
    [[ "$public_port" =~ ^[0-9]+$ ]] || die "公网端口必须是数字"

    local destination_sql=""
    [[ -n "$dst_ip" ]] && destination_sql+=" AND destination_ip='$dst_ip'"
    [[ -n "$dst_port" ]] && destination_sql+=" AND destination_port=$dst_port"

    local rows
    rows="$(
        sqlite3 -csv "$AUDIT_DB" <<SQL
SELECT
    CASE
      WHEN $target_epoch < start_epoch THEN start_epoch-$target_epoch
      WHEN end_epoch IS NOT NULL AND $target_epoch > end_epoch THEN $target_epoch-end_epoch
      ELSE 0
    END AS diff,
    start_epoch,
    end_epoch,
    protocol,
    vpn_ip,
    vpn_port,
    public_ip,
    public_port,
    destination_ip,
    destination_port
FROM nat_sessions
WHERE protocol='$protocol'
  AND public_port=$public_port
  AND start_epoch <= $((target_epoch+tolerance))
  AND COALESCE(end_epoch,start_epoch) >= $((target_epoch-tolerance))
  $destination_sql
ORDER BY diff ASC, start_epoch DESC
LIMIT 10;
SQL
    )"

    [[ -n "$rows" ]] || {
        echo "未找到匹配记录。可增大 --tolerance，或补充目标 IP/端口。"
        return 1
    }

    echo "========== NAT 历史审计查询 =========="
    local diff start end proto vpn_ip vpn_port pub_ip pub_port dip dport session username s e
    while IFS=, read -r diff start end proto vpn_ip vpn_port pub_ip pub_port dip dport; do
        session="$(lookup_username "$start" "$vpn_ip")"
        username=""
        if [[ -n "$session" ]]; then
            IFS=, read -r username s e <<<"$session"
        fi

        echo
        printf '连接开始：%s UTC\n' "$(date -u -d "@$start" '+%F %T')"
        if [[ -n "$end" ]]; then
            printf '连接结束：%s UTC\n' "$(date -u -d "@$end" '+%F %T')"
        else
            printf '连接结束：当前仍未记录结束\n'
        fi
        printf '与查询时间差：%s 秒\n' "$diff"
        printf '协议：%s\n' "$proto"
        printf '公网映射：%s:%s\n' "$pub_ip" "$pub_port"
        printf 'VPN 客户端：%s:%s\n' "$vpn_ip" "$vpn_port"
        printf '远程目标：%s:%s\n' "$dip" "$dport"
        printf 'VPN 用户：%s\n' "${username:-未匹配到用户名会话}"
    done <<<"$rows"
}

port_add() {
    require_root
    load_config
    ensure_dirs
    local proto="${1:-}" public_port="${2:-}" vpn_ip="${3:-}" target_port="${4:-}"
    local source="${5:-0.0.0.0/0}" comment="${6:-}"
    valid_mapping_line yes "$proto" "$public_port" "$vpn_ip" "$target_port" "$source" ||
        die "用法：port add <tcp|udp|both> <公网端口> <VPN_IP> <目标端口> [来源CIDR] [备注]"
    printf 'yes\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$proto" "$public_port" "$vpn_ip" "$target_port" "$source" "$comment" >> "$PORT_MAP_FILE"
    network_apply
}

port_list() {
    load_config
    ensure_dirs
    printf '状态\t协议\t公网端口\tVPN IP\t目标端口\t来源CIDR\t备注\n'
    cat "$PORT_MAP_FILE"
}

port_delete() {
    require_root
    load_config
    ensure_dirs
    local proto="${1:-}" public_port="${2:-}"
    [[ -n "$proto" && -n "$public_port" ]] || die "用法：port delete <协议> <公网端口>"
    local tmp
    tmp="$(mktemp)"
    awk -F'\t' -v p="$proto" -v port="$public_port" \
        '!(($2==p || (p=="both" && $2=="both")) && $3==port)' "$PORT_MAP_FILE" > "$tmp"
    mv "$tmp" "$PORT_MAP_FILE"
    chmod 600 "$PORT_MAP_FILE"
    network_apply
}

set_rate() {
    require_root
    load_config
    local new="${1:-}"
    validate_rate "$new" || die "限速格式应类似 50mbit"
    sed -i "s/^RATE=.*/RATE=\"${new}\"/" "$CONFIG_FILE"
    systemctl restart ocserv-limit.service
    log "限速已改为：$new"
}

bt_toggle() {
    require_root
    load_config
    local value="$1"
    sed -i "s/^BT_GUARD_ENABLED=.*/BT_GUARD_ENABLED=\"${value}\"/" "$CONFIG_FILE"
    network_apply
}

status() {
    require_root
    load_config
    local wan
    wan="$(resolve_wan)"
    cat <<EOF
ocserv-manager $VERSION
VPN 网段：$VPN_SUBNET
公网设置：$WAN_INTERFACE
当前公网网卡：$wan
限速：$RATE
BT 风险控制：$BT_GUARD_ENABLED
NAT 审计：$AUDIT_ENABLED
用户会话审计：$SESSION_AUDIT_ENABLED
日志保留：$AUDIT_RETENTION_DAYS 天
EOF
    echo
    systemctl --no-pager --full status \
        ocserv-network.timer ocserv-limit.service \
        ocserv-audit.service ocserv-session-audit.service ocserv-audit-maintenance.timer \
        "${ATTRIB_UNITS[@]}" 2>/dev/null || true
    rm -f /etc/systemd/system/ocserv-attrib-*.service /etc/systemd/system/ocserv-attrib-maint.timer \
        /usr/local/sbin/ocserv-attrib /usr/local/sbin/ocserv-whois /etc/sysctl.d/98-ocserv-attrib.conf
    echo
    "$IPTABLES_BIN" -nvL "$BT_CHAIN" 2>/dev/null || true
}

write_default_config() {
    local ipt
    ipt="$(detect_iptables)"
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
VPN_SUBNET="${VPN_SUBNET:-192.168.1.0/24}"
VPN_INTERFACE_GLOB="${VPN_INTERFACE_GLOB:-vpns+}"
VPN_INTERFACE_REGEX="${VPN_INTERFACE_REGEX:-^vpns[0-9]+$}"
WAN_INTERFACE="${WAN_INTERFACE:-auto}"

RATE="${RATE:-50mbit}"
IFB_DEVICE="${IFB_DEVICE:-ifb0}"
LIMIT_SCAN_INTERVAL="${LIMIT_SCAN_INTERVAL:-1}"

NETWORK_CHECK_INTERVAL="${NETWORK_CHECK_INTERVAL:-60}"

BT_GUARD_ENABLED="${BT_GUARD_ENABLED:-yes}"
BT_CONN_LIMIT="${BT_CONN_LIMIT:-350}"
BT_NEW_RATE="${BT_NEW_RATE:-80/second}"
BT_NEW_BURST="${BT_NEW_BURST:-160}"
BT_BLOCK_CLASSIC_PORTS="${BT_BLOCK_CLASSIC_PORTS:-yes}"
BT_STRING_MATCH="${BT_STRING_MATCH:-yes}"

AUDIT_ENABLED="${AUDIT_ENABLED:-yes}"
AUDIT_RETENTION_DAYS="${AUDIT_RETENTION_DAYS:-31}"
AUDIT_IGNORE_NONPUBLIC_DESTINATIONS="${AUDIT_IGNORE_NONPUBLIC_DESTINATIONS:-yes}"
AUDIT_IGNORE_DNS="${AUDIT_IGNORE_DNS:-yes}"
AUDIT_DNS_SERVERS="${AUDIT_DNS_SERVERS:-8.8.8.8,8.8.4.4}"

SESSION_AUDIT_ENABLED="${SESSION_AUDIT_ENABLED:-yes}"
SESSION_SCAN_INTERVAL="${SESSION_SCAN_INTERVAL:-30}"
OCCTL_COMMAND="${OCCTL_COMMAND:-docker exec ocserv occtl -j show users}"

IPTABLES_BIN="${ipt}"
EOF
    chmod 600 "$CONFIG_FILE"
}

write_units() {
    load_config

    cat > "$NETWORK_SERVICE" <<EOF
[Unit]
Description=Apply ocserv network, NAT, BT guard and DNAT rules
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} network-ensure
EOF

    cat > "$NETWORK_TIMER" <<EOF
[Unit]
Description=Periodically restore ocserv network rules

[Timer]
OnBootSec=20s
OnUnitActiveSec=${NETWORK_CHECK_INTERVAL}s
AccuracySec=10s
Persistent=true
Unit=ocserv-network.service

[Install]
WantedBy=timers.target
EOF

    cat > "$LIMIT_SERVICE" <<EOF
[Unit]
Description=Automatically limit ocserv vpns interfaces
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=simple
ExecStart=${INSTALL_PATH} limit-daemon
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

    cat > "$AUDIT_SERVICE" <<EOF
[Unit]
Description=Record historical ocserv NAT mappings
Wants=network-online.target
After=network-online.target docker.service ocserv-network.service

[Service]
Type=simple
ExecStart=${INSTALL_PATH} audit-daemon
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF

    cat > "$SESSION_SERVICE" <<EOF
[Unit]
Description=Record ocserv VPN IP to username sessions
After=docker.service ocserv.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${INSTALL_PATH} session-daemon
ExecStop=${INSTALL_PATH} session-close
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF

    cat > "$AUDIT_MAINT_SERVICE" <<EOF
[Unit]
Description=Maintain ocserv audit SQLite database

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} audit-maintenance
Nice=15
EOF

    cat > "$AUDIT_MAINT_TIMER" <<'EOF'
[Unit]
Description=Daily ocserv audit database maintenance

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=15m
Unit=ocserv-audit-maintenance.service

[Install]
WantedBy=timers.target
EOF

}

write_logrotate() {
    load_config
    cat > "$LOGROTATE_FILE" <<EOF
${SESSION_DIR}/*.csv ${AUDIT_DIR}/*.csv {
    daily
    rotate ${AUDIT_RETENTION_DAYS}
    compress
    delaycompress
    missingok
    notifempty
    dateext
    create 0600 root root
}
EOF
}

ATTRIB_UNITS=(ocserv-attrib-nat.service ocserv-attrib-session.service ocserv-attrib-maint.timer)

# 2.2.0: NAT/session attribution logging (ocserv-attrib + ocserv-whois).
write_attrib_files() {
    cat > /usr/local/sbin/ocserv-attrib <<'ATTRIB_EOF'
#!/usr/bin/env python3
# ocserv-attrib (ocserv-manager 2.2.0 addon): abuse/copyright attribution logging.
#   nat-daemon      conntrack NEW/DESTROY events of the VPN pool -> /var/log/ocserv-attrib/nat/nat-YYYY-MM-DD.tsv
#   session-daemon  occtl poller -> /var/log/ocserv-attrib/sessions/sess-YYYY-MM-DD.tsv (CONNECT/DISCONNECT)
#   maintain        gzip closed days, delete files older than RETENTION_DAYS
#   stats           sizes / event counts
# All times UTC. Files are per UTC day.
import os, sys, re, time, json, subprocess, signal, gzip, shutil, datetime, glob

VERSION = "2.2.0"
CONF = "/etc/ocserv-attrib.conf"

def load_conf():
    c = {"VPN_SUBNET": "", "LOG_DIR": "/var/log/ocserv-attrib", "STATE_DIR": "/var/lib/ocserv-attrib",
         "RETENTION_DAYS": "100", "NAT_EVENTS": "NEW,DESTROY", "IGNORE_DNS_SERVERS": "8.8.8.8,8.8.4.4",
         "OCCTL_COMMAND": "docker exec ocserv occtl -j show users", "SESSION_INTERVAL": "5",
         "CT_BUFFER": "67108864"}
    for f in ("/etc/ocserv-manager/config", CONF):
        try:
            for line in open(f):
                m = re.match(r'^\s*([A-Z_]+)=["\']?(.*?)["\']?\s*$', line)
                if m and (f == CONF or m.group(1) == "VPN_SUBNET"):
                    c[m.group(1)] = m.group(2)
        except FileNotFoundError:
            pass
    if not c["VPN_SUBNET"]:
        c["VPN_SUBNET"] = "10.88.0.0/16"
    return c

def iso(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"

def day(ts):
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%d")

class DailyWriter:
    def __init__(self, d, prefix, header):
        self.d, self.prefix, self.header = d, prefix, header
        os.makedirs(d, mode=0o700, exist_ok=True)
        self.cur = None; self.fh = None; self.last_flush = time.time()
    def write(self, ts, line):
        dd = day(ts)
        if dd != self.cur:
            self.close()
            path = os.path.join(self.d, f"{self.prefix}-{dd}.tsv")
            new = not os.path.exists(path) or os.path.getsize(path) == 0
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            self.fh = os.fdopen(fd, "a", buffering=1 << 16)
            if new:
                self.fh.write(self.header + "\n")
            self.cur = dd
        self.fh.write(line + "\n")
        now = time.time()
        if now - self.last_flush >= 2:
            self.fh.flush(); self.last_flush = now
    def flush(self):
        if self.fh: self.fh.flush()
    def close(self):
        if self.fh:
            self.fh.flush(); self.fh.close(); self.fh = None

NAT_HEADER = "#ts_utc\tepoch\tevent\tproto\tinner_ip\tinner_port\tdst_ip\tdst_port\tpublic_ip\tpublic_port\tduration_s"
TS_RE = re.compile(r'^\[(\d+\.\d+)\]\s+')
EV_RE = re.compile(r'\[(NEW|DESTROY)\]')
KV_RE = re.compile(r'\b(src|dst|sport|dport)=(\S+)')
PROTO_RE = re.compile(r'\b(tcp|udp)\s+\d+\s')
DUR_RE = re.compile(r'delta-time=(\d+)')
START_RE = re.compile(r'\[start=([^\]]+)\]')

def parse_ct(line, default_ev=None):
    m = TS_RE.match(line)
    ts = float(m.group(1)) if m else time.time()
    e = EV_RE.search(line)
    ev = e.group(1) if e else default_ev
    p = PROTO_RE.search(line)
    if not ev or not p:
        return None
    vals = {"src": [], "dst": [], "sport": [], "dport": []}
    for k, v in KV_RE.findall(line):
        vals[k].append(v)
    if len(vals["src"]) < 2 or len(vals["sport"]) < 2:
        return None
    dur = ""
    d = DUR_RE.search(line)
    if d:
        dur = d.group(1)
    return ts, ev, p.group(1), vals["src"][0], vals["sport"][0], vals["dst"][0], vals["dport"][0], vals["dst"][1], vals["dport"][1], dur

def nat_daemon(c):
    import ipaddress
    net = ipaddress.ip_network(c["VPN_SUBNET"], strict=False)
    ign = set(x.strip() for x in c["IGNORE_DNS_SERVERS"].split(",") if x.strip())
    w = DailyWriter(os.path.join(c["LOG_DIR"], "nat"), "nat", NAT_HEADER)
    stop = {"v": False}
    def term(*a):
        stop["v"] = True; w.close(); sys.exit(0)
    signal.signal(signal.SIGTERM, term); signal.signal(signal.SIGINT, term)

    def emit(rec):
        ts, ev, proto, sip, sp, dip, dp, rsrc, rdport, dur = rec
        # rsrc = reply src (= original dst); reply dst/dport = public (SNAT) ip/port
        return
    def handle(rec):
        ts, ev, proto, sip, sp, dip, dp, pub_ip, pub_port, dur = rec
        try:
            if ipaddress.ip_address(sip) not in net:
                return
        except ValueError:
            return
        if pub_ip == sip:          # not SNATed (local / DNAT reply etc.)
            return
        if dip in ign and dp in ("53", "853"):
            return
        w.write(ts, "\t".join((iso(ts), "%.3f" % ts, ev, proto, sip, sp, dip, dp, pub_ip, pub_port, dur)))

    # Snapshot of flows that already exist (start time unknown, <= snapshot time).
    try:
        out = subprocess.run(["conntrack", "-L", "-o", "extended", "-s", c["VPN_SUBNET"]],
                             capture_output=True, text=True, timeout=60).stdout
        now = time.time(); n = 0
        for line in out.splitlines():
            r = parse_ct(line, "SNAP")
            if r:
                r = (now,) + r[1:]; handle(r); n += 1
        w.flush()
        print(f"snapshot: {n} existing flows", flush=True)
    except Exception as ex:
        print(f"snapshot failed: {ex}", file=sys.stderr, flush=True)

    while not stop["v"]:
        cmd = ["conntrack", "-E", "-e", c["NAT_EVENTS"], "-o", "timestamp,extended",
               "-s", c["VPN_SUBNET"], "-b", c["CT_BUFFER"]]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True, bufsize=1 << 16)
        for line in p.stdout:
            r = parse_ct(line)
            if r:
                handle(r)
        w.flush()
        print(f"conntrack exited rc={p.wait()}, restarting in 3s", file=sys.stderr, flush=True)
        time.sleep(3)

SESS_HEADER = "#ts_utc\tepoch\tevent\tusername\tvpn_ip\tocctl_id\tremote_ip\tdevice\tconnected_at_raw"

def occtl_users(c):
    out = subprocess.run(c["OCCTL_COMMAND"], shell=True, capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise RuntimeError(f"occtl rc={out.returncode}")
    data = json.loads(out.stdout or "[]")
    res = {}
    for u in data:
        if u.get("State") != "connected" or not u.get("IPv4"):
            continue
        sid = str(u.get("ID"))
        user = str(u.get("Username", "")).replace("\t", " ").replace("\n", " ")
        res[sid] = {"user": user, "ip": u.get("IPv4"), "remote": u.get("Remote IP", ""),
                    "dev": u.get("Device", ""), "cat": u.get("Connected at", "")}
    return res

def session_daemon(c):
    sd = c["STATE_DIR"]; os.makedirs(sd, mode=0o700, exist_ok=True)
    stf = os.path.join(sd, "sessions.json")
    w = DailyWriter(os.path.join(c["LOG_DIR"], "sessions"), "sess", SESS_HEADER)
    def line(ts, ev, sid, s):
        w.write(ts, "\t".join((iso(ts), "%.0f" % ts, ev, s["user"], s["ip"], sid, s["remote"], s["dev"], s["cat"])))
    state = {}
    try:
        st = json.load(open(stf)); state = st.get("sessions", {}); last = st.get("last_poll", time.time())
    except Exception:
        last = None
    def save(ts):
        tmp = stf + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"last_poll": ts, "sessions": state}, f)
        os.chmod(tmp, 0o600); os.replace(tmp, stf)
    def term(*a):
        w.close(); sys.exit(0)
    signal.signal(signal.SIGTERM, term); signal.signal(signal.SIGINT, term)
    first = True
    interval = float(c["SESSION_INTERVAL"])
    while True:
        now = time.time()
        try:
            cur = occtl_users(c)
        except Exception as ex:
            print(f"occtl failed: {ex}", file=sys.stderr, flush=True)
            time.sleep(interval); continue
        for sid in list(state):
            if sid not in cur or cur[sid]["ip"] != state[sid]["ip"]:
                # first poll after restart: session ended sometime between last saved poll and now
                ts = (last if first and last else now)
                line(ts, "DISCONNECT", sid, state.pop(sid))
        for sid, s in cur.items():
            if sid not in state:
                line(now, "CONNECT" if not first or last is not None else "ONLINE", sid, s)
                state[sid] = s
        w.flush(); save(now); last = now; first = False
        time.sleep(interval)

def maintain(c):
    keep = int(c["RETENTION_DAYS"])
    today = day(time.time())
    cutoff = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=keep)).strftime("%Y-%m-%d")
    for sub in ("nat", "sessions"):
        for f in sorted(glob.glob(os.path.join(c["LOG_DIR"], sub, "*-????-??-??.tsv*"))):
            m = re.search(r'(\d{4}-\d{2}-\d{2})\.tsv', f)
            if not m: continue
            d = m.group(1)
            if d < cutoff:
                os.remove(f); print("deleted", f); continue
            if f.endswith(".tsv") and d < today:
                with open(f, "rb") as src, gzip.open(f + ".gz", "wb", 6) as dst:
                    shutil.copyfileobj(src, dst, 1 << 20)
                os.chmod(f + ".gz", 0o600); os.remove(f); print("compressed", f)

def stats(c):
    for sub in ("nat", "sessions"):
        print(f"== {sub}")
        for f in sorted(glob.glob(os.path.join(c["LOG_DIR"], sub, "*")))[-5:]:
            print(f"{os.path.getsize(f):>12}  {f}")
    subprocess.run(["du", "-sh", c["LOG_DIR"]])

if __name__ == "__main__":
    c = load_conf()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    {"nat-daemon": nat_daemon, "session-daemon": session_daemon, "maintain": maintain, "stats": stats}.get(
        cmd, lambda c: print(f"ocserv-attrib {VERSION}: nat-daemon|session-daemon|maintain|stats"))(c)
ATTRIB_EOF
    chmod 755 /usr/local/sbin/ocserv-attrib

    cat > /usr/local/sbin/ocserv-whois <<'ATTRIB_EOF'
#!/usr/bin/env python3
"""ocserv-whois (ocserv-manager 2.2.0): public IP:port + time -> NAT flow -> inner VPN IP -> username.
Usage: ocserv-whois --port 3266 --time 2026-10-16T16:58:15Z [--ip 203.0.113.10] [--window 300]
                    [--proto tcp|udp] [--dst 198.51.100.20] [--dport 443] [--days-back 3] [--json]
       ocserv-whois --inner 10.88.1.2 --time ...      (only username lookup for an inner IP)
Time without zone is treated as UTC. Reads plain and .gz daily files."""
import argparse, datetime, glob, gzip, json, os, re, sys, time

LOG = "/var/log/ocserv-attrib"
STATE = "/var/lib/ocserv-attrib/sessions.json"
OLD_SESS = "/var/log/ocserv-manager/sessions"

def parse_time(s):
    s = s.strip().replace(" ", "T", 1) if re.match(r"^\d{4}-\d\d-\d\d \d", s) else s.strip()
    if re.fullmatch(r"\d+(\.\d+)?", s): return float(s)
    if s.endswith("Z"): s = s[:-1] + "+00:00"
    d = datetime.datetime.fromisoformat(s)
    if d.tzinfo is None: d = d.replace(tzinfo=datetime.timezone.utc)
    return d.timestamp()

def iso(ts):
    if ts is None: return "?"
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def days(a, b):
    d = datetime.datetime.fromtimestamp(a, datetime.timezone.utc).date()
    e = datetime.datetime.fromtimestamp(b, datetime.timezone.utc).date()
    while d <= e:
        yield d.isoformat(); d += datetime.timedelta(days=1)

def open_any(f):
    return gzip.open(f, "rt", errors="replace") if f.endswith(".gz") else open(f, errors="replace")

def files(sub, prefix, a, b):
    out = []
    for d in days(a, b):
        for ext in (".tsv", ".tsv.gz"):
            f = os.path.join(LOG, sub, f"{prefix}-{d}{ext}")
            if os.path.exists(f): out.append(f)
    return out

def nat_flows(a, t0, t1):
    port = str(a.port)
    flows, openf = [], {}
    for f in files("nat", "nat", t0 - a.days_back * 86400, t1 + 86400):
        with open_any(f) as fh:
            for ln in fh:
                if ln.startswith("#") or ("\t" + port + "\t") not in ln:
                    continue
                p = ln.rstrip("\n").split("\t")
                if len(p) < 10 or p[9] != port: continue
                ts, ev, proto, iip, ipt, dip, dpt, pip, ppt = float(p[1]), p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9]
                dur = p[10] if len(p) > 10 else ""
                if a.ip and pip != a.ip: continue
                if a.proto and proto != a.proto: continue
                if a.dst and dip != a.dst: continue
                if a.dport and dpt != str(a.dport): continue
                k = (proto, iip, ipt, dip, dpt, pip, ppt)
                if ev in ("NEW", "SNAP"):
                    fl = {"start": ts if ev == "NEW" else None, "seen": ts, "end": None, "k": k, "src": ev}
                    flows.append(fl); openf[k] = fl
                elif ev == "DESTROY":
                    fl = openf.pop(k, None)
                    if fl is None:
                        fl = {"start": ts - float(dur) if dur else None, "seen": ts, "end": None, "k": k, "src": "DESTROY"}
                        flows.append(fl)
                    fl["end"] = ts
                    if fl["start"] is None and dur: fl["start"] = ts - float(dur)
    res = []
    now = time.time()
    for fl in flows:
        s = fl["start"] if fl["start"] is not None else fl["seen"] - 10 * 86400
        e = fl["end"] if fl["end"] is not None else now
        if s <= t1 and e >= t0:
            fl["diff"] = 0 if s <= a.t <= e else min(abs(s - a.t), abs(e - a.t))
            res.append(fl)
    res.sort(key=lambda x: (x["diff"], -(x["start"] or 0)))
    return res

def sessions_for(ip, t0, t1):
    """return list of (user, start, end, source) overlapping [t0,t1] for vpn ip"""
    out, opened = [], {}
    for f in files("sessions", "sess", t0 - 30 * 86400, t1 + 86400):
        with open_any(f) as fh:
            for ln in fh:
                if ln.startswith("#"): continue
                p = ln.rstrip("\n").split("\t")
                if len(p) < 6 or p[4] != ip: continue
                ts, ev, user, sid = float(p[1]), p[2], p[3], p[5]
                if ev in ("CONNECT", "ONLINE"):
                    opened[sid] = [user, ts if ev == "CONNECT" else None, None, "attrib", ts]
                    out.append(opened[sid])
                elif ev == "DISCONNECT":
                    r = opened.pop(sid, None)
                    if r is None:
                        r = [user, None, None, "attrib", ts]; out.append(r)
                    r[2] = ts
    try:
        st = json.load(open(STATE))
        for sid, s in st.get("sessions", {}).items():
            if s["ip"] == ip and sid in opened:
                opened[sid][2] = None  # still online
    except Exception:
        pass
    # legacy ocserv-manager 2.1.0 session CSVs (start,end,ip,user; 30s poll)
    for f in sorted(glob.glob(os.path.join(OLD_SESS, "sessions-*"))):
        try:
            with open_any(f) as fh:
                for ln in fh:
                    p = ln.strip().split(",", 3)
                    if len(p) == 4 and p[2] == ip and p[0].isdigit():
                        out.append([p[3], float(p[0]), float(p[1]), "legacy-2.1", float(p[0])])
        except Exception:
            pass
    now = time.time()
    res = []
    for u, s, e, src, seen in out:
        s2 = s if s is not None else seen - 30 * 86400
        e2 = e if e is not None else now
        if s2 <= t1 and e2 >= t0:
            res.append({"user": u, "start": s, "end": e, "source": src, "first_seen": seen})
    return res

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int); ap.add_argument("--ip"); ap.add_argument("--time", required=True)
    ap.add_argument("--window", type=int, default=300); ap.add_argument("--proto", choices=["tcp", "udp"])
    ap.add_argument("--dst"); ap.add_argument("--dport", type=int); ap.add_argument("--days-back", type=int, default=3)
    ap.add_argument("--inner"); ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    a.t = parse_time(a.time); t0, t1 = a.t - a.window, a.t + a.window
    result = {"query": {"time": iso(a.t), "window_s": a.window, "public_ip": a.ip, "public_port": a.port}, "flows": []}
    if a.inner:
        result["flows"].append({"inner_ip": a.inner, "users": sessions_for(a.inner, a.t, a.t)})
    else:
        if not a.port: ap.error("--port or --inner required")
        for fl in nat_flows(a, t0, t1)[:50]:
            proto, iip, ipt, dip, dpt, pip, ppt = fl["k"]
            s = fl["start"] if fl["start"] is not None else fl["seen"]
            e = fl["end"] if fl["end"] is not None else time.time()
            at = min(max(a.t, s), e)          # point of the flow closest to the query time
            users = sessions_for(iip, at, at)
            result["flows"].append({"proto": proto, "public": f"{pip}:{ppt}", "inner_ip": iip, "inner_port": ipt,
                                    "dst": f"{dip}:{dpt}", "start": iso(fl["start"]) if fl["start"] else f"<= {iso(fl['seen'])} (pre-existing)",
                                    "end": iso(fl["end"]) if fl["end"] else "open/unknown", "diff_s": round(fl["diff"]), "users": users})
    if a.json:
        print(json.dumps(result, indent=1, default=str)); return
    q = result["query"]
    print(f"query: time={q['time']} ±{a.window}s public={a.ip or '*'}:{a.port or '-'}")
    if not result["flows"]:
        print("NO MATCH: no NAT flow in window (try --window larger / --days-back / drop --ip)"); sys.exit(1)
    for f in result["flows"]:
        if "proto" in f:
            print(f"\nFLOW {f['proto']} public {f['public']}  inner {f['inner_ip']}:{f['inner_port']} -> {f['dst']}"
                  f"  start {f['start']}  end {f['end']}  Δ={f['diff_s']}s")
        else:
            print(f"\nINNER {f['inner_ip']}")
        if not f["users"]:
            print("   USER: (no session record covering this time)")
        for u in f["users"]:
            print(f"   USER: {u['user'].strip()!s:40}  session {iso(u['start']) if u['start'] else '<='+iso(u['first_seen'])} .. "
                  f"{iso(u['end']) if u['end'] else 'online'}  [{u['source']}]")

if __name__ == "__main__":
    main()
ATTRIB_EOF
    chmod 755 /usr/local/sbin/ocserv-whois

    if [[ ! -f /etc/ocserv-attrib.conf ]]; then
        cat > /etc/ocserv-attrib.conf <<'ATTRIB_EOF'
# ocserv-attrib (ocserv-manager 2.2.0). VPN_SUBNET defaults to /etc/ocserv-manager/config.
#VPN_SUBNET="10.88.0.0/16"
LOG_DIR="/var/log/ocserv-attrib"
STATE_DIR="/var/lib/ocserv-attrib"
RETENTION_DAYS="100"
NAT_EVENTS="NEW,DESTROY"
IGNORE_DNS_SERVERS="8.8.8.8,8.8.4.4"
OCCTL_COMMAND="docker exec ocserv occtl -j show users"
SESSION_INTERVAL="5"
CT_BUFFER="67108864"
ATTRIB_EOF
        chmod 600 /etc/ocserv-attrib.conf
    fi

    mkdir -p /var/log/ocserv-attrib/nat /var/log/ocserv-attrib/sessions /var/lib/ocserv-attrib
    chmod 700 /var/log/ocserv-attrib /var/log/ocserv-attrib/nat /var/log/ocserv-attrib/sessions /var/lib/ocserv-attrib

    echo 'net.netfilter.nf_conntrack_timestamp = 1' > /etc/sysctl.d/98-ocserv-attrib.conf
    sysctl -q -w net.netfilter.nf_conntrack_timestamp=1 2>/dev/null || true

    cat > /etc/systemd/system/ocserv-attrib-nat.service <<'ATTRIB_EOF'
[Unit]
Description=ocserv-attrib: log VPN-pool NAT mappings (conntrack NEW/DESTROY events)
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/sbin/modprobe nf_conntrack
ExecStartPre=-/sbin/sysctl -q -w net.netfilter.nf_conntrack_timestamp=1
ExecStart=/usr/local/sbin/ocserv-attrib nat-daemon
Restart=always
RestartSec=3
Nice=5
MemoryMax=300M

[Install]
WantedBy=multi-user.target
ATTRIB_EOF
    cat > /etc/systemd/system/ocserv-attrib-session.service <<'ATTRIB_EOF'
[Unit]
Description=ocserv-attrib: log username <-> VPN IP sessions (occtl poll 5s)
After=docker.service
Wants=docker.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/ocserv-attrib session-daemon
Restart=always
RestartSec=5
Nice=5

[Install]
WantedBy=multi-user.target
ATTRIB_EOF
    cat > /etc/systemd/system/ocserv-attrib-maint.service <<'ATTRIB_EOF'
[Unit]
Description=ocserv-attrib: gzip closed days, prune > RETENTION_DAYS

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/local/sbin/ocserv-attrib maintain
ATTRIB_EOF
    cat > /etc/systemd/system/ocserv-attrib-maint.timer <<'ATTRIB_EOF'
[Unit]
Description=ocserv-attrib daily maintenance

[Timer]
OnCalendar=*-*-* 00:20:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
ATTRIB_EOF
}

install_program() {
    require_root

    local required=(ip awk sed grep sysctl systemctl tc modprobe python3 conntrack jq gzip find sort stdbuf flock sqlite3)
    local missing=() cmd
    for cmd in "${required[@]}"; do has "$cmd" || missing+=("$cmd"); done
    if ((${#missing[@]})); then
        die "缺少依赖：${missing[*]}。Debian/Ubuntu 可执行：apt install -y iproute2 iptables kmod conntrack jq coreutils python3 logrotate sqlite3"
    fi

    ensure_dirs
    write_default_config
    install -m 700 "$0" "$INSTALL_PATH"

    cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward = 1
EOF

    write_units
    write_logrotate

    sysctl --system >/dev/null
    systemctl daemon-reload
    systemctl enable --now ocserv-network.timer
    systemctl enable --now ocserv-limit.service
    systemctl enable --now ocserv-session-audit.service
    # 2.2.0: legacy NAT audit (never logged in 2.1.0) replaced by ocserv-attrib
    systemctl disable --now ocserv-audit.service ocserv-audit-maintenance.timer 2>/dev/null || true
    systemctl reset-failed ocserv-audit-maintenance.service 2>/dev/null || true
    write_attrib_files
    systemctl daemon-reload
    systemctl enable --now "${ATTRIB_UNITS[@]}"
    systemctl restart ocserv-attrib-nat.service ocserv-attrib-session.service
    systemctl restart ocserv-network.service

    log "安装完成。"
    log "请测试用户名读取命令：bash -c '$(grep '^OCCTL_COMMAND=' "$CONFIG_FILE" | cut -d= -f2-)'"
    log "运行管理菜单：ocserv-manager"
}

remove_chain() {
    local table="$1" parent="$2" chain="$3" ipt="$IPTABLES_BIN" targs=()
    [[ "$table" != "filter" ]] && targs=(-t "$table")
    while "$ipt" -w "${targs[@]}" -C "$parent" -j "$chain" 2>/dev/null; do
        "$ipt" -w "${targs[@]}" -D "$parent" -j "$chain"
    done
    "$ipt" -w "${targs[@]}" -F "$chain" 2>/dev/null || true
    "$ipt" -w "${targs[@]}" -X "$chain" 2>/dev/null || true
}

uninstall_program() {
    require_root
    load_config || true

    systemctl disable --now ocserv-network.timer ocserv-limit.service \
        ocserv-audit.service ocserv-session-audit.service ocserv-audit-maintenance.timer 2>/dev/null || true
    systemctl stop ocserv-network.service 2>/dev/null || true
    limit_clear 2>/dev/null || true

    remove_chain filter FORWARD "$FORWARD_CHAIN"
    remove_chain filter "$FORWARD_CHAIN" "$BT_CHAIN" || true
    remove_chain filter "$FORWARD_CHAIN" "$DNAT_FILTER_CHAIN" || true
    remove_chain nat PREROUTING "$DNAT_CHAIN"
    remove_chain nat POSTROUTING "$NAT_CHAIN"

    rm -f "$NETWORK_SERVICE" "$NETWORK_TIMER" "$LIMIT_SERVICE" "$AUDIT_SERVICE" "$SESSION_SERVICE" "$AUDIT_MAINT_SERVICE" "$AUDIT_MAINT_TIMER"
    rm -f "$SYSCTL_FILE" "$LOGROTATE_FILE" "$INSTALL_PATH"
    systemctl daemon-reload
    log "程序已卸载。审计日志和配置仍保留在 $LOG_DIR、$CONFIG_DIR、/var/log/ocserv-attrib 与 /etc/ocserv-attrib.conf。"
}

menu() {
    require_root
    while true; do
        cat <<'EOF'

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
EOF
        read -r -p "请选择：" c
        case "$c" in
            1) status ;;
            2) read -r -p "限速（例如 50mbit）：" r; set_rate "$r" ;;
            3) network_apply ;;
            4)
                read -r -p "协议 tcp/udp/both：" p
                read -r -p "公网端口：" pp
                read -r -p "VPN IP：" vip
                read -r -p "目标端口：" tp
                read -r -p "来源 CIDR（默认 0.0.0.0/0）：" src
                port_add "$p" "$pp" "$vip" "$tp" "${src:-0.0.0.0/0}"
                ;;
            5) port_list ;;
            6)
                read -r -p "协议：" p
                read -r -p "公网端口：" pp
                port_delete "$p" "$pp"
                ;;
            7) bt_toggle yes ;;
            8) bt_toggle no ;;
            9)
                read -r -p "事件时间（UTC 例如 2026-10-16T16:58:15Z）：" t
                read -r -p "公网源端口：" pp
                read -r -p "协议 tcp/udp（可留空）：" p
                read -r -p "目标 IP（可留空）：" d
                read -r -p "目标端口（可留空）：" dp
                /usr/local/sbin/ocserv-whois --port "$pp" --time "$t" \
                    ${p:+--proto "$p"} ${d:+--dst "$d"} ${dp:+--dport "$dp"}
                ;;
            10) "${EDITOR:-nano}" "$CONFIG_FILE" ;;
            11) journalctl -u ocserv-network.service -u ocserv-limit.service \
                    -u ocserv-attrib-nat.service -u ocserv-attrib-session.service -u ocserv-session-audit.service -n 100 --no-pager ;;
            12)
                read -r -p "输入 YES 确认卸载：" x
                [[ "$x" == YES ]] && uninstall_program && exit
                ;;
            0) exit ;;
        esac
    done
}

usage() {
    cat <<EOF
$PROGRAM $VERSION

安装与管理：
  $PROGRAM install
  $PROGRAM uninstall
  $PROGRAM status
  $PROGRAM menu
  $PROGRAM network-ensure
  $PROGRAM network-apply
  $PROGRAM set-rate 50mbit
  $PROGRAM limit-apply
  $PROGRAM limit-clear

端口映射：
  $PROGRAM port add tcp 33891 192.168.1.10 3389 [0.0.0.0/0] [备注]
  $PROGRAM port list
  $PROGRAM port delete tcp 33891

BT 风险控制：
  $PROGRAM bt enable
  $PROGRAM bt disable

滥用/版权投诉溯源（2.2.0，ocserv-attrib）：
  $PROGRAM whois --port 3266 --time 2026-10-16T16:58:15Z [--ip 203.0.113.10] [--window 300] \\
      [--proto tcp|udp] [--dst 198.51.100.20] [--dport 443] [--days-back 3] [--json]
  $PROGRAM whois --inner 10.88.1.2 --time 2026-10-16T16:58:15Z
  $PROGRAM attrib stats|maintain

旧版历史审计（2.1.0，已由 ocserv-attrib 取代）：
  $PROGRAM audit stats
  $PROGRAM audit maintenance
  $PROGRAM audit migrate-csv
  $PROGRAM audit lookup --time "2026-08-02 10:30:00 +0800" \\
      --public-port 42671 --protocol tcp \\
      [--destination 198.51.100.20] [--destination-port 51413] [--tolerance 120]
EOF
}

main() {
    local cmd="${1:-menu}"
    case "$cmd" in
        install) install_program ;;
        uninstall) uninstall_program ;;
        status) status ;;
        menu) menu ;;
        network-ensure) network_ensure ;;
        network-apply) network_apply ;;
        set-rate) shift; set_rate "${1:-}" ;;
        limit-apply) limit_apply ;;
        limit-daemon) limit_daemon ;;
        limit-clear) limit_clear ;;
        whois) shift; exec /usr/local/sbin/ocserv-whois "$@" ;;
        attrib) shift; exec /usr/local/sbin/ocserv-attrib "$@" ;;
        audit-daemon) log "2.2.0: NAT audit moved to ocserv-attrib-nat.service"; exec sleep infinity ;;
        session-daemon) session_daemon ;;
        session-close) close_active_sessions ;;
        audit)
            shift
            case "${1:-}" in
                lookup) shift; audit_lookup "$@" ;;
                stats) audit_stats ;;
                maintenance) exec /usr/local/sbin/ocserv-attrib maintain ;;
                migrate-csv) audit_migrate_csv ;;
                close-open) audit_close_open ;;
                *) die "审计命令：lookup/stats/maintenance/migrate-csv" ;;
            esac
            ;;
        port)
            shift
            case "${1:-}" in
                add) shift; port_add "$@" ;;
                list) port_list ;;
                delete) shift; port_delete "$@" ;;
                *) die "端口命令：add/list/delete" ;;
            esac
            ;;
        bt)
            shift
            case "${1:-}" in
                enable) bt_toggle yes ;;
                disable) bt_toggle no ;;
                *) die "BT 命令：enable/disable" ;;
            esac
            ;;
        -h|--help|help) usage ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
