#!/usr/bin/env bash
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
failures=0

assert_contains() {
    local file=$1
    local text=$2
    if ! grep -Fq -- "$text" "$file"; then
        printf 'FAIL: %s does not contain %s\n' "$file" "$text" >&2
        failures=$((failures + 1))
    fi
}

assert_not_contains() {
    local file=$1
    local text=$2
    if grep -Fq -- "$text" "$file"; then
        printf 'FAIL: %s contains forbidden text %s\n' "$file" "$text" >&2
        failures=$((failures + 1))
    fi
}

for script in "$ROOT/optimize.sh" "$ROOT/optimize-performance.sh"; do
    bash -n "$script" || failures=$((failures + 1))
    bash "$script" --help >/dev/null || failures=$((failures + 1))
done

assert_contains "$ROOT/optimize.sh" '--dry-run'
assert_contains "$ROOT/optimize.sh" '--rollback'
assert_contains "$ROOT/optimize.sh" 'LimitNOFILE=65535'
assert_contains "$ROOT/optimize.sh" 'install -m 600'
assert_contains "$ROOT/optimize.sh" 'hashes.txt'
assert_contains "$ROOT/optimize.sh" 'VERSION_URL'
assert_contains "$ROOT/optimize.sh" 'hysteria2://${HY2_PASSWORD}@${SERVER_IP}:${HY2_PORT}'
assert_contains "$ROOT/optimize-performance.sh" '--diagnose'
assert_contains "$ROOT/optimize-performance.sh" '99-hy2.conf'
assert_not_contains "$ROOT/optimize.sh" 'curl -fsSL https://get.hy2.sh/ | bash'
assert_not_contains "$ROOT/optimize-performance.sh" 'bash "$DEPLOY_SCRIPT"'
assert_not_contains "$ROOT/optimize.sh" 'hysteria check'
assert_not_contains "$ROOT/optimize-performance.sh" 'hysteria check'

if (( failures > 0 )); then
    printf '%d test(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'script regression tests: PASS\n'
