#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; PLAIN=$'\033[0m'
info() { printf '%b[INFO]%b %s\n' "$CYAN" "$PLAIN" "$*"; }
ok() { printf '%b[OK]%b %s\n' "$GREEN" "$PLAIN" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$PLAIN" "$*" >&2; }
die() { printf '%b[ERROR]%b %s\n' "$RED" "$PLAIN" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: bash optimize.sh [options]
  --no-outbound                 do not configure an outbound proxy
  --outbound-type TYPE          socks5 or http
  --outbound-addr HOST:PORT     outbound proxy address
  --outbound-user USER          outbound username
  --outbound-pass PASS          outbound password
  --port PORT                   Hysteria2 UDP port
  --password PASS               Hysteria2 password
  --yes                         accept service restart and firewall changes
  --allow-kernel-upgrade        permit kernel package installation (no reboot)
  --dry-run                     validate and print intended changes only
  --rollback [BACKUP]           restore the newest or named config backup
  --help                        show this help
EOF
}

NO_OUTBOUND=0; DRY_RUN=0; YES=0; ALLOW_KERNEL=0; ROLLBACK=''
OUTBOUND_TYPE=''; OUTBOUND_ADDR=''; OUTBOUND_USER=''; OUTBOUND_PASS=''; HY2_PORT=''; HY2_PASSWORD=''
while (($#)); do
    case $1 in
        --no-outbound) NO_OUTBOUND=1; shift;;
        --outbound-type) OUTBOUND_TYPE=${2:?missing value}; shift 2;;
        --outbound-addr) OUTBOUND_ADDR=${2:?missing value}; shift 2;;
        --outbound-user) OUTBOUND_USER=${2:?missing value}; shift 2;;
        --outbound-pass) OUTBOUND_PASS=${2:?missing value}; shift 2;;
        --port) HY2_PORT=${2:?missing value}; shift 2;;
        --password) HY2_PASSWORD=${2:?missing value}; shift 2;;
        --yes) YES=1; shift;;
        --allow-kernel-upgrade) ALLOW_KERNEL=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        --rollback) ROLLBACK=${2:-latest}; [[ $# -gt 1 ]] && shift 2 || shift;;
        --help|-h) usage; exit 0;;
        *) die "unknown option: $1";;
    esac
done

CONFIG=/etc/hysteria/config.yaml
BACKUP_DIR=/etc/hysteria/backups
SYSCTL_FILE=/etc/sysctl.d/99-hy2.conf
SERVICE_FILE=/etc/systemd/system/hysteria-server.service
CERT_DIR=/root/cert

run() { if (( DRY_RUN )); then printf '%b[DRY-RUN]%b' "$CYAN" "$PLAIN"; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
backup_file() {
    local file=$1 stamp
    [[ -f $file ]] || return 0
    stamp=$(date +%Y%m%d-%H%M%S)
    run install -d -m 700 "$BACKUP_DIR"
    run cp -p "$file" "$BACKUP_DIR/$(basename "$file").$stamp.bak"
}
valid_port() { [[ $1 =~ ^[0-9]+$ && $1 -ge 1 && $1 -le 65535 ]]; }
valid_addr() { [[ $1 =~ ^\[?[A-Za-z0-9:.%-]+\]?:[0-9]+$ ]]; }
yaml_quote() { printf "'%s'" "${1//\'/\'\'}"; }

if [[ -n $ROLLBACK ]]; then
    (( EUID == 0 )) || die 'rollback requires root'
    [[ -d $BACKUP_DIR ]] || die "backup directory not found: $BACKUP_DIR"
    if [[ $ROLLBACK == latest ]]; then
        ROLLBACK=$(find "$BACKUP_DIR" -type f -name 'config.yaml.*.bak' -print | sort | tail -1)
    else
        ROLLBACK="$BACKUP_DIR/$(basename "$ROLLBACK")"
    fi
    [[ -f $ROLLBACK ]] || die 'backup not found'
    (( DRY_RUN )) || install -m 600 "$ROLLBACK" "$CONFIG"
    ok "configuration rollback selected: $ROLLBACK"
    exit 0
fi

(( EUID == 0 || DRY_RUN )) || die 'run as root'
[[ -r /etc/os-release ]] || die 'cannot detect operating system'
. /etc/os-release
case ${ID:-} in
    debian|ubuntu) PKG=apt-get;;
    centos|rhel|rocky|almalinux|fedora) PKG=$(command -v dnf || command -v yum || true); [[ -n $PKG ]] || die 'dnf/yum not found';;
    *) die "unsupported OS: ${ID:-unknown}; supported: Debian, Ubuntu, CentOS, RHEL, Rocky, AlmaLinux, Fedora";;
esac

if [[ -z $HY2_PORT ]]; then HY2_PORT=443; fi
valid_port "$HY2_PORT" || die 'invalid --port'
if [[ -z $HY2_PASSWORD ]]; then HY2_PASSWORD=$(openssl rand -hex 16); fi
[[ $HY2_PASSWORD != *$'\n'* && -n $HY2_PASSWORD ]] || die 'invalid password'

if (( ! NO_OUTBOUND )) && [[ -z $OUTBOUND_TYPE && -t 0 ]]; then
    read -r -p 'Configure outbound proxy? [y/N]: ' answer
    [[ $answer =~ ^[Yy]$ ]] || NO_OUTBOUND=1
fi
if (( ! NO_OUTBOUND )); then
    OUTBOUND_TYPE=${OUTBOUND_TYPE:-socks5}
    [[ $OUTBOUND_TYPE == socks5 || $OUTBOUND_TYPE == http ]] || die 'outbound type must be socks5 or http'
    if [[ -z $OUTBOUND_ADDR && -t 0 ]]; then read -r -p "${OUTBOUND_TYPE} proxy HOST:PORT: " OUTBOUND_ADDR; fi
    valid_addr "$OUTBOUND_ADDR" || die 'invalid outbound address; use HOST:PORT or [IPv6]:PORT'
    if [[ -z $OUTBOUND_USER && -t 0 ]]; then read -r -p 'Proxy username (empty for none): ' OUTBOUND_USER; fi
    if [[ -z $OUTBOUND_PASS && -n $OUTBOUND_USER && -t 0 ]]; then read -r -s -p 'Proxy password: ' OUTBOUND_PASS; printf '\n'; fi
fi

if (( DRY_RUN )); then
    info "OS: $ID ${VERSION_ID:-}"; info "would configure Hysteria2 on UDP $HY2_PORT"
    (( NO_OUTBOUND )) || info "would configure $OUTBOUND_TYPE outbound at $OUTBOUND_ADDR"
    exit 0
fi

info "installing required packages"
if [[ $PKG == apt-get ]]; then
    DEBIAN_FRONTEND=noninteractive "$PKG" update
    DEBIAN_FRONTEND=noninteractive "$PKG" install -y curl openssl ca-certificates iproute2
else
    "$PKG" install -y curl openssl ca-certificates iproute
fi

if (( ALLOW_KERNEL )); then
    warn 'kernel upgrade was explicitly requested; installing packages without reboot'
    if [[ $PKG == apt-get ]]; then "$PKG" install -y linux-image-generic linux-headers-generic; else "$PKG" install -y kernel; fi
else
    info "kernel upgrade disabled; current kernel: $(uname -r)"
fi

install -d -m 700 "$CERT_DIR" /var/www/html /etc/hysteria "$BACKUP_DIR"
if [[ ! -s $CERT_DIR/hy2_server.crt || ! -s $CERT_DIR/hy2_server.key ]]; then
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$CERT_DIR/hy2_server.key" -out "$CERT_DIR/hy2_server.crt" \
        -subj /CN=www.bing.com -days 36500 2>/dev/null
    chmod 644 "$CERT_DIR/hy2_server.crt"; chmod 600 "$CERT_DIR/hy2_server.key"
fi
install -m 644 /dev/null /var/www/html/index.html
printf '%s\n' '<!doctype html><title>404 Not Found</title><h1>404 Not Found</h1>' > /var/www/html/index.html

if ! command -v hysteria >/dev/null 2>&1; then
    command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required for verified Hysteria2 installation'
    arch=$(uname -m)
    case $arch in x86_64) hy_arch=amd64;; aarch64) hy_arch=arm64;; armv7l) hy_arch=armv7;; *) die "unsupported architecture: $arch";; esac
    api=$(mktemp); binary=$(mktemp); hashes=$(mktemp)
    trap 'rm -f "${TMP:-}" "${api:-}" "${binary:-}" "${hashes:-}"' EXIT
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        https://api.github.com/repos/apernet/hysteria/releases/latest -o "$api"
    version=$(sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p' "$api" | head -1)
    [[ $version =~ ^(app/)?v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'could not validate latest Hysteria2 version'
    VERSION_URL=${version//\//%2F}
    asset="hysteria-linux-${hy_arch}"
    base="https://github.com/apernet/hysteria/releases/download/${VERSION_URL}"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$base/$asset" -o "$binary"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$base/hashes.txt" -o "$hashes"
    expected=$(awk -v name="$asset" '$0 ~ name {print $1; exit}' "$hashes")
    [[ $expected =~ ^[A-Fa-f0-9]{64}$ ]] || die 'release checksum was not found'
    actual=$(sha256sum "$binary" | awk '{print $1}')
    [[ $actual == "$expected" ]] || die 'Hysteria2 checksum verification failed'
    install -m 755 "$binary" /usr/local/bin/hysteria
    rm -f "$api" "$binary" "$hashes"
    ok "verified Hysteria2 release installed: $version"
fi

TMP=''
TMP=$(mktemp /etc/hysteria/config.yaml.XXXXXX)
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
listen: :$HY2_PORT
tls:
  cert: $CERT_DIR/hy2_server.crt
  key: $CERT_DIR/hy2_server.key
auth:
  type: password
  password: $(yaml_quote "$HY2_PASSWORD")
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 16777216
  initConnReceiveWindow: 12500000
  maxConnReceiveWindow: 25000000
masquerade:
  type: file
  file:
    dir: /var/www/html
EOF
if (( ! NO_OUTBOUND )); then
    {
        printf 'outbounds:\n  - name: static-ip\n    type: %s\n' "$OUTBOUND_TYPE"
        if [[ $OUTBOUND_TYPE == socks5 ]]; then
            printf '    socks5:\n      addr: %s\n' "$(yaml_quote "$OUTBOUND_ADDR")"
            [[ -n $OUTBOUND_USER ]] && printf '      username: %s\n      password: %s\n' "$(yaml_quote "$OUTBOUND_USER")" "$(yaml_quote "$OUTBOUND_PASS")"
        else
            printf '    http:\n      url: %s\n' "$(yaml_quote "http://${OUTBOUND_USER}:${OUTBOUND_PASS}@${OUTBOUND_ADDR}")"
        fi
    } >> "$TMP"
fi
backup_file "$CONFIG"
chmod 600 "$TMP"
mv -f "$TMP" "$CONFIG"

cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Hysteria2 Server Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
NoNewPrivileges=true
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable hysteria-server.service >/dev/null
if (( YES )) || [[ ! -t 0 ]]; then
    systemctl restart hysteria-server.service
else
    read -r -p 'Restart Hysteria2 now? [y/N]: ' answer
    [[ $answer =~ ^[Yy]$ ]] && systemctl restart hysteria-server.service || warn 'configuration installed; service was not restarted'
fi
if systemctl is-active --quiet hysteria-server.service; then ok 'Hysteria2 service is active'; else warn 'service is not active; inspect journalctl -u hysteria-server'; fi
ok "configuration installed with mode 600: $CONFIG"

SERVER_IP=$(curl -4fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)
if [[ -z $SERVER_IP ]]; then
    SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
fi
if [[ -n $SERVER_IP ]]; then
    HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}?sni=www.bing.com&insecure=1#Hysteria2"
    printf '\nHysteria2 连接链接（请勿公开分享）：\n%s\n\n' "$HY2_LINK"
else
    warn 'unable to detect public IP; retrieve it with: curl -4s https://api.ipify.org'
    printf '\nHysteria2 连接链接格式：\nhysteria2://%s@你的VPS公网IP:%s?sni=www.bing.com&insecure=1#Hysteria2\n\n' "$HY2_PASSWORD" "$HY2_PORT"
fi
