#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== 进程锁 =="

sandbox_init t02
mkdir -p "$SB_PROJ/data" "$SB_BACKUP"
echo hi > "$SB_PROJ/data/a.txt"

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
backup_pre_hook=sleep 3
EOF

# 启动一个会持锁较久的备份
bash "$BM_SCRIPT" run --automatic >/dev/null 2>&1 &
BGPID=$!
sleep 1

bm_capture run --automatic
assert_rc "$BM_RC" 8 "第二个任务返回 LOCKED(8)"
assert_contains "已有备份任务正在运行" "$BM_OUT" "提示已有任务"
assert_contains "PID" "$BM_OUT" "显示 PID"

# 等待后台结束
wait "$BGPID" 2>/dev/null || true
sleep 0.3
bm_capture run --dry-run
assert_rc "$BM_RC" 0 "锁释放后可再次执行"

exit $(( FAIL > 0 ? 1 : 0 ))
