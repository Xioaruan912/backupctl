#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== run --project =="

sandbox_init t12
mkdir -p "$SB_PROJ/a" "$SB_PROJ/b"
echo a > "$SB_PROJ/a/a.txt"
echo b > "$SB_PROJ/b/b.txt"

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
source=$SB_PROJ/a
heuristic=false
[project:p2]
name=P2
enabled=true
type=dir
source=$SB_PROJ/b
heuristic=false
EOF

bm_capture run --project p1
assert_rc "$BM_RC" 0 "run --project p1 成功"
M="$(find "$SB_BACKUP" -name manifest.conf | sort | tail -1)"
assert_contains "[project:p1]" "$(cat "$M")" "manifest 含 p1"
assert_not_contains "[project:p2]" "$(cat "$M")" "manifest 不含 p2"
assert_not_file "$(find "$SB_BACKUP" -name 'p2-*.tar.gz' | head -1)" "未备份 p2"
assert_contains "status=PROJECT_ONLY" "$(cat "$M")" "单项目运行标记 PROJECT_ONLY"
assert_not_file "$SB_BM/state/last-success.conf" "单项目运行不更新 last-success"
assert_eq "$(find "$SB_REMOTE" -name RUN_COMPLETE | wc -l)" "0" "单项目运行不写 RUN_COMPLETE"
assert_eq "$(find "$SB_REMOTE" -name RUN_PARTIAL | wc -l)" "1" "单项目运行写 RUN_PARTIAL"

bm_capture run --dry-run --project p1
assert_rc "$BM_RC" 0 "run --dry-run --project p1 成功"

exit $(( FAIL > 0 ? 1 : 0 ))
