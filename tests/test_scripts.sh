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

for script in "$ROOT/optimize.sh" "$ROOT/optimize-performance.sh" "$ROOT/setup-clash-subscription.sh"; do
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
assert_contains "$ROOT/install.sh" 'REPO_BRANCH="master"'
assert_contains "$ROOT/install.sh" 'git clone --depth 1 --branch "$REPO_BRANCH"'
assert_contains "$ROOT/install.sh" '$REPO_BRANCH:refs/remotes/origin/$REPO_BRANCH'
assert_contains "$ROOT/setup-clash-subscription.sh" 'tindy2013/subconverter:latest'
assert_contains "$ROOT/setup-clash-subscription.sh" 'reverse_proxy subconverter:25500'
assert_contains "$ROOT/setup-clash-subscription.sh" 'openssl rand -hex 24'
assert_contains "$ROOT/setup-clash-subscription.sh" 'docker port subscription-subconverter'
assert_contains "$ROOT/setup-clash-subscription.sh" 'sslip.io'
assert_contains "$ROOT/setup-clash-subscription.sh" 'docker-compose-v2'
assert_contains "$ROOT/setup-clash-subscription.sh" 'address.is_global'
assert_contains "$ROOT/setup-clash-subscription.sh" 'pref\.example\.ini'
assert_contains "$ROOT/setup-clash-subscription.sh" 'default_url=base/local-sub.txt'
assert_not_contains "$ROOT/setup-clash-subscription.sh" '25500:25500'
assert_not_contains "$ROOT/optimize.sh" 'curl -fsSL https://get.hy2.sh/ | bash'
assert_not_contains "$ROOT/optimize-performance.sh" 'bash "$DEPLOY_SCRIPT"'
assert_not_contains "$ROOT/optimize.sh" 'hysteria check'
assert_not_contains "$ROOT/optimize-performance.sh" 'hysteria check'

if (( failures > 0 )); then
    printf '%d test(s) failed\n' "$failures" >&2
    exit 1
fi
python3 "$ROOT/tests/test_subscription_source.py" || exit 1
printf 'script regression tests: PASS\n'
