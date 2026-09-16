#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== systemd timer =="

sandbox_init t08
mkdir -p "$SB_PROJ/data"; echo hi > "$SB_PROJ/data/a.txt"
write_conf <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
heuristic_mode=off
onedrive_reserved_space_gb=0.5
[project:p1]
name=P1
enabled=true
type=dir
source=$SB_PROJ
heuristic=false
EOF

UNIT_DIR="$SB_BM/test-systemd"

bm schedule install 04:15 >/dev/null 2>&1
assert_rc "$?" 0 "安装计划任务"
assert_file "$UNIT_DIR/backup-manager.timer" "生成 timer"
assert_file "$UNIT_DIR/backup-manager.service" "生成 service"
T="$(cat "$UNIT_DIR/backup-manager.timer")"
S="$(cat "$UNIT_DIR/backup-manager.service")"
assert_contains "OnCalendar=*-*-* 04:15:00" "$T" "OnCalendar 正确"
assert_contains "Persistent=true" "$T" "Persistent=true 存在"
assert_contains "Unit=backup-manager.service" "$T" "Timer 绑定 service"
assert_contains "ExecStart=/usr/local/bin/backupctl run --automatic" "$S" "ExecStart 正确"
assert_contains "UMask=0077" "$S" "UMask 正确"

# 修改时间
bm schedule modify 05:45 >/dev/null 2>&1
assert_contains "OnCalendar=*-*-* 05:45:00" "$(cat "$UNIT_DIR/backup-manager.timer")" "修改时间生效"
# 不应产生重复 timer
assert_eq "$(find "$UNIT_DIR" -maxdepth 1 -name 'backup-manager.timer' | wc -l)" "1" "无重复 timer"

# 非法时间
bm schedule install 25:99 >/dev/null 2>&1
assert_rc "$?" 1 "非法时间被拒绝"
assert_contains "OnCalendar=*-*-* 05:45:00" "$(cat "$UNIT_DIR/backup-manager.timer")" "非法时间未破坏现有配置"

# 查看
bm_capture schedule status
assert_rc "$BM_RC" 0 "查看计划任务"

# 删除
bm schedule remove >/dev/null 2>&1
assert_rc "$?" 0 "删除计划任务"
assert_not_file "$UNIT_DIR/backup-manager.timer" "timer 已删除"
assert_not_file "$UNIT_DIR/backup-manager.service" "service 已删除"

exit $(( FAIL > 0 ? 1 : 0 ))
