#!/usr/bin/env bash
set -Eeuo pipefail

# Debian / Alibaba Cloud CDT egress guard for Xray.
# It monitors the default-route interface's TX bytes. When the monthly limit is
# reached, it stops Xray for the rest of the Beijing-time calendar month and
# automatically starts Xray again in the next month.
#
# Examples:
#   bash install-aliyun-xray-traffic-guard.sh
#   bash install-aliyun-xray-traffic-guard.sh --limit 180 --used-gb 23.5
#   bash install-aliyun-xray-traffic-guard.sh --service xray.service

readonly PROGRAM_NAME="aliyun-xray-traffic-guard"
readonly CONFIG_FILE="/etc/${PROGRAM_NAME}.conf"
readonly DAEMON_FILE="/usr/local/sbin/${PROGRAM_NAME}"
readonly SERVICE_FILE="/etc/systemd/system/${PROGRAM_NAME}.service"
readonly STATE_DIR="/var/lib/${PROGRAM_NAME}"
readonly STATE_FILE="${STATE_DIR}/state"

LIMIT_GB="180"
USED_GB="0"
USED_GB_WAS_SET=0
CHECK_INTERVAL="10"
MONITORED_INTERFACE="auto"
XRAY_SERVICE="xray.service"
AUTO_RESUME="1"

usage() {
    cat <<'EOF'
用法：
  bash install-aliyun-xray-traffic-guard.sh [选项]

选项：
  --limit GB         月度停止阈值，默认 180（十进制 GB）
  --used-gb GB       本月安装前已使用的公网出流量，默认 0
                     重装时只有显式传入才会覆盖现有累计值
  --interval 秒      检查间隔，默认 10，允许 1～300
  --iface 网卡       指定网卡；默认 auto，自动识别默认路由网卡
  --service 服务名   Xray 服务名，默认 xray.service
  --no-auto-resume   下个自然月不自动启动 Xray
  -h, --help         显示帮助

安装后的常用命令：
  aliyun-xray-traffic-guard status
  aliyun-xray-traffic-guard reset 0
  journalctl -u aliyun-xray-traffic-guard -f
EOF
}

die() {
    printf '[错误] %s\n' "$*" >&2
    exit 1
}

info() {
    printf '[信息] %s\n' "$*"
}

is_nonnegative_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]{1,6})?$ ]]
}

gb_to_bytes() {
    awk -v value="$1" 'BEGIN { printf "%.0f\n", value * 1000000000 }'
}

while (($#)); do
    case "$1" in
        --limit)
            (($# >= 2)) || die "--limit 缺少数值"
            LIMIT_GB="$2"
            shift 2
            ;;
        --used-gb)
            (($# >= 2)) || die "--used-gb 缺少数值"
            USED_GB="$2"
            USED_GB_WAS_SET=1
            shift 2
            ;;
        --interval)
            (($# >= 2)) || die "--interval 缺少数值"
            CHECK_INTERVAL="$2"
            shift 2
            ;;
        --iface)
            (($# >= 2)) || die "--iface 缺少网卡名称"
            MONITORED_INTERFACE="$2"
            shift 2
            ;;
        --service)
            (($# >= 2)) || die "--service 缺少服务名"
            XRAY_SERVICE="$2"
            shift 2
            ;;
        --no-auto-resume)
            AUTO_RESUME="0"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知参数：$1（使用 --help 查看帮助）"
            ;;
    esac
done

((EUID == 0)) || die "请使用 root 权限运行。"
command -v systemctl >/dev/null 2>&1 || die "当前系统不是 systemd 环境。"

is_nonnegative_number "$LIMIT_GB" || die "--limit 必须是大于 0 的数字。"
awk -v value="$LIMIT_GB" 'BEGIN { exit !(value > 0) }' ||
    die "--limit 必须大于 0。"
is_nonnegative_number "$USED_GB" ||
    die "--used-gb 必须是大于或等于 0 的数字。"
[[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] ||
    die "--interval 必须是 1～300 的整数。"
((CHECK_INTERVAL >= 1 && CHECK_INTERVAL <= 300)) ||
    die "--interval 必须是 1～300 的整数。"
[[ "$MONITORED_INTERFACE" =~ ^[a-zA-Z0-9_.:@-]+$ ]] ||
    die "--iface 包含不允许的字符。"
[[ "$XRAY_SERVICE" =~ ^[a-zA-Z0-9_.@:-]+$ ]] ||
    die "--service 包含不允许的字符。"
[[ "$XRAY_SERVICE" == *.service ]] || XRAY_SERVICE="${XRAY_SERVICE}.service"

LIMIT_BYTES="$(gb_to_bytes "$LIMIT_GB")"
USED_BYTES="$(gb_to_bytes "$USED_GB")"

if ! command -v ip >/dev/null 2>&1; then
    info "正在安装 iproute2……"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends iproute2
fi

if [[ ! -e /usr/share/zoneinfo/Asia/Shanghai ]]; then
    info "正在安装时区数据……"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends tzdata
fi

systemctl cat "$XRAY_SERVICE" >/dev/null 2>&1 ||
    die "找不到 ${XRAY_SERVICE}，请先安装 Xray 或使用 --service 指定正确服务名。"

if [[ "$MONITORED_INTERFACE" != "auto" &&
      ! -r "/sys/class/net/${MONITORED_INTERFACE}/statistics/tx_bytes" ]]; then
    die "找不到网卡 ${MONITORED_INTERFACE}。"
fi

install -d -m 0755 "$STATE_DIR"

temporary_daemon="$(mktemp)"
config_tmp=""
service_tmp=""
cleanup() {
    rm -f "$temporary_daemon"
    [[ -z "$config_tmp" ]] || rm -f "$config_tmp"
    [[ -z "$service_tmp" ]] || rm -f "$service_tmp"
}
trap cleanup EXIT

cat >"$temporary_daemon" <<'DAEMON'
#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROGRAM_NAME="aliyun-xray-traffic-guard"
readonly CONFIG_FILE="/etc/${PROGRAM_NAME}.conf"
readonly STATE_DIR="/var/lib/${PROGRAM_NAME}"
readonly STATE_FILE="${STATE_DIR}/state"
readonly SYS_CLASS_NET="${SYS_CLASS_NET:-/sys/class/net}"

log() {
    printf '%s %s\n' "$(date '+%F %T')" "$*"
    logger -t "$PROGRAM_NAME" -- "$*" 2>/dev/null || true
}

die() {
    printf '[错误] %s\n' "$*" >&2
    exit 1
}

is_uint() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

load_config() {
    [[ -r "$CONFIG_FILE" ]] || die "配置文件不存在：${CONFIG_FILE}"
    # This file is generated by the installer and writable only by root.
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"

    is_uint "${LIMIT_BYTES:-}" && ((LIMIT_BYTES > 0)) ||
        die "配置中的 LIMIT_BYTES 无效。"
    is_uint "${CHECK_INTERVAL:-}" &&
        ((CHECK_INTERVAL >= 1 && CHECK_INTERVAL <= 300)) ||
        die "配置中的 CHECK_INTERVAL 无效。"
    [[ "${MONITORED_INTERFACE:-}" =~ ^[a-zA-Z0-9_.:@-]+$ ]] ||
        die "配置中的 MONITORED_INTERFACE 无效。"
    [[ "${XRAY_SERVICE:-}" =~ ^[a-zA-Z0-9_.@:-]+[.]service$ ]] ||
        die "配置中的 XRAY_SERVICE 无效。"
    [[ "${AUTO_RESUME:-}" == "0" || "${AUTO_RESUME:-}" == "1" ]] ||
        die "配置中的 AUTO_RESUME 无效。"
    is_uint "${INITIAL_USED_BYTES:-}" ||
        die "配置中的 INITIAL_USED_BYTES 无效。"
}

beijing_month() {
    TZ=Asia/Shanghai date '+%Y-%m'
}

detect_interface() {
    local route_line="" iface=""

    if [[ "$MONITORED_INTERFACE" != "auto" ]]; then
        printf '%s\n' "$MONITORED_INTERFACE"
        return
    fi

    route_line="$(ip -4 route get 1.1.1.1 2>/dev/null | head -n1 || true)"
    iface="$(awk '{
        for (i = 1; i <= NF; i++) {
            if ($i == "dev" && (i + 1) <= NF) {
                print $(i + 1)
                exit
            }
        }
    }' <<<"$route_line")"

    if [[ -z "$iface" ]]; then
        route_line="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -n1 || true)"
        iface="$(awk '{
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) {
                    print $(i + 1)
                    exit
                }
            }
        }' <<<"$route_line")"
    fi

    printf '%s\n' "$iface"
}

state_month=""
state_iface=""
last_raw_bytes="0"
tracked_bytes="0"
tripped="0"
resume_xray="0"

load_state() {
    local key value
    state_month=""
    state_iface=""
    last_raw_bytes="0"
    tracked_bytes="$INITIAL_USED_BYTES"
    tripped="0"
    resume_xray="0"

    [[ -r "$STATE_FILE" ]] || return 0

    while IFS='=' read -r key value; do
        case "$key" in
            month) state_month="$value" ;;
            iface) state_iface="$value" ;;
            last_raw_bytes) last_raw_bytes="$value" ;;
            tracked_bytes) tracked_bytes="$value" ;;
            tripped) tripped="$value" ;;
            resume_xray) resume_xray="$value" ;;
        esac
    done <"$STATE_FILE"

    is_uint "$last_raw_bytes" || last_raw_bytes="0"
    is_uint "$tracked_bytes" || tracked_bytes="$INITIAL_USED_BYTES"
    [[ "$tripped" == "0" || "$tripped" == "1" ]] || tripped="0"
    [[ "$resume_xray" == "0" || "$resume_xray" == "1" ]] || resume_xray="0"
}

write_state() {
    local temporary_state
    temporary_state="$(mktemp "${STATE_DIR}/.state.XXXXXX")"
    {
        printf 'month=%s\n' "$state_month"
        printf 'iface=%s\n' "$state_iface"
        printf 'last_raw_bytes=%s\n' "$last_raw_bytes"
        printf 'tracked_bytes=%s\n' "$tracked_bytes"
        printf 'tripped=%s\n' "$tripped"
        printf 'resume_xray=%s\n' "$resume_xray"
    } >"$temporary_state"
    chmod 0600 "$temporary_state"
    mv -f "$temporary_state" "$STATE_FILE"
}

format_gb() {
    awk -v bytes="$1" 'BEGIN { printf "%.3f", bytes / 1000000000 }'
}

resume_xray_if_pending() {
    ((tripped == 0 && resume_xray == 1)) || return 0

    if ((AUTO_RESUME == 0)); then
        resume_xray="0"
        write_state
        return 0
    fi

    if systemctl start "$XRAY_SERVICE"; then
        resume_xray="0"
        write_state
        log "新账期已开始，${XRAY_SERVICE} 已自动恢复运行。"
    else
        log "${XRAY_SERVICE} 自动恢复失败，将继续重试。"
    fi
}

stop_xray_for_limit() {
    if ((tripped == 0)); then
        if systemctl is-active --quiet "$XRAY_SERVICE"; then
            resume_xray="1"
        else
            resume_xray="0"
        fi
        tripped="1"
        write_state
        log "公网出方向累计 $(format_gb "$tracked_bytes") GB，达到阈值 $(format_gb "$LIMIT_BYTES") GB，停止 ${XRAY_SERVICE}。"
    fi

    if systemctl is-active --quiet "$XRAY_SERVICE"; then
        systemctl stop "$XRAY_SERVICE" ||
            log "停止 ${XRAY_SERVICE} 失败，将继续重试。"
    fi
}

initialize_or_update() {
    local current_month current_iface current_raw delta state_existed=0
    current_month="$(beijing_month)"
    current_iface="$(detect_interface)"

    if [[ -z "$current_iface" ||
          ! -r "${SYS_CLASS_NET}/${current_iface}/statistics/tx_bytes" ]]; then
        return 1
    fi

    current_raw="$(<"${SYS_CLASS_NET}/${current_iface}/statistics/tx_bytes")"
    is_uint "$current_raw" || return 1

    [[ -r "$STATE_FILE" ]] && state_existed=1
    load_state

    if [[ "$state_month" != "$current_month" ]]; then
        if ((state_existed == 1)) && [[ -n "$state_month" ]]; then
            log "进入新账期 ${current_month}（北京时间），月度累计已清零。"
            tracked_bytes="0"
        fi
        state_month="$current_month"
        state_iface="$current_iface"
        last_raw_bytes="$current_raw"
        tripped="0"
        write_state
        resume_xray_if_pending
        return 0
    fi

    if [[ "$state_iface" != "$current_iface" || "$current_raw" -lt "$last_raw_bytes" ]]; then
        if [[ -n "$state_iface" && "$state_iface" != "$current_iface" ]]; then
            log "默认路由网卡由 ${state_iface} 变为 ${current_iface}。"
        fi
        state_iface="$current_iface"
        last_raw_bytes="$current_raw"
    else
        delta=$((current_raw - last_raw_bytes))
        tracked_bytes=$((tracked_bytes + delta))
        last_raw_bytes="$current_raw"
    fi

    if ((tracked_bytes >= LIMIT_BYTES)); then
        stop_xray_for_limit
    else
        tripped="0"
        write_state
        resume_xray_if_pending
    fi
}

show_status() {
    local current_iface current_month percent xray_status
    load_config
    load_state
    current_iface="$(detect_interface)"
    current_month="$(beijing_month)"
    xray_status="$(systemctl is-active "$XRAY_SERVICE" 2>/dev/null || true)"

    if [[ ! -r "$STATE_FILE" ]]; then
        printf '状态：尚未产生状态数据\n'
        printf '当前识别网卡：%s\n' "${current_iface:-未识别}"
        printf '关停阈值：%s GB\n' "$(format_gb "$LIMIT_BYTES")"
        printf 'Xray：%s\n' "${xray_status:-unknown}"
        return
    fi

    percent="$(awk -v used="$tracked_bytes" -v limit="$LIMIT_BYTES" \
        'BEGIN { printf "%.2f", used * 100 / limit }')"
    printf '账期（北京时间）：%s\n' "${state_month:-$current_month}"
    printf '监控网卡：%s\n' "${state_iface:-${current_iface:-未识别}}"
    printf '公网出方向累计：%s GB\n' "$(format_gb "$tracked_bytes")"
    printf 'Xray 停止阈值：%s GB\n' "$(format_gb "$LIMIT_BYTES")"
    printf '使用比例：%s%%\n' "$percent"
    printf '是否已触发：%s\n' "$([[ "$tripped" == "1" ]] && printf '是' || printf '否')"
    printf 'Xray 服务：%s\n' "${xray_status:-unknown}"
}

reset_usage() {
    local new_gb="${1:-0}" new_bytes current_iface current_raw
    local should_resume=0

    [[ "$new_gb" =~ ^[0-9]+([.][0-9]{1,6})?$ ]] ||
        die "reset 后必须是大于或等于 0 的 GB 数值。"
    new_bytes="$(awk -v value="$new_gb" \
        'BEGIN { printf "%.0f\n", value * 1000000000 }')"
    current_iface="$(detect_interface)"
    [[ -n "$current_iface" &&
       -r "${SYS_CLASS_NET}/${current_iface}/statistics/tx_bytes" ]] ||
        die "无法识别可用的默认路由网卡。"
    current_raw="$(<"${SYS_CLASS_NET}/${current_iface}/statistics/tx_bytes")"

    load_state
    ((tripped == 1 && resume_xray == 1)) && should_resume=1

    state_month="$(beijing_month)"
    state_iface="$current_iface"
    last_raw_bytes="$current_raw"
    tracked_bytes="$new_bytes"
    tripped="0"
    resume_xray="$should_resume"
    write_state
    resume_xray_if_pending
    printf '本月累计值已设置为 %s GB。\n' "$(format_gb "$tracked_bytes")"
}

run_daemon() {
    local failure_logged=0
    load_config
    install -d -m 0755 "$STATE_DIR"

    while :; do
        if initialize_or_update; then
            failure_logged=0
        elif ((failure_logged == 0)); then
            log "暂时无法识别默认路由网卡，将继续重试。"
            failure_logged=1
        fi
        sleep "$CHECK_INTERVAL"
    done
}

case "${1:-run}" in
    run)
        run_daemon
        ;;
    status)
        show_status
        ;;
    reset)
        load_config
        install -d -m 0755 "$STATE_DIR"
        service_was_active=0
        if systemctl is-active --quiet "${PROGRAM_NAME}.service" 2>/dev/null; then
            service_was_active=1
            systemctl stop "${PROGRAM_NAME}.service"
        fi
        reset_usage "${2:-0}"
        if ((service_was_active == 1)); then
            systemctl start "${PROGRAM_NAME}.service"
        fi
        ;;
    *)
        die "用法：${PROGRAM_NAME} {run|status|reset [GB]}"
        ;;
esac
DAEMON

install -m 0755 "$temporary_daemon" "$DAEMON_FILE"

config_tmp="$(mktemp)"
{
    printf 'LIMIT_BYTES=%s\n' "$LIMIT_BYTES"
    printf 'CHECK_INTERVAL=%s\n' "$CHECK_INTERVAL"
    printf 'MONITORED_INTERFACE=%q\n' "$MONITORED_INTERFACE"
    printf 'XRAY_SERVICE=%q\n' "$XRAY_SERVICE"
    printf 'AUTO_RESUME=%s\n' "$AUTO_RESUME"
    printf 'INITIAL_USED_BYTES=%s\n' "$USED_BYTES"
} >"$config_tmp"
install -m 0600 "$config_tmp" "$CONFIG_FILE"

service_tmp="$(mktemp)"
cat >"$service_tmp" <<'SERVICE'
[Unit]
Description=Alibaba Cloud CDT Egress Guard for Xray
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/aliyun-xray-traffic-guard run
Restart=always
RestartSec=5
User=root
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/var/lib/aliyun-xray-traffic-guard

[Install]
WantedBy=multi-user.target
SERVICE
install -m 0644 "$service_tmp" "$SERVICE_FILE"

systemctl stop "${PROGRAM_NAME}.service" 2>/dev/null || true

if [[ ! -r "$STATE_FILE" || "$USED_GB_WAS_SET" == "1" ]]; then
    "$DAEMON_FILE" reset "$USED_GB"
fi

systemctl daemon-reload
systemctl enable --now "${PROGRAM_NAME}.service"

info "安装完成。"
info "监控口径：默认路由网卡的 TX（出方向）流量。"
info "阈值：${LIMIT_GB} GB；Xray 服务：${XRAY_SERVICE}。"
if ((AUTO_RESUME == 1)); then
    info "达到阈值后停止 Xray，下个北京时间自然月自动恢复。"
else
    info "达到阈值后停止 Xray，下个月不会自动恢复。"
fi
if systemctl is-active --quiet aliyun-traffic-guard.service 2>/dev/null; then
    printf '[警告] 检测到关机版 aliyun-traffic-guard 仍在运行；达到其阈值时服务器仍会关机。\n'
fi
printf '\n'
"$DAEMON_FILE" status
