#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

usage() { cat <<'EOF'
Usage: sudo bash setup-clash-subscription.sh [options]
  --link URI       use an existing hysteria2:// URI instead of server config
  --listen PORT    HTTP subscription port (default: 18080)
  --name NAME      node name shown in Clash (default: Hysteria2-VPS)
  --public-host H  public IP or domain used in the subscription URL
  --token TOKEN    secret URL path (default: randomly generated)
  --yes            open the TCP port with ufw/firewalld without prompting
  --dry-run        print detected values without installing the service
  --help           show this help

The generated profile requires Mihomo/Clash Meta (Hysteria2 is not supported
by the discontinued original Clash core).
EOF
}

LINK=''; LISTEN_PORT=18080; NODE_NAME='Hysteria2-VPS'; PUBLIC_HOST=''; TOKEN=''; YES=0; DRY_RUN=0
while (($#)); do
    case $1 in
        --link) LINK=${2:?missing value}; shift 2;;
        --listen) LISTEN_PORT=${2:?missing value}; shift 2;;
        --name) NODE_NAME=${2:?missing value}; shift 2;;
        --public-host) PUBLIC_HOST=${2:?missing value}; shift 2;;
        --token) TOKEN=${2:?missing value}; shift 2;;
        --yes) YES=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        --help|-h) usage; exit 0;;
        *) die "unknown option: $1";;
    esac
done

[[ $LISTEN_PORT =~ ^[0-9]+$ && $LISTEN_PORT -ge 1 && $LISTEN_PORT -le 65535 ]] || die 'invalid --listen port'
[[ -n $NODE_NAME && $NODE_NAME != *$'\n'* ]] || die 'invalid --name'
[[ -z $TOKEN || $TOKEN =~ ^[A-Za-z0-9_-]{16,128}$ ]] || die '--token must contain 16-128 letters, digits, _ or -'
(( EUID == 0 || DRY_RUN )) || die 'run as root (or use --dry-run)'

if [[ -r /etc/os-release ]]; then . /etc/os-release; else die 'cannot detect operating system'; fi
case ${ID:-} in
    debian|ubuntu) INSTALL_PYTHON=(apt-get install -y python3);;
    centos|rhel|rocky|almalinux|fedora)
        PKG=$(command -v dnf || command -v yum || true)
        [[ -n $PKG ]] || die 'dnf/yum not found'
        INSTALL_PYTHON=("$PKG" install -y python3)
        ;;
    *) die "unsupported OS: ${ID:-unknown}";;
esac

if [[ -z $PUBLIC_HOST ]]; then
    PUBLIC_HOST=$(curl -4fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)
    [[ -n $PUBLIC_HOST ]] || PUBLIC_HOST=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
fi
[[ -n $PUBLIC_HOST && $PUBLIC_HOST != *$'\n'* && $PUBLIC_HOST != *'/'* ]] || die 'cannot detect public IP; pass --public-host'
[[ -n $TOKEN ]] || TOKEN=$(openssl rand -hex 24)

if (( DRY_RUN )); then
    info "would publish a Mihomo/Clash Meta profile at http://${PUBLIC_HOST}:${LISTEN_PORT}/${TOKEN}.yaml"
    if [[ -n $LINK ]]; then info 'source: supplied Hysteria2 URI'; else info 'source: /etc/hysteria/config.yaml'; fi
    exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
    info 'installing Python 3 for the local subscription server'
    "${INSTALL_PYTHON[@]}"
fi
command -v openssl >/dev/null 2>&1 || die 'openssl is required'

INSTALL_DIR=/etc/clash-subscription
WWW_DIR=/var/lib/clash-subscription
ENV_FILE=$INSTALL_DIR/server.env
PROFILE=$WWW_DIR/$TOKEN.yaml
SERVICE_FILE=/etc/systemd/system/clash-subscription.service
install -d -m 700 "$INSTALL_DIR"
install -d -m 755 "$WWW_DIR"
printf '%s\n' 'Not Found' > "$WWW_DIR/index.html"
chmod 644 "$WWW_DIR/index.html"

export LINK NODE_NAME PUBLIC_HOST PROFILE
python3 - <<'PY'
import json, os, re, urllib.parse

link = os.environ.get("LINK", "")
name = os.environ["NODE_NAME"]
server = os.environ["PUBLIC_HOST"]
port = None
password = None
sni = "www.bing.com"
insecure = True

if link:
    parsed = urllib.parse.urlsplit(link)
    if parsed.scheme not in ("hysteria2", "hy2"):
        raise SystemExit("[ERROR] --link must start with hysteria2:// or hy2://")
    password = urllib.parse.unquote(parsed.username or "")
    server = parsed.hostname or server
    port = parsed.port or 443
    query = urllib.parse.parse_qs(parsed.query)
    sni = query.get("sni", query.get("peer", [sni]))[0]
    insecure = query.get("insecure", ["0"])[0].lower() in ("1", "true", "yes")
    if parsed.fragment:
        name = urllib.parse.unquote(parsed.fragment)
else:
    path = "/etc/hysteria/config.yaml"
    try:
        config = open(path, encoding="utf-8").read()
    except OSError as exc:
        raise SystemExit(f"[ERROR] cannot read {path}; pass --link instead: {exc}")
    listen = re.search(r"(?m)^listen:\s*(?:[^:]*:)?(\d+)\s*$", config)
    secret = re.search(r"(?m)^\s+password:\s*(.+?)\s*$", config)
    if not listen or not secret:
        raise SystemExit("[ERROR] cannot find listen/password in Hysteria2 config; pass --link")
    port = int(listen.group(1))
    raw = secret.group(1)
    password = raw[1:-1].replace("''", "'") if len(raw) >= 2 and raw[0] == raw[-1] == "'" else raw.strip('"')

if not password:
    raise SystemExit("[ERROR] empty Hysteria2 password")

q = lambda value: json.dumps(value, ensure_ascii=False)
profile = f'''mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
ipv6: true

proxies:
  - name: {q(name)}
    type: hysteria2
    server: {q(server)}
    port: {port}
    password: {q(password)}
    sni: {q(sni)}
    skip-cert-verify: {str(insecure).lower()}
    udp: true

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - {q(name)}
      - DIRECT

rules:
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
'''
with open(os.environ["PROFILE"], "w", encoding="utf-8") as output:
    output.write(profile)
os.chmod(os.environ["PROFILE"], 0o644)
PY

cat > "$ENV_FILE" <<EOF
SUBSCRIPTION_DIRECTORY=$WWW_DIR
SUBSCRIPTION_PORT=$LISTEN_PORT
EOF
chmod 600 "$ENV_FILE"
cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Clash subscription HTTP server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/clash-subscription/server.env
ExecStart=/usr/bin/python3 -m http.server ${SUBSCRIPTION_PORT} --bind 0.0.0.0 --directory ${SUBSCRIPTION_DIRECTORY}
Restart=on-failure
RestartSec=3
DynamicUser=true
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now clash-subscription.service >/dev/null

open_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then ufw allow "$LISTEN_PORT/tcp"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$LISTEN_PORT/tcp"
        firewall-cmd --reload
    else warn "no active ufw/firewalld detected; ensure TCP $LISTEN_PORT is allowed by the VPS firewall/security group"
    fi
}
if (( YES )); then
    open_firewall
elif [[ -t 0 ]]; then
    read -r -p "Open TCP $LISTEN_PORT in the local firewall? [y/N]: " answer
    [[ $answer =~ ^[Yy]$ ]] && open_firewall || warn "ensure TCP $LISTEN_PORT is reachable"
else
    warn "firewall unchanged; rerun with --yes or allow TCP $LISTEN_PORT manually"
fi

systemctl is-active --quiet clash-subscription.service || die 'subscription service failed to start; inspect journalctl -u clash-subscription'
URL="http://${PUBLIC_HOST}:${LISTEN_PORT}/${TOKEN}.yaml"
ok "Clash profile installed: $PROFILE"
printf '\nMihomo/Clash Meta 订阅链接（请勿公开分享）：\n%s\n\n' "$URL"
warn 'This URL uses plain HTTP. For long-term use, put it behind an HTTPS domain/reverse proxy.'
