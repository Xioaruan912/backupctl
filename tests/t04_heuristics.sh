#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "== 启发式 =="

latest_autoex() {
    local m
    m="$(find "$SB_BACKUP" -name manifest.conf 2>/dev/null | sort | tail -1)"
    [[ -n "$m" ]] && grep '^auto_exclude=' "$m" | tail -1 | cut -d= -f2- || echo ""
}

make_media() { # dir count mbytes
    local d="$1" n="$2" mb="$3" i
    mkdir -p "$d"
    for ((i=1;i<=n;i++)); do head -c $((mb*1024*1024)) /dev/zero > "$d/v$i.mp4"; done
}

base_conf() { # extra project lines via $1
    write_conf <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
heuristic_mode=smart
heuristic_scan_depth=2
heuristic_auto_exclude_score=25
onedrive_reserved_space_gb=0.5
retry_count=1
retry_delay=1
[project:tg]
name=TG
enabled=true
type=dir
source=$SB_PROJ
heuristic=true
$1
EOF
}

# 压力: 安全可用约 50MiB
export FAKE_FREE_BYTES=$((50*1024*1024 + 512*1024*1024))

# --- Case 1: downloads 大量视频 + 容量压力 => 自动排除 ---
sandbox_init t04c1
export FAKE_FREE_BYTES=$((50*1024*1024 + 512*1024*1024))
make_media "$SB_PROJ/downloads" 2 60
mkdir -p "$SB_PROJ/data"; echo important > "$SB_PROJ/data/a.txt"
base_conf ""
bm_capture run --automatic
assert_contains "downloads" "$(latest_autoex)" "Case1 downloads 被自动排除"
assert_contains "AUTO_EXCLUDE" "$(cat "$SB_BM"/logs/backup-*.log)" "Case1 记录 AUTO_EXCLUDE"

# --- Case 2: 目录改名为 dl => 同样识别 ---
sandbox_init t04c2
export FAKE_FREE_BYTES=$((50*1024*1024 + 512*1024*1024))
make_media "$SB_PROJ/dl" 2 60
mkdir -p "$SB_PROJ/data"; echo important > "$SB_PROJ/data/a.txt"
base_conf ""
bm_capture run --automatic
assert_contains "dl" "$(latest_autoex)" "Case2 dl 被自动排除"

# --- Case 3: 随机目录名 + 95% 媒体 => 识别 ---
sandbox_init t04c3
export FAKE_FREE_BYTES=$((50*1024*1024 + 512*1024*1024))
make_media "$SB_PROJ/runtime-thing" 2 60
mkdir -p "$SB_PROJ/data"; echo important > "$SB_PROJ/data/a.txt"
base_conf ""
bm_capture run --automatic
assert_contains "runtime-thing" "$(latest_autoex)" "Case3 随机名被识别并排除"

# --- Case 4: data 含 sqlite => 硬保护, 永不自动排除 ---
sandbox_init t04c4
export FAKE_FREE_BYTES=$((50*1024*1024 + 512*1024*1024))
make_media "$SB_PROJ/data" 2 60
printf 'SQLite format 3\0' > "$SB_PROJ/data/important.sqlite"
base_conf ""
bm_capture run --automatic
aut="$(latest_autoex)"
assert_not_contains "data" "$aut" "Case4 含 sqlite 不被自动排除"
assert_contains "硬保护" "$(cat "$SB_BM"/logs/backup-*.log)" "Case4 记录硬保护"

# --- Case 5: 容量充足 => 不自动排除 ---
sandbox_init t04c5
export FAKE_FREE_BYTES=$((50*1024*1024*1024))
make_media "$SB_PROJ/downloads" 2 60
mkdir -p "$SB_PROJ/data"; echo important > "$SB_PROJ/data/a.txt"
base_conf ""
bm_capture run --automatic
assert_not_contains "downloads" "$(latest_autoex)" "Case5 容量充足时不排除"
assert_contains "容量充足" "$(cat "$SB_BM"/logs/backup-*.log)" "Case5 记录容量充足"

# --- Case 6: 用户 protect=downloads => 永不排除 ---
sandbox_init t04c6
export FAKE_FREE_BYTES=$((50*1024*1024 + 512*1024*1024))
make_media "$SB_PROJ/downloads" 2 60
mkdir -p "$SB_PROJ/data"; echo important > "$SB_PROJ/data/a.txt"
base_conf "protect=downloads"
bm_capture run --automatic
assert_not_contains "downloads" "$(latest_autoex)" "Case6 protect 时永不排除"

exit $(( FAIL > 0 ? 1 : 0 ))
