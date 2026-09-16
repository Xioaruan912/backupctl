#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== Manifest / SHA256 =="

sandbox_init t09
mkdir -p "$SB_PROJ/data"; echo hi > "$SB_PROJ/data/a.txt"; echo more > "$SB_PROJ/data/b.txt"
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

bm_capture run --automatic
assert_rc "$BM_RC" 0 "运行成功"
RUN="$(find "$SB_BACKUP" -name 'manifest.conf' | head -1 | xargs dirname)"
assert_file "$RUN/manifest.conf" "manifest.conf 存在"
assert_file "$RUN/manifest.sha256" "manifest.sha256 存在"
assert_file "$RUN/summary.txt" "summary.txt 存在"
assert_contains "sha256=" "$(cat "$RUN/manifest.conf")" "manifest 含 sha256"

# 标准 sha256sum -c 通过
( cd "$RUN" && sha256sum -c manifest.sha256 >/dev/null 2>&1 )
assert_rc "$?" 0 "sha256sum -c 通过"

# 修改 archive 后校验失败
ARCH="$(find "$RUN" -name 'p1-*.tar.gz' | head -1)"
printf 'X' >> "$ARCH"
( cd "$RUN" && sha256sum -c manifest.sha256 >/dev/null 2>&1 )
assert_ne "$?" 0 "archive 被篡改后 sha256sum -c 失败"

exit $(( FAIL > 0 ? 1 : 0 ))
