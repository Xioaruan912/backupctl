#!/usr/bin/env bash
# 测试公共库
# shellcheck disable=SC2034  # 本库的全局变量 (SB_*, BM_*, CURRENT_TEST) 由各测试脚本消费
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BM_SCRIPT="$(cd "$TESTS_DIR/.." && pwd)/backup.sh"
TMPBASE="${BM_TEST_TMPBASE:-/tmp/bm-tests}"
FAKEBIN_SRC="$TESTS_DIR/fakebin"
ORIG_PATH="$PATH"

PASS=0
FAIL=0
CURRENT_TEST=""

_color() { printf '%s' "$1"; }

ok()   { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$(_color $'\033[32m')" "$(_color $'\033[0m')" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n' "$(_color $'\033[31m')" "$(_color $'\033[0m')" "$1"; }

assert_eq()       { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (期望 '$2', 实际 '$1')"; }
assert_ne()       { [[ "$1" != "$2" ]] && ok "$3" || bad "$3 (不应等于 '$2')"; }
assert_file()     { [[ -f "$1" ]] && ok "$2" || bad "$2 (缺少文件 $1)"; }
assert_not_file() { [[ ! -f "$1" ]] && ok "$2" || bad "$2 (不应存在 $1)"; }
assert_dir()      { [[ -d "$1" ]] && ok "$2" || bad "$2 (缺少目录 $1)"; }
assert_not_dir()  { [[ ! -d "$1" ]] && ok "$2" || bad "$2 (不应存在目录 $1)"; }
assert_contains() { case "$2" in *"$1"*) ok "$3" ;; *) bad "$3 ('$2' 不含 '$1')" ;; esac; }
assert_not_contains() { case "$2" in *"$1"*) bad "$3 ('$2' 含 '$1')" ;; *) ok "$3" ;; esac; }
assert_rc()       { [[ "$1" == "$2" ]] && ok "$3" || bad "$3 (期望 rc=$2, 实际 rc=$1)"; }

# 初始化沙箱; 输出目录变量: SB, SB_BM, SB_BACKUP, SB_REMOTE, SB_PROJ
sandbox_init() {
    local name="$1"
    SB="$TMPBASE/$name"
    rm -rf "$SB"
    mkdir -p "$SB/bm" "$SB/backup" "$SB/remote" "$SB/proj" "$SB/fakebin"
    cp "$FAKEBIN_SRC/rclone" "$SB/fakebin/rclone"
    chmod +x "$SB/fakebin/rclone"
    SB_BM="$SB/bm"
    SB_BACKUP="$SB/backup"
    SB_REMOTE="$SB/remote"
    SB_PROJ="$SB/proj"

    unset FAKE_FREE_BYTES FAKE_TOTAL_BYTES
    export BACKUPCTL_TEST_MODE=1
    export BACKUP_MANAGER_ROOT="$SB_BM"
    export BACKUP_MANAGER_LOCK_FILE="$SB/lock"
    export FAKE_RCLONE_STATE_DIR="$SB_REMOTE"
    export FAKE_FREE_BYTES="${FAKE_FREE_BYTES:-$((50*1024*1024*1024))}"
    export FAKE_TOTAL_BYTES="${FAKE_TOTAL_BYTES:-$((100*1024*1024*1024))}"
    export PATH="$SB/fakebin:$ORIG_PATH"
    unset FAKE_RCLONE_ABOUT_FAIL FAKE_RCLONE_UPLOAD_FAIL FAKE_RCLONE_CHECK_FAIL
    unset BACKUPCTL_TEST_CHECK_PERMS
}

# 写配置 (stdin)
write_conf() {
    cat > "$SB_BM/backup.conf"
    chmod 600 "$SB_BM/backup.conf"
}

# 运行 backupctl; 返回其退出码, 输出到 stdout+stderr
bm() { bash "$BM_SCRIPT" "$@"; }

# 采集输出并返回 rc
bm_capture() {
    BM_OUT="$(bash "$BM_SCRIPT" "$@" 2>&1)"
    BM_RC=$?
    return 0
}
