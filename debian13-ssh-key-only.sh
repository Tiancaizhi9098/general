#!/usr/bin/env bash
set -Eeuo pipefail

NEW_PORT=30022
SSH_DROPIN="/etc/ssh/sshd_config.d/00-key-only.conf"
AUTHORIZED_KEYS="/root/.ssh/authorized_keys"
PRIVATE_KEY="/root/ssh-key-${NEW_PORT}"
PUBLIC_KEY="${PRIVATE_KEY}.pub"

die() {
  echo "错误：$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "请使用 root 运行此脚本。"
command -v sshd >/dev/null 2>&1 || die "未安装 OpenSSH Server，请先运行：apt update && apt install -y openssh-server"
command -v ssh-keygen >/dev/null 2>&1 || die "未找到 ssh-keygen，请先安装 openssh-client。"

install -d -m 700 /root/.ssh
touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"
chown root:root /root/.ssh "$AUTHORIZED_KEYS"

if [[ ! -f "$PRIVATE_KEY" || ! -f "$PUBLIC_KEY" ]]; then
  rm -f "$PRIVATE_KEY" "$PUBLIC_KEY"
  ssh-keygen \
    -q \
    -t ed25519 \
    -a 100 \
    -N "" \
    -C "root@$(hostname)-port-${NEW_PORT}" \
    -f "$PRIVATE_KEY"
fi

chmod 600 "$PRIVATE_KEY"
chmod 644 "$PUBLIC_KEY"
generated_public_key="$(<"$PUBLIC_KEY")"
grep -qxF "$generated_public_key" "$AUTHORIZED_KEYS" \
  || printf '%s\n' "$generated_public_key" >> "$AUTHORIZED_KEYS"

mkdir -p /etc/ssh/sshd_config.d
if [[ -f "$SSH_DROPIN" ]]; then
  cp -a "$SSH_DROPIN" "${SSH_DROPIN}.bak.$(date +%Y%m%d-%H%M%S)"
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT
cat > "$tmp_file" <<EOF
# Managed by debian13-ssh-key-only.sh
Port $NEW_PORT
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF
install -m 600 "$tmp_file" "$SSH_DROPIN"

if ! sshd -t; then
  rm -f "$SSH_DROPIN"
  die "SSH 配置校验失败，已撤销新配置。"
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow "${NEW_PORT}/tcp"
fi

if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
  systemctl reload ssh
else
  systemctl reload sshd
fi

echo
echo "设置完成：SSH 端口已改为 $NEW_PORT，密码登录已禁用，只允许密钥登录。"
echo
echo "下面是自动生成的私钥，请完整复制并保存到你的电脑："
echo "==================== 私钥开始 ===================="
cat "$PRIVATE_KEY"
echo "==================== 私钥结束 ===================="
echo
echo "服务器上的私钥文件：$PRIVATE_KEY"
echo "保存好以后，请在电脑上把私钥文件权限设为仅自己可读。"
echo "然后不要关闭当前窗口，先另开终端测试："
echo "ssh -i 私钥文件路径 -p $NEW_PORT root@你的服务器IP"
echo
echo "确认新连接成功后，删除服务器上的私钥副本："
echo "rm -f $PRIVATE_KEY"
echo
echo "注意：如果服务商有安全组/云防火墙，还需放行 TCP $NEW_PORT。"
