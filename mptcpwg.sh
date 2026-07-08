#!/usr/bin/env bash
set -euo pipefail

# MPTCP over 4 WireGuard relay paths.
# Roles:
#   prepare   Run once on the entry server. Creates /root/mptcpwg.env.
#   entry     Run on 119.135.0.5 after copying /root/mptcpwg.env there.
#   gz1       Run on 182.61.57.187 after copying /root/mptcpwg.env there.
#   gz2       Run on 182.61.6.142 after copying /root/mptcpwg.env there.
#   gz3       Run on 118.145.110.134 after copying /root/mptcpwg.env there.
#   gz4       Run on 111.230.88.75 after copying /root/mptcpwg.env there.
#   hk        Run on 161.248.136.111 after copying /root/mptcpwg.env there.
#   test      Run on entry after entry/gz/hk are configured.
#   xray      Run on entry after test is good. Backs up and rewrites Xray outbound.
#
# Target flow:
#   mihomo -> entry Xray:62701 -> 127.0.0.1:10809
#   entry mptcp relay -> MPTCP subflows over wg-gz1..wg-gz4 -> GZ NAT relays
#   HK mptcp relay -> 127.0.0.1:10808 danted -> HK public Internet

ENTRY_IP="119.135.0.5"
HK_IP="161.248.136.111"

GZ1_IP="182.61.57.187"
GZ2_IP="182.61.6.142"
GZ3_IP="118.145.110.134"
GZ4_IP="111.230.88.75"

HK_MPTCP_PORT="40000"
ENTRY_LOCAL_SOCKS_PORT="10809"
HK_LOCAL_SOCKS_PORT="10808"

WG_BASE_PORT="52000"
WG_NET_PREFIX="10.201"
ENV_FILE="/root/mptcpwg.env"

need_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "Run as root." >&2
    exit 1
  fi
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "$@"
}

load_env() {
  if [ ! -f "$ENV_FILE" ]; then
    echo "Missing $ENV_FILE. Run '$0 prepare' on the entry server first, then copy $ENV_FILE to this server." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

prepare() {
  need_root
  apt_install wireguard-tools

  umask 077
  ENTRY_PRIV="$(wg genkey)"
  ENTRY_PUB="$(printf '%s' "$ENTRY_PRIV" | wg pubkey)"

  GZ1_PRIV="$(wg genkey)"
  GZ1_PUB="$(printf '%s' "$GZ1_PRIV" | wg pubkey)"
  GZ2_PRIV="$(wg genkey)"
  GZ2_PUB="$(printf '%s' "$GZ2_PRIV" | wg pubkey)"
  GZ3_PRIV="$(wg genkey)"
  GZ3_PUB="$(printf '%s' "$GZ3_PRIV" | wg pubkey)"
  GZ4_PRIV="$(wg genkey)"
  GZ4_PUB="$(printf '%s' "$GZ4_PRIV" | wg pubkey)"

  cat >"$ENV_FILE" <<EOF
ENTRY_PRIV='$ENTRY_PRIV'
ENTRY_PUB='$ENTRY_PUB'
GZ1_PRIV='$GZ1_PRIV'
GZ1_PUB='$GZ1_PUB'
GZ2_PRIV='$GZ2_PRIV'
GZ2_PUB='$GZ2_PUB'
GZ3_PRIV='$GZ3_PRIV'
GZ3_PUB='$GZ3_PUB'
GZ4_PRIV='$GZ4_PRIV'
GZ4_PUB='$GZ4_PUB'
EOF
  chmod 600 "$ENV_FILE"

  echo "Created $ENV_FILE"
  echo
  echo "Copy this file to /root/mptcpwg.env on entry, gz1, gz2, gz3, gz4, and hk."
  echo "Example from your own terminal:"
  echo "  scp -P 62700 $ENV_FILE root@$ENTRY_IP:/root/mptcpwg.env"
  echo "  scp $ENV_FILE root@$GZ1_IP:/root/mptcpwg.env"
  echo "  scp $ENV_FILE root@$GZ2_IP:/root/mptcpwg.env"
  echo "  scp $ENV_FILE root@$GZ3_IP:/root/mptcpwg.env"
  echo "  scp $ENV_FILE root@$GZ4_IP:/root/mptcpwg.env"
  echo "  scp -J root@$GZ1_IP:22 -P 12760 $ENV_FILE root@$HK_IP:/root/mptcpwg.env"
}

enable_mptcp() {
  cat >/etc/sysctl.d/99-mptcpwg.conf <<EOF
net.mptcp.enabled=1
net.mptcp.checksum_enabled=0
EOF
  sysctl --system >/dev/null
  ip mptcp limits set subflows 8 add_addr_accepted 8 || true
}

install_relay_script() {
  install -d -m 755 /usr/local/lib/mptcpwg
  cat >/usr/local/lib/mptcpwg/mptcp_relay.py <<'PY'
#!/usr/bin/env python3
import argparse
import selectors
import signal
import socket
import sys

IPPROTO_MPTCP = 262

def make_listener(host, port, mptcp):
    proto = IPPROTO_MPTCP if mptcp else 0
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM, proto)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((host, port))
    s.listen(256)
    return s

def make_connection(host, port, mptcp):
    proto = IPPROTO_MPTCP if mptcp else 0
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM, proto)
    s.connect((host, port))
    return s

def pipe(a, b):
    sel = selectors.DefaultSelector()
    a.setblocking(False)
    b.setblocking(False)
    sel.register(a, selectors.EVENT_READ, b)
    sel.register(b, selectors.EVENT_READ, a)
    sockets = {a, b}
    try:
        while sockets:
            for key, _ in sel.select():
                src = key.fileobj
                dst = key.data
                try:
                    data = src.recv(65536)
                except BlockingIOError:
                    continue
                except OSError:
                    return
                if not data:
                    return
                try:
                    dst.sendall(data)
                except OSError:
                    return
    finally:
        for s in list(sockets):
            try:
                sel.unregister(s)
            except Exception:
                pass
            try:
                s.close()
            except Exception:
                pass

def main():
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    p = argparse.ArgumentParser()
    p.add_argument("--listen-host", required=True)
    p.add_argument("--listen-port", type=int, required=True)
    p.add_argument("--target-host", required=True)
    p.add_argument("--target-port", type=int, required=True)
    p.add_argument("--listen-mptcp", action="store_true")
    p.add_argument("--connect-mptcp", action="store_true")
    args = p.parse_args()

    listener = make_listener(args.listen_host, args.listen_port, args.listen_mptcp)
    print(f"listening on {args.listen_host}:{args.listen_port}", flush=True)
    while True:
        client, _ = listener.accept()
        try:
            upstream = make_connection(args.target_host, args.target_port, args.connect_mptcp)
        except Exception as e:
            print(f"connect failed: {e}", file=sys.stderr, flush=True)
            client.close()
            continue
        pid = None
        try:
            pid = __import__("os").fork()
        except AttributeError:
            pid = None
        if pid == 0:
            listener.close()
            pipe(client, upstream)
            sys.exit(0)
        if pid is None:
            pipe(client, upstream)
        else:
            client.close()
            upstream.close()

if __name__ == "__main__":
    main()
PY
  chmod 755 /usr/local/lib/mptcpwg/mptcp_relay.py
}

entry_role() {
  need_root
  load_env
  apt_install wireguard-tools iproute2 python3 jq curl
  enable_mptcp
  install_relay_script

  install -d -m 700 /etc/wireguard

  cat >/etc/wireguard/wg-gz1.conf <<EOF
[Interface]
Address = ${WG_NET_PREFIX}.1.2/30
PrivateKey = $ENTRY_PRIV
ListenPort = $((WG_BASE_PORT + 1))
MTU = 1380
Table = off

[Peer]
PublicKey = $GZ1_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = ${GZ1_IP}:$((WG_BASE_PORT + 1))
PersistentKeepalive = 15
EOF

  cat >/etc/wireguard/wg-gz2.conf <<EOF
[Interface]
Address = ${WG_NET_PREFIX}.2.2/30
PrivateKey = $ENTRY_PRIV
ListenPort = $((WG_BASE_PORT + 2))
MTU = 1380
Table = off

[Peer]
PublicKey = $GZ2_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = ${GZ2_IP}:$((WG_BASE_PORT + 2))
PersistentKeepalive = 15
EOF

  cat >/etc/wireguard/wg-gz3.conf <<EOF
[Interface]
Address = ${WG_NET_PREFIX}.3.2/30
PrivateKey = $ENTRY_PRIV
ListenPort = $((WG_BASE_PORT + 3))
MTU = 1380
Table = off

[Peer]
PublicKey = $GZ3_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = ${GZ3_IP}:$((WG_BASE_PORT + 3))
PersistentKeepalive = 15
EOF

  cat >/etc/wireguard/wg-gz4.conf <<EOF
[Interface]
Address = ${WG_NET_PREFIX}.4.2/30
PrivateKey = $ENTRY_PRIV
ListenPort = $((WG_BASE_PORT + 4))
MTU = 1380
Table = off

[Peer]
PublicKey = $GZ4_PUB
AllowedIPs = 0.0.0.0/0
Endpoint = ${GZ4_IP}:$((WG_BASE_PORT + 4))
PersistentKeepalive = 15
EOF

  systemctl enable --now wg-quick@wg-gz1 wg-quick@wg-gz2 wg-quick@wg-gz3 wg-quick@wg-gz4

  cat >/usr/local/sbin/mptcpwg-entry-routing.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
ip mptcp limits set subflows 8 add_addr_accepted 8 || true
ip mptcp endpoint flush 2>/dev/null || true
EOF
  for n in 1 2 3 4; do
    table=$((100+n))
    src="${WG_NET_PREFIX}.${n}.2"
    dev="wg-gz${n}"
    cat >>/usr/local/sbin/mptcpwg-entry-routing.sh <<EOF
ip rule del from "$src/32" table "$table" 2>/dev/null || true
ip route flush table "$table" 2>/dev/null || true
ip rule add from "$src/32" table "$table"
ip route add default dev "$dev" table "$table"
ip mptcp endpoint add "$src" dev "$dev" subflow 2>/dev/null || true
EOF
  done
  cat >>/usr/local/sbin/mptcpwg-entry-routing.sh <<EOF
ip route replace "${HK_IP}/32" dev wg-gz1
EOF
  chmod 755 /usr/local/sbin/mptcpwg-entry-routing.sh

  cat >/etc/systemd/system/mptcpwg-entry-routing.service <<EOF
[Unit]
Description=MPTCPWG entry routing and MPTCP endpoints
After=network-online.target wg-quick@wg-gz1.service wg-quick@wg-gz2.service wg-quick@wg-gz3.service wg-quick@wg-gz4.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mptcpwg-entry-routing.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/mptcpwg-entry-relay.service <<EOF
[Unit]
Description=MPTCPWG entry local SOCKS TCP-to-MPTCP relay
After=network-online.target mptcpwg-entry-routing.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/mptcpwg/mptcp_relay.py --listen-host 127.0.0.1 --listen-port ${ENTRY_LOCAL_SOCKS_PORT} --target-host ${HK_IP} --target-port ${HK_MPTCP_PORT} --connect-mptcp
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now mptcpwg-entry-routing
  systemctl enable --now mptcpwg-entry-relay

  echo "Entry configured. Local SOCKS relay is 127.0.0.1:${ENTRY_LOCAL_SOCKS_PORT}"
}

gz_role() {
  need_root
  load_env
  local n="$1"
  local priv pub peer_addr local_addr port
  case "$n" in
    1) priv="$GZ1_PRIV"; pub="$ENTRY_PUB"; local_addr="${WG_NET_PREFIX}.1.1/30"; peer_addr="${WG_NET_PREFIX}.1.2/32"; port=$((WG_BASE_PORT + 1));;
    2) priv="$GZ2_PRIV"; pub="$ENTRY_PUB"; local_addr="${WG_NET_PREFIX}.2.1/30"; peer_addr="${WG_NET_PREFIX}.2.2/32"; port=$((WG_BASE_PORT + 2));;
    3) priv="$GZ3_PRIV"; pub="$ENTRY_PUB"; local_addr="${WG_NET_PREFIX}.3.1/30"; peer_addr="${WG_NET_PREFIX}.3.2/32"; port=$((WG_BASE_PORT + 3));;
    4) priv="$GZ4_PRIV"; pub="$ENTRY_PUB"; local_addr="${WG_NET_PREFIX}.4.1/30"; peer_addr="${WG_NET_PREFIX}.4.2/32"; port=$((WG_BASE_PORT + 4));;
    *) echo "bad gz number"; exit 1;;
  esac

  apt_install wireguard-tools iproute2 nftables

  cat >/etc/sysctl.d/99-mptcpwg-forward.conf <<EOF
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null

  install -d -m 700 /etc/wireguard
  cat >/etc/wireguard/wg-entry.conf <<EOF
[Interface]
Address = ${local_addr}
PrivateKey = ${priv}
ListenPort = ${port}
MTU = 1380

[Peer]
PublicKey = ${pub}
AllowedIPs = ${peer_addr}
PersistentKeepalive = 15
EOF
  systemctl enable --now wg-quick@wg-entry

  WAN_IF="$(ip route show default | awk '{print $5; exit}')"
  cat >/usr/local/sbin/mptcpwg-nft.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail
nft list table ip mptcpwg >/dev/null 2>&1 && nft delete table ip mptcpwg || true
nft -f - <<'NFT'
table ip mptcpwg {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${peer_addr%/32} ip daddr ${HK_IP} tcp dport ${HK_MPTCP_PORT} oifname "${WAN_IF}" masquerade
  }
}
NFT
EOF
  chmod 755 /usr/local/sbin/mptcpwg-nft.sh
  /usr/local/sbin/mptcpwg-nft.sh

  cat >/etc/systemd/system/mptcpwg-nft.service <<EOF
[Unit]
Description=MPTCPWG NAT table
After=network-online.target wg-quick@wg-entry.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mptcpwg-nft.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now mptcpwg-nft

  echo "GZ${n} configured. It relays ${peer_addr%/32} -> ${HK_IP}:${HK_MPTCP_PORT} through ${WAN_IF}."
}

hk_role() {
  need_root
  load_env
  apt_install iproute2 python3 dante-server jq curl
  enable_mptcp
  install_relay_script

  WAN_IF="$(ip route show default | awk '{print $5; exit}')"
  cp -a /etc/danted.conf "/etc/danted.conf.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
  cat >/etc/danted.conf <<EOF
logoutput: syslog
internal: 127.0.0.1 port = ${HK_LOCAL_SOCKS_PORT}
external: ${WAN_IF}
socksmethod: none
user.privileged: root
user.unprivileged: nobody

client pass {
 from: 127.0.0.1/32 to: 0.0.0.0/0
}

socks pass {
 from: 127.0.0.1/32 to: 0.0.0.0/0
 protocol: tcp udp
 command: connect udpassociate
}
EOF
  systemctl enable --now danted
  systemctl restart danted

  cat >/etc/systemd/system/mptcpwg-hk-relay.service <<EOF
[Unit]
Description=MPTCPWG HK MPTCP-to-local-SOCKS relay
After=network-online.target danted.service
Wants=network-online.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/lib/mptcpwg/mptcp_relay.py --listen-host 0.0.0.0 --listen-port ${HK_MPTCP_PORT} --target-host 127.0.0.1 --target-port ${HK_LOCAL_SOCKS_PORT} --listen-mptcp
Restart=always
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now mptcpwg-hk-relay

  echo "HK configured. MPTCP listener is 0.0.0.0:${HK_MPTCP_PORT}; local SOCKS is 127.0.0.1:${HK_LOCAL_SOCKS_PORT}"
}

test_role() {
  need_root
  echo "WireGuard:"
  wg show || true
  echo
  echo "MPTCP endpoints:"
  ip mptcp endpoint show || true
  echo
  echo "MPTCP counters before curl:"
  nstat -az | grep -E 'MPTcp|TcpExtMPTCP' || true
  echo
  echo "Testing SOCKS through MPTCP relay:"
  curl -x "socks5h://127.0.0.1:${ENTRY_LOCAL_SOCKS_PORT}" -4 --max-time 20 https://api.ipify.org
  echo
  echo "MPTCP counters after curl:"
  nstat -az | grep -E 'MPTcp|TcpExtMPTCP' || true
  echo
  echo "Active MPTCP sockets:"
  ss -Mnti dst "${HK_IP}:${HK_MPTCP_PORT}" || true
}

xray_role() {
  need_root
  apt_install jq
  local cfg=""
  if [ -f /usr/local/etc/xray/config.json ]; then
    cfg="/usr/local/etc/xray/config.json"
  elif [ -f /etc/xray/config.json ]; then
    cfg="/etc/xray/config.json"
  else
    echo "Cannot find Xray config at /usr/local/etc/xray/config.json or /etc/xray/config.json" >&2
    exit 1
  fi

  local backup="${cfg}.bak.$(date +%F-%H%M%S)"
  cp -a "$cfg" "$backup"
  echo "Backed up Xray config to $backup"

  jq --arg host "127.0.0.1" --argjson port "$ENTRY_LOCAL_SOCKS_PORT" '
    .outbounds = ([{
      "tag": "hk-mptcp-socks",
      "protocol": "socks",
      "settings": {
        "servers": [{
          "address": $host,
          "port": $port
        }]
      }
    }] + ((.outbounds // []) | map(select(.tag != "hk-mptcp-socks"))))
  ' "$cfg" >/tmp/xray.mptcpwg.json

  if command -v xray >/dev/null 2>&1; then
    xray -test -config /tmp/xray.mptcpwg.json
  fi
  install -m 600 /tmp/xray.mptcpwg.json "$cfg"
  systemctl restart xray
  systemctl status xray --no-pager
  echo "Xray now uses 127.0.0.1:${ENTRY_LOCAL_SOCKS_PORT} as the first outbound."
}

usage() {
  cat <<EOF
Usage: $0 ROLE

Roles:
  prepare   Generate /root/mptcpwg.env. Run once on entry, then copy env file to all servers.
  entry     Configure entry server.
  gz1       Configure Guangzhou relay 1.
  gz2       Configure Guangzhou relay 2.
  gz3       Configure Guangzhou relay 3.
  gz4       Configure Guangzhou relay 4.
  hk        Configure HK server.
  test      Test from entry.
  xray      Change entry Xray outbound after test succeeds.
EOF
}

main() {
  local role="${1:-}"
  case "$role" in
    prepare) prepare ;;
    entry) entry_role ;;
    gz1) gz_role 1 ;;
    gz2) gz_role 2 ;;
    gz3) gz_role 3 ;;
    gz4) gz_role 4 ;;
    hk) hk_role ;;
    test) test_role ;;
    xray) xray_role ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
