#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
CYAN=$'\033[0;36m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; PLAIN=$'\033[0m'
info() { printf '%b[INFO]%b %s\n' "$CYAN" "$PLAIN" "$*"; }
ok() { printf '%b[OK]%b %s\n' "$GREEN" "$PLAIN" "$*"; }
warn() { printf '%b[WARN]%b %s\n' "$YELLOW" "$PLAIN" "$*" >&2; }
die() { printf '%b[ERROR]%b %s\n' "$YELLOW" "$PLAIN" "$*" >&2; exit 1; }
usage() { cat <<'EOF'
Usage: bash optimize-performance.sh [--dry-run] [--yes] [--diagnose] [--rollback]
  --dry-run    show changes without writing files or restarting services
  --yes        restart the service without prompting
  --diagnose   perform optional outbound connectivity checks
  --rollback   restore the newest sysctl backup
  --help       show this help
EOF
}
DRY_RUN=0; YES=0; DIAGNOSE=0; ROLLBACK=0
while (($#)); do case $1 in
    --dry-run) DRY_RUN=1; shift;; --yes) YES=1; shift;; --diagnose) DIAGNOSE=1; shift;;
    --rollback) ROLLBACK=1; shift;; --help|-h) usage; exit 0;; *) die "unknown option: $1";;
esac; done
(( EUID == 0 || DRY_RUN )) || die 'run as root'
CONFIG=/etc/hysteria/config.yaml; SYSCTL_FILE=/etc/sysctl.d/99-hy2.conf; BACKUP_DIR=/etc/hysteria/backups
run() { if (( DRY_RUN )); then printf '%b[DRY-RUN]%b' "$CYAN" "$PLAIN"; printf ' %q' "$@"; printf '\n'; else "$@"; fi; }
[[ -f $CONFIG ]] || die "missing config: $CONFIG"
if (( ROLLBACK )); then
    backup=$(find "$BACKUP_DIR" -type f -name '99-hy2.conf.*.bak' -print 2>/dev/null | sort | tail -1 || true)
    [[ -n $backup && -f $backup ]] || die 'no sysctl backup found'
    run install -m 644 "$backup" "$SYSCTL_FILE"; ok "restored $backup"; exit 0
fi

[[ -s $CONFIG ]] || die "empty config: $CONFIG"
grep -Eq '^listen:' "$CONFIG" || die 'config has no listen directive'
if (( ! DRY_RUN )); then
    mkdir -p "$BACKUP_DIR"
    if [[ -f $SYSCTL_FILE ]]; then cp -p "$SYSCTL_FILE" "$BACKUP_DIR/99-hy2.conf.$(date +%Y%m%d-%H%M%S).bak"; fi
fi
if (( DRY_RUN )); then
    info 'would apply conservative BBR/TCP settings from /etc/sysctl.d/99-hy2.conf'
else
    install -m 644 /dev/null "$SYSCTL_FILE"
    cat > "$SYSCTL_FILE" <<'EOF'
# Managed by Hysteria2 optimizer. Conservative settings; measure before tuning further.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.core.netdev_max_backlog = 50000
EOF
    sysctl --system >/dev/null 2>&1 || warn 'some sysctl values were rejected by this kernel'
    ok 'conservative network settings applied'
fi
cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')
info "active TCP congestion control: $cc"
if (( DIAGNOSE )); then
    info 'diagnostic mode only verifies local DNS and service state; it does not print proxy credentials'
    getent hosts github.com >/dev/null 2>&1 && ok 'DNS resolution works' || warn 'DNS resolution failed'
fi
if (( YES )); then systemctl restart hysteria-server; elif [[ -t 0 ]]; then read -r -p 'Restart Hysteria2 now? [y/N]: ' answer; [[ $answer =~ ^[Yy]$ ]] && systemctl restart hysteria-server || true; else warn 'service was not restarted; use --yes to apply runtime changes'; fi
systemctl is-active --quiet hysteria-server && ok 'Hysteria2 service is active' || warn 'Hysteria2 service is not active'
