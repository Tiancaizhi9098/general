#!/usr/bin/env bash
set -Eeuo pipefail

DEFAULT_PORT=22
SSH_DROPIN="/etc/ssh/sshd_config.d/00-000-root-password-login.conf"
AUTHORIZED_KEYS="/root/.ssh/authorized_keys"

die() {
  echo "错误：$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "请使用 root 运行此脚本。"
command -v sshd >/dev/null 2>&1 || die "未安装 OpenSSH Server，请先运行：apt update && apt install -y openssh-server"
command -v ssh-keygen >/dev/null 2>&1 || die "未找到 ssh-keygen，请先安装 openssh-client。"

if [[ -n "${SSH_PORT:-}" ]]; then
  NEW_PORT="$SSH_PORT"
elif [[ -r /dev/tty && -w /dev/tty ]]; then
  printf '请输入新的 SSH 端口 [默认 %s]：' "$DEFAULT_PORT" > /dev/tty
  IFS= read -r NEW_PORT < /dev/tty || NEW_PORT=""
  NEW_PORT="${NEW_PORT:-$DEFAULT_PORT}"
else
  NEW_PORT="$DEFAULT_PORT"
  echo "未检测到交互终端，将使用默认 SSH 端口：$NEW_PORT"
fi

[[ "$NEW_PORT" =~ ^[0-9]+$ ]] || die "SSH 端口必须是数字。"
(( 10#$NEW_PORT >= 1 && 10#$NEW_PORT <= 65535 )) || die "SSH 端口范围必须是 1–65535。"
NEW_PORT="$((10#$NEW_PORT))"

if [[ -n "${DISABLE_PASSWORD_LOGIN:-}" ]]; then
  PASSWORD_CHOICE="$DISABLE_PASSWORD_LOGIN"
elif [[ -r /dev/tty && -w /dev/tty ]]; then
  printf '是否关闭 SSH 密码登录？[Y/n]：' > /dev/tty
  IFS= read -r PASSWORD_CHOICE < /dev/tty || PASSWORD_CHOICE=""
  PASSWORD_CHOICE="${PASSWORD_CHOICE:-y}"
else
  PASSWORD_CHOICE="y"
  echo "未检测到交互终端，将默认关闭 SSH 密码登录。"
fi

case "$PASSWORD_CHOICE" in
  y|Y|yes|YES|1)
    DISABLE_PASSWORD_LOGIN="yes"
    ;;
  n|N|no|NO|0)
    DISABLE_PASSWORD_LOGIN="no"
    ;;
  *)
    die "是否关闭密码登录只能输入 y 或 n。"
    ;;
esac

PRIVATE_KEY="/root/ssh-key-${NEW_PORT}"
PUBLIC_KEY="${PRIVATE_KEY}.pub"

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
BACKUP_FILE=""
if [[ -f "$SSH_DROPIN" ]]; then
  BACKUP_FILE="${SSH_DROPIN}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$SSH_DROPIN" "$BACKUP_FILE"
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT
cat > "$tmp_file" <<EOF
# Managed by debian13-ssh-key-only.sh
Port $NEW_PORT
PubkeyAuthentication yes
EOF

if [[ "$DISABLE_PASSWORD_LOGIN" == "yes" ]]; then
  cat >> "$tmp_file" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
EOF
else
  cat >> "$tmp_file" <<'EOF'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
PermitRootLogin yes
UsePAM yes
EOF
fi

install -m 600 "$tmp_file" "$SSH_DROPIN"

restore_ssh_config() {
  if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
    cp -a "$BACKUP_FILE" "$SSH_DROPIN"
  else
    rm -f "$SSH_DROPIN"
  fi
}

if ! sshd -t; then
  restore_ssh_config
  die "SSH 配置校验失败，已撤销新配置。"
fi

if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
  ufw allow "${NEW_PORT}/tcp"
fi

if systemctl cat ssh.service >/dev/null 2>&1; then
  SSH_SERVICE="ssh"
else
  SSH_SERVICE="sshd"
fi

if ! systemctl reload "$SSH_SERVICE"; then
  restore_ssh_config
  systemctl reload "$SSH_SERVICE" >/dev/null 2>&1 || true
  die "SSH 服务重载失败，已恢复修改前的配置。"
fi

echo
if [[ "$DISABLE_PASSWORD_LOGIN" == "yes" ]]; then
  echo "设置完成：SSH 端口为 $NEW_PORT，密码登录已关闭，只允许密钥登录。"
else
  echo "设置完成：SSH 端口为 $NEW_PORT，密钥登录和密码登录均已开启。"
  if command -v passwd >/dev/null 2>&1 \
    && [[ "$(passwd -S root 2>/dev/null | awk '{print $2}')" != "P" ]]; then
    echo "提醒：root 当前没有可用密码，如需密码登录请执行：passwd root"
  fi
fi
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
