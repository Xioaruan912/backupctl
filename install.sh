#!/usr/bin/env bash
# =============================================================================
# Backup Manager - installer
#
# Copies the manager to its installation prefix, creates the runtime
# directories and links the global `backupctl` command. It does NOT touch
# existing configuration unless you pass --init.
# =============================================================================
set -Eeuo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC_DIR
readonly NAME="backup-manager"
VERSION="$(cat "$SRC_DIR/VERSION" 2>/dev/null || echo unknown)"

DEST="${BACKUP_MANAGER_ROOT:-/root/backup-manager}"
BIN_DIR="/usr/local/bin"
DO_INIT=0
FORCE=0

# 颜色
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_RESET=""; C_BOLD=""
fi

info()  { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() {
    cat <<EOF
${C_BOLD}$NAME $VERSION installer${C_RESET}

Usage: sudo bash install.sh [options]

Options:
  --dest DIR       Installation prefix        (default: /root/backup-manager)
  --bin-dir DIR    Directory for backupctl     (default: /usr/local/bin)
  --init           Run 'backupctl init' if no configuration exists
  --force          Overwrite an existing backup.sh (a .bak copy is kept)
  -h, --help       Show this help
  -V, --version    Show version
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --dest)    DEST="${2:-}"; shift 2 ;;
        --dest=*)  DEST="${1#*=}"; shift ;;
        --bin-dir) BIN_DIR="${2:-}"; shift 2 ;;
        --bin-dir=*) BIN_DIR="${1#*=}"; shift ;;
        --init)    DO_INIT=1; shift ;;
        --force)   FORCE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -V|--version) printf '%s %s\n' "$NAME" "$VERSION"; exit 0 ;;
        *) die "未知参数: $1 (使用 --help)" ;;
    esac
done

[[ -n "$DEST" ]] || die "--dest 不能为空"
[[ "$DEST" == /* ]] || die "--dest 必须是绝对路径"
[[ "$BIN_DIR" == /* ]] || die "--bin-dir 必须是绝对路径"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "需要 root 权限 (例如: sudo bash install.sh)"
fi

info "安装 $NAME $VERSION"
info "  安装目录: $DEST"
info "  命令目录: $BIN_DIR"

# ---------------------------------------------------------------------------
# 文件
# ---------------------------------------------------------------------------
FILES=(
    backup.sh
    README.md
    LICENSE
    CHANGELOG.md
    CONTRIBUTING.md
    CODE_OF_CONDUCT.md
    SECURITY.md
    AUTHORS.md
    VERSION
    Makefile
    install.sh
)
DIRS=(docs tests man)

mkdir -p "$DEST" "$BIN_DIR"

# 保留现有脚本
if [[ -f "$DEST/backup.sh" ]]; then
    if (( FORCE == 1 )); then
        local_ts="$(date +%Y%m%d-%H%M%S)"
        cp -p "$DEST/backup.sh" "$DEST/backup.sh.bak-$local_ts"
        warn "已保留现有脚本为 backup.sh.bak-$local_ts"
    else
        die "$DEST/backup.sh 已存在 (使用 --force 覆盖并保留备份)"
    fi
fi

for f in "${FILES[@]}"; do
    if [[ -f "$SRC_DIR/$f" ]]; then
        install -m 0644 "$SRC_DIR/$f" "$DEST/$f"
    fi
done
chmod 0755 "$DEST/backup.sh"
chmod 0755 "$DEST/install.sh" 2>/dev/null || true

for d in "${DIRS[@]}"; do
    if [[ -d "$SRC_DIR/$d" ]]; then
        mkdir -p "$DEST/$d"
        cp -a "$SRC_DIR/$d/." "$DEST/$d/"
    fi
done

# 运行期目录 (仅 root)
for d in logs state cache restore-history; do
    mkdir -p "$DEST/$d"
    chmod 0700 "$DEST/$d"
done

# ---------------------------------------------------------------------------
# 全局命令
# ---------------------------------------------------------------------------
ln -sf "$DEST/backup.sh" "$BIN_DIR/backupctl"
ok "已创建命令: $BIN_DIR/backupctl -> $DEST/backup.sh"

# ---------------------------------------------------------------------------
# 可选初始化
# ---------------------------------------------------------------------------
if (( DO_INIT == 1 )); then
    if [[ -f "$DEST/backup.conf" ]]; then
        info "配置已存在, 跳过初始化: $DEST/backup.conf"
    else
        BACKUP_MANAGER_ROOT="$DEST" bash "$DEST/backup.sh" init
    fi
fi

# ---------------------------------------------------------------------------
# 完成
# ---------------------------------------------------------------------------
printf '\n%s安装完成%s\n\n' "$C_BOLD" "$C_RESET"
printf '下一步:\n'
if [[ ! -f "$DEST/backup.conf" ]]; then
    printf '  1. %sbackupctl init%s            生成默认配置\n' "$C_BOLD" "$C_RESET"
fi
printf '  2. %sbackupctl check%s           系统检查\n' "$C_BOLD" "$C_RESET"
printf '  3. %sbackupctl run --dry-run%s   预演\n' "$C_BOLD" "$C_RESET"
printf '  4. %sbackupctl%s                 打开交互界面\n' "$C_BOLD" "$C_RESET"
printf '  5. %sbackupctl schedule install%s 安装每日计划任务\n\n' "$C_BOLD" "$C_RESET"
