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

自动生成 Ed25519 公私钥、禁用密码登录，并在执行时询问需要使用的 SSH 端口。直接按回车使用默认端口 `22`，也可以输入 `30022` 等自定义端口。

```bash
apt-get update && apt-get install -y curl openssh-server && curl -fsSL https://raw.githubusercontent.com/Tiancaizhi9098/general/main/debian13-ssh-key-only.sh | bash
```

执行时会看到：

```text
请输入新的 SSH 端口 [默认 22]：
```

保存好脚本输出的私钥后，请不要关闭当前 SSH 窗口，先打开新终端测试：

```bash
ssh -i 私钥文件路径 -p 你设置的端口 root@服务器IP
```

确认登录成功后，可删除服务器上的私钥副本：

```bash
rm -f /root/ssh-key-你设置的端口
```
