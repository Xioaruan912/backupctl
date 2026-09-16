#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== 配置解析与校验 =="

sandbox_init t01
mkdir -p "$SB_PROJ/data"

# --- 合法 INI + 中文名称 + 空格 + 值中的 = ---
write_conf <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
heuristic_mode=off
onedrive_reserved_space_gb=0.5

[project:demoapp]
name=我的保险库 Vault
enabled=true
type=dir
source=$SB_PROJ
heuristic=true
exclude=downloads
exclude=archive backup
protect==weird
backup_pre_hook=
backup_post_hook=echo a=b
EOF
bm_capture project list
assert_rc "$BM_RC" 0 "合法配置通过解析"
assert_contains "demoapp" "$BM_OUT" "列出项目 id"

# 值中包含 = 的 hook
cat > "$SB_BM/backup.conf" <<EOF
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
backup_post_hook=touch $SB/hook_ok=1
EOF
chmod 600 "$SB_BM/backup.conf"
rm -f "$SB/hook_ok=1"
bm run --automatic >/dev/null 2>&1
assert_file "$SB/hook_ok=1" "hook 值中的 '=' 被正确保留"

# --- 重复 exclude/protect 累积 ---
cat > "$SB_BM/backup.conf" <<EOF
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
exclude=dl
exclude=cache,tmp
protect=data
protect=secret
EOF
chmod 600 "$SB_BM/backup.conf"
bm_capture project exclude p1
assert_contains "dl" "$BM_OUT" "重复 exclude 保留 dl"
assert_contains "cache" "$BM_OUT" "重复 exclude 保留 cache"
assert_contains "tmp" "$BM_OUT" "逗号分隔 exclude 保留 tmp"
bm_capture project protect p1
assert_contains "data" "$BM_OUT" "protect 保留 data"
assert_contains "secret" "$BM_OUT" "protect 保留 secret"

# --- 非法数字 ---
cat > "$SB_BM/backup.conf" <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
retry_count=abc
[project:p1]
name=P1
enabled=true
type=dir
source=$SB_PROJ
EOF
chmod 600 "$SB_BM/backup.conf"
bm_capture run --automatic
assert_rc "$BM_RC" 2 "非法数字 -> CONFIG_ERROR"
assert_contains "retry_count" "$BM_OUT" "错误信息包含字段名"

# --- 非法 bool ---
cat > "$SB_BM/backup.conf" <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
[project:p1]
name=P1
enabled=maybe
type=dir
source=$SB_PROJ
EOF
chmod 600 "$SB_BM/backup.conf"
bm_capture run --automatic
assert_rc "$BM_RC" 2 "非法 bool -> CONFIG_ERROR"

# --- 非法 project id ---
cat > "$SB_BM/backup.conf" <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
[project:Bad ID]
name=P1
enabled=true
type=dir
source=$SB_PROJ
EOF
chmod 600 "$SB_BM/backup.conf"
bm_capture run --automatic
assert_rc "$BM_RC" 2 "非法 project id -> CONFIG_ERROR"

# --- 未知字段 ---
cat > "$SB_BM/backup.conf" <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
not_a_field=1
[project:p1]
name=P1
enabled=true
type=dir
source=$SB_PROJ
EOF
chmod 600 "$SB_BM/backup.conf"
bm_capture run --automatic
assert_rc "$BM_RC" 2 "未知全局字段 -> CONFIG_ERROR"

# --- 非法 exclude 路径 ---
cat > "$SB_BM/backup.conf" <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
[project:p1]
name=P1
enabled=true
type=dir
source=$SB_PROJ
exclude=../etc
EOF
chmod 600 "$SB_BM/backup.conf"
bm_capture run --automatic
assert_rc "$BM_RC" 2 "非法 exclude 路径 -> CONFIG_ERROR"

# --- 配置不做 shell expansion ---
rm -f "$SB/pwned"
cat > "$SB_BM/backup.conf" <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
heuristic_mode=off
[project:p1]
name=P1
enabled=true
type=dir
source=$SB_PROJ
backup_pre_hook=\$(touch $SB/pwned)
EOF
chmod 600 "$SB_BM/backup.conf"
bm run --dry-run >/dev/null 2>&1
assert_not_file "$SB/pwned" "配置不会被 source/eval 执行"

# --- 权限不安全 -> 自动模式拒绝 ---
cat > "$SB_BM/backup.conf" <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
[project:p1]
name=P1
enabled=true
type=dir
source=$SB_PROJ
EOF
chmod 644 "$SB_BM/backup.conf"
BACKUPCTL_TEST_CHECK_PERMS=1 bm_capture run --automatic
assert_rc "$BM_RC" 2 "权限不安全 -> 拒绝执行"
chmod 600 "$SB_BM/backup.conf"

# --- config rollback ---
cp "$SB_BM/backup.conf" "$SB_BM/backup.conf.bak"
bm_capture config rollback
assert_rc "$BM_RC" 0 "config rollback 成功"

exit $(( FAIL > 0 ? 1 : 0 ))
