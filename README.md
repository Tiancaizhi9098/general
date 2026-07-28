# Linux 一键运维脚本合集

## Xray VLESS + REALITY + XTLS Vision

```bash
apt-get update && apt-get install -y curl ca-certificates openssl jq iproute2 && bash -c "$(curl -fsSL https://raw.githubusercontent.com/Tiancaizhi9098/general/05035155b2bf698ad099e1e256564314365e3179/xray-reality-installer.sh)"
```

[查看详细说明](./XRAY-REALITY.md)

## 阿里云 CDT 流量达到 180GB 后暂停 Xray

自动识别默认路由网卡，只统计 TX 出方向流量。达到阈值后停止 Xray，并在下一个北京时间自然月自动恢复。

```bash
apt-get update && apt-get install -y curl && curl -fsSL https://raw.githubusercontent.com/Tiancaizhi9098/general/main/install-aliyun-xray-traffic-guard.sh | bash -s -- --limit 180 --used-gb 0
```

如果本月安装前已经使用了流量，请把 `--used-gb 0` 改成实际数值，例如 `--used-gb 35.5`。

查看状态：

```bash
aliyun-xray-traffic-guard status
```

## Debian 13 SSH 密钥登录

```bash
apt-get update && apt-get install -y curl openssh-server && curl -fsSL https://raw.githubusercontent.com/Tiancaizhi9098/general/main/debian13-ssh-key-only.sh | bash
```
