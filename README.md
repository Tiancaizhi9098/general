# Debian 13 SSH 密钥登录一键配置

这是一个适用于 **Debian 13** 的 SSH 安全配置脚本，可自动生成 Ed25519 密钥，并将 SSH 修改为仅允许密钥登录。

## 功能

- 自动生成 Ed25519 公钥和私钥
- 自动将公钥添加到 root 的 `authorized_keys`
- 将 SSH 端口修改为 `30022`
- 禁用 SSH 密码登录
- 禁用键盘交互式验证
- 保留 root 密钥登录
- 修改前自动备份已有配置
- 自动执行 `sshd -t` 检查配置
- 检测到 UFW 已启用时，自动放行 `30022/tcp`
- 执行完成后在终端显示生成的私钥

## 一键执行

请使用 **root 用户**运行：

```bash
curl -fsSL https://raw.githubusercontent.com/Tiancaizhi9098/general/main/debian13-ssh-key-only.sh | bash
```

如果服务器没有安装 `curl`：

```bash
apt update && apt install -y curl
```

然后重新执行上面的一键命令。

## 登录方法

脚本运行完成后，会在终端显示自动生成的私钥。将私钥从：

```text
-----BEGIN OPENSSH PRIVATE KEY-----
```

一直完整复制到：

```text
-----END OPENSSH PRIVATE KEY-----
```

在 Windows 上可以保存为：

```text
C:\Users\Administrator\.ssh\debian13_30022
```

然后使用 PowerShell 登录：

```powershell
ssh -i "$env:USERPROFILE\.ssh\debian13_30022" -p 30022 root@服务器IP
```

Linux 或 macOS 保存私钥后，需要设置权限：

```bash
chmod 600 ~/.ssh/debian13_30022
ssh -i ~/.ssh/debian13_30022 -p 30022 root@服务器IP
```

## 重要提醒

1. 执行脚本前，请先在服务商安全组或云防火墙中放行 TCP `30022`。
2. 脚本执行后不要立即关闭原来的 SSH 窗口。
3. 请先打开一个新终端，确认可以使用私钥和 `30022` 端口正常登录。
4. 确认登录成功并保存好私钥后，删除服务器上的私钥副本：

```bash
rm -f /root/ssh-key-30022
```

服务器仍会保留公钥，不会影响后续密钥登录。

## 脚本文件

- [debian13-ssh-key-only.sh](./debian13-ssh-key-only.sh)
