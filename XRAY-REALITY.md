# Xray VLESS + REALITY + XTLS Vision 一键安装脚本

自动安装最新版 Xray-core，部署 VLESS + REALITY + `xtls-rprx-vision` 节点，并在控制台输出可直接复制到 Mihomo/Clash Meta 的 YAML 配置。

默认配置：

- 监听端口：`443/TCP`
- REALITY 目标：`hkg.biliimg.com:443`
- SNI：`hkg.biliimg.com`
- 传输方式：TCP
- Flow：`xtls-rprx-vision`
- 客户端指纹：Chrome
- UDP 封包：XUDP

每次安装都会生成新的 UUID、Reality X25519 密钥对和 16 位 short ID，不会使用仓库中的固定密钥。

## 支持系统

- Debian 11、12、13
- Ubuntu 20.04 及以上版本
- CentOS Stream、Rocky Linux、AlmaLinux 等使用 `dnf`/`yum` 且支持 systemd 的发行版
- `x86_64`、`aarch64` 等 Xray 官方安装脚本支持的架构

必须使用 `root` 用户运行。

## 一键安装

Debian/Ubuntu：

```bash
apt-get update && apt-get install -y curl ca-certificates openssl jq iproute2 && bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/Tiancaizhi9098/general/c93b8fa3ffb6d2659e3753f8b4b84c2b9b3ff519/xray-reality-installer.sh')"
```

CentOS Stream、Rocky Linux、AlmaLinux：

```bash
(command -v dnf >/dev/null 2>&1 && dnf install -y curl ca-certificates openssl jq iproute || yum install -y curl ca-certificates openssl jq iproute) && bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/Tiancaizhi9098/general/c93b8fa3ffb6d2659e3753f8b4b84c2b9b3ff519/xray-reality-installer.sh')"
```

一键命令会先安装依赖再执行脚本；脚本自身也会检测并补装缺失依赖。

安装完成后，Mihomo YAML 会直接显示在控制台，并保存到：

```text
/root/mihomo-vless-reality.yaml
```

Xray 服务端配置位于：

```text
/usr/local/etc/xray/config.json
```

## 自定义参数

可通过环境变量修改配置：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `PORT` | `443` | Xray 监听端口 |
| `SERVER_NAME` | `hkg.biliimg.com` | REALITY SNI |
| `REALITY_DEST` | `${SERVER_NAME}:443` | REALITY 回落目标 |
| `SERVER_ADDRESS` | 自动检测公网 IP | Mihomo 配置里的服务器地址，可填写域名 |
| `NODE_NAME` | `VLESS-REALITY` | Mihomo 节点名称 |

示例：

```bash
apt-get update
apt-get install -y curl ca-certificates openssl jq iproute2

PORT=8443 \
SERVER_NAME=hkg.biliimg.com \
REALITY_DEST=hkg.biliimg.com:443 \
SERVER_ADDRESS=node.example.com \
NODE_NAME=香港落地 \
bash -c "$(curl -fsSL 'https://raw.githubusercontent.com/Tiancaizhi9098/general/c93b8fa3ffb6d2659e3753f8b4b84c2b9b3ff519/xray-reality-installer.sh')"
```

如果使用 `sudo`，建议先切换到 root，避免环境变量被 `sudo` 丢弃：

```bash
sudo -i
```

然后再运行安装命令。

## Mihomo 配置示例

脚本实际输出的 UUID、公钥和 short ID 都会随机生成：

```yaml
proxies:
  - name: "VLESS-REALITY"
    type: vless
    server: "203.0.113.10"
    port: 443
    uuid: "自动生成的UUID"
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    packet-encoding: xudp
    servername: "hkg.biliimg.com"
    client-fingerprint: chrome
    reality-opts:
      public-key: "自动生成的Reality公钥"
      short-id: "自动生成的short-id"
```

## 常用命令

查看状态：

```bash
systemctl status xray --no-pager
```

查看实时日志：

```bash
journalctl -u xray -f
```

重启服务：

```bash
systemctl restart xray
```

查看 Mihomo 配置：

```bash
cat /root/mihomo-vless-reality.yaml
```

检查 Xray 配置：

```bash
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
```

## 重复运行和防火墙

- 重复运行会生成全新的客户端凭据，旧客户端配置会失效。
- 原有 `/usr/local/etc/xray/config.json` 会自动备份为带时间戳的 `.bak` 文件。
- 如果安装中途失败，脚本会恢复旧配置，并尽量恢复原来的 Xray 服务。
- 脚本会自动放行处于启用状态的 UFW 或 firewalld。
- 云厂商安全组、宿主机 nftables/iptables 仍需自行放行对应的 TCP 端口。
- 如果端口已被 Nginx、Caddy 或其他程序占用，脚本会停止并提示更换端口。

## 安全说明

REALITY 私钥只保存在服务端的 Xray 配置中；Mihomo 文件和控制台只会输出公钥。不要把服务端 `config.json` 公开上传。

通过 `curl | bash` 运行脚本前，可以先下载并检查内容：

```bash
curl -fsSL 'https://raw.githubusercontent.com/Tiancaizhi9098/general/c93b8fa3ffb6d2659e3753f8b4b84c2b9b3ff519/xray-reality-installer.sh' -o install.sh
less install.sh
bash install.sh
```

本项目调用 [XTLS 官方 Xray-install](https://github.com/XTLS/Xray-install) 安装和更新 Xray-core。
