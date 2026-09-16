#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== CLI / 非交互 =="

sandbox_init t10
mkdir -p "$SB_PROJ/data"; echo hi > "$SB_PROJ/data/a.txt"

# 非 TTY 无参数 -> 打印帮助, 不 read
BM_OUT="$(bash "$BM_SCRIPT" < /dev/null 2>&1)"; BM_RC=$?
assert_rc "$BM_RC" 0 "无参数非 TTY 退出码 0"
assert_contains "用法: backupctl" "$BM_OUT" "无参数非 TTY 打印帮助"

# init
bm_capture init
assert_rc "$BM_RC" 0 "init 成功"
assert_file "$SB_BM/backup.conf" "生成 backup.conf"

# project add (非交互)
bm_capture project add myproj "我的项目" "$SB_PROJ" dir true
assert_rc "$BM_RC" 0 "project add 成功"
assert_contains "myproj" "$(cat "$SB_BM/backup.conf")" "配置中包含新项目"

# disable / enable
bm_capture project disable myproj
assert_contains "enabled=false" "$(cat "$SB_BM/backup.conf")" "disable 生效"
bm_capture project enable myproj
assert_contains "enabled=true" "$(cat "$SB_BM/backup.conf")" "enable 生效"

# remove (只删配置)
bm_capture project remove myproj
assert_rc "$BM_RC" 0 "project remove 成功"
assert_not_contains "[project:myproj]" "$(cat "$SB_BM/backup.conf")" "项目配置已删除"
assert_dir "$SB_PROJ/data" "删除项目未影响源数据"

# check
bm_capture check
assert_contains "系统检查" "$BM_OUT" "check 运行"

# logs
bm_capture logs 5
assert_rc "$BM_RC" 0 "logs 命令"

# status
bm_capture status
assert_rc "$BM_RC" 0 "status 命令"

# remote list
bm_capture remote list
assert_rc "$BM_RC" 0 "remote list"

exit $(( FAIL > 0 ? 1 : 0 ))
