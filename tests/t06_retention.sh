#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== Retention / 安全清理 =="

count_remote_complete() { find "$SB_REMOTE" -name RUN_COMPLETE 2>/dev/null | wc -l; }
count_local_complete() { find "$SB_BACKUP" -name RUN_COMPLETE 2>/dev/null | wc -l; }

seed_remote_snapshot() { # date run
    mkdir -p "$SB_REMOTE/backup/$1/$2"
    : > "$SB_REMOTE/backup/$1/$2/RUN_COMPLETE"
    : > "$SB_REMOTE/backup/$1/$2/manifest.conf"
}
seed_local_run() { # date run age_days
    local d="$SB_BACKUP/$1/$2"
    mkdir -p "$d"
    : > "$d/RUN_COMPLETE"; echo "run_id=$2" > "$d/manifest.conf"
    touch -d "$3 days ago" "$d"
}

project_conf() {
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
[project:p1]
name=P1
enabled=true
type=dir
source=$SB_PROJ
heuristic=false
EOF
}

setup() { sandbox_init "$1"; mkdir -p "$SB_PROJ/data"; echo hi > "$SB_PROJ/data/a.txt"; project_conf; }

# --- 新备份失败 -> 旧成功快照一个都不删 ---
setup t06_fail
seed_remote_snapshot 2020-01-01 20200101-000000
seed_remote_snapshot 2020-01-02 20200102-000000
seed_remote_snapshot 2020-01-03 20200103-000000
before="$(count_remote_complete)"
export FAKE_RCLONE_UPLOAD_FAIL=1
bm_capture run --automatic
after="$(count_remote_complete)"
assert_rc "$BM_RC" 4 "失败运行返回上传错误"
assert_eq "$after" "$before" "新备份失败: 旧成功快照未被删除"
unset FAKE_RCLONE_UPLOAD_FAIL

# --- 新备份成功 -> 只删超期, 且保留 >=2 ---
setup t06_ok
seed_remote_snapshot 2020-01-01 20200101-000000
seed_remote_snapshot 2020-01-02 20200102-000000
seed_remote_snapshot 2020-01-03 20200103-000000
seed_remote_snapshot 2020-01-04 20200104-000000
# 一个较新的成功快照 (不应被删)
seed_remote_snapshot "$(date +%Y-%m-%d)" 20990101-000000
bm_capture run --automatic
assert_rc "$BM_RC" 0 "成功运行"
newcount="$(count_remote_complete)"
assert_ge() { [[ "$1" -ge "$2" ]] && ok "$3" || bad "$3 ($1 < $2)"; }
assert_ge "$newcount" 2 "远端仍保留 >= 2 个成功快照"
assert_file "$SB_REMOTE/backup/$(date +%Y-%m-%d)/20990101-000000/RUN_COMPLETE" "较新的成功快照被保留"

# --- legacy 目录受保护, 不删 ---
setup t06_legacy
mkdir -p "$SB_REMOTE/backup/2018-01-01"
: > "$SB_REMOTE/backup/2018-01-01/demoapp-backup-2018-01-01.tar.gz"
assert_file "$SB_REMOTE/backup/2018-01-01/demoapp-backup-2018-01-01.tar.gz" "legacy 备份存在"
bm_capture run --automatic
assert_rc "$BM_RC" 0 "带 legacy 的运行为成功"
assert_file "$SB_REMOTE/backup/2018-01-01/demoapp-backup-2018-01-01.tar.gz" "legacy 备份未被删除"

# --- 本地清理: 保留最少数量 ---
setup t06_local
seed_local_run 2020-01-01 20200101-000000 30
seed_local_run 2020-01-02 20200102-000000 30
seed_local_run 2020-01-03 20200103-000000 30
seed_local_run 2020-01-04 20200104-000000 30
bm_capture run --automatic
lcount="$(count_local_complete)"
assert_rc "$BM_RC" 0 "本地清理运行成功"
assert_ge "$lcount" 2 "本地仍保留 >= 2 个成功快照"

exit $(( FAIL > 0 ? 1 : 0 ))
