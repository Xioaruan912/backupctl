#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== 恢复系统 =="

setup() {
    sandbox_init "$1"
    local extra="${2:-}"
    extra="${extra//__SB__/$SB}"
    mkdir -p "$SB_PROJ/data"
    echo "ORIGINAL" > "$SB_PROJ/data/important.txt"
    write_conf <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
heuristic_mode=off
retry_count=1
retry_delay=1
onedrive_reserved_space_gb=0.5
[project:p1]
name=P1
enabled=true
type=dir
source=$SB_PROJ
heuristic=false
$extra
EOF
}

first_run_id() { find "$SB_BACKUP" -name 'manifest.conf' | sort | head -1 | awk -F/ '{print $(NF-1)}'; }

# --- 正常恢复 + before-restore + rollback ---
setup t07_ok 'restore_post_hook=touch __SB__/restore_hook_ran'
bm_capture run --automatic
RID="$(first_run_id)"
echo "MODIFIED" > "$SB_PROJ/data/important.txt"
bm_capture restore --local --run "$RID" --project p1
assert_rc "$BM_RC" 0 "本地恢复成功"
assert_eq "$(cat "$SB_PROJ/data/important.txt")" "ORIGINAL" "文件内容已恢复"
assert_file "$SB/restore_hook_ran" "restore_post_hook 执行"
assert_dir "$(find "$(dirname "$SB_PROJ")" -maxdepth 1 -name 'proj.before-restore-*' | head -1)" "生成 before-restore 目录"
assert_file "$(find "$SB_BM/restore-history" -name 'restore-*.conf' | head -1)" "写入恢复历史"

# rollback
bm_capture restore --rollback
assert_rc "$BM_RC" 0 "回滚成功"
assert_eq "$(cat "$SB_PROJ/data/important.txt")" "MODIFIED" "回滚恢复被替换的数据"

# --- SHA256 不匹配 -> 拒绝恢复 ---
setup t07_sha ""
bm_capture run --automatic
RID="$(first_run_id)"
ARCH="$(find "$SB_BACKUP" -name 'p1-*.tar.gz' | head -1)"
printf 'TAMPER' >> "$ARCH"
echo "NEWDATA" > "$SB_PROJ/data/important.txt"
bm_capture restore --local --run "$RID" --project p1
assert_rc "$BM_RC" 9 "SHA256 不匹配 -> 拒绝恢复(9)"
assert_contains "REJECTED" "$(cat "$(find "$SB_BM/restore-history" -name 'restore-*.conf' | head -1)")" "记录 REJECTED"
assert_eq "$(cat "$SB_PROJ/data/important.txt")" "NEWDATA" "拒绝恢复未改动目标"

# --- 远端恢复 ---
setup t07_remote ""
bm_capture run --automatic
RID="$(first_run_id)"
DATE="$(date +%Y-%m-%d)"
# 模拟本地丢失, 只能从远端恢复
rm -rf "$SB_BACKUP"
echo "LOST" > "$SB_PROJ/data/important.txt"
bm_capture restore --remote --date "$DATE" --run "$RID" --project p1
assert_rc "$BM_RC" 0 "远端恢复成功"
assert_eq "$(cat "$SB_PROJ/data/important.txt")" "ORIGINAL" "远端恢复内容正确"

exit $(( FAIL > 0 ? 1 : 0 ))
