#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== legacy 备份清理 =="

project_conf() { # $1 = cleanup_legacy
    write_conf <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
heuristic_mode=off
local_retention_days=7
remote_retention_days=2
partial_retention_days=2
min_local_success_backups=2
min_remote_success_backups=2
retry_count=1
retry_delay=1
onedrive_reserved_space_gb=0.5
cleanup_legacy=$1
[project:p1]
name=P1
enabled=true
type=dir
source=$SB_PROJ
heuristic=false
EOF
}

seed_legacy() { # date
    mkdir -p "$SB_REMOTE/backup/$1"
    : > "$SB_REMOTE/backup/$1/demoapp-backup-$1.tar.gz"
}

setup() {
    sandbox_init "$1"
    mkdir -p "$SB_PROJ/data"; echo hi > "$SB_PROJ/data/a.txt"
}

YDAY="$(date -d '1 day ago' +%Y-%m-%d)"

# --- cleanup_legacy=true: 过期清理, 未过期保留 ---
setup t11_on
seed_legacy 2020-01-01
seed_legacy 2020-01-02
seed_legacy "$YDAY"
project_conf true
bm_capture run --automatic
assert_rc "$BM_RC" 0 "开启后运行成功"
assert_not_dir "$SB_REMOTE/backup/2020-01-01" "过期 legacy 2020-01-01 被清理"
assert_not_dir "$SB_REMOTE/backup/2020-01-02" "过期 legacy 2020-01-02 被清理"
assert_dir "$SB_REMOTE/backup/$YDAY" "未过期 legacy 被保留"

# --- cleanup_legacy=false: 一律保留 ---
setup t11_off
seed_legacy 2020-01-01
project_conf false
bm_capture run --automatic
assert_rc "$BM_RC" 0 "关闭后运行成功"
assert_dir "$SB_REMOTE/backup/2020-01-01" "关闭时过期 legacy 仍保留"

# --- remote purge --legacy ---
setup t11_purge
project_conf false
seed_legacy 2020-05-05
seed_legacy 2020-05-06
bm_capture remote purge --legacy 2020-05-05 --yes
assert_rc "$BM_RC" 0 "remote purge --legacy 成功"
assert_not_dir "$SB_REMOTE/backup/2020-05-05" "指定 legacy 已删除"
assert_dir "$SB_REMOTE/backup/2020-05-06" "其他 legacy 未受影响"

# --- 非 legacy 目录被拒绝 ---
setup t11_reject
project_conf false
mkdir -p "$SB_REMOTE/backup/2026-09-16/20260916-000000"
: > "$SB_REMOTE/backup/2026-09-16/20260916-000000/RUN_COMPLETE"
bm_capture remote purge --legacy 2026-09-16 --yes
assert_ne "$BM_RC" 0 "对非 legacy 目录拒绝删除"
assert_dir "$SB_REMOTE/backup/2026-09-16" "非 legacy 目录未被删除"

# --- remote purge --legacy-expired ---
setup t11_exp
seed_legacy 2020-01-01
seed_legacy 2020-01-02
project_conf true
bm_capture remote purge --legacy-expired --yes
assert_rc "$BM_RC" 0 "legacy-expired 成功"
assert_not_dir "$SB_REMOTE/backup/2020-01-01" "legacy-expired 删除 1"
assert_not_dir "$SB_REMOTE/backup/2020-01-02" "legacy-expired 删除 2"

exit $(( FAIL > 0 ? 1 : 0 ))
