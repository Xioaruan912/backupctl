#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== 备份引擎 / Hooks / 半包 =="

# ---------- A: PRE 成功 + 备份失败 -> POST 仍执行 ----------
sandbox_init t03a
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
backup_pre_hook=rm -rf $SB_PROJ
backup_post_hook=touch $SB/post_ran
EOF
bm_capture run --automatic
assert_file "$SB/post_ran" "PRE 成功且 backup 失败时 POST 仍执行"
assert_rc "$BM_RC" 3 "部分失败 -> BACKUP_ERROR(3)"

# ---------- B: PRE 失败 -> backup 不执行, POST 不执行 ----------
sandbox_init t03b
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
backup_pre_hook=false
backup_post_hook=touch $SB/post_ran
EOF
bm_capture run --automatic
assert_not_file "$SB/post_ran" "PRE 失败时 POST 不执行"
assert_rc "$BM_RC" 3 "PRE 失败 -> 运行失败"

# ---------- C: POST 失败 -> 整体失败但归档保留 ----------
sandbox_init t03c
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
backup_post_hook=false
EOF
bm_capture run --automatic
assert_rc "$BM_RC" 3 "POST 失败 -> 运行失败"
ARCH="$(find "$SB_BACKUP" -name 'p1-*.tar.gz' | head -1)"
assert_file "$ARCH" "POST 失败仍保留有效归档"

# ---------- D: tar 失败 -> 不产生正式归档, 不残留 partial ----------
sandbox_init t03d
mkdir -p "$SB_PROJ/data"; echo hi > "$SB_PROJ/data/a.txt"
cat > "$SB/fakebin/tar" <<'FAKETAR'
#!/usr/bin/env bash
for ((i=0;i<${#@};i++)); do :; done
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
    if [[ "${args[$i]}" == "-czf" ]]; then
        out="${args[$((i+1))]}"
        : > "$out"; echo garbage > "$out"
        exit 2
    fi
done
exit 0
FAKETAR
chmod +x "$SB/fakebin/tar"
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
bm_capture run --automatic
assert_rc "$BM_RC" 3 "tar 失败 -> 部分失败"
assert_eq "$(find "$SB_BACKUP" -name '*.tar.gz' | wc -l)" "0" "无正式 .tar.gz"
assert_eq "$(find "$SB_BACKUP" "$SB_BM/cache" -name '*.partial' 2>/dev/null | wc -l)" "0" "无残留 .partial"

# ---------- E: 自动模式不读取输入 ----------
sandbox_init t03e
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
bash "$BM_SCRIPT" run --automatic < /dev/null >/dev/null 2>&1
assert_rc "$?" 0 "自动模式在无 stdin 时成功且不阻塞"

exit $(( FAIL > 0 ? 1 : 0 ))
