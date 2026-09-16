#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== OneDrive / rclone =="

setup_project() {
    sandbox_init "$1"
    mkdir -p "$SB_PROJ/data"; echo hi > "$SB_PROJ/data/a.txt"
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
EOF
}

# --- 上传失败 ---
setup_project t05_upload
export FAKE_RCLONE_UPLOAD_FAIL=1
bm_capture run --automatic
assert_rc "$BM_RC" 4 "上传失败 -> REMOTE_UPLOAD_ERROR(4)"
assert_not_file "$SB_BM/state/last-success.conf" "上传失败不更新 last-success"
assert_file "$(find "$SB_BACKUP" -name manifest.conf | head -1)" "上传失败仍保留本地备份"
unset FAKE_RCLONE_UPLOAD_FAIL

# --- 校验失败 ---
setup_project t05_check
export FAKE_RCLONE_CHECK_FAIL=1
bm_capture run --automatic
assert_rc "$BM_RC" 5 "远端校验失败 -> VERIFY_ERROR(5)"
assert_not_file "$SB_BM/state/last-success.conf" "校验失败不更新 last-success"
unset FAKE_RCLONE_CHECK_FAIL

# --- 配额不足 ---
setup_project t05_quota
export FAKE_FREE_BYTES=100000
bm_capture run --automatic
assert_rc "$BM_RC" 6 "配额不足 -> CAPACITY_ERROR(6)"
assert_contains "CAPACITY_ERROR" "$(find "$SB_BACKUP" -name manifest.conf | head -1 | xargs grep '^status=' 2>/dev/null)" "manifest 标记 CAPACITY_ERROR"
assert_not_file "$SB_BM/state/last-success.conf" "容量错误不更新 last-success"

# --- about 失败: 仍尝试上传 ---
setup_project t05_about
export FAKE_RCLONE_ABOUT_FAIL=1
bm_capture run --automatic
assert_rc "$BM_RC" 0 "about 失败时仍完成上传"
unset FAKE_RCLONE_ABOUT_FAIL

# --- 成功 + 标记 ---
setup_project t05_ok
bm_capture run --automatic
assert_rc "$BM_RC" 0 "正常上传成功"
assert_file "$SB_BM/state/last-success.conf" "成功后更新 last-success"
find "$SB_REMOTE" -name RUN_COMPLETE | grep -q . && ok "远端写入 RUN_COMPLETE" || bad "远端缺少 RUN_COMPLETE"

exit $(( FAIL > 0 ? 1 : 0 ))
