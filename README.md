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

自动生成 Ed25519 公私钥，并在执行时询问 SSH 端口以及是否关闭密码登录。端口直接回车使用默认值 `22`；关闭密码登录默认选择 `Y`。

```bash
apt-get update && apt-get install -y curl openssh-server && curl -fsSL https://raw.githubusercontent.com/Tiancaizhi9098/general/main/debian13-ssh-key-only.sh | bash
```

执行时会看到：

```text
请输入新的 SSH 端口 [默认 22]：
是否关闭 SSH 密码登录？[Y/n]：
```

- 选择 `Y` 或直接回车：关闭密码登录，只允许密钥登录。
- 选择 `n`：同时保留密钥登录和 root 密码登录；如果 root 尚未设置密码，请执行 `passwd root`。

保存好脚本输出的私钥后，请不要关闭当前 SSH 窗口，先打开新终端测试：

```bash
ssh -i 私钥文件路径 -p 你设置的端口 root@服务器IP
```

确认登录成功后，可删除服务器上的私钥副本：

```bash
rm -f /root/ssh-key-你设置的端口
```

## Debian 开启 root 密码登录

开启 SSH 的 root 登录和密码验证，不修改当前 SSH 端口。脚本会询问是否设置或修改 root 密码，并在配置错误时自动恢复原 SSH 配置。

```bash
apt-get update && apt-get install -y curl openssh-server passwd && curl -fsSL https://raw.githubusercontent.com/Tiancaizhi9098/general/main/debian-enable-root-password-login.sh | bash
```

执行时默认选择 `Y`，然后按照提示输入两次新的 root 密码：

```text
是否现在设置或修改 root 密码？[Y/n]：
```

设置完成后使用当前 SSH 端口登录：

```bash
ssh -p 当前端口 root@服务器IP
```

开启 root 密码登录会增加暴力破解风险，请使用强密码并限制防火墙来源地址。
