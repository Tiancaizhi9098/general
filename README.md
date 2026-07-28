# Linux 一键运维脚本合集

## Xray VLESS + REALITY + XTLS Vision

```bash
apt-get update && apt-get install -y curl ca-certificates openssl jq iproute2 && bash -c "$(curl -fsSL https://raw.githubusercontent.com/Tiancaizhi9098/general/c93b8fa3ffb6d2659e3753f8b4b84c2b9b3ff519/xray-reality-installer.sh)"
```

[查看详细说明](./XRAY-REALITY.md)

## Debian 13 SSH 密钥登录

```bash
apt-get update && apt-get install -y curl openssh-server && curl -fsSL https://raw.githubusercontent.com/Tiancaizhi9098/general/main/debian13-ssh-key-only.sh | bash
```
