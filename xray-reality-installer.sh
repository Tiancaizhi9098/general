#!/usr/bin/env bash

set -Eeuo pipefail

readonly XRAY_INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly MIHOMO_CONFIG="/root/mihomo-vless-reality.yaml"
readonly SCRIPT_VERSION="2026.07.28.3"

PORT="${PORT:-443}"
SERVER_NAME="${SERVER_NAME:-hkg.biliimg.com}"
REALITY_DEST="${REALITY_DEST:-${SERVER_NAME}:443}"
SERVER_ADDRESS="${SERVER_ADDRESS:-}"
NODE_NAME="${NODE_NAME:-VLESS-REALITY}"

INSTALLER_TMP=""
CONFIG_TMP=""
BACKUP_CONFIG=""
INSTALL_FINISHED=0
XRAY_WAS_ACTIVE=0

info() {
  printf '\033[1;34m[信息]\033[0m %s\n' "$*"
}

success() {
  printf '\033[1;32m[成功]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[提示]\033[0m %s\n' "$*"
}

die() {
  printf '\033[1;31m[错误]\033[0m %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?

  [[ -z "$INSTALLER_TMP" ]] || rm -f -- "$INSTALLER_TMP"
  [[ -z "$CONFIG_TMP" ]] || rm -f -- "$CONFIG_TMP"

  if (( exit_code != 0 && INSTALL_FINISHED == 0 )) && [[ -n "$BACKUP_CONFIG" && -f "$BACKUP_CONFIG" ]]; then
    warn "安装失败，正在恢复原 Xray 配置。"
    cp -a -- "$BACKUP_CONFIG" "$XRAY_CONFIG"
    if (( XRAY_WAS_ACTIVE == 1 )); then
      systemctl restart xray.service >/dev/null 2>&1 || true
    fi
  fi

  exit "$exit_code"
}

trap cleanup EXIT

require_root_and_systemd() {
  (( EUID == 0 )) || die "请使用 root 用户运行此脚本。"
  command -v systemctl >/dev/null 2>&1 || die "当前系统不支持 systemd。"
}

validate_settings() {
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT 必须是数字。"
  (( PORT >= 1 && PORT <= 65535 )) || die "PORT 必须在 1-65535 之间。"
  [[ "$SERVER_NAME" =~ ^[A-Za-z0-9.-]+$ ]] || die "SERVER_NAME 格式不正确。"
  [[ "$REALITY_DEST" =~ ^[A-Za-z0-9.-]+:[0-9]{1,5}$ ]] || die "REALITY_DEST 必须是 域名:端口。"
  [[ "$NODE_NAME" != *$'\n'* && "$NODE_NAME" != *$'\r'* ]] || die "NODE_NAME 不能包含换行符。"

  if [[ -n "$SERVER_ADDRESS" ]]; then
    [[ "$SERVER_ADDRESS" =~ ^[A-Za-z0-9._:-]+$ ]] || die "SERVER_ADDRESS 格式不正确。"
  fi
}

install_dependencies() {
  if command -v curl >/dev/null 2>&1 \
    && command -v openssl >/dev/null 2>&1 \
    && command -v jq >/dev/null 2>&1 \
    && command -v ss >/dev/null 2>&1; then
    info "运行依赖已满足，跳过重复安装。"
    return
  fi

  info "安装运行依赖……"

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl ca-certificates openssl jq iproute2
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl jq iproute
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssl jq iproute
  else
    die "不支持当前系统的包管理器；请先安装 curl、ca-certificates、openssl、jq 和 iproute2。"
  fi
}

detect_server_address() {
  local detected=""
  local endpoint

  if [[ -n "$SERVER_ADDRESS" ]]; then
    return
  fi

  for endpoint in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com"; do
    detected="$(curl -4fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null || true)"
    detected="${detected//$'\r'/}"
    detected="${detected//$'\n'/}"
    if [[ "$detected" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      SERVER_ADDRESS="$detected"
      return
    fi
  done

  for endpoint in \
    "https://api64.ipify.org" \
    "https://ipv6.icanhazip.com"; do
    detected="$(curl -6fsS --connect-timeout 5 --max-time 10 "$endpoint" 2>/dev/null || true)"
    detected="${detected//$'\r'/}"
    detected="${detected//$'\n'/}"
    if [[ "$detected" == *:* && "$detected" =~ ^[0-9A-Fa-f:]+$ ]]; then
      SERVER_ADDRESS="$detected"
      return
    fi
  done

  die "无法自动获取公网 IP。请使用 SERVER_ADDRESS=服务器IP 重新运行。"
}

install_xray() {
  INSTALLER_TMP="$(mktemp)"
  info "下载并运行 Xray 官方安装脚本……"
  curl -fsSL --retry 3 "$XRAY_INSTALLER_URL" -o "$INSTALLER_TMP"
  bash "$INSTALLER_TMP" install
  [[ -x "$XRAY_BIN" ]] || die "Xray 安装完成后未找到 $XRAY_BIN。"
}

backup_and_stop_xray() {
  if [[ -f "$XRAY_CONFIG" ]]; then
    BACKUP_CONFIG="${XRAY_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$XRAY_CONFIG" "$BACKUP_CONFIG"
    info "旧配置已备份到 $BACKUP_CONFIG"
  fi

  if systemctl is-active --quiet xray.service; then
    XRAY_WAS_ACTIVE=1
    systemctl stop xray.service
  fi
}

check_listen_port() {
  local listeners

  listeners="$(ss -H -ltn | awk -v suffix=":${PORT}" '$4 ~ (suffix "$") { print }')"
  if [[ -n "$listeners" ]]; then
    printf '%s\n' "$listeners" >&2
    die "TCP 端口 $PORT 已被其他程序占用。请关闭占用程序或使用 PORT=其他端口 重新运行。"
  fi
}

generate_credentials() {
  local key_output
  local -a key_values=()

  UUID="$("$XRAY_BIN" uuid)"
  key_output="$("$XRAY_BIN" x25519)"
  mapfile -t key_values < <(
    grep -Eo '[A-Za-z0-9_-]{43}' <<<"$key_output" || true
  )
  PRIVATE_KEY="${key_values[0]:-}"
  PUBLIC_KEY="${key_values[1]:-}"
  SHORT_ID="$(openssl rand -hex 8)"

  [[ -n "$UUID" ]] || die "UUID 生成失败。"
  [[ -n "$PRIVATE_KEY" ]] || die "Reality 私钥生成失败。"
  [[ -n "$PUBLIC_KEY" ]] || die "Reality 公钥生成失败。"
  [[ "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || die "Reality short ID 生成失败。"
}

write_xray_config() {
  CONFIG_TMP="$(mktemp --suffix=.json)"

  jq -n \
    --arg uuid "$UUID" \
    --arg private_key "$PRIVATE_KEY" \
    --arg short_id "$SHORT_ID" \
    --arg dest "$REALITY_DEST" \
    --arg server_name "$SERVER_NAME" \
    --argjson port "$PORT" \
    '{
      log: {
        loglevel: "warning"
      },
      inbounds: [
        {
          listen: "0.0.0.0",
          port: $port,
          protocol: "vless",
          settings: {
            clients: [
              {
                id: $uuid,
                flow: "xtls-rprx-vision"
              }
            ],
            decryption: "none"
          },
          streamSettings: {
            network: "tcp",
            security: "reality",
            realitySettings: {
              show: false,
              dest: $dest,
              xver: 0,
              serverNames: [
                $server_name
              ],
              privateKey: $private_key,
              shortIds: [
                $short_id
              ]
            }
          },
          sniffing: {
            enabled: true,
            destOverride: [
              "http",
              "tls",
              "quic"
            ],
            routeOnly: true
          }
        }
      ],
      outbounds: [
        {
          protocol: "freedom",
          tag: "direct"
        },
        {
          protocol: "blackhole",
          tag: "block"
        }
      ]
    }' >"$CONFIG_TMP"

  "$XRAY_BIN" run -test -config "$CONFIG_TMP"

  install -d -m 755 "$(dirname "$XRAY_CONFIG")"
  install -m 640 "$CONFIG_TMP" "$XRAY_CONFIG"

  local service_user
  local service_group
  service_user="$(systemctl show xray.service -p User --value)"
  service_user="${service_user:-root}"
  service_group="$(id -gn "$service_user" 2>/dev/null || printf 'root')"
  chown "root:${service_group}" "$XRAY_CONFIG"
}

yaml_double_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

write_mihomo_config() {
  local yaml_name
  local yaml_server
  local yaml_server_name

  yaml_name="$(yaml_double_quote "$NODE_NAME")"
  yaml_server="$(yaml_double_quote "$SERVER_ADDRESS")"
  yaml_server_name="$(yaml_double_quote "$SERVER_NAME")"

  umask 077
  {
    printf 'proxies:\n'
    printf '  - name: %s\n' "$yaml_name"
    printf '    type: vless\n'
    printf '    server: %s\n' "$yaml_server"
    printf '    port: %s\n' "$PORT"
    printf '    uuid: "%s"\n' "$UUID"
    printf '    network: tcp\n'
    printf '    udp: true\n'
    printf '    tls: true\n'
    printf '    flow: xtls-rprx-vision\n'
    printf '    packet-encoding: xudp\n'
    printf '    servername: %s\n' "$yaml_server_name"
    printf '    client-fingerprint: chrome\n'
    printf '    reality-opts:\n'
    printf '      public-key: "%s"\n' "$PUBLIC_KEY"
    printf '      short-id: "%s"\n' "$SHORT_ID"
  } >"$MIHOMO_CONFIG"
}

open_local_firewall() {
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow "${PORT}/tcp" >/dev/null
    info "已放行 UFW 的 TCP 端口 $PORT。"
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld.service; then
    firewall-cmd --permanent --add-port="${PORT}/tcp" >/dev/null
    firewall-cmd --reload >/dev/null
    info "已放行 firewalld 的 TCP 端口 $PORT。"
  fi
}

start_and_verify_xray() {
  systemctl daemon-reload
  systemctl enable xray.service >/dev/null

  if ! systemctl restart xray.service; then
    journalctl -u xray.service -n 30 --no-pager >&2 || true
    die "Xray 服务启动失败。"
  fi

  sleep 1
  if ! systemctl is-active --quiet xray.service; then
    journalctl -u xray.service -n 30 --no-pager >&2 || true
    die "Xray 服务未保持运行。"
  fi

  if ! ss -H -ltn | awk -v suffix=":${PORT}" '$4 ~ (suffix "$") { found=1 } END { exit !found }'; then
    die "Xray 已启动，但未监听 TCP 端口 $PORT。"
  fi
}

print_result() {
  local xray_version
  xray_version="$("$XRAY_BIN" version | head -n 1)"

  printf '\n'
  success "VLESS + REALITY + XTLS Vision 节点已安装"
  printf 'Xray 版本：%s\n' "$xray_version"
  printf '服务状态：active\n'
  printf '服务端配置：%s\n' "$XRAY_CONFIG"
  printf 'Mihomo 配置：%s\n' "$MIHOMO_CONFIG"
  [[ -z "$BACKUP_CONFIG" ]] || printf '原配置备份：%s\n' "$BACKUP_CONFIG"
  printf '\n'
  printf '%s\n' '---------- Mihomo YAML ----------'
  cat "$MIHOMO_CONFIG"
  printf '%s\n' '---------------------------------'
  printf '\n'
  warn "如果使用云服务器安全组，请另外放行 TCP 端口 $PORT。"
}

main() {
  require_root_and_systemd
  info "脚本版本：$SCRIPT_VERSION"
  validate_settings
  install_dependencies
  detect_server_address
  install_xray
  backup_and_stop_xray
  check_listen_port
  generate_credentials
  write_xray_config
  write_mihomo_config
  open_local_firewall
  start_and_verify_xray
  INSTALL_FINISHED=1
  print_result
}

main "$@"
