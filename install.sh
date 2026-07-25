#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/sunshinecoolme-gif/vpn-optimizer.git"
REPO_BRANCH="master"
INSTALL_DIR="/opt/vpn-optimizer"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 运行：sudo bash install.sh"
    exit 1
fi

if [[ ! -f /etc/os-release ]]; then
    echo "无法识别系统"
    exit 1
fi

. /etc/os-release

case "$ID" in
    debian|ubuntu)
        apt-get update
        apt-get install -y git ca-certificates
        ;;
    centos|rhel|rocky|almalinux|fedora)
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y git ca-certificates
        else
            yum install -y git ca-certificates
        fi
        ;;
    *)
        echo "暂不支持系统：$ID"
        exit 1
        ;;
esac

if [[ -d "$INSTALL_DIR/.git" ]]; then
    echo "更新已有脚本..."
    git -C "$INSTALL_DIR" fetch --depth 1 origin "$REPO_BRANCH"
    if git -C "$INSTALL_DIR" show-ref --verify --quiet "refs/heads/$REPO_BRANCH"; then
        git -C "$INSTALL_DIR" switch "$REPO_BRANCH"
    else
        git -C "$INSTALL_DIR" switch --create "$REPO_BRANCH" --track "origin/$REPO_BRANCH"
    fi
    git -C "$INSTALL_DIR" pull --ff-only origin "$REPO_BRANCH"
else
    echo "下载部署脚本..."
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

chmod +x "$INSTALL_DIR/optimize.sh"
chmod +x "$INSTALL_DIR/optimize-performance.sh"

echo
echo "脚本已下载到：$INSTALL_DIR"
echo "开始运行 Hysteria2 部署脚本..."
echo

cd "$INSTALL_DIR"
exec bash ./optimize.sh
