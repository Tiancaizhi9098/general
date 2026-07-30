#!/usr/bin/env bash
set -Eeuo pipefail

SSH_DROPIN="/etc/ssh/sshd_config.d/00-000-root-password-login.conf"

die() {
  echo "错误：$*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "请使用 root 运行此脚本。"
command -v sshd >/dev/null 2>&1 || die "未安装 OpenSSH Server，请先安装 openssh-server。"
command -v passwd >/dev/null 2>&1 || die "未找到 passwd 命令。"
[[ -r /dev/tty && -w /dev/tty ]] || die "需要交互终端来设置 root 密码。"

printf '是否现在设置或修改 root 密码？[Y/n]：' > /dev/tty
IFS= read -r SET_PASSWORD < /dev/tty || SET_PASSWORD=""
case "${SET_PASSWORD:-y}" in
  y|Y|yes|YES)
    echo "请按提示输入两次新的 root 密码：" > /dev/tty
    passwd root < /dev/tty > /dev/tty 2>&1 || die "root 密码设置失败。"
    ;;
  n|N|no|NO)
    ROOT_PASSWORD_STATUS="$(passwd -S root 2>/dev/null | awk '{print $2}')"
    [[ "$ROOT_PASSWORD_STATUS" == "P" ]] \
      || die "root 当前没有可用密码，请重新运行并选择设置密码。"
    ;;
  *)
    die "请输入 y 或 n。"
    ;;
esac

mkdir -p /etc/ssh/sshd_config.d
BACKUP_FILE=""
if [[ -f "$SSH_DROPIN" ]]; then
  BACKUP_FILE="${SSH_DROPIN}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$SSH_DROPIN" "$BACKUP_FILE"
fi

restore_ssh_config() {
  if [[ -n "$BACKUP_FILE" && -f "$BACKUP_FILE" ]]; then
    cp -a "$BACKUP_FILE" "$SSH_DROPIN"
  else
    rm -f "$SSH_DROPIN"
  fi
}

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT
cat > "$tmp_file" <<'EOF'
# Managed by debian-enable-root-password-login.sh
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
UsePAM yes
EOF
install -m 600 "$tmp_file" "$SSH_DROPIN"

if ! sshd -t; then
  restore_ssh_config
  die "SSH 配置校验失败，已恢复修改前的配置。"
fi

EFFECTIVE_CONFIG="$(sshd -T)"
EFFECTIVE_ROOT_LOGIN="$(awk '$1 == "permitrootlogin" {print $2; exit}' <<< "$EFFECTIVE_CONFIG")"
EFFECTIVE_PASSWORD_LOGIN="$(awk '$1 == "passwordauthentication" {print $2; exit}' <<< "$EFFECTIVE_CONFIG")"

if [[ "$EFFECTIVE_ROOT_LOGIN" != "yes" || "$EFFECTIVE_PASSWORD_LOGIN" != "yes" ]]; then
  restore_ssh_config
  die "SSH 配置被其他规则覆盖，已恢复修改前的配置。"
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

SSH_PORT="$(awk '$1 == "port" {print $2; exit}' <<< "$EFFECTIVE_CONFIG")"

echo
echo "设置完成：root 登录和 SSH 密码登录均已开启。"
echo "当前 SSH 端口：$SSH_PORT"
echo "登录命令：ssh -p $SSH_PORT root@服务器IP"
