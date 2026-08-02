#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM="ocserv-manager"
VERSION="2.0.1"

INSTALL_PATH="/usr/local/sbin/ocserv-manager"
CONFIG_DIR="/etc/ocserv-manager"
CONFIG_FILE="${CONFIG_DIR}/config"
PORT_MAP_FILE="${CONFIG_DIR}/port-mappings.tsv"
STATE_DIR="/var/lib/ocserv-manager"
SESSION_STATE="${STATE_DIR}/active-sessions.tsv"
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

    # Rebuild the IFB root hierarchy from scratch. Using replace/change can
    # fail when an older script left another qdisc type attached to ifb0.
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

    # Remove qdiscs previously created by this or older limiter scripts.
    # Recreating the hierarchy is more portable than tc replace/change.
    tc qdisc del dev "$iface" root 2>/dev/null || true
    tc qdisc del dev "$iface" ingress 2>/dev/null || true

    run_tc "create HTB root on $iface" \
        tc qdisc add dev "$iface" root handle 1: htb default 10

    run_tc "create HTB class on $iface" \
        tc class add dev "$iface" parent 1: classid 1:10 \
        htb rate "$RATE" ceil "$RATE"

    run_tc "create ingress qdisc on $iface" \
        tc qdisc add dev "$iface" handle ffff: ingress

    run_tc "redirect ingress from $iface to $IFB_DEVICE" \
        tc filter add dev "$iface" parent ffff: protocol all pref 10 u32 \
        match u32 0 0 action mirred egress redirect dev "$IFB_DEVICE"
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

audit_file_today() {
    printf '%s/nat-%s.csv\n' "$AUDIT_DIR" "$(date -u +%F)"
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

        if output="$(bash -c "$OCCTL_COMMAND" 2>/dev/null)"; then
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
    ensure_dirs

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
        die "无法解析时间：$time_text。建议包含时区，例如 '2026-08-02 10:30:00 +0800'"

    protocol="${protocol,,}"
    [[ "$protocol" =~ ^(tcp|udp)$ ]] || die "协议只能是 tcp 或 udp"

    local candidates
    candidates="$(
        read_log_files "$AUDIT_DIR" 'nat-*.csv' |
        awk -F, -v t="$target_epoch" -v tol="$tolerance" \
            -v pp="$public_port" -v proto="$protocol" \
            -v dip="$dst_ip" -v dp="$dst_port" '
            $1 ~ /^[0-9]+$/ && $2=="NEW" && $3==proto && $7==pp &&
            ($1>=t-tol && $1<=t+tol) &&
            (dip=="" || $8==dip) &&
            (dp=="" || $9==dp) {
                diff=$1-t; if(diff<0)diff=-diff
                print diff "," $0
            }
        ' | sort -t, -k1,1n | head -n10
    )"

    [[ -n "$candidates" ]] || {
        echo "未找到匹配记录。可尝试增大 --tolerance，或补充/移除目标 IP 与端口条件。"
        return 1
    }

    echo "========== NAT 历史审计查询 =========="
    local line diff epoch event proto vpn_ip vpn_port pub_ip pub_port dip dport session username start end
    while IFS=, read -r diff epoch event proto vpn_ip vpn_port pub_ip pub_port dip dport; do
        session="$(lookup_username "$epoch" "$vpn_ip")"
        username=""
        if [[ -n "$session" ]]; then
            IFS=, read -r username start end <<<"$session"
        fi

        echo
        printf '记录时间：%s UTC（相差 %s 秒）\n' "$(date -u -d "@$epoch" '+%F %T')" "$diff"
        printf '协议：%s\n' "$proto"
        printf '公网映射：%s:%s\n' "$pub_ip" "$pub_port"
        printf 'VPN 客户端：%s:%s\n' "$vpn_ip" "$vpn_port"
        printf '远程目标：%s:%s\n' "$dip" "$dport"
        printf 'VPN 用户：%s\n' "${username:-未匹配到用户名会话}"
    done <<<"$candidates"
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
        ocserv-audit.service ocserv-session-audit.service 2>/dev/null || true
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

SESSION_AUDIT_ENABLED="${SESSION_AUDIT_ENABLED:-yes}"
SESSION_SCAN_INTERVAL="${SESSION_SCAN_INTERVAL:-30}"
OCCTL_COMMAND="${OCCTL_COMMAND:-occtl -j show users}"

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
ExecStart=${INSTALL_PATH} network-apply
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
}

write_logrotate() {
    load_config
    cat > "$LOGROTATE_FILE" <<EOF
${AUDIT_DIR}/*.csv ${SESSION_DIR}/*.csv {
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

install_program() {
    require_root

    local required=(ip awk sed grep sysctl systemctl tc modprobe python3 conntrack jq gzip find sort stdbuf)
    local missing=() cmd
    for cmd in "${required[@]}"; do has "$cmd" || missing+=("$cmd"); done
    if ((${#missing[@]})); then
        die "缺少依赖：${missing[*]}。Debian/Ubuntu 可执行：apt install -y iproute2 iptables kmod conntrack jq coreutils python3 logrotate"
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
    systemctl enable --now ocserv-audit.service
    systemctl enable --now ocserv-session-audit.service
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
        ocserv-audit.service ocserv-session-audit.service 2>/dev/null || true
    systemctl stop ocserv-network.service 2>/dev/null || true
    limit_clear 2>/dev/null || true

    remove_chain filter FORWARD "$FORWARD_CHAIN"
    remove_chain filter "$FORWARD_CHAIN" "$BT_CHAIN" || true
    remove_chain filter "$FORWARD_CHAIN" "$DNAT_FILTER_CHAIN" || true
    remove_chain nat PREROUTING "$DNAT_CHAIN"
    remove_chain nat POSTROUTING "$NAT_CHAIN"

    rm -f "$NETWORK_SERVICE" "$NETWORK_TIMER" "$LIMIT_SERVICE" "$AUDIT_SERVICE" "$SESSION_SERVICE"
    rm -f "$SYSCTL_FILE" "$LOGROTATE_FILE" "$INSTALL_PATH"
    systemctl daemon-reload
    log "程序已卸载。审计日志和配置仍保留在 $LOG_DIR 与 $CONFIG_DIR。"
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
                read -r -p "事件时间（含时区）：" t
                read -r -p "公网源端口：" pp
                read -r -p "协议 tcp/udp：" p
                read -r -p "目标 IP（可留空）：" d
                read -r -p "目标端口（可留空）：" dp
                audit_lookup --time "$t" --public-port "$pp" --protocol "$p" \
                    ${d:+--destination "$d"} ${dp:+--destination-port "$dp"}
                ;;
            10) "${EDITOR:-nano}" "$CONFIG_FILE" ;;
            11) journalctl -u ocserv-network.service -u ocserv-limit.service \
                    -u ocserv-audit.service -u ocserv-session-audit.service -n 100 --no-pager ;;
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

历史审计：
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
        network-apply) network_apply ;;
        set-rate) shift; set_rate "${1:-}" ;;
        limit-apply) limit_apply ;;
        limit-daemon) limit_daemon ;;
        limit-clear) limit_clear ;;
        audit-daemon) audit_daemon ;;
        session-daemon) session_daemon ;;
        session-close) close_active_sessions ;;
        audit)
            shift
            [[ "${1:-}" == lookup ]] || die "仅支持 audit lookup"
            shift
            audit_lookup "$@"
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
