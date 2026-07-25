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
  --name NAME      node name shown in Mihomo (default: Hysteria2-VPS)
  --public-host H  HTTPS hostname (default: <public-ip>.sslip.io)
  --token TOKEN    secret URL path; specifying it rotates the subscription URL
  --yes            install packages and change the firewall without prompting
  --dry-run        validate inputs and print the intended public URL only
  --help           show this help

The public endpoint is HTTPS-only and produces a Mihomo/Clash Meta profile.
TCP ports 80 and 443 must be available. Hysteria2 can continue using UDP 443.
EOF
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_HELPER=$SCRIPT_DIR/scripts/build-subscription-source.py
LINK=''; NODE_NAME='Hysteria2-VPS'; PUBLIC_HOST=''; TOKEN=''; TOKEN_GIVEN=0; YES=0; DRY_RUN=0
while (($#)); do
    case $1 in
        --link) LINK=${2:?missing value}; shift 2;;
        --name) NODE_NAME=${2:?missing value}; shift 2;;
        --public-host) PUBLIC_HOST=${2:?missing value}; shift 2;;
        --token) TOKEN=${2:?missing value}; TOKEN_GIVEN=1; shift 2;;
        --yes) YES=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        --help|-h) usage; exit 0;;
        *) die "unknown option: $1";;
    esac
done

[[ -f $SOURCE_HELPER ]] || die "missing helper: $SOURCE_HELPER"
[[ -n $NODE_NAME && $NODE_NAME != *$'\n'* ]] || die 'invalid --name'
[[ -z $TOKEN || $TOKEN =~ ^[A-Za-z0-9_-]{32,128}$ ]] || die '--token must contain 32-128 letters, digits, _ or -'
[[ -z $PUBLIC_HOST || $PUBLIC_HOST =~ ^[A-Za-z0-9.-]+$ ]] || die 'invalid --public-host'
(( EUID == 0 || DRY_RUN )) || die 'run as root (or use --dry-run)'

STATE_DIR=/etc/subconverter-stack
STATE_FILE=$STATE_DIR/install.env
if [[ -f $STATE_FILE && $TOKEN_GIVEN -eq 0 ]]; then
    saved_token=$(sed -n 's/^SUBSCRIPTION_TOKEN=//p' "$STATE_FILE" | head -1)
    [[ $saved_token =~ ^[A-Za-z0-9_-]{32,128}$ ]] && TOKEN=$saved_token
fi

[[ -r /etc/os-release ]] || (( DRY_RUN )) || die 'cannot detect operating system'
if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
install_packages() {
    case ${ID:-} in
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y docker.io curl ca-certificates openssl python3 iproute2 tar
            apt-get install -y docker-compose-v2 2>/dev/null || apt-get install -y docker-compose
            ;;
        centos|rhel|rocky|almalinux|fedora)
            local pkg
            pkg=$(command -v dnf || command -v yum || true)
            [[ -n $pkg ]] || die 'dnf/yum not found'
            "$pkg" install -y docker curl ca-certificates openssl python3 iproute tar docker-compose-plugin 2>/dev/null || \
                "$pkg" install -y docker curl ca-certificates openssl python3 iproute tar docker-compose
            ;;
        *) die "unsupported OS: ${ID:-unknown}";;
    esac
}

has_compose() {
    docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1
}
if (( ! DRY_RUN )) && { ! command -v docker >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || \
    ! command -v python3 >/dev/null 2>&1 || ! command -v openssl >/dev/null 2>&1 || ! command -v ss >/dev/null 2>&1 || \
    ! command -v tar >/dev/null 2>&1 || ! has_compose; }; then
    (( YES )) || { [[ -t 0 ]] && read -r -p 'Install Docker, Compose, curl, OpenSSL and Python 3? [y/N]: ' answer; [[ ${answer:-} =~ ^[Yy]$ ]] || die 'required packages are missing'; }
    info 'installing required packages from the operating-system repositories'
    install_packages
fi
command -v openssl >/dev/null 2>&1 || die 'openssl is required'
command -v python3 >/dev/null 2>&1 || die 'python3 is required'
[[ -n $TOKEN ]] || TOKEN=$(openssl rand -hex 24)

detect_ipv4() {
    local address=''
    if command -v curl >/dev/null 2>&1; then
        address=$(curl -4fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org 2>/dev/null || true)
    fi
    is_public_ipv4 "$address" || address=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
    is_public_ipv4 "$address" || return 1
    printf '%s' "$address"
}

is_public_ipv4() {
    python3 - "$1" <<'PY' >/dev/null 2>&1
import ipaddress
import sys
try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
raise SystemExit(0 if address.version == 4 and address.is_global else 1)
PY
}

PUBLIC_IP=$(detect_ipv4) || die 'cannot detect a public IPv4 address'
if [[ -z $PUBLIC_HOST ]]; then PUBLIC_HOST=${PUBLIC_IP//./-}.sslip.io; fi
URL="https://${PUBLIC_HOST}/${TOKEN}.yaml"

if (( DRY_RUN )); then
    python3 "$SOURCE_HELPER" --server-config /etc/hysteria/config.yaml --link "$LINK" --name "$NODE_NAME" --server "$PUBLIC_IP" --check
    info "would publish a Mihomo profile at $URL"
    info 'would expose TCP 80/443; subconverter port 25500 would remain private'
    exit 0
fi

systemctl enable --now docker >/dev/null

if docker compose version >/dev/null 2>&1; then COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE=(docker-compose)
else die 'Docker Compose is not available'; fi

if ! docker ps --format '{{.Names}}' | grep -qx 'subscription-caddy'; then
    for port in 80 443; do
        if ss -ltn "sport = :$port" 2>/dev/null | tail -n +2 | grep -q .; then
            die "TCP $port is already in use; stop the existing web server or use it as the reverse proxy"
        fi
    done
fi

SUB_IMAGE_BASE=tindy2013/subconverter:latest
CADDY_IMAGE_BASE=caddy:2-alpine
info 'pulling container images'
docker pull "$SUB_IMAGE_BASE" >/dev/null
docker pull "$CADDY_IMAGE_BASE" >/dev/null
resolve_digest() {
    local image=$1 digest
    digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)
    [[ $digest == *@sha256:* ]] || die "could not resolve immutable digest for $image"
    printf '%s' "$digest"
}
SUB_IMAGE=$(resolve_digest "$SUB_IMAGE_BASE")
CADDY_IMAGE=$(resolve_digest "$CADDY_IMAGE_BASE")

BACKUP_DIR=$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)
if [[ -d $STATE_DIR ]]; then
    install -d -m 700 "$BACKUP_DIR"
    for file in compose.yaml Caddyfile pref.ini install.env source.txt; do
        [[ -f $STATE_DIR/$file ]] && cp -p "$STATE_DIR/$file" "$BACKUP_DIR/$file"
    done
fi
install -d -m 700 "$STATE_DIR"

python3 "$SOURCE_HELPER" --server-config /etc/hysteria/config.yaml --link "$LINK" --name "$NODE_NAME" --server "$PUBLIC_IP" --output "$STATE_DIR/source.txt"
chmod 600 "$STATE_DIR/source.txt"

temp_container=subconverter-pref-$$
docker create --name "$temp_container" "$SUB_IMAGE" >/dev/null
trap 'docker rm -f "$temp_container" >/dev/null 2>&1 || true' EXIT
pref_path=$(docker export "$temp_container" | tar -tf - | awk '
    /(^|\/)pref\.ini$/ { exact=$0 }
    /(^|\/)pref\.example\.ini$/ { example=$0 }
    END { if (exact) print exact; else if (example) print example }
')
[[ -n $pref_path ]] || die 'could not locate pref.ini in the subconverter image'
docker cp "$temp_container:/$pref_path" "$STATE_DIR/pref.ini"
image_workdir=$(docker image inspect --format '{{.Config.WorkingDir}}' "$SUB_IMAGE")
[[ $image_workdir == /* ]] || image_workdir=/$(dirname "$pref_path")
if [[ $(basename "$pref_path") == pref.ini ]]; then pref_mount_path=/$pref_path; else pref_mount_path=$image_workdir/pref.ini; fi
docker rm "$temp_container" >/dev/null
trap - EXIT
sed -i \
    -e 's|^default_url=.*|default_url=http://caddy:8080/source.txt|' \
    -e 's|^serve_file_root=.*|serve_file_root=|' \
    -e 's|^api_access_token=.*|api_access_token=disabled|' \
    -e 's|^proxy_subscription=.*|proxy_subscription=NONE|' \
    "$STATE_DIR/pref.ini"
grep -q '^default_url=http://caddy:8080/source.txt$' "$STATE_DIR/pref.ini" || die 'failed to configure subconverter default source'
chmod 600 "$STATE_DIR/pref.ini"

cat > "$STATE_DIR/Caddyfile" <<EOF
$PUBLIC_HOST {
    @subscription path /$TOKEN.yaml
    handle @subscription {
        rewrite * /sub?target=clash&insert=false&emoji=false&list=false&udp=true&scv=true&sort=false
        reverse_proxy subconverter:25500
    }
    handle {
        respond "Not Found" 404
    }
}

:8080 {
    root * /srv/subscription-source
    file_server
}
EOF
chmod 600 "$STATE_DIR/Caddyfile"

cat > "$STATE_DIR/compose.yaml" <<EOF
services:
  subconverter:
    image: $SUB_IMAGE
    container_name: subscription-subconverter
    restart: unless-stopped
    volumes:
      - ./pref.ini:$pref_mount_path:ro
    networks: [subscription]
    security_opt: [no-new-privileges:true]
  caddy:
    image: $CADDY_IMAGE
    container_name: subscription-caddy
    restart: unless-stopped
    depends_on: [subconverter]
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./source.txt:/srv/subscription-source/source.txt:ro
      - caddy_data:/data
      - caddy_config:/config
    networks: [subscription]
    security_opt: [no-new-privileges:true]
networks:
  subscription: {}
volumes:
  caddy_data: {}
  caddy_config: {}
EOF
chmod 600 "$STATE_DIR/compose.yaml"

cat > "$STATE_FILE" <<EOF
SUBSCRIPTION_HOST=$PUBLIC_HOST
SUBSCRIPTION_TOKEN=$TOKEN
SUBCONVERTER_IMAGE=$SUB_IMAGE
CADDY_IMAGE=$CADDY_IMAGE
EOF
chmod 600 "$STATE_FILE"

info 'starting subconverter and Caddy'
"${COMPOSE[@]}" -f "$STATE_DIR/compose.yaml" --project-directory "$STATE_DIR" up -d

open_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then
        ufw allow 80/tcp
        ufw allow 443/tcp
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=http
        firewall-cmd --permanent --add-service=https
        firewall-cmd --reload
    else
        warn 'no active ufw/firewalld detected; allow TCP 80/443 in the VPS provider security group'
    fi
}
if (( YES )); then open_firewall
elif [[ -t 0 ]]; then
    read -r -p 'Open TCP 80/443 in the local firewall? [y/N]: ' answer
    [[ $answer =~ ^[Yy]$ ]] && open_firewall || warn 'ensure TCP 80/443 is reachable'
else warn 'firewall unchanged; rerun with --yes or allow TCP 80/443 manually'
fi

info 'waiting for the HTTPS certificate and converted profile'
verified=0
for _ in $(seq 1 30); do
    response=$(curl -fsS --connect-timeout 5 --max-time 15 "$URL" 2>/dev/null || true)
    if grep -q 'type: hysteria2' <<<"$response"; then verified=1; break; fi
    sleep 2
done
if (( ! verified )); then
    warn 'HTTPS validation failed; the old subscription service was left unchanged'
    [[ -n $response ]] && warn "conversion response: $response"
    "${COMPOSE[@]}" -f "$STATE_DIR/compose.yaml" --project-directory "$STATE_DIR" logs --tail=50 >&2 || true
    die 'check DNS resolution, provider firewall/security group, and TCP 80/443'
fi
[[ $(curl -sS -o /dev/null -w '%{http_code}' "https://$PUBLIC_HOST/" 2>/dev/null || true) == 404 ]] || die 'root path is unexpectedly accessible'
[[ $(curl -sS -o /dev/null -w '%{http_code}' "https://$PUBLIC_HOST/sub" 2>/dev/null || true) == 404 ]] || die 'public converter API is unexpectedly accessible'
docker port subscription-subconverter 2>/dev/null | grep -q . && die 'subconverter unexpectedly publishes a host port'
docker port subscription-caddy 8080/tcp 2>/dev/null | grep -q . && die 'internal source endpoint unexpectedly publishes a host port'

if systemctl list-unit-files clash-subscription.service >/dev/null 2>&1; then
    systemctl disable --now clash-subscription.service >/dev/null 2>&1 || true
    warn 'disabled the previous Python subscription service; its files were retained'
fi
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q '^Status: active'; then ufw delete allow 18080/tcp >/dev/null 2>&1 || true; fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port=18080/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
fi

ok 'HTTPS subscription is ready for Mihomo/Clash Meta'
printf '\n订阅链接（请勿公开分享）：\n%s\n\n' "$URL"
printf '状态：cd %q && %s ps\n' "$STATE_DIR" "${COMPOSE[*]}"
printf '日志：cd %q && %s logs --tail=100\n' "$STATE_DIR" "${COMPOSE[*]}"
warn 'The random HTTPS URL is the access credential. Rotate it with --token if it leaks.'
