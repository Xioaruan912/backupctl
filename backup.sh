#!/usr/bin/env bash
# =============================================================================
# Backup Manager
# 智能服务器备份管理工具 (纯 Bash)
#
# 设计原则: 数据安全 > 可恢复性 > 可靠性 > 简单性 > 性能 > UI
# 核心运行程序保持为单文件。
#
# 需要 Bash >= 4.4
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# 版本 / 常量
# -----------------------------------------------------------------------------
readonly BACKUP_MANAGER_VERSION="2.1.0"
readonly MANIFEST_FORMAT_VERSION="2"
readonly BACKUP_MANAGER_NAME="Backup Manager"

# 退出码
# shellcheck disable=SC2034
readonly E_SUCCESS=0
readonly E_GENERAL=1
readonly E_CONFIG=2
readonly E_BACKUP=3
readonly E_REMOTE_UPLOAD=4
readonly E_VERIFY=5
readonly E_CAPACITY=6
readonly E_HOOK=7
readonly E_LOCKED=8
readonly E_RESTORE=9
readonly E_MAINTENANCE=10

# -----------------------------------------------------------------------------
# 全局路径 (测试模式下允许覆盖)
# -----------------------------------------------------------------------------
BM_ROOT="${BACKUP_MANAGER_ROOT:-/root/backup-manager}"
readonly BM_ROOT
readonly CONF_FILE="$BM_ROOT/backup.conf"
readonly CONF_BAK="$BM_ROOT/backup.conf.bak"
readonly LOG_DIR="$BM_ROOT/logs"
readonly STATE_DIR="$BM_ROOT/state"
readonly CACHE_DIR="$BM_ROOT/cache"
readonly RESTORE_HISTORY_DIR="$BM_ROOT/restore-history"
readonly STATE_LAST_RUN="$STATE_DIR/last-run.conf"
readonly STATE_LAST_SUCCESS="$STATE_DIR/last-success.conf"
readonly STATE_HEURISTICS="$STATE_DIR/heuristics.conf"

readonly BACKUPCTL_PATH="/usr/local/bin/backupctl"
LOCK_FILE="${BACKUP_MANAGER_LOCK_FILE:-/run/lock/backup-manager.lock}"
readonly LOCK_FILE
readonly LOCK_INFO_FILE="${LOCK_FILE}.info"

SELF_SCRIPT="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
readonly SELF_SCRIPT

# 测试模式
BM_TEST_MODE=0
if [[ "${BACKUPCTL_TEST_MODE:-0}" == "1" ]]; then
    BM_TEST_MODE=1
fi
readonly BM_TEST_MODE

# -----------------------------------------------------------------------------
# 颜色 (非 TTY / NO_COLOR 关闭)
# -----------------------------------------------------------------------------
C_RESET=""
C_RED=""
C_GREEN=""
C_YELLOW=""
C_BLUE=""
C_CYAN=""
C_BOLD=""
C_DIM=""
bm_colors_init() {
    if { [[ -t 1 ]] || [[ -t 2 ]]; } && [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
        C_RESET=$'\033[0m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_BLUE=$'\033[34m'
        C_CYAN=$'\033[36m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
    else
        C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""
        C_BLUE=""; C_CYAN=""; C_BOLD=""; C_DIM=""
    fi
}

# 清屏 (仅交互终端; BM_NO_CLEAR=1 可关闭)
ui_reset() {
    if [[ -t 1 && "${BM_NO_CLEAR:-0}" != "1" ]]; then
        clear 2>/dev/null || printf '\033[2J\033[H'
    fi
}

# -----------------------------------------------------------------------------
# 全局运行时状态
# -----------------------------------------------------------------------------
LOG_FILE=""                 # 当前日志文件 (为空则只输出终端)
CURRENT_RUN_ID=""
CURRENT_MODE="manual"       # manual | automatic | dry-run
LOG_LOCK_FD=""              # flock 文件描述符
POST_PENDING=0              # 当前项目 POST hook 是否必须执行
POST_DONE=0
CURRENT_PROJECT_ID=""
declare -a TEMP_FILES=()

# -----------------------------------------------------------------------------
# 配置内存模型
# -----------------------------------------------------------------------------
declare -A GLOBAL=()        # GLOBAL[key]=value
declare -a PROJECT_IDS=()   # 有序
declare -A PROJ=()          # PROJ[id.field]=value
declare -A PROJ_EXCLUDE=()  # id -> 换行分隔列表
declare -A PROJ_PROTECT=()  # id -> 换行分隔列表

# 运行结果累积
declare -A RUN_PROJECT_STATUS=()   # id -> ok|failed|skipped
declare -A RUN_PROJECT_SIZE=()     # id -> bytes (archive)
declare -A RUN_PROJECT_ARCHIVE=()  # id -> filename
declare -A RUN_PROJECT_HASH=()     # id -> sha256
declare -A RUN_PROJECT_AUTOEX=()   # id -> newline list of auto-excluded rel paths
declare -A RUN_PROJECT_ERR=()      # id -> error
RUN_WARNINGS=0
RUN_FAILED=0
RUN_REMOTE_UPLOAD=0
RUN_REMOTE_VERIFY=0

# =============================================================================
# Utility
# =============================================================================

now_iso() { date +'%Y-%m-%dT%H:%M:%S%:z'; }
now_epoch() { date +%s; }

trim() {
    local s
    if (( $# > 0 )); then
        s="$1"
    else
        s=""
        IFS= read -r s || true
    fi
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

is_int() { [[ "$1" =~ ^-?[0-9]+$ ]]; }

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

is_bool() { [[ "$1" == "true" || "$1" == "false" ]]; }

# 数值范围验证
validate_int_range() {
    local val="$1" min="$2" max="$3" name="$4"
    if ! is_int "$val"; then
        cfg_error "字段 $name 必须是整数 (当前: '$val')"
        return 1
    fi
    if (( val < min || val > max )); then
        cfg_error "字段 $name 超出范围 [$min,$max] (当前: $val)"
        return 1
    fi
    return 0
}

# 数值 (允许小数)
is_number() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]; }

quote_sh() { printf '%q' "$1"; }

# 把大小 (人类可读) 转成字节, 支持 "5 GiB", "1.3GiB", "1024"
human_to_bytes() {
    local v="$1"
    v="$(trim "$v")"
    local num unit
    num="$(printf '%s' "$v" | sed -E 's/^([0-9]+([.][0-9]+)?).*/\1/')"
    unit="$(printf '%s' "$v" | sed -E 's/^[0-9]+([.][0-9]+)?[[:space:]]*([A-Za-z]*).*/\2/' | tr '[:lower:]' '[:upper:]')"
    [[ -z "$num" ]] && { echo 0; return; }
    local mult=1
    case "$unit" in
        B|"") mult=1 ;;
        K|KI|KIB) mult=1024 ;;
        M|MI|MIB) mult=1048576 ;;
        G|GI|GIB) mult=1073741824 ;;
        T|TI|TIB) mult=1099511627776 ;;
        P|PI|PIB) mult=1125899906842624 ;;
        *) mult=1 ;;
    esac
    awk -v n="$num" -v m="$mult" 'BEGIN{printf "%.0f", n*m}'
}

# 字节 -> 人类可读
bytes_to_human() {
    local b="${1:-0}"
    awk -v b="$b" 'BEGIN{
        split("B KiB MiB GiB TiB PiB", u, " ");
        i=1; while (b >= 1024 && i < 7) { b/=1024; i++ }
        if (i==1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i];
    }'
}

# 原子写文件 (内容从 stdin)
atomic_write() {
    local target="$1"
    local dir
    dir="$(dirname "$target")"
    mkdir -p "$dir"
    local tmp
    tmp="$(mktemp "$dir/.tmp.XXXXXX")"
    cat > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$target"
}

# 幂等注册临时文件清理
register_temp() { TEMP_FILES+=("$1"); }

remove_temp_files() {
    local f
    for f in "${TEMP_FILES[@]:-}"; do
        if [[ -n "$f" && -e "$f" ]]; then
            rm -rf -- "$f" 2>/dev/null || true
        fi
    done
}

# =============================================================================
# 日志
# =============================================================================

# 日志文件写入 (无 ANSI)
_log_file() {
    local line="$1"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# 核心日志
# $1=level (INFO/OK/WARN/ERROR/DEBUG) $2=scope $3=message
log_line() {
    local level="$1" scope="$2" msg="$3"
    local color="" ts
    ts="$(now_iso)"
    case "$level" in
        INFO)  color="$C_BLUE" ;;
        OK)    color="$C_GREEN" ;;
        WARN)  color="$C_YELLOW" ;;
        ERROR) color="$C_RED" ;;
        DEBUG) color="$C_DIM" ;;
    esac
    # 终端输出 (带颜色); 日志走 stderr, 保持 stdout 为纯数据
    if [[ -n "$color" ]]; then
        printf '%s%s%s%s %s%-5s%s %s[%s]%s %s\n' \
            "$C_DIM" "$ts" "$C_RESET" \
            "" "$color" "$level" "$C_RESET" \
            "$C_CYAN" "$scope" "$C_RESET" "$msg" >&2
    else
        printf '%s %-5s [%s] %s\n' "$ts" "$level" "$scope" "$msg" >&2
    fi
    _log_file "$ts $level [$scope] $msg"
}

log_info()  { log_line INFO  "${CURRENT_PROJECT_ID:-run}" "$*"; }
log_ok()    { log_line OK    "${CURRENT_PROJECT_ID:-run}" "$*"; }
log_warn()  { log_line WARN  "${CURRENT_PROJECT_ID:-run}" "$*"; RUN_WARNINGS=$((RUN_WARNINGS+1)); }
log_error() { log_line ERROR "${CURRENT_PROJECT_ID:-run}" "$*"; }
log_debug() { if [[ "${BM_DEBUG:-0}" == "1" ]]; then log_line DEBUG "${CURRENT_PROJECT_ID:-run}" "$*"; fi; }

# 简单错误 (用于配置/参数), 不进入 RUN 统计
fail() { log_line ERROR "backupctl" "$*"; }
cfg_error() { log_line ERROR "config" "$*"; }

# =============================================================================
# 安全删除
# =============================================================================

# 判断路径是否危险
is_dangerous_path() {
    local p="$1"
    [[ -z "$p" ]] && return 0
    # 归一化 (去掉尾斜杠)
    local norm="${p%/}"
    [[ -z "$norm" ]] && norm="/"
    case "$norm" in
        /|.|..|/root|/usr|/var|/etc|/home|/opt|/boot|/bin|/sbin|/lib|/lib64|/proc|/sys|/dev)
            return 0 ;;
    esac
    # 不能是 BM_ROOT 本身
    if [[ "$norm" == "$BM_ROOT" ]]; then
        return 0
    fi
    # 不能是 BM_ROOT 的祖先
    if [[ "$BM_ROOT" == "$norm"/* ]]; then
        return 0
    fi
    return 1
}

# safe_remove_tree: 只在确认安全的路径上执行 rm -rf
safe_remove_tree() {
    local target="$1"
    if [[ -z "$target" ]]; then
        log_error "safe_remove_tree: 空路径, 拒绝删除"
        return 1
    fi
    local norm
    norm="$(readlink -f -- "$target" 2>/dev/null || printf '%s' "$target")"
    if is_dangerous_path "$norm"; then
        log_error "safe_remove_tree: 危险路径, 拒绝删除: $norm"
        return 1
    fi
    # 路径穿越检查
    case "$norm" in
        *'/../'*|*'/..')
            log_error "safe_remove_tree: 路径包含 .., 拒绝: $norm"
            return 1 ;;
    esac
    # 必须位于允许的根内: backup_dir / cache / restore temp
    local allowed=0
    local root
    for root in "$CACHE_DIR" "${BACKUP_DIR:-/nonexistent}" "${RESTORE_HISTORY_DIR:-/nonexistent}"; do
        [[ -z "$root" ]] && continue
        if [[ "$norm" == "$root"/* ]]; then allowed=1; break; fi
    done
    if (( allowed == 0 )) && [[ "$BM_TEST_MODE" == "1" ]]; then
        # 测试模式下允许删除测试 tmp 目录
        if [[ "$norm" == "${BM_TEST_TMPDIR:-/nonexistent}"/* ]]; then allowed=1; fi
    fi
    if (( allowed == 0 )); then
        log_error "safe_remove_tree: 路径不在允许范围内, 拒绝删除: $norm"
        return 1
    fi
    rm -rf -- "$norm"
}

# 验证目录名日期格式 YYYY-MM-DD
is_valid_date_dir() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; }

# 验证 RUN_ID 格式 YYYYMMDD-HHMMSS
is_valid_run_id() { [[ "$1" =~ ^[0-9]{8}-[0-9]{6}$ ]]; }

# 验证项目 ID
is_valid_project_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,63}$ ]]; }

# =============================================================================
# 依赖检查
# =============================================================================

DEP_COMMANDS=(tar gzip sha256sum du df stat find grep sed awk flock timeout base64 date mktemp)

check_dependencies() {
    local missing=() cmd
    for cmd in "${DEP_COMMANDS[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        fail "缺少必需命令: ${missing[*]}"
        return "$E_GENERAL"
    fi
    # Bash 版本
    if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4 ) )); then
        fail "Bash 版本过低: $BASH_VERSION (需要 >= 4.4)"
        return "$E_GENERAL"
    fi
    return 0
}

require_root() {
    if [[ "$BM_TEST_MODE" == "1" ]]; then
        return 0
    fi
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        fail "必须以 root 身份运行 (当前 UID: ${EUID:-$(id -u)})"
        return "$E_GENERAL"
    fi
    return 0
}

# =============================================================================
# 锁
# =============================================================================

acquire_lock() {
    local mode="$1"
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    if ! exec {LOG_LOCK_FD}>"$LOCK_FILE"; then
        fail "无法打开锁文件: $LOCK_FILE"
        return "$E_GENERAL"
    fi
    if ! flock -n "$LOG_LOCK_FD"; then
        log_line WARN "lock" "已有备份任务正在运行"
        if [[ -f "$LOCK_INFO_FILE" ]]; then
            local pid start rmode
            # shellcheck disable=SC1090
            pid="$(grep -E '^pid=' "$LOCK_INFO_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"
            start="$(grep -E '^start=' "$LOCK_INFO_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"
            rmode="$(grep -E '^mode=' "$LOCK_INFO_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)"
            printf '  PID:  %s\n' "${pid:-未知}"
            printf '  开始: %s\n' "${start:-未知}"
            printf '  模式: %s\n' "${rmode:-未知}"
        fi
        printf '  %s请等待当前任务结束。%s\n' "$C_YELLOW" "$C_RESET"
        return "$E_LOCKED"
    fi
    {
        printf 'pid=%s\n' "$$"
        printf 'start=%s\n' "$(now_iso)"
        printf 'mode=%s\n' "$mode"
    } > "$LOCK_INFO_FILE" 2>/dev/null || true
    return 0
}

release_lock() {
    rm -f "$LOCK_INFO_FILE" 2>/dev/null || true
    # FD 关闭后自动释放锁
}

# 锁信息是否对应一个仍然存活的任务
lock_is_active() {
    [[ -f "$LOCK_INFO_FILE" ]] || return 1
    local pid
    pid="$(grep -E '^pid=' "$LOCK_INFO_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    [[ -n "$pid" ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    return 0
}

# =============================================================================
# Config
# =============================================================================

# 全局字段白名单
readonly -a GLOBAL_KEYS=(
    backup_dir onedrive_remote
    local_retention_days remote_retention_days partial_retention_days
    min_local_success_backups min_remote_success_backups
    retry_count retry_delay
    heuristic_mode heuristic_scan_depth heuristic_auto_exclude_score
    onedrive_reserved_space_gb
    hook_timeout_seconds log_retention_days
    cleanup_legacy
)

# 项目字段白名单
readonly -a PROJECT_KEYS=(
    name enabled type source heuristic
    exclude protect
    backup_pre_hook backup_post_hook
    restore_pre_hook restore_post_hook
)

declare -A GLOBAL_DEFAULTS=(
    [backup_dir]="/root/backup/backup"
    [onedrive_remote]="onedrive:backup"
    [local_retention_days]="7"
    [remote_retention_days]="4"
    [partial_retention_days]="2"
    [min_local_success_backups]="2"
    [min_remote_success_backups]="2"
    [retry_count]="3"
    [retry_delay]="10"
    [heuristic_mode]="smart"
    [heuristic_scan_depth]="2"
    [heuristic_auto_exclude_score]="85"
    [onedrive_reserved_space_gb]="2"
    [hook_timeout_seconds]="300"
    [log_retention_days]="30"
    [cleanup_legacy]="false"
)

in_list() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# 判断相对路径 (exclude/protect) 是否合法
is_safe_rel_path() {
    local p="$1"
    [[ -z "$p" ]] && return 1
    # 绝对路径
    [[ "$p" == /* ]] && return 1
    # 路径穿越 / 当前目录 / 父目录
    [[ "$p" == "." || "$p" == ".." ]] && return 1
    [[ "$p" == ../* || "$p" == */../* || "$p" == */.. || "$p" == */../* ]] && return 1
    # 空段
    [[ "$p" == *//* ]] && return 1
    return 0
}

# 解析配置文件到内存; 出错返回非零
parse_config_file() {
    local file="$1"
    GLOBAL=()
    PROJECT_IDS=()
    PROJ=()
    PROJ_EXCLUDE=()
    PROJ_PROTECT=()

    [[ -f "$file" ]] || { cfg_error "配置文件不存在: $file"; return 1; }

    local line section="" lineno=0
    local seen_projects=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno+1))
        line="${line%$'\r'}"            # 去掉 CR
        local t
        t="$(trim "$line")"
        [[ -z "$t" ]] && continue
        if [[ "$t" == \#* || "$t" == \;* ]]; then
            continue
        fi
        if [[ "$t" == \[*\]* ]]; then
            local sec="${t#\[}"
            sec="${sec%%\]*}"
            sec="$(trim "$sec")"
            if [[ "$sec" == "global" ]]; then
                section="global"
            elif [[ "$sec" == project:* ]]; then
                local pid="${sec#project:}"
                if ! is_valid_project_id "$pid"; then
                    cfg_error "第 ${lineno} 行: 非法项目 ID '$pid'"
                    return 1
                fi
                if [[ " $seen_projects " == *" $pid "* ]]; then
                    cfg_error "第 ${lineno} 行: 重复的项目段 [$sec]"
                    return 1
                fi
                seen_projects+=" $pid"
                PROJECT_IDS+=("$pid")
                PROJ["$pid.enabled"]="true"
                PROJ["$pid.heuristic"]="true"
                section="project:$pid"
            else
                cfg_error "第 ${lineno} 行: 未知段名 [$sec]"
                return 1
            fi
            continue
        fi

        if [[ "$line" != *=* ]]; then
            cfg_error "第 ${lineno} 行: 缺少 '=' 分隔符"
            return 1
        fi
        local key="${line%%=*}"
        local value="${line#*=}"
        key="$(trim "$key")"
        value="$(trim "$value")"

        if [[ "$section" == "global" ]]; then
            if ! in_list "$key" "${GLOBAL_KEYS[@]}"; then
                cfg_error "第 ${lineno} 行: 未知全局字段 '$key'"
                return 1
            fi
            if [[ -n "${GLOBAL[$key]+x}" ]]; then
                cfg_error "第 ${lineno} 行: 重复的全局字段 '$key'"
                return 1
            fi
            GLOBAL["$key"]="$value"
        elif [[ "$section" == project:* ]]; then
            local pid="${section#project:}"
            if ! in_list "$key" "${PROJECT_KEYS[@]}"; then
                cfg_error "第 ${lineno} 行 (项目 $pid): 未知字段 '$key'"
                return 1
            fi
            case "$key" in
                exclude)
                    local old="${PROJ_EXCLUDE[$pid]:-}"
                    PROJ_EXCLUDE["$pid"]="${old:+$old$'\n'}$value"
                    ;;
                protect)
                    local oldp="${PROJ_PROTECT[$pid]:-}"
                    PROJ_PROTECT["$pid"]="${oldp:+$oldp$'\n'}$value"
                    ;;
                *)
                    PROJ["$pid.$key"]="$value"
                    ;;
            esac
        else
            cfg_error "第 ${lineno} 行: 字段出现在任何段之前"
            return 1
        fi
    done < "$file"

    return 0
}

# 应用默认值并做类型/范围校验
validate_config_model() {
    local k
    for k in "${GLOBAL_KEYS[@]}"; do
        if [[ -z "${GLOBAL[$k]+x}" ]]; then
            GLOBAL["$k"]="${GLOBAL_DEFAULTS[$k]}"
        fi
    done

    # 必需字段
    if [[ -z "${GLOBAL[backup_dir]:-}" ]]; then
        cfg_error "backup_dir 不能为空"; return 1
    fi
    if [[ "${GLOBAL[backup_dir]}" != /* ]]; then
        cfg_error "backup_dir 必须是绝对路径: ${GLOBAL[backup_dir]}"; return 1
    fi
    if [[ -z "${GLOBAL[onedrive_remote]:-}" ]]; then
        cfg_error "onedrive_remote 不能为空"; return 1
    fi

    # 整数
    validate_int_range "${GLOBAL[local_retention_days]}" 0 3650 local_retention_days || return 1
    validate_int_range "${GLOBAL[remote_retention_days]}" 0 3650 remote_retention_days || return 1
    validate_int_range "${GLOBAL[partial_retention_days]}" 0 3650 partial_retention_days || return 1
    validate_int_range "${GLOBAL[min_local_success_backups]}" 1 1000 min_local_success_backups || return 1
    validate_int_range "${GLOBAL[min_remote_success_backups]}" 1 1000 min_remote_success_backups || return 1
    validate_int_range "${GLOBAL[retry_count]}" 0 10 retry_count || return 1
    validate_int_range "${GLOBAL[retry_delay]}" 1 3600 retry_delay || return 1
    validate_int_range "${GLOBAL[heuristic_scan_depth]}" 1 5 heuristic_scan_depth || return 1
    validate_int_range "${GLOBAL[heuristic_auto_exclude_score]}" 0 100 heuristic_auto_exclude_score || return 1
    validate_int_range "${GLOBAL[hook_timeout_seconds]}" 1 86400 hook_timeout_seconds || return 1
    validate_int_range "${GLOBAL[log_retention_days]}" 1 3650 log_retention_days || return 1

    # 小数
    if ! is_number "${GLOBAL[onedrive_reserved_space_gb]}"; then
        cfg_error "onedrive_reserved_space_gb 必须是数字: '${GLOBAL[onedrive_reserved_space_gb]}'"
        return 1
    fi

    # 枚举
    case "${GLOBAL[heuristic_mode]}" in
        smart|manual|off) ;;
        *) cfg_error "heuristic_mode 只能是 smart/manual/off: '${GLOBAL[heuristic_mode]}'"; return 1 ;;
    esac

    # 布尔
    if ! is_bool "${GLOBAL[cleanup_legacy]}"; then
        cfg_error "cleanup_legacy 必须是 true/false: '${GLOBAL[cleanup_legacy]}'"
        return 1
    fi

    # 项目
    local pid
    for pid in "${PROJECT_IDS[@]}"; do
        local pname="${PROJ[$pid.name]:-}"
        local psrc="${PROJ[$pid.source]:-}"
        local ptype="${PROJ[$pid.type]:-dir}"
        local pen="${PROJ[$pid.enabled]:-true}"
        local pheu="${PROJ[$pid.heuristic]:-true}"

        if [[ -z "$pname" ]]; then
            cfg_error "项目 $pid: name 不能为空"; return 1
        fi
        if [[ -z "$psrc" ]]; then
            cfg_error "项目 $pid: source 不能为空"; return 1
        fi
        if [[ "$psrc" != /* ]]; then
            cfg_error "项目 $pid: source 必须是绝对路径: $psrc"; return 1
        fi
        case "$ptype" in
            dir|file) ;;
            *) cfg_error "项目 $pid: type 只能是 dir/file: '$ptype'"; return 1 ;;
        esac
        if ! is_bool "$pen"; then
            cfg_error "项目 $pid: enabled 必须是 true/false: '$pen'"; return 1
        fi
        if ! is_bool "$pheu"; then
            cfg_error "项目 $pid: heuristic 必须是 true/false: '$pheu'"; return 1
        fi

        # exclude / protect 相对路径校验
        local entry
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            # 允许空格/逗号分隔
            local e
            for e in $entry; do
                e="${e%,}"; e="$(trim "$e")"
                [[ -z "$e" ]] && continue
                if ! is_safe_rel_path "$e"; then
                    cfg_error "项目 $pid: 非法 exclude/protect 路径 '$e' (必须是项目内部相对路径)"
                    return 1
                fi
            done
        done <<< "${PROJ_EXCLUDE[$pid]:-}"
        while IFS= read -r entry; do
            [[ -z "$entry" ]] && continue
            local e
            for e in $entry; do
                e="${e%,}"; e="$(trim "$e")"
                [[ -z "$e" ]] && continue
                if ! is_safe_rel_path "$e"; then
                    cfg_error "项目 $pid: 非法 protect 路径 '$e' (必须是项目内部相对路径)"
                    return 1
                fi
            done
        done <<< "${PROJ_PROTECT[$pid]:-}"
    done
    return 0
}

# 配置权限检查: owner=root, mode=600
check_config_permissions() {
    local file="$1"
    if [[ "$BM_TEST_MODE" == "1" && "${BACKUPCTL_TEST_CHECK_PERMS:-0}" != "1" ]]; then
        return 0
    fi
    [[ -f "$file" ]] || { cfg_error "配置文件不存在: $file"; return 1; }
    local owner mode
    owner="$(stat -c '%U' "$file" 2>/dev/null || echo '?')"
    mode="$(stat -c '%a' "$file" 2>/dev/null || echo '??')"
    if [[ "$owner" != "root" ]]; then
        cfg_error "配置文件属主必须是 root (当前: $owner)"
        return 1
    fi
    if [[ "$mode" != "600" ]]; then
        cfg_error "配置文件权限必须是 600 (当前: $mode)"
        return 1
    fi
    return 0
}

# 加载配置 (含权限检查); 用于 run/check
load_config_strict() {
    if [[ ! -f "$CONF_FILE" ]]; then
        cfg_error "配置文件不存在: $CONF_FILE (请先运行 backupctl 初始化)"
        return "$E_CONFIG"
    fi
    if ! check_config_permissions "$CONF_FILE"; then
        return "$E_CONFIG"
    fi
    if ! parse_config_file "$CONF_FILE"; then
        return "$E_CONFIG"
    fi
    if ! validate_config_model; then
        return "$E_CONFIG"
    fi
    BACKUP_DIR="${GLOBAL[backup_dir]}"
    ONEDRIVE_REMOTE="${GLOBAL[onedrive_remote]}"
    return 0
}

# 加载配置 (宽松, 供只读命令; 权限问题只警告)
load_config_lenient() {
    if [[ ! -f "$CONF_FILE" ]]; then
        return "$E_CONFIG"
    fi
    if ! check_config_permissions "$CONF_FILE"; then
        log_warn "配置文件权限不安全 (应为 root:600)"
    fi
    if ! parse_config_file "$CONF_FILE"; then
        return "$E_CONFIG"
    fi
    if ! validate_config_model; then
        return "$E_CONFIG"
    fi
    BACKUP_DIR="${GLOBAL[backup_dir]}"
    ONEDRIVE_REMOTE="${GLOBAL[onedrive_remote]}"
    return 0
}

# ---------------------------------------------------------------------------
# 配置原子写入
# ---------------------------------------------------------------------------

# 对 tmp 文件执行 mutation, 校验后原子替换, 保留 .bak
apply_config_edit() {
    local mutator="$1"; shift
    if [[ ! -f "$CONF_FILE" ]]; then
        cfg_error "配置文件不存在, 无法修改"
        return "$E_CONFIG"
    fi
    local tmp="$CONF_FILE.tmp.$$"
    register_temp "$tmp"
    cp -p "$CONF_FILE" "$tmp"
    if ! "$mutator" "$tmp" "$@"; then
        rm -f "$tmp"
        return "$E_CONFIG"
    fi
    if ! parse_config_file "$tmp"; then
        rm -f "$tmp"
        cfg_error "修改后配置校验失败, 已放弃修改"
        return "$E_CONFIG"
    fi
    if ! validate_config_model; then
        rm -f "$tmp"
        cfg_error "修改后配置校验失败, 已放弃修改"
        return "$E_CONFIG"
    fi
    chmod 600 "$tmp"
    if [[ "$BM_TEST_MODE" != "1" ]]; then chown root:root "$tmp" 2>/dev/null || true; fi
    cp -p "$CONF_FILE" "$CONF_BAK"
    mv -f "$tmp" "$CONF_FILE"
    return 0
}

# awk 在指定段内设置 key=value (不存在则插入段尾)
_awk_set_in_section() {
    local file="$1" sect="$2" key="$3" val="$4"
    local want="[$sect]"
    local tmp="$file.awktmp"
    awk -v want="$want" -v k="$key" -v v="$val" '
        BEGIN { insec=0; done=0 }
        {
            line=$0
            if (line ~ /^[[:space:]]*\[/) {
                if (insec && !done) { print k "=" v; done=1 }
                insec = (line == want)
            }
            if (insec && !done) {
                pos = index(line, "=")
                if (pos > 0) {
                    kk = substr(line, 1, pos-1)
                    gsub(/^[ \t]+|[ \t]+$/, "", kk)
                    if (kk == k) { print k "=" v; done=1; next }
                }
            }
            print line
        }
        END { if (insec && !done) print k "=" v }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

mut_set_global() {
    local file="$1" key="$2" val="$3"
    _awk_set_in_section "$file" "global" "$key" "$val"
}

mut_set_project() {
    local file="$1" id="$2" key="$3" val="$4"
    _awk_set_in_section "$file" "project:$id" "$key" "$val"
}

mut_project_block() {
    local file="$1" id="$2" name="$3" src="$4" type="$5" heuristic="$6"
    {
        printf '\n[project:%s]\n' "$id"
        printf 'name=%s\n' "$name"
        printf 'enabled=true\n'
        printf 'type=%s\n' "$type"
        printf 'source=%s\n' "$src"
        printf '\n'
        printf 'heuristic=%s\n' "$heuristic"
        printf '\n'
        printf 'backup_pre_hook=\n'
        printf 'backup_post_hook=\n'
        printf '\n'
        printf 'restore_pre_hook=\n'
        printf 'restore_post_hook=\n'
    } >> "$file"
}

mut_remove_project() {
    local file="$1" id="$2"
    local want="[project:$id]"
    local tmp="$file.rmtmp"
    awk -v want="$want" '
        /^[[:space:]]*\[/ { inblock = ($0 == want) }
        { if (!inblock) print }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# 确保 project id 不存在重复
config_project_exists() {
    local id="$1"
    in_list "$id" "${PROJECT_IDS[@]:-}"
}

# 生成默认配置模板
generate_default_config() {
    local target="$1"
    cat > "$target" <<'EOF'
# Backup Manager 配置文件
# 安全 INI 格式; 禁止 shell 语法。
# 权限必须为 root:600。
#
# 每个 [project:ID] 段定义一个备份项目;
# ID 只能用小写字母/数字/._-, 中文请写在 name=。

[global]

backup_dir=/root/backup/backup
onedrive_remote=onedrive:backup

local_retention_days=7
remote_retention_days=4
partial_retention_days=2

min_local_success_backups=2
min_remote_success_backups=2

retry_count=3
retry_delay=10

heuristic_mode=smart
heuristic_scan_depth=2
heuristic_auto_exclude_score=85

onedrive_reserved_space_gb=2

hook_timeout_seconds=300
log_retention_days=30

# 是否清理旧版扁平日期目录 (升级前遗留的备份):
# true = 过期后按保留策略自动清理; false = 永久保留。
cleanup_legacy=false


# 示例项目: 请按需修改或删除。
[project:example-app]

name=Example App
enabled=true
type=dir
source=/opt/example-app

heuristic=true

# 始终排除的相对路径 (空格或逗号分隔, 可多行)
exclude=

# 永不自动排除的相对路径
protect=

backup_pre_hook=
backup_post_hook=

restore_pre_hook=
restore_post_hook=
EOF
}

# =============================================================================
# State
# =============================================================================

# 从 last-*.conf 读取值
state_get() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || { echo ""; return 0; }
    grep -E "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# 写入 last-run.conf (原子)
state_write_last_run() {
    local status="$1" exit_code="$2" duration="$3" local_size="$4" remote_size="$5" \
          cleanup_status="$6" capacity="$7"
    mkdir -p "$STATE_DIR"
    local auto_ex=""
    local id
    for id in "${ACTIVE_IDS[@]:-}"; do
        if [[ -n "${RUN_PROJECT_AUTOEX[$id]:-}" ]]; then
            local rel
            while IFS= read -r rel; do
                [[ -z "$rel" ]] && continue
                auto_ex+="${id}:${rel}"$'\n'
            done <<< "${RUN_PROJECT_AUTOEX[$id]}"
        fi
    done
    {
        printf 'run_id=%s\n' "$CURRENT_RUN_ID"
        printf 'start=%s\n' "${RUN_START_ISO:-}"
        printf 'end=%s\n' "$(now_iso)"
        printf 'duration_seconds=%s\n' "$duration"
        printf 'mode=%s\n' "$CURRENT_MODE"
        printf 'status=%s\n' "$status"
        printf 'exit_code=%s\n' "$exit_code"
        printf 'success_projects=%s\n' "$(run_success_list)"
        printf 'failed_projects=%s\n' "$(run_failed_list)"
        printf 'warnings=%s\n' "$RUN_WARNINGS"
        printf 'local_size_bytes=%s\n' "$local_size"
        printf 'remote_upload_bytes=%s\n' "$remote_size"
        printf 'remote_capacity=%s\n' "$capacity"
        printf 'cleanup_status=%s\n' "$cleanup_status"
        printf 'auto_excluded=%s\n' "$(printf '%s' "$auto_ex" | tr '\n' '|')"
    } | atomic_write "$STATE_LAST_RUN"
}

state_write_last_success() {
    mkdir -p "$STATE_DIR"
    local id
    {
        printf 'run_id=%s\n' "$CURRENT_RUN_ID"
        printf 'time=%s\n' "$(now_iso)"
        printf 'success_projects=%s\n' "$(run_success_list)"
        printf 'local_size_bytes=%s\n' "${RUN_LOCAL_SIZE:-0}"
        printf 'remote_upload_bytes=%s\n' "${RUN_REMOTE_SIZE:-0}"
    } | atomic_write "$STATE_LAST_SUCCESS"
}

run_success_list() {
    local out="" id
    for id in "${ACTIVE_IDS[@]:-}"; do
        [[ "${RUN_PROJECT_STATUS[$id]:-}" == "ok" ]] && out+="${id} "
    done
    printf '%s' "$(trim "$out")"
}

run_failed_list() {
    local out="" id
    for id in "${ACTIVE_IDS[@]:-}"; do
        case "${RUN_PROJECT_STATUS[$id]:-}" in
            failed|skipped) out+="${id} " ;;
        esac
    done
    printf '%s' "$(trim "$out")"
}

# 启发式历史状态: 格式 entry.<project>.<path>.<field>=value
heur_state_get() {
    local project="$1" rel="$2" field="$3"
    local key="entry.${project}.${rel// /_}.${field}"
    state_get "$STATE_HEURISTICS" "$key"
}

heur_state_set_record() {
    # $1=project $2=rel $3=size $4=score $5=status $6=count
    local project="$1" rel="$2" size="$3" score="$4" status="$5" count="$6"
    mkdir -p "$STATE_DIR"
    local f="$STATE_HEURISTICS"
    [[ -f "$f" ]] || : > "$f"
    local safe_rel="${rel// /_}"
    local key="entry.${project}.${safe_rel}"
    local tmp="$f.tmp.$$"
    grep -v -E "^${key//./\\.}\." "$f" > "$tmp" 2>/dev/null || : > "$tmp"
    local now
    now="$(now_iso)"
    local first
    first="$(state_get "$f" "${key}.first_seen")"
    [[ -z "$first" ]] && first="$now"
    {
        cat "$tmp"
        printf '%s.first_seen=%s\n' "$key" "$first"
        printf '%s.last_seen=%s\n' "$key" "$now"
        printf '%s.size_bytes=%s\n' "$key" "$size"
        printf '%s.score=%s\n' "$key" "$score"
        printf '%s.auto_exclude_count=%s\n' "$key" "$count"
        printf '%s.status=%s\n' "$key" "$status"
    } | atomic_write "$f"
    rm -f "$tmp" 2>/dev/null || true
}

# =============================================================================
# 初始化
# =============================================================================

ensure_dirs() {
    mkdir -p "$BM_ROOT" "$LOG_DIR" "$STATE_DIR" "$CACHE_DIR" "$RESTORE_HISTORY_DIR"
}

# 日志文件与清理
log_setup_run() {
    mkdir -p "$LOG_DIR"
    local ts="$CURRENT_RUN_ID"
    LOG_FILE="$LOG_DIR/backup-${ts}.log"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
    log_prune
}

log_prune() {
    local days="${GLOBAL[log_retention_days]:-30}"
    [[ -d "$LOG_DIR" ]] || return 0
    find "$LOG_DIR" -maxdepth 1 -type f -name 'backup-*.log' -mtime "+${days}" -delete 2>/dev/null || true
}

cmd_init() {
    ensure_dirs
    if [[ -f "$CONF_FILE" ]]; then
        log_warn "配置已存在, 不覆盖: $CONF_FILE"
    else
        local tmp="$CONF_FILE.tmp.$$"
        generate_default_config "$tmp"
        if ! parse_config_file "$tmp" || ! validate_config_model; then
            rm -f "$tmp"
            fail "生成的默认配置校验失败 (内部错误)"
            return "$E_CONFIG"
        fi
        chmod 600 "$tmp"
        if [[ "$BM_TEST_MODE" != "1" ]]; then chown root:root "$tmp" 2>/dev/null || true; fi
        mv -f "$tmp" "$CONF_FILE"
        log_ok "已创建配置: $CONF_FILE (mode 600)"
    fi

    # 全局命令
    if [[ "$BM_TEST_MODE" != "1" ]]; then
        if [[ ! -e "$BACKUPCTL_PATH" ]]; then
            ln -sf "$SELF_SCRIPT" "$BACKUPCTL_PATH" && log_ok "已创建命令: $BACKUPCTL_PATH"
        fi
    fi
    log_ok "初始化完成。请运行 'backupctl check' 验证。"
    return 0
}

# =============================================================================
# 项目辅助
# =============================================================================

project_get() { local id="$1" f="$2"; printf '%s' "${PROJ[$id.$f]:-}"; }

# 输出归一化后的 exclude/protect 列表 (每行一个)
project_list() {
    local id="$1" which="$2"
    local raw
    if [[ "$which" == "exclude" ]]; then raw="${PROJ_EXCLUDE[$id]:-}"; else raw="${PROJ_PROTECT[$id]:-}"; fi
    [[ -z "$raw" ]] && return 0
    local line e
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        for e in $line; do
            e="${e%,}"; e="$(trim "$e")"
            [[ -z "$e" ]] && continue
            printf '%s\n' "$e"
        done
    done <<< "$raw"
}

# 检查相对路径是否命中 protect (等于或父目录在 protect 中)
path_is_protected() {
    local id="$1" rel="$2"
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if [[ "$rel" == "$p" || "$rel" == "$p"/* ]]; then
            return 0
        fi
    done < <(project_list "$id" "protect")
    return 1
}

# =============================================================================
# Hooks
# =============================================================================

run_hook() {
    # $1 = phase (backup_pre/backup_post/restore_pre/restore_post)
    # $2 = command string
    local phase="$1" cmd="$2"
    if [[ -z "$(trim "$cmd")" ]]; then
        return 0
    fi
    local timeout_s="${GLOBAL[hook_timeout_seconds]:-300}"
    local work="${CURRENT_WORK_DIR:-$CACHE_DIR}"
    log_info "执行 ${phase} hook"
    local rc=0
    set +e
    BACKUP_PROJECT_ID="$CURRENT_PROJECT_ID" \
    BACKUP_PROJECT_NAME="${CURRENT_PROJECT_NAME:-}" \
    BACKUP_SOURCE="${CURRENT_PROJECT_SOURCE:-}" \
    BACKUP_RUN_ID="$CURRENT_RUN_ID" \
    BACKUP_WORK_DIR="$work" \
    BACKUP_PHASE="$phase" \
        timeout "$timeout_s" bash -o pipefail -c "$cmd"
    rc=$?
    set -e
    if (( rc == 0 )); then
        log_ok "${phase} hook 完成"
    elif (( rc == 124 )); then
        log_error "${phase} hook 超时 (${timeout_s}s)"
    else
        log_error "${phase} hook 失败 (exit=$rc)"
    fi
    return "$rc"
}

# =============================================================================
# Heuristics
# =============================================================================

declare -A HEUR_SCORE=() HEUR_SIZE=() HEUR_PROT=() HEUR_EST=() HEUR_LEVEL=()
declare -a HEUR_CANDIDATES=()
EST_PROJECT_BYTES=0

readonly -a STRONG_NAME_TOKENS=(download downloads dl cache tmp temp runtime output outputs session sessions)
readonly -a WEAK_NAME_TOKENS=(media video videos files storage)

readonly -a MEDIA_EXTS=(mp4 mkv webm mov avi ts m4v mpg mpeg mp3 flac wav aac ogg jpg jpeg png webp gif bmp)
readonly -a COMPRESSED_EXTS=(zip rar 7z gz xz bz2 iso tgz)
readonly -a TEMP_EXTS=(tmp part cache download crdownload partial)
readonly -a SRC_EXTS=(py js ts tsx jsx go rs c cpp h hpp java rb php sh bash lua)
readonly -a CFG_EXTS=(yaml yml json toml conf ini env)

_ext_in() { local e="$1"; shift; in_list "$e" "$@"; }

# 目录大小 -> 字节 (du -x)
dir_size_bytes() {
    local d="$1"
    local kb
    kb="$(du -xsk "$d" 2>/dev/null | awk 'NR==1{print $1}')"
    [[ -z "$kb" ]] && kb=0
    printf '%s' "$(( kb * 1024 ))"
}

# 区间评分 (取最高档)
heur_size_score() {
    local b="$1"
    if (( b > 10*1024*1024*1024 )); then echo 25
    elif (( b > 5*1024*1024*1024 )); then echo 20
    elif (( b > 3*1024*1024*1024 )); then echo 15
    elif (( b > 1024*1024*1024 )); then echo 10
    elif (( b > 500*1024*1024 )); then echo 5
    else echo 0; fi
}

heur_ratio_score() {
    local pct="$1"
    if (( pct > 90 )); then echo 25
    elif (( pct > 75 )); then echo 20
    elif (( pct > 60 )); then echo 10
    elif (( pct > 40 )); then echo 5
    else echo 0; fi
}

# 名称评分 (只做 token 匹配, 永不单独触发排除)
heur_name_score() {
    local name="$1"
    name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
    # 拆分为 token
    local tokens
    tokens="$(printf '%s' "$name" | tr -c 'a-z0-9' ' ')"
    local tok
    for tok in $tokens; do
        if in_list "$tok" "${STRONG_NAME_TOKENS[@]}"; then echo 15; return; fi
    done
    for tok in $tokens; do
        if in_list "$tok" "${WEAK_NAME_TOKENS[@]}"; then echo 5; return; fi
    done
    echo 0
}

# 采样目录: 最多 200 个普通文件; 结果写入全局
SAMPLE_TOTAL=0 SAMPLE_MEDIA=0 SAMPLE_COMPRESSED=0 SAMPLE_TEMP=0 SAMPLE_SRC=0 SAMPLE_CFG=0
SAMPLE_AVG=0 SAMPLE_MAX=0
heur_sample_dir() {
    local dir="$1"
    SAMPLE_TOTAL=0 SAMPLE_MEDIA=0 SAMPLE_COMPRESSED=0 SAMPLE_TEMP=0 SAMPLE_SRC=0 SAMPLE_CFG=0
    SAMPLE_AVG=0 SAMPLE_MAX=0
    local sample
    sample="$(find "$dir" -xdev -type f -printf '%s %f\n' 2>/dev/null | head -n 200 || true)"
    [[ -z "$sample" ]] && return 0
    local line sz fn ext
    while IFS=' ' read -r sz fn; do
        [[ -z "$fn" ]] && continue
        ext="${fn##*.}"
        ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
        if [[ "$ext" == "$fn" ]]; then ext=""; fi
        SAMPLE_TOTAL=$((SAMPLE_TOTAL+1))
        SAMPLE_MAX=$(( sz > SAMPLE_MAX ? sz : SAMPLE_MAX ))
        if [[ -n "$ext" ]] && in_list "$ext" "${MEDIA_EXTS[@]}"; then SAMPLE_MEDIA=$((SAMPLE_MEDIA+1));
        elif [[ -n "$ext" ]] && in_list "$ext" "${COMPRESSED_EXTS[@]}"; then SAMPLE_COMPRESSED=$((SAMPLE_COMPRESSED+1));
        elif [[ -n "$ext" ]] && in_list "$ext" "${TEMP_EXTS[@]}"; then SAMPLE_TEMP=$((SAMPLE_TEMP+1));
        elif [[ -n "$ext" ]] && in_list "$ext" "${SRC_EXTS[@]}"; then SAMPLE_SRC=$((SAMPLE_SRC+1));
        elif [[ -n "$ext" ]] && in_list "$ext" "${CFG_EXTS[@]}"; then SAMPLE_CFG=$((SAMPLE_CFG+1));
        fi
    done <<< "$sample"
    if (( SAMPLE_TOTAL > 0 )); then
        local total=0
        while IFS=' ' read -r sz _fn; do total=$((total+sz)); done <<< "$sample"
        SAMPLE_AVG=$(( total / SAMPLE_TOTAL ))
    fi
    return 0
}

# 硬保护扫描: 命中则返回 0 并打印原因
heur_hard_protect() {
    local id="$1" rel="$2" dir="$3"
    # 用户 protect
    if path_is_protected "$id" "$rel"; then
        printf 'protect 配置: %s' "$rel"; return 0
    fi
    local p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        # protect 在候选内部
        if [[ "$p" == "$rel"/* ]]; then
            printf 'protect 配置: %s' "$p"; return 0
        fi
    done < <(project_list "$id" "protect")

    local hit=""
    local -a names=()
    local pat
    for pat in '*.db' '*.sqlite' '*.sqlite3' '*.sql' '*.dump' '*.bson' '*.key' '*.pem' '*.p12' '*.pfx' '.env' '.env.*'; do
        names+=(-name "$pat")
        # 组合成 -o
    done
    # 构造 find 表达式: ( -name a -o -name b ... )
    local -a expr=()
    local first=1
    for pat in '*.db' '*.sqlite' '*.sqlite3' '*.sql' '*.dump' '*.bson' '*.key' '*.pem' '*.p12' '*.pfx' '.env' '.env.*'; do
        if (( first )); then expr+=(-name "$pat"); first=0; else expr+=(-o -name "$pat"); fi
    done
    hit="$(find "$dir" -xdev -type f \( "${expr[@]}" \) -print -quit 2>/dev/null || true)"
    if [[ -n "$hit" ]]; then
        printf '发现受保护文件: %s' "${hit#"$dir"/}"
        return 0
    fi
    return 1
}

# 对候选目录评分 (综合名称/大小/占比/采样)
heur_score_candidate() {
    local id="$1" rel="$2" dir="$3" csize="$4" raw_size="$5"
    local score=0
    local s nscore
    s="$(heur_size_score "$csize")"; score=$((score+s))
    local pct=0
    if (( raw_size > 0 )); then pct=$(( csize * 100 / raw_size )); fi
    s="$(heur_ratio_score "$pct")"; score=$((score+s))
    nscore="$(heur_name_score "$rel")"; score=$((score+nscore))
    # 采样 (仅对可疑候选: 名称有分 或 大小>=1GB 或 占比>=40%)
    if (( nscore > 0 )) || (( csize >= 1024*1024*1024 )) || (( pct >= 40 )); then
        heur_sample_dir "$dir"
        if (( SAMPLE_TOTAL > 0 )); then
            local mratio=0
            mratio=$(( SAMPLE_MEDIA * 100 / SAMPLE_TOTAL ))
            local cratio=0; cratio=$(( SAMPLE_COMPRESSED * 100 / SAMPLE_TOTAL ))
            local tratio=0; tratio=$(( SAMPLE_TEMP * 100 / SAMPLE_TOTAL ))
            local sratio=0; sratio=$(( SAMPLE_SRC * 100 / SAMPLE_TOTAL ))
            local gratio=0; gratio=$(( SAMPLE_CFG * 100 / SAMPLE_TOTAL ))
            if (( mratio > 90 )); then score=$((score+25)); elif (( mratio > 70 )); then score=$((score+10)); fi
            if (( SAMPLE_AVG > 100*1024*1024 )); then score=$((score+10)); fi
            if (( SAMPLE_MAX > 1024*1024*1024 )); then score=$((score+5)); fi
            if (( cratio > 80 )); then score=$((score+15)); fi
            if (( tratio > 50 )); then score=$((score+10)); fi
            if (( sratio > 30 )); then score=$((score-20)); fi
            if (( gratio > 30 )); then score=$((score-15)); fi
            # 估算 targz 大小
            local factor=60
            if (( mratio > 70 )); then factor=97
            elif (( cratio > 70 )); then factor=99
            elif (( sratio > 30 )); then factor=35
            fi
            HEUR_EST["$rel"]=$(( csize * factor / 100 ))
        fi
    fi
    (( score > 100 )) && score=100
    (( score < 0 )) && score=0
    HEUR_SCORE["$rel"]=$score
    HEUR_SIZE["$rel"]=$csize
    [[ -z "${HEUR_EST[$rel]:-}" ]] && HEUR_EST["$rel"]=$(( csize * 70 / 100 ))
}

heur_level() {
    local score="$1"
    if (( score >= 85 )); then echo "HIGH"
    elif (( score >= 70 )); then echo "SUGGEST"
    elif (( score >= 50 )); then echo "SUSPICIOUS"
    else echo "NORMAL"; fi
}

# 扫描一个项目, 填充 HEUR_* 数组
heur_scan_project() {
    local id="$1"
    HEUR_SCORE=() HEUR_SIZE=() HEUR_PROT=() HEUR_EST=() HEUR_LEVEL=()
    HEUR_CANDIDATES=()
    EST_PROJECT_BYTES=0

    local src; src="$(project_get "$id" source)"
    [[ -d "$src" ]] || return 1

    local raw_size; raw_size="$(dir_size_bytes "$src")"
    local depth="${GLOBAL[heuristic_scan_depth]:-2}"

    # 项目整体采样 (决定估算系数)
    heur_sample_dir "$src"
    local pfactor=60
    if (( SAMPLE_TOTAL > 0 )); then
        local mratio=$(( SAMPLE_MEDIA * 100 / SAMPLE_TOTAL ))
        local cratio=$(( SAMPLE_COMPRESSED * 100 / SAMPLE_TOTAL ))
        local sratio=$(( SAMPLE_SRC * 100 / SAMPLE_TOTAL ))
        if (( mratio > 70 )); then pfactor=97
        elif (( cratio > 70 )); then pfactor=99
        elif (( sratio > 30 )); then pfactor=35
        fi
    fi
    EST_PROJECT_BYTES=$(( raw_size * pfactor / 100 ))

    local -a level1=()
    local d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        level1+=("$d")
    done < <(find "$src" -mindepth 1 -maxdepth 1 -type d -xdev -printf '%f\n' 2>/dev/null || true)

    local rel csize
    for rel in "${level1[@]}"; do
        [[ -z "$rel" ]] && continue
        csize="$(dir_size_bytes "$src/$rel")"
        heur_score_candidate "$id" "$rel" "$src/$rel" "$csize" "$raw_size"
        HEUR_CANDIDATES+=("$rel")
        if heur_hard_protect "$id" "$rel" "$src/$rel" >/tmp/.heur_prot.$$ 2>/dev/null; then
            HEUR_PROT["$rel"]="$(cat /tmp/.heur_prot.$$ 2>/dev/null)"
        else
            HEUR_PROT["$rel"]=""
        fi
        rm -f /tmp/.heur_prot.$$ 2>/dev/null || true
        HEUR_LEVEL["$rel"]="$(heur_level "${HEUR_SCORE[$rel]}")"

        # depth 2: 仅当一级候选确实很大/占比高
        if (( depth >= 2 )) && { (( csize >= 500*1024*1024 )) || (( raw_size > 0 && csize * 100 / raw_size > 40 )); }; then
            local sub
            while IFS= read -r sub; do
                [[ -z "$sub" ]] && continue
                local srel="$rel/$sub"
                local ssize
                ssize="$(dir_size_bytes "$src/$srel")"
                heur_score_candidate "$id" "$srel" "$src/$srel" "$ssize" "$raw_size"
                HEUR_CANDIDATES+=("$srel")
                if heur_hard_protect "$id" "$srel" "$src/$srel" >/tmp/.heur_prot.$$ 2>/dev/null; then
                    HEUR_PROT["$srel"]="$(cat /tmp/.heur_prot.$$ 2>/dev/null)"
                else
                    HEUR_PROT["$srel"]=""
                fi
                rm -f /tmp/.heur_prot.$$ 2>/dev/null || true
                HEUR_LEVEL["$srel"]="$(heur_level "${HEUR_SCORE[$srel]}")"
            done < <(find "$src/$rel" -mindepth 1 -maxdepth 1 -type d -xdev -printf '%f\n' 2>/dev/null || true)
        fi
    done
    return 0
}

# =============================================================================
# OneDrive / rclone
# =============================================================================

REMOTE_TOTAL=-1 REMOTE_USED=-1 REMOTE_FREE=-1
REMOTE_ABOUT_OK=0

rclone_available() { command -v rclone >/dev/null 2>&1; }

_rclone_root() { local r="$1"; printf '%s:' "${r%%:*}"; }

# 刷新远端容量
remote_about() {
    local remote="${1:-$ONEDRIVE_REMOTE}"
    REMOTE_TOTAL=-1 REMOTE_USED=-1 REMOTE_FREE=-1 REMOTE_ABOUT_OK=0
    if ! rclone_available; then
        log_warn "rclone 不可用"
        return 1
    fi
    local root; root="$(_rclone_root "$remote")"
    local json=""
    json="$(rclone about "$remote" --json 2>/dev/null || true)"
    if [[ -z "$json" ]]; then
        json="$(rclone about "$root" --json 2>/dev/null || true)"
    fi
    if [[ -n "$json" ]]; then
        local t u f
        t="$(printf '%s' "$json" | grep -oE '"total":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
        u="$(printf '%s' "$json" | grep -oE '"used":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
        f="$(printf '%s' "$json" | grep -oE '"free":[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1 || true)"
        [[ -n "$t" ]] && REMOTE_TOTAL="$t"
        [[ -n "$u" ]] && REMOTE_USED="$u"
        [[ -n "$f" ]] && REMOTE_FREE="$f"
        if (( REMOTE_FREE < 0 && REMOTE_TOTAL >= 0 && REMOTE_USED >= 0 )); then
            REMOTE_FREE=$(( REMOTE_TOTAL - REMOTE_USED ))
        fi
    fi
    if (( REMOTE_TOTAL < 0 && REMOTE_FREE < 0 )); then
        local txt=""
        txt="$(rclone about "$root" 2>/dev/null || true)"
        if [[ -n "$txt" ]]; then
            local val
            val="$(printf '%s\n' "$txt" | grep -iE '^[[:space:]]*Total:' | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' || true)"
            [[ -n "$val" ]] && REMOTE_TOTAL="$(human_to_bytes "$val")"
            val="$(printf '%s\n' "$txt" | grep -iE '^[[:space:]]*Used:' | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' || true)"
            [[ -n "$val" ]] && REMOTE_USED="$(human_to_bytes "$val")"
            val="$(printf '%s\n' "$txt" | grep -iE '^[[:space:]]*Free:' | head -1 | sed -E 's/^[^:]*:[[:space:]]*//' || true)"
            [[ -n "$val" ]] && REMOTE_FREE="$(human_to_bytes "$val")"
        fi
    fi
    if (( REMOTE_FREE >= 0 || REMOTE_TOTAL >= 0 )); then
        REMOTE_ABOUT_OK=1
        return 0
    fi
    return 1
}

# 安全可用空间 = free - reserved
remote_safe_free() {
    local reserved_gb="${GLOBAL[onedrive_reserved_space_gb]:-2}"
    local reserved; reserved="$(human_to_bytes "${reserved_gb}GiB")"
    local free="$REMOTE_FREE"
    (( free < 0 )) && { echo 0; return; }
    local s=$(( free - reserved ))
    (( s < 0 )) && s=0
    echo "$s"
}

remote_run_path() {
    local date="$1" run="$2"
    printf '%s/%s/%s' "$ONEDRIVE_REMOTE" "$date" "$run"
}

# 上传整个 RUN 目录; 返回 0 成功
remote_upload_run() {
    local run_dir="$1" date="$2" run_id="$3"
    local rpath; rpath="$(remote_run_path "$date" "$run_id")"
    local attempt=1 max=$(( ${GLOBAL[retry_count]:-3} )) delay="${GLOBAL[retry_delay]:-10}"
    while :; do
        log_info "上传到 OneDrive: $rpath (尝试 $attempt/$max)"
        if rclone copy "$run_dir" "$rpath" --retries 2 --low-level-retries 5 --log-level ERROR; then
            log_ok "上传完成"
            return 0
        fi
        if (( attempt >= max )); then
            log_error "上传失败 (已达最大重试)"
            return "$E_REMOTE_UPLOAD"
        fi
        local sleep_s=$(( delay * (2 ** (attempt-1)) ))
        (( sleep_s > 300 )) && sleep_s=300
        log_warn "上传失败, ${sleep_s}s 后重试"
        sleep "$sleep_s"
        attempt=$((attempt+1))
    done
}

# 远端校验 (rclone check --one-way)
remote_verify_run() {
    local run_dir="$1" date="$2" run_id="$3"
    local rpath; rpath="$(remote_run_path "$date" "$run_id")"
    log_info "校验远端文件: $rpath"
    local out rc=0
    set +e
    out="$(rclone check "$run_dir" "$rpath" --one-way 2>&1)"
    rc=$?
    set -e
    if (( rc == 0 )); then
        log_ok "远端校验通过 (hash/size)"
        return 0
    fi
    # 退化: 明确记录验证级别
    log_warn "rclone check 未通过 (exit=$rc): $out"
    # 尝试 size-only 校验
    set +e
    out="$(rclone check "$run_dir" "$rpath" --one-way --size-only 2>&1)"
    rc=$?
    set -e
    if (( rc == 0 )); then
        log_warn "远端校验降级为 size-only 通过"
        return 0
    fi
    log_error "远端校验失败 (size-only 也失败): $out"
    return "$E_VERIFY"
}

# 写入 marker (RUN_COMPLETE / RUN_PARTIAL)
remote_write_marker() {
    local run_dir="$1" date="$2" run_id="$3" marker="$4"
    local rpath; rpath="$(remote_run_path "$date" "$run_id")"
    local local_marker="$run_dir/$marker"
    {
        printf 'run_id=%s\n' "$run_id"
        printf 'status=%s\n' "$marker"
        printf 'time=%s\n' "$(now_iso)"
        printf 'version=%s\n' "$BACKUP_MANAGER_VERSION"
    } > "$local_marker"
    local attempt=1 max=$(( ${GLOBAL[retry_count]:-3} )) delay="${GLOBAL[retry_delay]:-10}"
    while :; do
        if rclone copyto "$local_marker" "$rpath/$marker" --log-level ERROR; then
            log_ok "已写入远端标记: $marker"
            return 0
        fi
        if (( attempt >= max )); then
            log_error "写入远端标记失败: $marker"
            return "$E_REMOTE_UPLOAD"
        fi
        local sleep_s=$(( delay * attempt ))
        log_warn "写入标记失败, ${sleep_s}s 后重试"
        sleep "$sleep_s"
        attempt=$((attempt+1))
    done
}

# 列出远端日期目录 (仅合法 YYYY-MM-DD)
remote_list_dates() {
    rclone lsf "$ONEDRIVE_REMOTE/" --dirs-only 2>/dev/null | sed 's:/$::' | while IFS= read -r d; do
        is_valid_date_dir "$d" && printf '%s\n' "$d"
    done
}

# 列出某日期下的 run 目录 (合法 RUN_ID)
remote_list_runs() {
    local date="$1"
    rclone lsf "$ONEDRIVE_REMOTE/$date/" --dirs-only 2>/dev/null | sed 's:/$::' | while IFS= read -r r; do
        is_valid_run_id "$r" && printf '%s\n' "$r"
    done
}

# 判断远端某个日期目录是否为 legacy (直接包含 .tar.gz 文件)
remote_is_legacy_date() {
    local date="$1"
    local f
    f="$(rclone lsf "$ONEDRIVE_REMOTE/$date/" --files-only 2>/dev/null | grep -E '\.(tar\.gz|sh)$' | head -1 || true)"
    [[ -n "$f" ]]
}

remote_run_has_marker() {
    local date="$1" run="$2" marker="$3"
    rclone lsf "$ONEDRIVE_REMOTE/$date/$run/$marker" --files-only 2>/dev/null | grep -q . || return 1
}

# 统计远端成功快照数量 (RUN_COMPLETE)
remote_count_success() {
    local count=0 date run
    while IFS= read -r date; do
        [[ -z "$date" ]] && continue
        while IFS= read -r run; do
            [[ -z "$run" ]] && continue
            if remote_run_has_marker "$date" "$run" "RUN_COMPLETE"; then
                count=$((count+1))
            fi
        done < <(remote_list_runs "$date")
    done < <(remote_list_dates)
    echo "$count"
}

remote_purge_run() {
    local date="$1" run="$2"
    log_warn "删除远端快照: $ONEDRIVE_REMOTE/$date/$run"
    rclone purge "$ONEDRIVE_REMOTE/$date/$run" 2>/dev/null || {
        log_error "删除失败: $date/$run"
        return 1
    }
    # 若日期目录为空则一并删除
    local remain
    remain="$(rclone lsf "$ONEDRIVE_REMOTE/$date/" 2>/dev/null | head -1 || true)"
    if [[ -z "$remain" ]]; then
        rclone rmdir "$ONEDRIVE_REMOTE/$date/" 2>/dev/null || true
    fi
    return 0
}

# 删除一个 legacy 日期目录 (整目录)
remote_purge_legacy_date() {
    local date="$1"
    log_warn "删除远端 legacy 备份: $ONEDRIVE_REMOTE/$date"
    rclone purge "$ONEDRIVE_REMOTE/$date" 2>/dev/null || {
        log_error "删除失败: $date"
        return 1
    }
    return 0
}

# 统计远端快照单元数 (有内容的日期目录, legacy 或新格式都算 1)
remote_snapshot_units() {
    local n=0 date
    while IFS= read -r date; do
        [[ -z "$date" ]] && continue
        if [[ -n "$(rclone lsf "$ONEDRIVE_REMOTE/$date/" 2>/dev/null | head -1 || true)" ]]; then
            n=$((n+1))
        fi
    done < <(remote_list_dates)
    echo "$n"
}

# 列出过期的 legacy 日期目录 (从旧到新)
remote_expired_legacy_dates() {
    local cutoff="$1" date
    while IFS= read -r date; do
        [[ -z "$date" ]] && continue
        remote_is_legacy_date "$date" || continue
        [[ "$date" < "$cutoff" ]] && printf '%s\n' "$date"
    done < <(remote_list_dates) | sort
}

# =============================================================================
# Retention
# =============================================================================

path_age_days() {
    local p="$1"
    local mtime now
    mtime="$(stat -c '%Y' "$p" 2>/dev/null || echo 0)"
    now="$(now_epoch)"
    echo $(( (now - mtime) / 86400 ))
}

# 本地 run 目录是否为成功快照 (有 RUN_COMPLETE 与 manifest)
local_run_is_complete() {
    local d="$1"
    [[ -f "$d/RUN_COMPLETE" && -f "$d/manifest.conf" ]]
}

# 列出本地 run 目录: 输出 "date run path" 按时间倒序
local_list_runs() {
    local base="${BACKUP_DIR:-}"
    [[ -d "$base" ]] || return 0
    local datedir run
    while IFS= read -r datedir; do
        [[ -z "$datedir" ]] && continue
        local dname; dname="$(basename "$datedir")"
        is_valid_date_dir "$dname" || continue
        while IFS= read -r run; do
            [[ -z "$run" ]] && continue
            local rname; rname="$(basename "$run")"
            is_valid_run_id "$rname" || continue
            printf '%s %s %s\n' "$dname" "$rname" "$run"
        done < <(find "$datedir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
    done < <(find "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true) | sort -r
}

# 本地 cleanup (仅完整成功后调用)
retention_local_cleanup() {
    local days="${GLOBAL[local_retention_days]:-7}"
    local min="${GLOBAL[min_local_success_backups]:-2}"
    local cleanup_status="OK"
    local base="${BACKUP_DIR:-}"
    if [[ ! -d "$base" ]]; then
        echo "NO_LOCAL_DIR"; return 0
    fi

    # 收集成功快照 (按时间倒序)
    local -a succ=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local path="${line##* }"
        if local_run_is_complete "$path"; then
            succ+=("$path")
        fi
    done < <(local_list_runs)

    local i=0
    local -a delete_list=()
    for p in "${succ[@]}"; do
        i=$((i+1))
        if (( i <= min )); then
            continue
        fi
        local age; age="$(path_age_days "$p")"
        if (( age > days )); then
            delete_list+=("$p")
        fi
    done

    # 执行删除 (在成功计数保护下)
    # 重新统计: 删除后剩余成功数不得少于 min
    local remaining="${#succ[@]}"
    for p in "${delete_list[@]}"; do
        if (( remaining - 1 < min )); then
            log_warn "本地清理: 达到最少保留数量 ($min), 停止删除"
            cleanup_status="PROTECTED"
            break
        fi
        log_info "本地清理: 删除过期快照 $p"
        if safe_remove_tree "$p"; then
            remaining=$((remaining-1))
        else
            cleanup_status="WARN"
        fi
        # 清空的日期目录
        local dd; dd="$(dirname "$p")"
        if [[ -d "$dd" ]] && [[ -z "$(ls -A "$dd" 2>/dev/null)" ]]; then
            rmdir "$dd" 2>/dev/null || true
        fi
    done

    # 部分/失败 run: 仅清理超过 partial_retention_days 且非成功的
    local pdays="${GLOBAL[partial_retention_days]:-2}"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local path="${line##* }"
        if local_run_is_complete "$path"; then continue; fi
        local age; age="$(path_age_days "$path")"
        if (( age > pdays )); then
            log_info "本地清理: 删除旧 partial run $path"
            safe_remove_tree "$path" || cleanup_status="WARN"
        fi
    done < <(local_list_runs)

    # *.partial 文件
    while IFS= read -r pf; do
        [[ -z "$pf" ]] && continue
        local age; age="$(path_age_days "$pf")"
        if (( age > pdays )); then
            log_info "本地清理: 删除残留 partial $pf"
            rm -f -- "$pf" 2>/dev/null || true
        fi
    done < <(find "$base" "$CACHE_DIR" -type f -name '*.partial' 2>/dev/null || true)

    echo "$cleanup_status"
}

# 远端 cleanup (仅完整成功后调用)
retention_remote_cleanup() {
    local days="${GLOBAL[remote_retention_days]:-4}"
    local min="${GLOBAL[min_remote_success_backups]:-2}"
    local pdays="${GLOBAL[partial_retention_days]:-2}"
    local cutoff; cutoff="$(date -d "-${days} days" +%Y-%m-%d)"
    local pcutoff; pcutoff="$(date -d "-${pdays} days" +%Y-%m-%d)"

    if ! rclone_available; then echo "NO_RCLONE"; return 0; fi

    # 统计成功快照; 视 cleanup_legacy 处理旧扁平目录
    local -a successes=()
    local date run
    local cleanup_status="OK"
    local units; units="$(remote_snapshot_units)"
    while IFS= read -r date; do
        [[ -z "$date" ]] && continue
        if remote_is_legacy_date "$date"; then
            if [[ "${GLOBAL[cleanup_legacy]:-false}" == "true" && "$date" < "$cutoff" ]]; then
                if (( units > 1 )); then
                    if remote_purge_legacy_date "$date"; then
                        units=$((units-1))
                    else
                        cleanup_status="WARN"
                    fi
                else
                    log_warn "远端清理: 仅剩最后一个快照, 保留 legacy $date"
                fi
            else
                log_debug "远端 legacy 目录, 保留: $date"
            fi
            continue
        fi
        while IFS= read -r run; do
            [[ -z "$run" ]] && continue
            if remote_run_has_marker "$date" "$run" "RUN_COMPLETE"; then
                successes+=("$date|$run")
            fi
        done < <(remote_list_runs "$date")
    done < <(remote_list_dates)

    # 降序排序
    if (( ${#successes[@]} > 0 )); then
        IFS=$'\n' read -r -d '' -a successes < <(printf '%s\n' "${successes[@]}" | sort -r && printf '\0')
    fi

    local remaining="${#successes[@]}"
    local entry d r
    for entry in "${successes[@]:-}"; do
        [[ -z "$entry" ]] && continue
        d="${entry%%|*}"; r="${entry##*|}"
        if (( remaining - 1 < min )); then
            log_warn "远端清理: 达到最少保留数量 ($min), 停止"
            cleanup_status="PROTECTED"
            break
        fi
        if [[ "$d" < "$cutoff" ]]; then
            if remote_purge_run "$d" "$r"; then
                remaining=$((remaining-1))
            else
                cleanup_status="WARN"
            fi
        fi
    done

    # partial 快照清理
    while IFS= read -r date; do
        [[ -z "$date" ]] && continue
        remote_is_legacy_date "$date" && continue
        if [[ "$date" < "$pcutoff" ]]; then
            while IFS= read -r run; do
                [[ -z "$run" ]] && continue
                if remote_run_has_marker "$date" "$run" "RUN_PARTIAL" \
                   && ! remote_run_has_marker "$date" "$run" "RUN_COMPLETE"; then
                    log_info "远端清理: 删除旧 partial $date/$run"
                    remote_purge_run "$date" "$run" || cleanup_status="WARN"
                fi
            done < <(remote_list_runs "$date")
        fi
    done < <(remote_list_dates)

    echo "$cleanup_status"
}

# 上传前容量预清理: 仅删除已过期且不破坏 min 的成功快照
remote_preclean_for_capacity() {
    local needed="$1"
    local days="${GLOBAL[remote_retention_days]:-4}"
    local min="${GLOBAL[min_remote_success_backups]:-2}"
    local cutoff; cutoff="$(date -d "-${days} days" +%Y-%m-%d)"
    local safe_free; safe_free="$(remote_safe_free)"
    if (( needed <= safe_free )); then
        return 0
    fi
    log_warn "容量不足: 需要 $needed 字节, 安全可用 $safe_free 字节, 尝试安全预清理"

    # cleanup_legacy: 先清理过期的旧扁平目录 (从最旧开始)
    if [[ "${GLOBAL[cleanup_legacy]:-false}" == "true" ]]; then
        local units; units="$(remote_snapshot_units)"
        local ldate
        while IFS= read -r ldate; do
            [[ -z "$ldate" ]] && continue
            (( units > 1 )) || break
            if remote_purge_legacy_date "$ldate"; then
                units=$((units-1))
                remote_about "$ONEDRIVE_REMOTE" || true
                safe_free="$(remote_safe_free)"
                if (( needed <= safe_free )); then
                    log_ok "容量预清理后空间充足"
                    return 0
                fi
            fi
        done < <(remote_expired_legacy_dates "$cutoff")
    fi

    local -a successes=()
    local date run
    while IFS= read -r date; do
        [[ -z "$date" ]] && continue
        remote_is_legacy_date "$date" && continue
        while IFS= read -r run; do
            [[ -z "$run" ]] && continue
            if remote_run_has_marker "$date" "$run" "RUN_COMPLETE"; then
                successes+=("$date|$run")
            fi
        done < <(remote_list_runs "$date")
    done < <(remote_list_dates)
    if (( ${#successes[@]} > 0 )); then
        IFS=$'\n' read -r -d '' -a successes < <(printf '%s\n' "${successes[@]}" | sort -r && printf '\0')
    fi
    local remaining="${#successes[@]}"
    local entry d r
    for entry in "${successes[@]:-}"; do
        [[ -z "$entry" ]] && continue
        d="${entry%%|*}"; r="${entry##*|}"
        # 只清理 已过期 且 保留后仍 >= min
        if (( remaining - 1 < min )); then break; fi
        if [[ "$d" < "$cutoff" ]]; then
            log_info "容量预清理: 删除过期快照 $d/$r"
            if remote_purge_run "$d" "$r"; then
                remaining=$((remaining-1))
                remote_about "$ONEDRIVE_REMOTE" || true
                safe_free="$(remote_safe_free)"
                (( needed <= safe_free )) && { log_ok "容量预清理后空间充足"; return 0; }
            fi
        fi
    done
    remote_about "$ONEDRIVE_REMOTE" || true
    safe_free="$(remote_safe_free)"
    if (( needed <= safe_free )); then
        log_ok "容量预清理后空间充足"
        return 0
    fi
    log_error "容量预清理后仍不足 (需要 $needed, 安全可用 $safe_free)"
    return 1
}

# =============================================================================
# Backup engine
# =============================================================================

BACKUP_DIR=""
ONEDRIVE_REMOTE=""
RUN_STATE_WRITTEN=0
FINALIZED=0
RUN_START_ISO=""
RUN_LOCAL_SIZE=0
RUN_REMOTE_SIZE=0

project_enabled() { [[ "$(project_get "$1" enabled)" == "true" ]]; }

SELECTED_PROJECT=""
declare -a ACTIVE_IDS=()

compute_active_ids() {
    ACTIVE_IDS=()
    if [[ -n "$SELECTED_PROJECT" ]]; then
        if config_project_exists "$SELECTED_PROJECT"; then
            ACTIVE_IDS=("$SELECTED_PROJECT")
        fi
        return 0
    fi
    local id
    for id in "${PROJECT_IDS[@]:-}"; do
        project_enabled "$id" && ACTIVE_IDS+=("$id")
    done
    return 0
}

# 输出项目的有效排除列表 (显式 + 本 run 自动排除)
project_effective_excludes() {
    local id="$1"
    project_list "$id" "exclude"
    if [[ -n "${RUN_PROJECT_AUTOEX[$id]:-}" ]]; then
        printf '%s\n' "${RUN_PROJECT_AUTOEX[$id]}"
    fi
}

# 创建归档 (partial -> 校验 -> sha -> 原子 mv); 成功输出 archive 名与 hash 到全局
_do_archive() {
    local id="$1" source="$2" type="$3" run_dir="$4"
    local archive="${id}-${RUN_ID}.tar.gz"
    local final="$run_dir/$archive"
    local partial="$run_dir/.${archive}.partial"

    rm -f -- "$partial" 2>/dev/null || true

    local -a excl=()
    local e
    while IFS= read -r e; do
        [[ -z "$e" ]] && continue
        excl+=(--exclude="./$e")
    done < <(project_effective_excludes "$id")

    local rc=0
    set +e
    if [[ "$type" == "file" ]]; then
        tar -czf "$partial" -C "$(dirname "$source")" "$(basename "$source")" 2>"$CURRENT_WORK_DIR/tar.err"
        rc=$?
    else
        tar -czf "$partial" --one-file-system -C "$source" "${excl[@]}" . 2>"$CURRENT_WORK_DIR/tar.err"
        rc=$?
    fi
    set -e

    # tar exit 1 = 文件在读取时发生变化; 若完整性通过则接受 (但告警)
    if (( rc > 1 )); then
        log_error "tar 失败 (exit=$rc): $(head -n 3 "$CURRENT_WORK_DIR/tar.err" 2>/dev/null | tr '\n' ' ')"
        rm -f -- "$partial" 2>/dev/null || true
        return 1
    fi
    if (( rc == 1 )); then
        log_warn "tar 报告文件变化 (exit=1), 将进行完整性校验"
    fi

    # 完整性校验
    if ! tar -tzf "$partial" >/dev/null 2>&1; then
        log_error "归档完整性校验失败 (tar -tzf)"
        rm -f -- "$partial" 2>/dev/null || true
        return 1
    fi

    # SHA256
    local hash
    hash="$(sha256sum "$partial" | awk '{print $1}')"
    [[ -n "$hash" ]] || { log_error "SHA256 生成失败"; rm -f -- "$partial" 2>/dev/null || true; return 1; }

    # 原子 mv
    mv -f "$partial" "$final"

    RUN_PROJECT_ARCHIVE["$id"]="$archive"
    RUN_PROJECT_HASH["$id"]="$hash"
    RUN_PROJECT_SIZE["$id"]="$(stat -c '%s' "$final" 2>/dev/null || echo 0)"
    return 0
}

# 备份一个项目
backup_one_project() {
    local id="$1" run_dir="$2"
    CURRENT_PROJECT_ID="$id"
    CURRENT_PROJECT_NAME="$(project_get "$id" name)"
    CURRENT_PROJECT_SOURCE="$(project_get "$id" source)"
    local type; type="$(project_get "$id" type)"; type="${type:-dir}"
    local source="$CURRENT_PROJECT_SOURCE"
    local pre_cmd post_cmd
    pre_cmd="$(project_get "$id" backup_pre_hook)"
    post_cmd="$(project_get "$id" backup_post_hook)"

    POST_PENDING=0 POST_DONE=0

    log_info "开始备份项目: ${CURRENT_PROJECT_NAME} ($id)"

    # 源检查 (永久错误, 不重试)
    if [[ ! -e "$source" ]]; then
        log_error "源路径不存在: $source (配置错误, 不重试)"
        RUN_PROJECT_STATUS["$id"]="failed"
        RUN_PROJECT_ERR["$id"]="source_not_found"
        RUN_FAILED=$((RUN_FAILED+1))
        return 1
    fi
    if [[ -L "$source" ]]; then
        log_error "源路径是符号链接, 默认拒绝备份: $source"
        RUN_PROJECT_STATUS["$id"]="failed"
        RUN_PROJECT_ERR["$id"]="source_is_symlink"
        RUN_FAILED=$((RUN_FAILED+1))
        return 1
    fi
    if [[ "$type" == "dir" && ! -d "$source" ]]; then
        log_error "类型为 dir 但源不是目录: $source"
        RUN_PROJECT_STATUS["$id"]="failed"; RUN_PROJECT_ERR["$id"]="source_not_dir"
        RUN_FAILED=$((RUN_FAILED+1)); return 1
    fi
    if [[ "$type" == "file" && ! -f "$source" ]]; then
        log_error "类型为 file 但源不是文件: $source"
        RUN_PROJECT_STATUS["$id"]="failed"; RUN_PROJECT_ERR["$id"]="source_not_file"
        RUN_FAILED=$((RUN_FAILED+1)); return 1
    fi
    if [[ ! -r "$source" ]]; then
        log_error "源不可读: $source"
        RUN_PROJECT_STATUS["$id"]="failed"; RUN_PROJECT_ERR["$id"]="source_unreadable"
        RUN_FAILED=$((RUN_FAILED+1)); return 1
    fi

    # PRE hook
    if [[ -n "$(trim "$pre_cmd")" ]]; then
        if ! run_hook "backup_pre" "$pre_cmd"; then
            log_error "backup_pre hook 失败, 跳过本项目备份 (不执行 POST)"
            RUN_PROJECT_STATUS["$id"]="failed"; RUN_PROJECT_ERR["$id"]="pre_hook_failed"
            RUN_FAILED=$((RUN_FAILED+1))
            return 1
        fi
    fi
    # PRE 成功 (或未配置) -> 标记 POST 必须执行
    POST_PENDING=1

    # 备份 (有限重试)
    local attempt=1 max=$(( ${GLOBAL[retry_count]:-3} )) delay="${GLOBAL[retry_delay]:-10}"
    local ok=0
    while :; do
        local brc=0
        _do_archive "$id" "$source" "$type" "$run_dir" || brc=$?
        if (( brc == 0 )); then ok=1; break; fi
        if (( attempt >= max )); then break; fi
        local sleep_s=$(( delay * (2 ** (attempt-1)) ))
        (( sleep_s > 300 )) && sleep_s=300
        log_warn "备份失败, ${sleep_s}s 后重试 ($attempt/$max)"
        sleep "$sleep_s"
        attempt=$((attempt+1))
    done

    local backup_ok=0
    (( ok == 1 )) && backup_ok=1

    # POST hook 必须执行 (PRE 成功后)
    local post_ok=1
    if (( POST_PENDING == 1 && POST_DONE == 0 )); then
        if [[ -n "$(trim "$post_cmd")" ]]; then
            if run_hook "backup_post" "$post_cmd"; then
                post_ok=1
            else
                post_ok=0
            fi
        fi
        POST_DONE=1
    fi

    if (( backup_ok == 1 && post_ok == 1 )); then
        log_ok "项目备份完成: $id ($(bytes_to_human "${RUN_PROJECT_SIZE[$id]}"))"
        RUN_PROJECT_STATUS["$id"]="ok"
        return 0
    fi

    RUN_PROJECT_STATUS["$id"]="failed"
    if (( backup_ok == 0 && post_ok == 0 )); then
        RUN_PROJECT_ERR["$id"]="tar_failed_and_post_hook_failed"
    elif (( backup_ok == 0 )); then
        RUN_PROJECT_ERR["$id"]="tar_failed"
    else
        RUN_PROJECT_ERR["$id"]="post_hook_failed"
    fi
    RUN_FAILED=$((RUN_FAILED+1))
    # 保留已经生成的有效 archive (若存在)
    return 1
}

# 自身元数据备份
create_meta_backup() {
    local run_dir="$1"
    local meta="backup-manager-meta-${RUN_ID}.tar.gz"
    local stage="$CACHE_DIR/meta-${RUN_ID}"
    rm -rf -- "$stage" 2>/dev/null || true
    mkdir -p "$stage/state" "$stage/systemd"

    if [[ -f "$SELF_SCRIPT" ]]; then cp -p "$SELF_SCRIPT" "$stage/backup.sh" 2>/dev/null || true; fi
    if [[ -f "$CONF_FILE" ]]; then cp -p "$CONF_FILE" "$stage/backup.conf" 2>/dev/null || true; fi
    if [[ -f "$STATE_HEURISTICS" ]]; then cp -p "$STATE_HEURISTICS" "$stage/state/heuristics.conf" 2>/dev/null || true; fi
    if [[ -f "$STATE_LAST_RUN" ]]; then cp -p "$STATE_LAST_RUN" "$stage/state/last-run.conf" 2>/dev/null || true; fi
    printf 'version=%s\nbuilt=%s\nhost=%s\n' "$BACKUP_MANAGER_VERSION" "$(now_iso)" "$(hostname 2>/dev/null || echo unknown)" > "$stage/VERSION"

    local unit
    for unit in /etc/systemd/system/backup-manager.service /etc/systemd/system/backup-manager.timer; do
        if [[ -f "$unit" ]]; then cp -p "$unit" "$stage/systemd/" 2>/dev/null || true; fi
    done

    local rc=0
    set +e
    tar -czf "$run_dir/$meta" -C "$stage" . 2>/dev/null
    rc=$?
    set -e
    rm -rf -- "$stage" 2>/dev/null || true
    if (( rc != 0 )); then
        rm -f -- "$run_dir/$meta" 2>/dev/null || true
        log_warn "自身元数据备份失败"
        return 1
    fi
    META_ARCHIVE="$meta"
    META_HASH="$(sha256sum "$run_dir/$meta" | awk '{print $1}')"
    log_ok "自身元数据备份: $meta"
    return 0
}

# 生成 manifest.conf / manifest.sha256 / summary.txt
write_manifest() {
    local run_dir="$1" status="$2" exit_code="$3"
    local host; host="$(hostname 2>/dev/null || echo unknown)"
    local manifest="$run_dir/manifest.conf"

    {
        printf '[manifest]\n'
        printf 'format_version=%s\n' "$MANIFEST_FORMAT_VERSION"
        printf 'manager_version=%s\n' "$BACKUP_MANAGER_VERSION"
        printf 'run_id=%s\n' "$RUN_ID"
        printf 'hostname=%s\n' "$host"
        printf 'start=%s\n' "${RUN_START_ISO}"
        printf 'end=%s\n' "$(now_iso)"
        printf 'mode=%s\n' "$CURRENT_MODE"
        printf 'status=%s\n' "$status"
        printf 'exit_code=%s\n' "$exit_code"
        printf 'failed_projects=%s\n' "$(run_failed_list)"
        printf '\n'
        local id
        for id in "${ACTIVE_IDS[@]:-}"; do
            printf '[project:%s]\n' "$id"
            printf 'project_id=%s\n' "$id"
            printf 'name=%s\n' "$(project_get "$id" name)"
            printf 'source=%s\n' "$(project_get "$id" source)"
            printf 'type=%s\n' "$(project_get "$id" type)"
            printf 'status=%s\n' "${RUN_PROJECT_STATUS[$id]:-skipped}"
            printf 'archive=%s\n' "${RUN_PROJECT_ARCHIVE[$id]:-}"
            printf 'archive_size=%s\n' "${RUN_PROJECT_SIZE[$id]:-0}"
            printf 'sha256=%s\n' "${RUN_PROJECT_HASH[$id]:-}"
            local ex
            ex="$(project_list "$id" exclude | tr '\n' ' ')"
            printf 'exclude=%s\n' "$(trim "$ex")"
            if [[ -n "${RUN_PROJECT_AUTOEX[$id]:-}" ]]; then
                printf 'auto_exclude=%s\n' "$(printf '%s' "${RUN_PROJECT_AUTOEX[$id]}" | tr '\n' ' ' | trim)"
            else
                printf 'auto_exclude=\n'
            fi
            printf 'error=%s\n' "${RUN_PROJECT_ERR[$id]:-}"
            printf '\n'
        done
        if [[ -n "${META_ARCHIVE:-}" ]]; then
            printf '[meta]\n'
            printf 'archive=%s\n' "$META_ARCHIVE"
            printf 'sha256=%s\n' "${META_HASH:-}"
            printf '\n'
        fi
    } > "$manifest"

    # manifest.sha256: archives + manifest.conf (标准 sha256sum 格式, 相对 run_dir)
    (
        cd "$run_dir" || exit 1
        : > manifest.sha256
        local id
        for id in "${ACTIVE_IDS[@]:-}"; do
            local a="${RUN_PROJECT_ARCHIVE[$id]:-}"
            [[ -n "$a" && -f "$a" ]] || continue
            sha256sum "$a" >> manifest.sha256
        done
        [[ -n "${META_ARCHIVE:-}" && -f "${META_ARCHIVE}" ]] && sha256sum "$META_ARCHIVE" >> manifest.sha256
        sha256sum manifest.conf >> manifest.sha256
    )

    # summary.txt
    write_summary "$run_dir" "$status"
    return 0
}

write_summary() {
    local run_dir="$1" status="$2"
    local f="$run_dir/summary.txt"
    {
        printf '========================================\n'
        printf '           本次备份结果\n'
        printf '========================================\n\n'
        printf '运行 ID: %s\n' "$RUN_ID"
        printf '主机:    %s\n' "$(hostname 2>/dev/null || echo unknown)"
        printf '模式:   %s\n' "$CURRENT_MODE"
        printf '\n'
        local id
        for id in "${ACTIVE_IDS[@]:-}"; do
            printf '%s\n' "$(project_get "$id" name)"
            case "${RUN_PROJECT_STATUS[$id]:-skipped}" in
                ok)      printf '  [OK] 成功  大小: %s\n' "$(bytes_to_human "${RUN_PROJECT_SIZE[$id]:-0}")" ;;
                failed)  printf '  [FAIL] 失败  (%s)\n' "${RUN_PROJECT_ERR[$id]:-未知}" ;;
                skipped) printf '  [SKIP] 跳过\n' ;;
            esac
            if [[ -n "${RUN_PROJECT_AUTOEX[$id]:-}" ]]; then
                printf '  自动排除:\n'
                local rel
                while IFS= read -r rel; do
                    [[ -z "$rel" ]] && continue
                    printf '    %s  %s  score=%s\n' "$rel" "$(bytes_to_human "${HALL_SIZE["$id|$rel"]:-0}")" "${HALL_SCORE["$id|$rel"]:-?}"
                done <<< "${RUN_PROJECT_AUTOEX[$id]}"
            fi
            printf '\n'
        done
        printf '%s\n' '----------------------------------------'
        printf '失败项目: %s\n' "$(run_failed_list)"
        printf '本地备份: %s\n' "$( ((RUN_FAILED==0)) && echo 完成 || echo 部分 )"
        printf 'OneDrive 上传: %s\n' "$( ((RUN_REMOTE_UPLOAD==1)) && echo 完成 || echo 未完成 )"
        printf 'OneDrive 校验: %s\n' "$( ((RUN_REMOTE_VERIFY==1)) && echo 完成 || echo 未完成 )"
        printf '状态: %s\n' "$status"
    } > "$f"
}

# 计算 run 目录总大小
run_dir_size() {
    local d="$1"
    du -xsk "$d" 2>/dev/null | awk 'NR==1{print $1*1024}'
}

# =============================================================================
# 启发式决策 (容量感知)
# =============================================================================

declare -A HALL_SIZE=() HALL_SCORE=() HALL_PROT=() HALL_EST=() HALL_LEVEL=() HALL_PROJ_EST=() HALL_LIST=()
RUN_ID=""

# 扫描并持久化项目启发式结果
heuristic_scan_store() {
    local id="$1"
    heur_scan_project "$id" || return 1
    HALL_PROJ_EST["$id"]="$EST_PROJECT_BYTES"
    local list="" rel
    for rel in "${HEUR_CANDIDATES[@]:-}"; do
        [[ -z "$rel" ]] && continue
        HALL_SIZE["$id|$rel"]="${HEUR_SIZE[$rel]}"
        HALL_SCORE["$id|$rel"]="${HEUR_SCORE[$rel]}"
        HALL_PROT["$id|$rel"]="${HEUR_PROT[$rel]}"
        HALL_EST["$id|$rel"]="${HEUR_EST[$rel]}"
        HALL_LEVEL["$id|$rel"]="${HEUR_LEVEL[$rel]}"
        list+="$rel"$'\n'
    done
    HALL_LIST["$id"]="$list"
    return 0
}

# 决策; apply=1 时真正写入 RUN_PROJECT_AUTOEX
# allow_interact=1 时人工模式会询问
decide_heuristics() {
    local apply="$1" allow_interact="${2:-0}"
    local mode="${GLOBAL[heuristic_mode]:-smart}"
    local threshold="${GLOBAL[heuristic_auto_exclude_score]:-85}"
    [[ "$mode" == "off" ]] && { log_info "启发式已关闭"; return 0; }

    local total_all=0 id
    for id in "${ACTIVE_IDS[@]:-}"; do
        [[ "$(project_get "$id" heuristic)" == "true" ]] || continue
        total_all=$(( total_all + ${HALL_PROJ_EST[$id]:-0} ))
    done

    local safe_free=0 pressure=0
    if (( REMOTE_ABOUT_OK == 1 )); then
        safe_free="$(remote_safe_free)"
        (( total_all > safe_free )) && pressure=1
    fi
    if (( pressure == 1 )); then
        log_warn "远端容量压力: 预计备份 $total_all 字节 > 安全可用 $safe_free 字节"
    fi

    for id in "${ACTIVE_IDS[@]:-}"; do
        [[ "$(project_get "$id" heuristic)" == "true" ]] || continue
        local list="${HALL_LIST[$id]:-}"
        [[ -z "$list" ]] && continue
        local rel score prot est count status
        while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            score="${HALL_SCORE["$id|$rel"]:-0}"
            prot="${HALL_PROT["$id|$rel"]:-}"
            est="${HALL_EST["$id|$rel"]:-0}"

            if (( score < threshold )); then
                continue
            fi
            # 硬保护最高优先级
            if [[ -n "$prot" ]]; then
                log_warn "候选 $id/$rel score=$score 命中硬保护 ($prot), 禁止自动排除"
                (( apply == 1 )) && heur_state_set_record "$id" "$rel" "${HALL_SIZE["$id|$rel"]}" "$score" "PROTECTED" "${HALL_SCORE["$id|$rel"]}"
                continue
            fi
            if [[ "$mode" == "manual" ]]; then
                log_warn "人工模式: 建议排除 $id/$rel (size=$(bytes_to_human "${HALL_SIZE["$id|$rel"]}") score=$score)"
                if (( apply == 1 && allow_interact == 1 )); then
                    _ask_candidate_action "$id" "$rel" "$score"
                elif (( apply == 1 )); then
                    heur_state_set_record "$id" "$rel" "${HALL_SIZE["$id|$rel"]}" "$score" "SUGGEST" "${HALL_SCORE["$id|$rel"]}"
                fi
                continue
            fi
            # smart
            if (( pressure == 0 )); then
                log_info "检测到可能的下载/缓存目录 $id/$rel (score=$score), 但当前远端容量充足, 本次仍备份。"
                (( apply == 1 )) && heur_state_set_record "$id" "$rel" "${HALL_SIZE["$id|$rel"]}" "$score" "OBSERVED" "0"
                continue
            fi
            local overflow=$(( total_all - safe_free ))
            if (( est >= overflow && overflow > 0 )); then
                if (( apply == 1 )); then
                    local cur="${RUN_PROJECT_AUTOEX[$id]:-}"
                    RUN_PROJECT_AUTOEX["$id"]="${cur:+$cur$'\n'}$rel"
                    total_all=$(( total_all - est ))
                    count="$(heur_state_get "$id" "$rel" auto_exclude_count)"
                    [[ -z "$count" ]] && count=0
                    count=$((count+1))
                    status="AUTO_EXCLUDED"
                    if (( score >= 90 && count >= 3 )); then status="STABLE_AUTO_EXCLUDE"; fi
                    log_warn "AUTO_EXCLUDE: $id/$rel size=$(bytes_to_human "${HALL_SIZE["$id|$rel"]}") score=$score reason=remote_capacity_pressure"
                    heur_state_set_record "$id" "$rel" "${HALL_SIZE["$id|$rel"]}" "$score" "$status" "$count"
                else
                    log_warn "预计自动排除: $id/$rel size=$(bytes_to_human "${HALL_SIZE["$id|$rel"]}") score=$score"
                fi
            else
                log_warn "候选 $id/$rel score=$score 但排除收益不足, 本次仍备份"
                (( apply == 1 )) && heur_state_set_record "$id" "$rel" "${HALL_SIZE["$id|$rel"]}" "$score" "OBSERVED" "0"
            fi
        done <<< "$list"
    done
    return 0
}

_ask_candidate_action() {
    local id="$1" rel="$2" score="$3"
    [[ -t 0 ]] || return 0
    printf '\n项目 %s 发现高占用目录: %s (score=%s, %s)\n' "$id" "$rel" "$score" "$(bytes_to_human "${HALL_SIZE["$id|$rel"]}")"
    printf '  1. 本次忽略 (仍备份)\n'
    printf '  2. 加入永久 exclude\n'
    printf '  3. 加入 protect\n'
    printf '  4. 保持备份\n'
    local ans
    read -r -p '请选择 [1-4]: ' ans || ans=4
    case "$ans" in
        2)
            local existing; existing="$(printf '%s' "${PROJ_EXCLUDE[$id]:-}")"
            apply_config_edit mut_set_project_and_list "$id" "exclude" "${existing:+$existing$'\n'}$rel" \
                && log_ok "已加入永久 exclude: $rel"
            ;;
        3)
            local existingp; existingp="$(printf '%s' "${PROJ_PROTECT[$id]:-}")"
            apply_config_edit mut_set_project_and_list "$id" "protect" "${existingp:+$existingp$'\n'}$rel" \
                && log_ok "已加入 protect: $rel"
            ;;
        *) : ;;
    esac
    return 0
}

# 追加 exclude/protect (供交互使用)
mut_set_project_and_list() {
    local file="$1" id="$2" key="$3" value="$4"
    # 删除旧的 key 行后追加
    local tmp="$file.lstmp"
    awk -v want="[project:$id]" -v k="$key" '
        /^[[:space:]]*\[/ { inblock = ($0 == want) }
        {
            if (inblock) {
                pos=index($0,"=")
                if (pos>0) { kk=substr($0,1,pos-1); gsub(/^[ \t]+|[ \t]+$/,"",kk); if(kk==k) next }
            }
            print
        }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    _awk_add_to_section "$file" "project:$id" "$key" "$value"
}

_awk_add_to_section() {
    local file="$1" sect="$2" key="$3" val="$4"
    local want="[$sect]"
    local tmp="$file.addtmp"
    awk -v want="$want" -v k="$key" -v v="$val" '
        BEGIN{insec=0; done=0}
        {
            if ($0 ~ /^[[:space:]]*\[/) {
                if (insec && !done) { print k "=" v; done=1 }
                insec = ($0 == want)
            }
            print
        }
        END { if (insec && !done) print k "=" v }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# =============================================================================
# 收尾 / 信号
# =============================================================================

RUN_START_EPOCH=0

run_finalize() {
    local rc=$?
    [[ "${FINALIZED:-0}" == "1" ]] && return 0
    FINALIZED=1
    trap - EXIT INT TERM
    # 必须执行的 POST hook
    if (( ${POST_PENDING:-0} == 1 && ${POST_DONE:-0} == 0 )) && [[ -n "${CURRENT_PROJECT_ID:-}" ]]; then
        local cmd=""
        if [[ -n "${GLOBAL[backup_dir]:-}" ]]; then
            cmd="$(project_get "$CURRENT_PROJECT_ID" backup_post_hook 2>/dev/null || true)"
        fi
        if [[ -n "$(trim "${cmd:-}")" ]]; then
            log_warn "收尾: 强制执行未完成的 POST hook"
            run_hook backup_post "$cmd" || true
        fi
        POST_DONE=1
    fi
    if [[ "${RUN_STATE_WRITTEN:-0}" == "0" && -n "${CURRENT_RUN_ID:-}" ]]; then
        local dur=$(( $(now_epoch) - ${RUN_START_EPOCH:-0} ))
        state_write_last_run "FAILED" "$rc" "$dur" "${RUN_LOCAL_SIZE:-0}" "${RUN_REMOTE_SIZE:-0}" "SKIPPED" "$REMOTE_FREE" 2>/dev/null || true
        RUN_STATE_WRITTEN=1
    fi
    remove_temp_files
    release_lock
    return 0
}

on_signal() {
    local sig="$1" num="$2"
    log_warn "收到信号 $sig, 正在安全收尾 (不会删除已验证归档)..."
    exit $((128 + num))
}

# =============================================================================
# Run 主流程
# =============================================================================

# 解析 run 参数
cmd_run() {
    local dry=0 auto=0 allow_interact=0
    local arg
    for arg in "$@"; do
        case "$arg" in
            --automatic) auto=1 ;;
            --dry-run)   dry=1 ;;
            --interactive) allow_interact=1 ;;
            --project)   SELECTED_PROJECT="${2:-}"; shift ;;
            *) fail "未知的 run 参数: $arg"; return "$E_GENERAL" ;;
        esac
    done

    if (( auto == 1 )); then CURRENT_MODE="automatic"
    elif (( dry == 1 )); then CURRENT_MODE="dry-run"
    else CURRENT_MODE="manual"; fi

    require_root || return $?
    check_dependencies || return $?
    load_config_strict || return $?
    ensure_dirs

    if [[ -n "$SELECTED_PROJECT" ]] && ! config_project_exists "$SELECTED_PROJECT"; then
        fail "项目不存在: $SELECTED_PROJECT"
        return "$E_CONFIG"
    fi
    compute_active_ids

    if (( dry == 1 )); then
        cmd_run_dry
        return $?
    fi

    # 锁
    acquire_lock "$CURRENT_MODE" || return $?

    trap 'run_finalize' EXIT
    trap 'on_signal INT 2' INT
    trap 'on_signal TERM 15' TERM

    RUN_ID="$(date +%Y%m%d-%H%M%S)"
    CURRENT_RUN_ID="$RUN_ID"
    RUN_START_ISO="$(now_iso)"
    RUN_START_EPOCH="$(now_epoch)"

    local date; date="$(date +%Y-%m-%d)"
    local run_dir="$BACKUP_DIR/$date/$RUN_ID"
    CURRENT_WORK_DIR="$CACHE_DIR/$RUN_ID"
    mkdir -p "$run_dir" "$CURRENT_WORK_DIR"

    log_setup_run
    log_line INFO "run" "=============================================="
    log_line INFO "run" "开始完整备份 (run_id=$RUN_ID, mode=$CURRENT_MODE)"
    log_line INFO "run" "版本: $BACKUP_MANAGER_VERSION"

    # 初始化状态
    local id
    for id in "${PROJECT_IDS[@]:-}"; do
        project_enabled "$id" && RUN_PROJECT_STATUS["$id"]="pending" || RUN_PROJECT_STATUS["$id"]="disabled"
    done
    for id in "${ACTIVE_IDS[@]:-}"; do
        RUN_PROJECT_STATUS["$id"]="pending"
    done

    # 远端容量
    remote_about "$ONEDRIVE_REMOTE" && \
        log_info "OneDrive: 总 $(bytes_to_human "$REMOTE_TOTAL") 已用 $(bytes_to_human "$REMOTE_USED") 可用 $(bytes_to_human "$REMOTE_FREE") 安全可用 $(bytes_to_human "$(remote_safe_free)")" || \
        log_warn "无法获取 OneDrive 容量信息"

    # 启发式扫描 + 决策
    local hmode="${GLOBAL[heuristic_mode]:-smart}"
    if [[ "$hmode" != "off" ]]; then
        log_info "执行启发式扫描..."
        for id in "${ACTIVE_IDS[@]:-}"; do
            [[ "$(project_get "$id" heuristic)" == "true" ]] || continue
            if ! heuristic_scan_store "$id"; then
                log_warn "项目 $id 启发式扫描失败 (跳过)"
            fi
        done
        decide_heuristics 1 "$allow_interact"
    fi

    # 逐项目备份
    for id in "${ACTIVE_IDS[@]:-}"; do
        CURRENT_PROJECT_ID="$id"
        backup_one_project "$id" "$run_dir" || true
    done
    CURRENT_PROJECT_ID=""

    # 自身元数据备份
    create_meta_backup "$run_dir" || true

    # 状态判定
    local all_ok=1
    for id in "${ACTIVE_IDS[@]:-}"; do
        [[ "${RUN_PROJECT_STATUS[$id]:-}" == "ok" ]] || all_ok=0
    done
    if (( ${#ACTIVE_IDS[@]} == 0 )); then all_ok=0; fi

    local overall="SUCCESS"
    (( all_ok == 0 )) && overall="PARTIAL"

    # manifest (先按当前 overall, 上传后可能更新)
    write_manifest "$run_dir" "$overall" "$( ((all_ok==1)) && echo 0 || echo $E_BACKUP )"

    RUN_LOCAL_SIZE="$(run_dir_size "$run_dir")"
    log_info "本地备份总大小: $(bytes_to_human "$RUN_LOCAL_SIZE")"

    # 上传前第二次容量检查
    local upload_bytes
    upload_bytes="$(du -xsk "$run_dir" 2>/dev/null | awk 'NR==1{print $1*1024}')"
    if (( REMOTE_ABOUT_OK == 1 )); then
        local safe_free; safe_free="$(remote_safe_free)"
        if (( upload_bytes > safe_free )); then
            log_warn "上传前容量检查不足: 需要 $upload_bytes, 安全可用 $safe_free"
            if ! remote_preclean_for_capacity "$upload_bytes"; then
                log_error "容量不足, 标记 CAPACITY_ERROR; 保留本地有效备份, 禁止危险清理"
                write_manifest "$run_dir" "CAPACITY_ERROR" "$E_CAPACITY"
                RUN_STATE_WRITTEN=0
                state_write_last_run "CAPACITY_ERROR" "$E_CAPACITY" "$(( $(now_epoch) - RUN_START_EPOCH ))" "$RUN_LOCAL_SIZE" "0" "SKIPPED" "$safe_free"
                RUN_STATE_WRITTEN=1
                log_line ERROR "run" "结束: CAPACITY_ERROR"
                return "$E_CAPACITY"
            fi
        fi
    else
        log_warn "无法获取容量信息, 仍尝试上传 (不做危险清理)"
    fi

    # 上传
    if ! remote_upload_run "$run_dir" "$date" "$RUN_ID"; then
        log_error "上传失败; 本地备份保留, last-success 不更新, 远端历史不清理"
        write_manifest "$run_dir" "UPLOAD_ERROR" "$E_REMOTE_UPLOAD"
        state_write_last_run "UPLOAD_ERROR" "$E_REMOTE_UPLOAD" "$(( $(now_epoch) - RUN_START_EPOCH ))" "$RUN_LOCAL_SIZE" "0" "SKIPPED" "$(remote_safe_free)"
        RUN_STATE_WRITTEN=1
        return "$E_REMOTE_UPLOAD"
    fi
    RUN_REMOTE_SIZE="$upload_bytes"
    RUN_REMOTE_UPLOAD=1

    # 远端校验
    if ! remote_verify_run "$run_dir" "$date" "$RUN_ID"; then
        log_error "远端校验失败; 保留本地备份"
        write_manifest "$run_dir" "VERIFY_ERROR" "$E_VERIFY"
        state_write_last_run "VERIFY_ERROR" "$E_VERIFY" "$(( $(now_epoch) - RUN_START_EPOCH ))" "$RUN_LOCAL_SIZE" "$RUN_REMOTE_SIZE" "SKIPPED" "$(remote_safe_free)"
        RUN_STATE_WRITTEN=1
        return "$E_VERIFY"
    fi
    RUN_REMOTE_VERIFY=1

    # 标记
    local marker="RUN_PARTIAL"
    (( all_ok == 1 )) && marker="RUN_COMPLETE"
    if ! remote_write_marker "$run_dir" "$date" "$RUN_ID" "$marker"; then
        write_manifest "$run_dir" "UPLOAD_ERROR" "$E_REMOTE_UPLOAD"
        state_write_last_run "UPLOAD_ERROR" "$E_REMOTE_UPLOAD" "$(( $(now_epoch) - RUN_START_EPOCH ))" "$RUN_LOCAL_SIZE" "$RUN_REMOTE_SIZE" "SKIPPED" "$(remote_safe_free)"
        RUN_STATE_WRITTEN=1
        return "$E_REMOTE_UPLOAD"
    fi

    local cleanup_status="SKIPPED"
    local exit_code=0
    local status="$overall"

    if (( all_ok == 1 )); then
        # 完整成功: 更新 last-success, 执行常规清理
        state_write_last_success
        log_info "执行 retention 清理..."
        local lc rc2
        lc="$(retention_local_cleanup)"; log_info "本地清理: $lc"
        rc2="$(retention_remote_cleanup)"; log_info "远端清理: $rc2"
        cleanup_status="OK"
        if [[ "$lc" != "OK" && "$lc" != "NO_LOCAL_DIR" ]] || [[ "$rc2" != "OK" ]]; then
            cleanup_status="WARN"
            status="SUCCESS_WITH_WARNINGS"
            exit_code="$E_MAINTENANCE"
            log_warn "备份成功但清理存在警告"
        else
            status="SUCCESS"
            exit_code=0
        fi
        write_manifest "$run_dir" "$status" "$exit_code"
    else
        # Partial: 不更新 last-success, 不危险清理
        log_warn "本次为 PARTIAL: 不更新 last-success, 跳过历史清理"
        cleanup_status="SKIPPED_PARTIAL"
        status="PARTIAL"
        exit_code="$E_BACKUP"
        write_manifest "$run_dir" "$status" "$exit_code"
    fi

    local dur=$(( $(now_epoch) - RUN_START_EPOCH ))
    state_write_last_run "$status" "$exit_code" "$dur" "$RUN_LOCAL_SIZE" "$RUN_REMOTE_SIZE" "$cleanup_status" "$(remote_safe_free)"
    RUN_STATE_WRITTEN=1

    print_run_result "$run_dir" "$status" "$dur"
    log_line INFO "run" "结束: $status (exit=$exit_code, 耗时 ${dur}s)"
    return "$exit_code"
}

print_run_result() {
    local run_dir="$1" status="$2" dur="$3"
    printf '\n'
    printf '%s========================================%s\n' "$C_BOLD" "$C_RESET"
    printf '%s            本次备份结果%s\n' "$C_BOLD" "$C_RESET"
    printf '%s========================================%s\n\n' "$C_BOLD" "$C_RESET"
    printf '运行 ID: %s\n\n' "$RUN_ID"
    local id
    for id in "${ACTIVE_IDS[@]:-}"; do
        printf '%s%s%s\n' "$C_BOLD" "$(project_get "$id" name)" "$C_RESET"
        case "${RUN_PROJECT_STATUS[$id]:-skipped}" in
            ok)      printf '  %s✓ 成功%s  大小: %s\n' "$C_GREEN" "$C_RESET" "$(bytes_to_human "${RUN_PROJECT_SIZE[$id]:-0}")" ;;
            failed)  printf '  %s✗ 失败%s  (%s)\n' "$C_RED" "$C_RESET" "${RUN_PROJECT_ERR[$id]:-未知}" ;;
            *)       printf '  %s- 跳过%s\n' "$C_DIM" "$C_RESET" ;;
        esac
        if [[ -n "${RUN_PROJECT_AUTOEX[$id]:-}" ]]; then
            printf '  自动排除:\n'
            local rel
            while IFS= read -r rel; do
                [[ -z "$rel" ]] && continue
                printf '    %s  %s  score=%s\n' "$rel" "$(bytes_to_human "${HALL_SIZE["$id|$rel"]:-0}")" "${HALL_SCORE["$id|$rel"]:-?}"
            done <<< "${RUN_PROJECT_AUTOEX[$id]}"
        fi
        printf '\n'
    done
    printf '%s----------------------------------------%s\n' "$C_DIM" "$C_RESET"
    printf '本地:        %s\n' "$( ((RUN_FAILED==0)) && printf '%s✓ 完成%s' "$C_GREEN" "$C_RESET" || printf '%s✗ 部分%s' "$C_RED" "$C_RESET" )"
    printf 'SHA256:      %s✓ 完成%s\n' "$C_GREEN" "$C_RESET"
    printf 'OneDrive:    %s\n' "$( ((RUN_REMOTE_UPLOAD==1)) && printf '%s✓ 上传完成%s' "$C_GREEN" "$C_RESET" || printf '%s✗ 未上传%s' "$C_RED" "$C_RESET" )"
    printf '远端校验:    %s\n' "$( ((RUN_REMOTE_VERIFY==1)) && printf '%s✓ 完成%s' "$C_GREEN" "$C_RESET" || printf '%s✗ 未完成%s' "$C_RED" "$C_RESET" )"
    if (( REMOTE_ABOUT_OK == 1 )); then
        printf '\nOneDrive:\n'
        printf '  总容量: %s  已使用: %s  安全剩余: %s\n' \
            "$(bytes_to_human "$REMOTE_TOTAL")" "$(bytes_to_human "$REMOTE_USED")" "$(bytes_to_human "$(remote_safe_free)")"
    fi
    printf '\n耗时: %dm %ds\n' "$((dur/60))" "$((dur%60))"
    local color="$C_GREEN"
    case "$status" in
        PARTIAL|UPLOAD_ERROR|VERIFY_ERROR|CAPACITY_ERROR) color="$C_RED" ;;
        SUCCESS_WITH_WARNINGS) color="$C_YELLOW" ;;
    esac
    printf '状态: %s%s%s\n' "$color" "$status" "$C_RESET"
    if [[ "$status" == "PARTIAL" ]]; then
        printf '%s历史备份清理已跳过%s\n' "$C_YELLOW" "$C_RESET"
    fi
}

# Dry run
cmd_run_dry() {
    log_info "Dry-run: 仅扫描与预测, 不执行 hook/tar/上传/删除"
    remote_about "$ONEDRIVE_REMOTE" && \
        log_info "OneDrive: 总 $(bytes_to_human "$REMOTE_TOTAL") 已用 $(bytes_to_human "$REMOTE_USED") 可用 $(bytes_to_human "$REMOTE_FREE") 安全可用 $(bytes_to_human "$(remote_safe_free)")" || \
        log_warn "无法获取 OneDrive 容量信息"

    local hmode="${GLOBAL[heuristic_mode]:-smart}"
    local id
    if [[ "$hmode" != "off" ]]; then
        printf '\n%s启发式扫描 (dry-run)%s\n' "$C_BOLD" "$C_RESET"
        for id in "${ACTIVE_IDS[@]:-}"; do
            [[ "$(project_get "$id" heuristic)" == "true" ]] || continue
            heuristic_scan_store "$id" || { log_warn "$id 扫描失败"; continue; }
            printf '\n[%s] 绝对路径: %s  预计大小: %s\n' "$id" "$(project_get "$id" source)" "$(bytes_to_human "${HALL_PROJ_EST[$id]:-0}")"
            local rel
            while IFS= read -r rel; do
                [[ -z "$rel" ]] && continue
                local score="${HALL_SCORE["$id|$rel"]}" prot="${HALL_PROT["$id|$rel"]}" level="${HALL_LEVEL["$id|$rel"]}"
                printf '  %-30s %10s  score=%-3s %s%s\n' "$rel" "$(bytes_to_human "${HALL_SIZE["$id|$rel"]}")" "$score" "$level" "${prot:+  [保护: $prot]}"
            done <<< "${HALL_LIST[$id]:-}"
        done
        printf '\n%s决策预览%s\n' "$C_BOLD" "$C_RESET"
        decide_heuristics 0 0
    fi

    printf '\n%sRetention 预览%s\n' "$C_BOLD" "$C_RESET"
    local line path age
    local ldays="${GLOBAL[local_retention_days]}"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        path="${line##* }"
        age="$(path_age_days "$path")"
        if (( age > ldays )); then
            printf '  [本地] 将清理 (age=%sd): %s\n' "$age" "$path"
        fi
    done < <(local_list_runs)
    printf '  本地最少保留: %s 个成功快照\n' "${GLOBAL[min_local_success_backups]}"
    printf '  远端最少保留: %s 个成功快照\n' "${GLOBAL[min_remote_success_backups]}"
    printf '\nDry-run 完成 (未做任何修改)。\n'
    return 0
}

# =============================================================================
# Restore
# =============================================================================

# 列出本地 run (输出 "date run path")
restore_list_local_runs() { local_list_runs; }

# 列出远端 run (输出 "date run")
restore_list_remote_runs() {
    local date run
    while IFS= read -r date; do
        [[ -z "$date" ]] && continue
        remote_is_legacy_date "$date" && { printf '%s LEGACY\n' "$date"; continue; }
        while IFS= read -r run; do
            [[ -z "$run" ]] && continue
            printf '%s %s\n' "$date" "$run"
        done < <(remote_list_runs "$date")
    done < <(remote_list_dates)
}

# 从 manifest 读取项目 source
manifest_project_source() {
    local manifest="$1" pid="$2"
    awk -v sec="[project:$pid]" '
        $0==sec {insec=1; next}
        /^\[/ {insec=0}
        insec && /^source=/ {sub(/^source=/,""); print; exit}
    ' "$manifest"
}

manifest_get() {
    local manifest="$1" section="$2" key="$3"
    awk -v sec="[$section]" -v k="$key" '
        $0==sec {insec=1; next}
        /^\[/ {insec=0}
        insec && index($0,k"=")==1 {sub(k"=",""); print; exit}
    ' "$manifest"
}

# 校验 run 目录 (sha256 + tar)
verify_run_archive() {
    local run_dir="$1" archive="$2"
    if [[ ! -f "$run_dir/$archive" ]]; then
        log_error "归档不存在: $run_dir/$archive"; return 1
    fi
    # manifest.sha256
    if [[ -f "$run_dir/manifest.sha256" ]]; then
        if ( cd "$run_dir" && sha256sum -c manifest.sha256 >/dev/null 2>&1 ); then
            log_ok "manifest.sha256 校验通过"
        else
            log_error "manifest.sha256 校验失败"
            # 尝试仅校验目标归档
            local expected actual
            expected="$(manifest_project_hash "$run_dir/manifest.conf" "$archive")"
            actual="$(sha256sum "$run_dir/$archive" | awk '{print $1}')"
            if [[ -n "$expected" && "$expected" == "$actual" ]]; then
                log_warn "manifest.sha256 未通过, 但目标归档 SHA256 匹配"
            else
                return 1
            fi
        fi
    fi
    if ! tar -tzf "$run_dir/$archive" >/dev/null 2>&1; then
        log_error "归档完整性校验失败 (tar -tzf)"; return 1
    fi
    log_ok "归档完整性校验通过: $archive"
    return 0
}

manifest_project_hash() {
    local manifest="$1" archive="$2"
    awk -v a="$archive" '
        /^\[project:/ {inp=1}
        /^\[/ && !/^\[project:/ {inp=0}
        inp && /^archive=/ {sub(/^archive=/,""); if($0==a){found=1; next}}
        found && /^sha256=/ {sub(/^sha256=/,""); print; exit}
    ' "$manifest"
}

# 磁盘空间检查
check_disk_space() {
    local path="$1" required="$2"
    local parent="$path"
    while [[ ! -d "$parent" && "$parent" != "/" ]]; do parent="$(dirname "$parent")"; done
    local avail
    avail="$(df -Pk "$parent" 2>/dev/null | awk 'NR==2{print $4*1024}')"
    [[ -z "$avail" ]] && return 0
    if (( required > avail )); then
        log_error "磁盘空间不足: 需要 $required, 可用 $avail ($parent)"
        return 1
    fi
    return 0
}

# 记录恢复历史
write_restore_history() {
    local run_id="$1" pid="$2" orig="$3" rollback="$4" sha_status="$5" hook_status="$6" final="$7" src="$8"
    mkdir -p "$RESTORE_HISTORY_DIR"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local f="$RESTORE_HISTORY_DIR/restore-${ts}.conf"
    {
        printf 'time=%s\n' "$(now_iso)"
        printf 'run_id=%s\n' "$run_id"
        printf 'project_id=%s\n' "$pid"
        printf 'source=%s\n' "$src"
        printf 'target=%s\n' "$orig"
        printf 'rollback_path=%s\n' "$rollback"
        printf 'sha256_status=%s\n' "$sha_status"
        printf 'hook_status=%s\n' "$hook_status"
        printf 'final_status=%s\n' "$final"
    } | atomic_write "$f"
    log_ok "恢复历史: $f"
}

# 执行恢复 (run_dir 已就绪, 归档已校验)
restore_project_from_run() {
    local run_dir="$1" pid="$2" run_id="$3"
    local manifest="$run_dir/manifest.conf"
    local archive hash src type
    archive="$(manifest_get "$manifest" "project:$pid" "archive")"
    hash="$(manifest_get "$manifest" "project:$pid" "sha256")"
    src="$(manifest_project_source "$manifest" "$pid")"
    type="$(manifest_get "$manifest" "project:$pid" "type")"; type="${type:-dir}"

    if [[ -z "$archive" ]]; then
        log_error "manifest 中未找到项目 $pid 的归档"; return "$E_RESTORE"
    fi
    # 目标路径优先使用当前配置, 否则 manifest
    local target="$src"
    if config_project_exists "$pid"; then
        target="$(project_get "$pid" source)"
    fi
    [[ -n "$target" ]] || { log_error "无法确定恢复目标路径"; return "$E_RESTORE"; }

    log_info "恢复项目 $pid -> $target"
    if ! verify_run_archive "$run_dir" "$archive"; then
        write_restore_history "$run_id" "$pid" "$target" "" "VERIFY_FAILED" "none" "REJECTED" "$run_dir/$archive"
        return "$E_RESTORE"
    fi
    # SHA256 精确校验
    if [[ -n "$hash" ]]; then
        local actual; actual="$(sha256sum "$run_dir/$archive" | awk '{print $1}')"
        if [[ "$actual" != "$hash" ]]; then
            log_error "SHA256 不匹配 (期望 $hash, 实际 $actual), 拒绝恢复"
            write_restore_history "$run_id" "$pid" "$target" "" "MISMATCH" "none" "REJECTED" "$run_dir/$archive"
            return "$E_RESTORE"
        fi
        log_ok "SHA256 匹配"
    fi

    # 空间检查 (宽松: 归档大小 * 2)
    local asize; asize="$(stat -c '%s' "$run_dir/$archive" 2>/dev/null || echo 0)"
    check_disk_space "$target" "$(( asize * 2 ))" || return "$E_RESTORE"

    # PRE hook
    local pre_cmd=""
    [[ -n "${GLOBAL[backup_dir]:-}" ]] && pre_cmd="$(project_get "$pid" restore_pre_hook)"
    CURRENT_PROJECT_ID="$pid"
    if [[ -n "$(trim "$pre_cmd")" ]]; then
        run_hook "restore_pre" "$pre_cmd" || {
            log_error "restore_pre hook 失败, 中止恢复"
            write_restore_history "$run_id" "$pid" "$target" "" "OK" "pre_failed" "ABORTED" "$run_dir/$archive"
            CURRENT_PROJECT_ID=""
            return "$E_RESTORE"
        }
    fi

    # 备份现有目标
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local rollback=""
    if [[ -e "$target" || -L "$target" ]]; then
        rollback="${target}.before-restore-${ts}"
        if ! mv -- "$target" "$rollback"; then
            log_error "无法重命名现有目标: $target"
            CURRENT_PROJECT_ID=""
            return "$E_RESTORE"
        fi
        log_info "已将现有目标重命名为: $rollback"
    fi

    # 解压
    local extract_rc=0
    set +e
    if [[ "$type" == "file" ]]; then
        mkdir -p "$(dirname "$target")"
        tar -xzf "$run_dir/$archive" -C "$(dirname "$target")" 2>"$CACHE_DIR/restore.err"
        extract_rc=$?
    else
        mkdir -p "$target"
        tar -xzf "$run_dir/$archive" -C "$target" 2>"$CACHE_DIR/restore.err"
        extract_rc=$?
    fi
    set -e

    if (( extract_rc != 0 )); then
        log_error "解压失败: $(head -n 3 "$CACHE_DIR/restore.err" 2>/dev/null | tr '\n' ' ')"
        # 保留新目录用于排查, 但恢复原目录
        local failed="${target}.failed-restore-${ts}"
        [[ -e "$target" ]] && mv -- "$target" "$failed" 2>/dev/null || true
        if [[ -n "$rollback" && -e "$rollback" ]]; then
            mv -- "$rollback" "$target" 2>/dev/null || log_error "回滚重命名失败, 请手动检查 $rollback"
            log_warn "已尝试恢复原目录"
        fi
        write_restore_history "$run_id" "$pid" "$target" "$rollback" "OK" "extract_failed" "ROLLED_BACK" "$run_dir/$archive"
        CURRENT_PROJECT_ID=""
        return "$E_RESTORE"
    fi

    # POST hook
    local post_cmd=""
    [[ -n "${GLOBAL[backup_dir]:-}" ]] && post_cmd="$(project_get "$pid" restore_post_hook)"
    local hook_status="ok"
    if [[ -n "$(trim "$post_cmd")" ]]; then
        if ! run_hook "restore_post" "$post_cmd"; then
            hook_status="post_failed"
            log_error "restore_post hook 失败; 保留恢复后的数据与 before-restore 目录"
            write_restore_history "$run_id" "$pid" "$target" "$rollback" "OK" "$hook_status" "OK_WITH_HOOK_WARNING" "$run_dir/$archive"
            CURRENT_PROJECT_ID=""
            return "$E_HOOK"
        fi
    fi

    write_restore_history "$run_id" "$pid" "$target" "$rollback" "OK" "$hook_status" "SUCCESS" "$run_dir/$archive"
    CURRENT_PROJECT_ID=""
    log_ok "恢复完成: $pid -> $target"
    return 0
}

# 回滚最近一次恢复
restore_rollback_last() {
    local latest
    latest="$(find "$RESTORE_HISTORY_DIR" -maxdepth 1 -type f -name 'restore-*.conf' 2>/dev/null | sort | tail -1)"
    if [[ -z "$latest" ]]; then
        log_error "没有恢复历史, 无法回滚"; return "$E_RESTORE"
    fi
    local target rollback
    target="$(state_get "$latest" target)"
    rollback="$(state_get "$latest" rollback_path)"
    if [[ -z "$rollback" || ! -e "$rollback" ]]; then
        log_error "找不到 before-restore 目录: ${rollback:-空}"; return "$E_RESTORE"
    fi
    if [[ -e "$target" ]]; then
        local ts; ts="$(date +%Y%m%d-%H%M%S)"
        mv -- "$target" "${target}.rolledback-${ts}" || { log_error "重命名恢复目录失败"; return "$E_RESTORE"; }
    fi
    mv -- "$rollback" "$target" || { log_error "回滚失败"; return "$E_RESTORE"; }
    log_ok "已回滚: $target"
    return 0
}

cmd_restore() {
    require_root || return $?
    load_config_lenient || return $?
    ensure_dirs

    local mode="" run_id="" date="" pid="" do_rollback=0 do_history=0
    while (( $# > 0 )); do
        case "$1" in
            --local) mode="local"; shift ;;
            --remote) mode="remote"; shift ;;
            --run) run_id="$2"; shift 2 ;;
            --date) date="$2"; shift 2 ;;
            --project) pid="$2"; shift 2 ;;
            --rollback) do_rollback=1; shift ;;
            --history) do_history=1; shift ;;
            --list) mode="list"; shift ;;
            *) fail "未知 restore 参数: $1"; return "$E_GENERAL" ;;
        esac
    done

    if (( do_history == 1 )); then
        ls -1 "$RESTORE_HISTORY_DIR" 2>/dev/null || true
        return 0
    fi
    if (( do_rollback == 1 )); then
        restore_rollback_last
        return $?
    fi
    if [[ "$mode" == "list" ]]; then
        printf '本地 run:\n'; restore_list_local_runs
        printf '\n远端 run:\n'; restore_list_remote_runs
        return 0
    fi
    if [[ -z "$mode" ]]; then
        if [[ -t 0 ]]; then restore_menu; return $?; fi
        fail "非交互环境请指定 --local/--remote --run --project"
        return "$E_GENERAL"
    fi

    local run_dir=""
    if [[ "$mode" == "local" ]]; then
        [[ -n "$run_id" && -n "$pid" ]] || { fail "本地恢复需要 --run 与 --project"; return "$E_GENERAL"; }
        while IFS= read -r line; do
            [[ "${line##* }" == *"/$run_id" ]] && run_dir="${line##* }"
        done < <(local_list_runs)
        [[ -n "$run_dir" ]] || { log_error "未找到本地 run: $run_id"; return "$E_RESTORE"; }
    else
        [[ -n "$run_id" && -n "$pid" && -n "$date" ]] || { fail "远端恢复需要 --date --run --project"; return "$E_GENERAL"; }
        if ! rclone_available; then log_error "rclone 不可用"; return "$E_RESTORE"; fi
        run_dir="$CACHE_DIR/restore-${date}-${run_id}"
        rm -rf -- "$run_dir" 2>/dev/null || true
        mkdir -p "$run_dir"
        log_info "下载远端 run 到 staging: $run_dir"
        if ! rclone copy "$ONEDRIVE_REMOTE/$date/$run_id" "$run_dir" --log-level ERROR; then
            log_error "远端下载失败"; return "$E_RESTORE"
        fi
    fi
    restore_project_from_run "$run_dir" "$pid" "$run_id"
    return $?
}

# 交互恢复菜单
restore_menu() {
    while :; do
        ui_reset
        printf '\n%s恢复备份%s\n' "$C_BOLD" "$C_RESET"
        printf '1. 从本地选择\n'
        printf '2. 从 OneDrive 选择\n'
        printf '3. 查看恢复历史\n'
        printf '4. 回滚最近一次恢复\n'
        printf '0. 返回\n'
        local c; read -r -p '请选择: ' c || return 0
        case "$c" in
            1) _restore_pick_local ;;
            2) _restore_pick_remote ;;
            3) ls -1 "$RESTORE_HISTORY_DIR" 2>/dev/null || true ;;
            4) restore_rollback_last || true ;;
            0) return 0 ;;
        esac
    done
}

_restore_pick_local() {
    printf '可用本地 run:\n'
    local -a arr=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        arr+=("$line")
        printf '  %d) %s\n' "${#arr[@]}" "$(printf '%s' "$line" | awk '{print $1" "$2}')"
    done < <(local_list_runs)
    (( ${#arr[@]} == 0 )) && { printf '  (无)\n'; return 0; }
    local i; read -r -p '选择编号: ' i || return 0
    [[ "$i" =~ ^[0-9]+$ ]] && (( i>=1 && i<=${#arr[@]} )) || return 0
    local path; path="$(printf '%s' "${arr[$((i-1))]}" | awk '{print $3}')"
    local run_id; run_id="$(printf '%s' "${arr[$((i-1))]}" | awk '{print $2}')"
    _restore_pick_project "$path" "$run_id" local
}

_restore_pick_remote() {
    printf '可用远端 run:\n'
    local -a arr=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" == *LEGACY* ]] && { printf '  [LEGACY] %s\n' "${line% LEGACY}"; continue; }
        arr+=("$line"); printf '  %d) %s\n' "${#arr[@]}" "$line"
    done < <(restore_list_remote_runs)
    (( ${#arr[@]} == 0 )) && { printf '  (无)\n'; return 0; }
    local i; read -r -p '选择编号: ' i || return 0
    [[ "$i" =~ ^[0-9]+$ ]] && (( i>=1 && i<=${#arr[@]} )) || return 0
    local date run
    date="$(printf '%s' "${arr[$((i-1))]}" | awk '{print $1}')"
    run="$(printf '%s' "${arr[$((i-1))]}" | awk '{print $2}')"
    cmd_restore --remote --date "$date" --run "$run" --project "$(_ask_project_id)"
}

_ask_project_id() {
    printf '项目列表:\n' >&2
    local id
    for id in "${PROJECT_IDS[@]:-}"; do printf '  %s (%s)\n' "$id" "$(project_get "$id" name)" >&2; done
    local v; read -r -p '项目 ID: ' v || true
    printf '%s' "$v"
}

_restore_pick_project() {
    local path="$1" run_id="$2" src="$3"
    printf '项目列表:\n'
    local id
    for id in "${PROJECT_IDS[@]:-}"; do printf '  %s (%s)\n' "$id" "$(project_get "$id" name)"; done
    local v; read -r -p '项目 ID: ' v || return 0
    restore_project_from_run "$path" "$v" "$run_id"
}

# =============================================================================
# systemd
# =============================================================================

sysd_unit_dir() {
    if [[ "$BM_TEST_MODE" == "1" ]]; then printf '%s' "$BM_ROOT/test-systemd";
    else printf '%s' "/etc/systemd/system"; fi
}

sysd_service_path() { printf '%s/backup-manager.service' "$(sysd_unit_dir)"; }
sysd_timer_path()   { printf '%s/backup-manager.timer' "$(sysd_unit_dir)"; }

render_service() {
    cat <<'EOF'
[Unit]
Description=Backup Manager
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backupctl run --automatic
UMask=0077
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
}

render_timer() {
    local hhmm="$1"
    cat <<EOF
[Unit]
Description=Backup Manager Daily Timer

[Timer]
OnCalendar=*-*-* ${hhmm}:00
Persistent=true
Unit=backup-manager.service

[Install]
WantedBy=timers.target
EOF
}

validate_hhmm() {
    [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]
}

sysd_apply() {
    if [[ "$BM_TEST_MODE" == "1" ]]; then
        log_debug "[test] 跳过 systemctl $*"
        return 0
    fi
    systemctl "$@"
}

cmd_schedule() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        install) _schedule_install "${1:-}" ;;
        modify|set) _schedule_modify "${1:-}" ;;
        status) _schedule_status ;;
        run|run-now) _schedule_run_now ;;
        remove|uninstall) _schedule_remove ;;
        "" )
            if [[ -t 0 ]]; then schedule_menu; else fail "用法: backupctl schedule {install|modify|status|run|remove}"; return "$E_GENERAL"; fi ;;
        *) fail "未知 schedule 子命令: $sub"; return "$E_GENERAL" ;;
    esac
}

_schedule_install() {
    require_root || return $?
    local dir; dir="$(sysd_unit_dir)"
    mkdir -p "$dir"
    local hhmm="${1:-}"
    if [[ -z "$hhmm" && -t 0 ]]; then
        read -r -p '每天几点运行? (HH:MM, 默认 03:30): ' hhmm || true
    fi
    [[ -z "$hhmm" ]] && hhmm="03:30"
    if ! validate_hhmm "$hhmm"; then
        fail "非法时间格式: $hhmm (应为 HH:MM)"
        return "$E_GENERAL"
    fi
    render_service > "$(sysd_service_path).tmp"
    render_timer "$hhmm" > "$(sysd_timer_path).tmp"
    mv -f "$(sysd_service_path).tmp" "$(sysd_service_path)"
    mv -f "$(sysd_timer_path).tmp" "$(sysd_timer_path)"
    chmod 644 "$(sysd_service_path)" "$(sysd_timer_path)" 2>/dev/null || true
    log_ok "已写入 systemd 单元 (每天 $hhmm)"
    sysd_apply daemon-reload || true
    sysd_apply enable --now backup-manager.timer || { log_error "启用 timer 失败"; return "$E_GENERAL"; }
    _schedule_status
    return 0
}

_schedule_modify() {
    require_root || return $?
    local hhmm="${1:-}"
    if [[ -z "$hhmm" && -t 0 ]]; then
        read -r -p '修改为每天几点运行? (HH:MM): ' hhmm || true
    fi
    if ! validate_hhmm "$hhmm"; then
        fail "非法时间格式: ${hhmm:-空} (应为 HH:MM)"; return "$E_GENERAL"
    fi
    render_timer "$hhmm" > "$(sysd_timer_path).tmp"
    mv -f "$(sysd_timer_path).tmp" "$(sysd_timer_path)"
    chmod 644 "$(sysd_timer_path)" 2>/dev/null || true
    sysd_apply daemon-reload || true
    sysd_apply restart backup-manager.timer || true
    log_ok "已修改为每天 $hhmm"
    _schedule_status
    return 0
}

_schedule_status() {
    if [[ "$BM_TEST_MODE" == "1" ]]; then
        printf 'service: %s\n' "$(sysd_service_path)"
        printf 'timer:   %s\n' "$(sysd_timer_path)"
        [[ -f "$(sysd_timer_path)" ]] && grep -E 'OnCalendar=|Persistent=' "$(sysd_timer_path)" || true
        return 0
    fi
    systemctl list-timers backup-manager.timer --no-pager 2>/dev/null || true
    printf '\n'
    systemctl status backup-manager.timer --no-pager 2>/dev/null | head -n 12 || true
    return 0
}

_schedule_run_now() {
    require_root || return $?
    if [[ "$BM_TEST_MODE" == "1" ]]; then
        cmd_run --automatic
        return $?
    fi
    systemctl start backup-manager.service
    return $?
}

_schedule_remove() {
    require_root || return $?
    sysd_apply disable --now backup-manager.timer 2>/dev/null || true
    rm -f "$(sysd_service_path)" "$(sysd_timer_path)"
    sysd_apply daemon-reload || true
    log_ok "已删除 Backup Manager 的 systemd 单元 (不影响其他服务)"
    return 0
}

schedule_menu() {
    while :; do
        ui_reset
        printf '\n%s计划任务管理%s\n' "$C_BOLD" "$C_RESET"
        printf '1. 安装计划任务\n'
        printf '2. 修改执行时间\n'
        printf '3. 查看计划任务\n'
        printf '4. 立即执行\n'
        printf '5. 删除计划任务\n'
        printf '0. 返回\n'
        local c; read -r -p '请选择: ' c || return 0
        case "$c" in
            1) _schedule_install ;;
            2) _schedule_modify ;;
            3) _schedule_status ;;
            4) _schedule_run_now ;;
            5) _schedule_remove ;;
            0) return 0 ;;
        esac
    done
}

# =============================================================================
# 项目管理
# =============================================================================

require_config_for_project_cmds() {
    if [[ ! -f "$CONF_FILE" ]]; then
        fail "配置文件不存在, 请先运行 'backupctl init'"
        return "$E_CONFIG"
    fi
    load_config_lenient || return "$E_CONFIG"
    return 0
}

cmd_project() {
    local sub="${1:-}"
    shift || true
    case "$sub" in
        list) _project_list ;;
        add) _project_add "$@" ;;
        edit) _project_edit "$@" ;;
        enable) _project_toggle "$@" true ;;
        disable) _project_toggle "$@" false ;;
        remove) _project_remove "$@" ;;
        exclude) _project_pathlist "exclude" "$@" ;;
        protect) _project_pathlist "protect" "$@" ;;
        "" )
            if [[ -t 0 ]]; then project_menu; else fail "用法: backupctl project {list|add|edit|enable|disable|remove|exclude|protect}"; return "$E_GENERAL"; fi ;;
        *) fail "未知 project 子命令: $sub"; return "$E_GENERAL" ;;
    esac
}

_project_list() {
    require_config_for_project_cmds || return $?
    printf '%-24s %-20s %-6s %-5s %-5s %s\n' "ID" "名称" "启用" "类型" "启发" "路径"
    local id
    for id in "${PROJECT_IDS[@]:-}"; do
        printf '%-24s %-20s %-6s %-5s %-5s %s\n' \
            "$id" "$(project_get "$id" name)" "$(project_get "$id" enabled)" \
            "$(project_get "$id" type)" "$(project_get "$id" heuristic)" "$(project_get "$id" source)"
    done
    return 0
}

_project_toggle() {
    local id="$1" value="$2"
    require_config_for_project_cmds || return $?
    if [[ -z "$id" ]]; then
        ui_reset; _project_list; printf '\n'
        read -r -p '项目 ID: ' id || return 0
    fi
    if ! config_project_exists "$id"; then fail "项目不存在: $id"; return "$E_CONFIG"; fi
    apply_config_edit mut_set_project "$id" "enabled" "$value" || return $?
    log_ok "项目 $id 已 $([[ "$value" == true ]] && echo 启用 || echo 禁用)"
    return 0
}

_project_remove() {
    local id="$1"
    require_config_for_project_cmds || return $?
    if [[ -z "$id" ]]; then
        ui_reset
        _project_list
        printf '\n'
        read -r -p '要删除的项目 ID: ' id || return 0
    fi
    if ! config_project_exists "$id"; then fail "项目不存在: $id"; return "$E_CONFIG"; fi
    if [[ -t 0 ]]; then
        ui_reset
        printf '%s删除项目%s\n\n' "$C_BOLD" "$C_RESET"
        printf '  ID:   %s\n' "$id"
        printf '  名称: %s\n\n' "$(project_get "$id" name)"
        local ans; read -r -p "确认删除该项目配置? (只删配置, 不删备份/源数据) [y/N]: " ans || true
        [[ "$ans" == "y" || "$ans" == "Y" ]] || { log_info "已取消"; return 0; }
    fi
    apply_config_edit mut_remove_project "$id" || return $?
    log_ok "已删除项目配置: $id (历史备份与源数据未受影响)"
    return 0
}

# 绘制编辑表单 (通过 nameref 读取字段值)
_edit_form_draw() {
    local id="$1"
    local -n _vals="$2"
    shift 2
    printf '%s修改项目%s\n' "$C_BOLD" "$C_RESET"
    printf '  项目 ID: %s\n' "$id"
    printf '  ────────────────────────────────────\n'
    local k
    for k in "$@"; do
        printf '  %-18s %s\n' "$k" "${_vals[$k]}"
    done
    printf '\n'
}

_project_edit() {
    require_config_for_project_cmds || return $?
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        ui_reset; _project_list; printf '\n'
        read -r -p '项目 ID: ' id || return 0
    fi
    if ! config_project_exists "$id"; then fail "项目不存在: $id"; return "$E_CONFIG"; fi

    local fields=(name source type heuristic backup_pre_hook backup_post_hook restore_pre_hook restore_post_hook)
    local -A val=()
    local f
    for f in "${fields[@]}"; do
        val["$f"]="$(project_get "$id" "$f")"
    done

    local changed=0
    for f in "${fields[@]}"; do
        ui_reset
        _edit_form_draw "$id" val "${fields[@]}"
        printf '  留空表示不修改。\n\n'
        local v; read -r -p "  ${f} = " v || { printf '\n'; break; }
        [[ -z "$v" ]] && continue
        if apply_config_edit mut_set_project "$id" "$f" "$v"; then
            val["$f"]="$v"
            changed=1
        fi
    done

    ui_reset
    _edit_form_draw "$id" val "${fields[@]}"
    if (( changed == 1 )); then
        log_ok "项目 $id 已更新"
    else
        printf '未做修改\n'
    fi
    return 0
}

_pathlist_apply() {
    local id="$1" which="$2" action="$3" path="$4"
    if ! is_safe_rel_path "$path"; then fail "非法相对路径: $path"; return "$E_CONFIG"; fi
    local existing; existing="$(project_list "$id" "$which" | tr '\n' ' ')"
    local newval="$existing"
    if [[ "$action" == "add" ]]; then
        newval="$(trim "$existing $path")"
    elif [[ "$action" == "remove" ]]; then
        # shellcheck disable=SC2086
        newval="$(printf '%s\n' $existing | grep -vx -- "$path" | tr '\n' ' ' | trim)" || true
    else
        fail "未知操作: $action"; return "$E_GENERAL"
    fi
    apply_config_edit mut_set_project_and_list "$id" "$which" "$newval" || return $?
    log_ok "项目 $id 的 $which 已更新: $newval"
    return 0
}

_project_pathlist() {
    local which="$1"; shift
    local id="${1:-}" action="${2:-}"
    require_config_for_project_cmds || return $?
    if [[ -z "$id" ]]; then read -r -p '项目 ID: ' id || return 0; fi
    if ! config_project_exists "$id"; then fail "项目不存在: $id"; return "$E_CONFIG"; fi

    if [[ -z "$action" ]]; then
        if [[ -t 0 ]]; then
            while :; do
                ui_reset
                printf '%s管理 %s: %s (%s)%s\n\n' "$C_BOLD" "$which" "$id" "$(project_get "$id" name)" "$C_RESET"
                printf '当前 %s:\n' "$which"
                local cur; cur="$(project_list "$id" "$which" | sed 's/^/  /')"
                [[ -n "$cur" ]] && printf '%s\n' "$cur" || printf '  (空)\n'
                printf '\n  1. 添加   2. 移除   0. 返回\n\n'
                local op; read -r -p '请选择: ' op || return 0
                case "$op" in
                    1|2)
                        local path; read -r -p '相对路径: ' path || return 0
                        [[ -z "$path" ]] && continue
                        if (( op == 1 )); then
                            _pathlist_apply "$id" "$which" add "$path" || { sleep 1; }
                        else
                            _pathlist_apply "$id" "$which" remove "$path" || { sleep 1; }
                        fi
                        ;;
                    0|"") return 0 ;;
                    *) : ;;
                esac
            done
        fi
        printf '当前 %s:\n' "$which"; project_list "$id" "$which" | sed 's/^/  /'
        printf '用法: backupctl project %s <id> {add|remove} <相对路径>\n' "$which"
        return 0
    fi

    local path="${3:-}"
    [[ -z "$path" ]] && { fail "缺少路径"; return "$E_GENERAL"; }
    _pathlist_apply "$id" "$which" "$action" "$path"
}

# 添加向导表单
_add_form_draw() {
    ui_reset
    printf '%s添加新项目%s\n' "$C_BOLD" "$C_RESET"
    printf '  ────────────────────────────────────\n'
    printf '  项目 ID:   %s\n' "$1"
    printf '  显示名称:  %s\n' "$2"
    printf '  路径:      %s\n' "$3"
    printf '  类型:      %s\n\n' "$4"
}

# 新项目向导
_project_add() {
    require_config_for_project_cmds || return $?
    local id="" name="" src="" type="dir" heuristic="true"
    # 非交互参数: id name source [type] [heuristic]
    if (( $# >= 3 )); then
        id="$1"; name="$2"; src="$3"; type="${4:-dir}"; heuristic="${5:-true}"
    else
        [[ -t 0 ]] || { fail "非交互添加请用: backupctl project add <id> <name> <source> [type] [heuristic]"; return "$E_GENERAL"; }
        _add_form_draw "" "" "" "dir"
        read -r -p '  项目 ID (小写字母/数字/._-): ' id || return 0
        _add_form_draw "$id" "" "" "dir"
        read -r -p '  显示名称: ' name || return 0
        _add_form_draw "$id" "$name" "" "dir"
        read -r -p '  路径: ' src || return 0
        _add_form_draw "$id" "$name" "$src" "dir"
        read -r -p '  类型 dir/file [dir]: ' type || true; type="${type:-dir}"
    fi
    if ! is_valid_project_id "$id"; then fail "非法项目 ID: $id"; return "$E_CONFIG"; fi
    if [[ -z "$name" ]]; then fail "显示名称不能为空"; return "$E_CONFIG"; fi
    if [[ "$src" != /* ]]; then fail "路径必须是绝对路径"; return "$E_CONFIG"; fi
    case "$type" in dir|file) ;; *) fail "类型只能是 dir/file"; return "$E_CONFIG";; esac
    if config_project_exists "$id"; then fail "项目已存在: $id"; return "$E_CONFIG"; fi

    # 检查
    if [[ ! -e "$src" ]]; then log_warn "路径当前不存在: $src (仍写入配置)"; fi
    [[ -L "$src" ]] && log_warn "路径是符号链接, 备份时会被拒绝"
    if [[ -e "$src" ]]; then
        local sz; sz="$(dir_size_bytes "$src")"
        log_info "项目大小: $(bytes_to_human "$sz")"
    fi

    if ! apply_config_edit mut_project_block "$id" "$name" "$src" "$type" "$heuristic"; then
        return "$E_CONFIG"
    fi
    log_ok "已添加项目: $id"

    # 启发式扫描展示
    load_config_lenient >/dev/null 2>&1 || true
    if [[ "$heuristic" == "true" && -d "$src" ]]; then
        log_info "执行启发式扫描..."
        if heuristic_scan_store "$id"; then
            printf '项目总大小(估算): %s\n' "$(bytes_to_human "${HALL_PROJ_EST[$id]}")"
            local rel
            while IFS= read -r rel; do
                [[ -z "$rel" ]] && continue
                local score="${HALL_SCORE["$id|$rel"]}"; local prot="${HALL_PROT["$id|$rel"]}"
                (( score < 50 )) && continue
                printf '发现: %-28s %10s score=%-3s %s%s\n' "$rel" "$(bytes_to_human "${HALL_SIZE["$id|$rel"]}")" "$score" "${HALL_LEVEL["$id|$rel"]}" "${prot:+ [保护: $prot]}"
                if (( score >= 70 )) && [[ -z "$prot" && -t 0 ]]; then
                    _ask_candidate_action "$id" "$rel" "$score"
                fi
            done <<< "${HALL_LIST[$id]}"
        fi
    fi
    return 0
}

# =============================================================================
# status / check / remote / logs
# =============================================================================

cmd_status() {
    require_config_for_project_cmds || return $?
    printf '%s%s %s 状态%s\n' "$C_BOLD" "$BACKUP_MANAGER_NAME" "$BACKUP_MANAGER_VERSION" "$C_RESET"
    printf '\n[最近一次运行]\n'
    if [[ -f "$STATE_LAST_RUN" ]]; then
        grep -E '^(run_id|start|end|duration_seconds|mode|status|exit_code|failed_projects|warnings|local_size_bytes|remote_upload_bytes|cleanup_status|auto_excluded)=' "$STATE_LAST_RUN" || true
    else
        printf '  (无)\n'
    fi
    printf '\n[最近一次成功]\n'
    if [[ -f "$STATE_LAST_SUCCESS" ]]; then
        grep -E '^(run_id|time|success_projects|local_size_bytes|remote_upload_bytes)=' "$STATE_LAST_SUCCESS" || true
    else
        printf '  (无)\n'
    fi
    printf '\n[本地备份]\n'
    local count=0 line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        count=$((count+1))
        printf '  %s\n' "$(printf '%s' "$line" | awk '{print $1"/"$2}')"
    done < <(local_list_runs | head -n 10)
    (( count == 0 )) && printf '  (无)\n'
    printf '\n[远端容量]\n'
    if remote_about "$ONEDRIVE_REMOTE"; then
        printf '  总 %s / 已用 %s / 可用 %s / 安全可用 %s\n' \
            "$(bytes_to_human "$REMOTE_TOTAL")" "$(bytes_to_human "$REMOTE_USED")" \
            "$(bytes_to_human "$REMOTE_FREE")" "$(bytes_to_human "$(remote_safe_free)")"
    else
        printf '  (无法获取)\n'
    fi
    printf '\n[锁]\n'
    if lock_is_active; then
        printf '  有任务运行中:\n'; sed 's/^/    /' "$LOCK_INFO_FILE"
    else
        printf '  空闲\n'
    fi
    return 0
}

cmd_logs() {
    local n="${1:-40}"
    local latest
    latest="$(find "$LOG_DIR" -maxdepth 1 -type f -name 'backup-*.log' 2>/dev/null | sort | tail -1)"
    if [[ -z "$latest" ]]; then
        printf '暂无日志\n'; return 0
    fi
    printf '日志文件: %s\n' "$latest"
    tail -n "$n" "$latest"
    return 0
}

_has_db_files() {
    local dir="$1"
    local hit
    hit="$(find "$dir" -xdev -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) -print -quit 2>/dev/null || true)"
    [[ -n "$hit" ]]
}

cmd_check() {
    local rc=0
    printf '%s%s %s 系统检查%s\n' "$C_BOLD" "$BACKUP_MANAGER_NAME" "$BACKUP_MANAGER_VERSION" "$C_RESET"
    printf '\n[环境]\n'
    if [[ "$BM_TEST_MODE" != "1" && "${EUID:-$(id -u)}" -ne 0 ]]; then
        printf '  %s✗ 非 root%s\n' "$C_RED" "$C_RESET"; rc=1
    else
        printf '  %s✓ root 权限%s\n' "$C_GREEN" "$C_RESET"
    fi
    printf '  Bash: %s\n' "$BASH_VERSION"
    local cmd
    for cmd in tar gzip sha256sum du df stat find grep sed awk flock timeout base64; do
        if command -v "$cmd" >/dev/null 2>&1; then printf '  %s✓ %s%s\n' "$C_GREEN" "$cmd" "$C_RESET";
        else printf '  %s✗ 缺少 %s%s\n' "$C_RED" "$cmd" "$C_RESET"; rc=1; fi
    done
    if rclone_available; then printf '  %s✓ rclone%s\n' "$C_GREEN" "$C_RESET"; else printf '  %s✗ 缺少 rclone%s\n' "$C_RED" "$C_RESET"; rc=1; fi
    if command -v systemctl >/dev/null 2>&1; then printf '  %s✓ systemctl%s\n' "$C_GREEN" "$C_RESET"; else printf '  %s- 无 systemctl%s\n' "$C_YELLOW" "$C_RESET"; fi

    printf '\n[配置]\n'
    if [[ ! -f "$CONF_FILE" ]]; then
        printf '  %s✗ 配置文件不存在%s\n' "$C_RED" "$C_RESET"; rc=1
    else
        printf '  %s✓ 配置文件存在%s\n' "$C_GREEN" "$C_RESET"
        if check_config_permissions "$CONF_FILE"; then
            printf '  %s✓ 权限 root:600%s\n' "$C_GREEN" "$C_RESET"
        else
            printf '  %s✗ 权限不安全 (应 root:600)%s\n' "$C_RED" "$C_RESET"; rc=1
        fi
        if parse_config_file "$CONF_FILE" && validate_config_model; then
            BACKUP_DIR="${GLOBAL[backup_dir]}"
            ONEDRIVE_REMOTE="${GLOBAL[onedrive_remote]}"
            printf '  %s✓ 配置合法 (%s 个项目)%s\n' "$C_GREEN" "${#PROJECT_IDS[@]}" "$C_RESET"
        else
            printf '  %s✗ 配置非法%s\n' "$C_RED" "$C_RESET"; rc=1
        fi
    fi

    local bdir="${BACKUP_DIR:-${GLOBAL[backup_dir]:-}}"
    if [[ -n "$bdir" ]]; then
        printf '\n[备份目录]\n'
        if mkdir -p "$bdir" 2>/dev/null && [[ -w "$bdir" ]]; then
            printf '  %s✓ 可写: %s%s\n' "$C_GREEN" "$bdir" "$C_RESET"
        else
            printf '  %s✗ 不可写: %s%s\n' "$C_RED" "$bdir" "$C_RESET"; rc=1
        fi
        local avail
        avail="$(df -Pk "$bdir" 2>/dev/null | awk 'NR==2{print $4*1024}')"
        printf '  本地剩余空间: %s\n' "$(bytes_to_human "${avail:-0}")"
        # backup_dir 不能位于任何 source 内部
        local id s
        for id in "${PROJECT_IDS[@]:-}"; do
            s="$(project_get "$id" source)"
            if [[ -n "$s" && ( "$bdir" == "$s" || "$bdir" == "$s"/* ) ]]; then
                printf '  %s✗ backup_dir 位于项目 %s 的 source 内 (会递归备份)%s\n' "$C_RED" "$id" "$C_RESET"; rc=1
            fi
        done
    fi

    printf '\n[项目]\n'
    local id
    for id in "${PROJECT_IDS[@]:-}"; do
        local s t en
        s="$(project_get "$id" source)"; t="$(project_get "$id" type)"; en="$(project_get "$id" enabled)"
        [[ "$en" == "true" ]] || { printf '  %s- %s (已禁用)%s\n' "$C_DIM" "$id" "$C_RESET"; continue; }
        if [[ ! -e "$s" ]]; then
            printf '  %s✗ %s: 路径不存在 %s%s\n' "$C_RED" "$id" "$s" "$C_RESET"; rc=1; continue
        fi
        if [[ -L "$s" ]]; then
            printf '  %s✗ %s: 源是符号链接, 备份会拒绝%s\n' "$C_RED" "$id" "$C_RESET"; rc=1
        fi
        if [[ "$t" == "dir" && ! -d "$s" ]]; then
            printf '  %s✗ %s: 应为目录%s\n' "$C_RED" "$id" "$C_RESET"; rc=1; continue
        fi
        [[ -r "$s" ]] || { printf '  %s✗ %s: 不可读%s\n' "$C_RED" "$id" "$C_RESET"; rc=1; }
        printf '  %s✓ %s: %s%s\n' "$C_GREEN" "$id" "$s" "$C_RESET"
        # DB 一致性警告
        if [[ "$t" == "dir" ]] && _has_db_files "$s"; then
            if [[ -z "$(trim "$(project_get "$id" backup_pre_hook)")" ]]; then
                printf '    %s⚠ 检测到 SQLite/DB 文件但未配置 backup_pre_hook; 直接 tar 无法保证一致性, 建议配置 Hook%s\n' "$C_YELLOW" "$C_RESET"
            fi
        fi
    done

    printf '\n[OneDrive]\n'
    if remote_about "$ONEDRIVE_REMOTE"; then
        printf '  %s✓ 可访问%s  总 %s / 可用 %s / 安全可用 %s\n' "$C_GREEN" "$C_RESET" \
            "$(bytes_to_human "$REMOTE_TOTAL")" "$(bytes_to_human "$REMOTE_FREE")" "$(bytes_to_human "$(remote_safe_free)")"
        local rcount; rcount="$(remote_count_success)"
        printf '  远端成功快照数: %s (最少保留 %s)\n' "$rcount" "${GLOBAL[min_remote_success_backups]}"
    else
        printf '  %s✗ 无法访问 OneDrive%s\n' "$C_RED" "$C_RESET"; rc=1
    fi

    printf '\n[systemd]\n'
    if [[ -f "$(sysd_timer_path)" ]]; then
        printf '  %s✓ timer 已安装%s\n' "$C_GREEN" "$C_RESET"
        grep -E 'OnCalendar=' "$(sysd_timer_path)" | sed 's/^/    /' || true
    else
        printf '  %s- 未安装 timer%s\n' "$C_YELLOW" "$C_RESET"
    fi

    printf '\n[锁]\n'
    if lock_is_active; then printf '  %s有任务运行中%s\n' "$C_YELLOW" "$C_RESET"; sed 's/^/    /' "$LOCK_INFO_FILE"; else printf '  空闲\n'; fi

    printf '\n'
    if (( rc == 0 )); then
        printf '%s检查通过%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '%s检查发现问题%s\n' "$C_RED" "$C_RESET"
    fi
    return "$rc"
}

cmd_remote() {
    local sub="${1:-status}"; shift || true
    require_config_for_project_cmds || return $?
    case "$sub" in
        status)
            if remote_about "$ONEDRIVE_REMOTE"; then
                printf 'OneDrive: 总 %s / 已用 %s / 可用 %s / 安全可用 %s\n' \
                    "$(bytes_to_human "$REMOTE_TOTAL")" "$(bytes_to_human "$REMOTE_USED")" \
                    "$(bytes_to_human "$REMOTE_FREE")" "$(bytes_to_human "$(remote_safe_free)")"
                printf '成功快照数: %s\n' "$(remote_count_success)"
            else
                fail "无法获取容量"; return "$E_REMOTE_UPLOAD"
            fi ;;
        list)
            printf '日期 / RUN_ID / 标记:\n'
            local date run
            while IFS= read -r date; do
                [[ -z "$date" ]] && continue
                if remote_is_legacy_date "$date"; then printf '  %s [LEGACY]\n' "$date"; continue; fi
                while IFS= read -r run; do
                    [[ -z "$run" ]] && continue
                    local mark="-"
                    remote_run_has_marker "$date" "$run" "RUN_COMPLETE" && mark="COMPLETE"
                    remote_run_has_marker "$date" "$run" "RUN_PARTIAL" && mark="PARTIAL"
                    printf '  %s  %s  %s\n' "$date" "$run" "$mark"
                done < <(remote_list_runs "$date")
            done < <(remote_list_dates) ;;
        verify)
            local date="" run_id=""
            while (( $# > 0 )); do
                case "$1" in --date) date="$2"; shift 2;; --run) run_id="$2"; shift 2;; *) shift;; esac
            done
            if [[ -z "$date" || -z "$run_id" ]]; then
                fail "用法: backupctl remote verify --date YYYY-MM-DD --run RUN_ID"; return "$E_GENERAL"
            fi
            local local_dir=""
            while IFS= read -r line; do
                [[ "${line##* }" == *"/$run_id" ]] && local_dir="${line##* }"
            done < <(local_list_runs)
            if [[ -n "$local_dir" ]]; then
                remote_verify_run "$local_dir" "$date" "$run_id"
            else
                local n
                n="$(rclone lsf "$ONEDRIVE_REMOTE/$date/$run_id" --files-only 2>/dev/null | wc -l)"
                printf '本地无对应 run, 仅列出远端对象数: %s\n' "$n"
                remote_run_has_marker "$date" "$run_id" "RUN_COMPLETE" && printf '标记: RUN_COMPLETE\n' || printf '标记: 无 RUN_COMPLETE\n'
            fi ;;
        purge)
            local date="" run_id="" legacy=0 legacy_expired=0 assume_yes=0
            while (( $# > 0 )); do
                case "$1" in
                    --legacy) legacy=1; shift ;;
                    --legacy-expired) legacy_expired=1; shift ;;
                    --yes|-y) assume_yes=1; shift ;;
                    *)
                        if [[ -z "$date" ]]; then date="$1"; elif [[ -z "$run_id" ]]; then run_id="$1"; fi
                        shift ;;
                esac
            done

            if (( legacy_expired == 1 )); then
                local lcutoff; lcutoff="$(date -d "-${GLOBAL[remote_retention_days]:-4} days" +%Y-%m-%d)"
                local ldate n=0
                while IFS= read -r ldate; do
                    [[ -z "$ldate" ]] && continue
                    if (( assume_yes == 0 )); then
                        if [[ -t 0 ]]; then
                            local a; read -r -p "确认删除过期 legacy $ldate ? [y/N]: " a || true
                            [[ "$a" == "y" || "$a" == "Y" ]] || continue
                        else
                            fail "非交互请加 --yes"; return "$E_GENERAL"
                        fi
                    fi
                    remote_purge_legacy_date "$ldate" && n=$((n+1))
                done < <(remote_expired_legacy_dates "$lcutoff")
                if (( n == 0 )); then printf '没有可清理的过期 legacy 目录\n'; else printf '已清理 %s 个 legacy 目录\n' "$n"; fi
                return 0
            fi

            if (( legacy == 1 )); then
                [[ -n "$date" ]] || { fail "用法: backupctl remote purge --legacy <YYYY-MM-DD>"; return "$E_GENERAL"; }
                is_valid_date_dir "$date" || { fail "非法日期: $date"; return "$E_GENERAL"; }
                if ! remote_is_legacy_date "$date"; then
                    fail "$date 不是 legacy(旧扁平)目录, 拒绝删除"
                    return "$E_GENERAL"
                fi
                if (( assume_yes == 0 )); then
                    if [[ -t 0 ]]; then
                        local a; read -r -p "确认删除远端 legacy $date ? [y/N]: " a || true
                        [[ "$a" == "y" || "$a" == "Y" ]] || return 0
                    else
                        fail "非交互请加 --yes"; return "$E_GENERAL"
                    fi
                fi
                remote_purge_legacy_date "$date"
                return $?
            fi

            [[ -z "$date" || -z "$run_id" ]] && { fail "用法: backupctl remote purge <date> <run> | --legacy <date> | --legacy-expired"; return "$E_GENERAL"; }
            is_valid_date_dir "$date" && is_valid_run_id "$run_id" || { fail "非法 date/run"; return "$E_GENERAL"; }
            if (( assume_yes == 0 )) && [[ -t 0 ]]; then
                local ans; read -r -p "确认删除远端 $date/$run_id ? [y/N]: " ans || true
                [[ "$ans" == "y" || "$ans" == "Y" ]] || return 0
            fi
            remote_purge_run "$date" "$run_id" ;;
        "") fail "用法: backupctl remote {status|list|verify|purge [--legacy <date>|--legacy-expired]}"; return "$E_GENERAL" ;;
        *) fail "未知 remote 子命令: $sub"; return "$E_GENERAL" ;;
    esac
}

# =============================================================================
# config 命令
# =============================================================================

cmd_config() {
    local sub="${1:-}"
    case "$sub" in
        rollback)
            require_root || return $?
            if [[ ! -f "$CONF_BAK" ]]; then fail "没有备份配置: $CONF_BAK"; return "$E_CONFIG"; fi
            local tmp="$CONF_FILE.tmp.$$"
            cp -p "$CONF_BAK" "$tmp"
            if ! parse_config_file "$tmp" || ! validate_config_model; then
                rm -f "$tmp"; fail "备份配置校验失败, 拒绝回滚"; return "$E_CONFIG"
            fi
            chmod 600 "$tmp"; [[ "$BM_TEST_MODE" != "1" ]] && chown root:root "$tmp" 2>/dev/null || true
            cp -p "$CONF_FILE" "$CONF_BAK.1" 2>/dev/null || true
            mv -f "$tmp" "$CONF_FILE"
            log_ok "已回滚配置到 backup.conf.bak"
            ;;
        show)
            require_config_for_project_cmds || return $?
            cat "$CONF_FILE" ;;
        "" ) fail "用法: backupctl config {rollback|show}"; return "$E_GENERAL" ;;
        *) fail "未知 config 子命令: $sub"; return "$E_GENERAL" ;;
    esac
}

# =============================================================================
# 交互 UI
# =============================================================================

main_menu() {
    ensure_dirs
    while :; do
        ui_reset
        printf '\n%s========================================%s\n' "$C_CYAN" "$C_RESET"
        printf '%s       Backup Manager %s%s\n' "$C_BOLD" "$BACKUP_MANAGER_VERSION" "$C_RESET"
        printf '%s       智能服务器备份管理工具%s\n' "$C_CYAN" "$C_RESET"
        printf '%s========================================%s\n\n' "$C_CYAN" "$C_RESET"
        printf '1. 立即执行完整备份\n'
        printf '2. 备份指定项目\n'
        printf '3. 查看备份状态\n\n'
        printf '4. 管理备份项目\n'
        printf '5. 恢复备份\n'
        printf '6. OneDrive 管理\n\n'
        printf '7. 计划任务管理\n'
        printf '8. 查看运行日志\n'
        printf '9. 系统检查\n\n'
        printf '0. 退出\n\n'
        local c; read -r -p '请选择: ' c || return 0
        case "$c" in
            1) cmd_run --interactive || true ;;
            2) _menu_run_project ;;
            3) cmd_status || true ;;
            4) project_menu || true ;;
            5) restore_menu || true ;;
            6) remote_menu || true ;;
            7) schedule_menu || true ;;
            8) cmd_logs 60 || true ;;
            9) cmd_check || true ;;
            0) return 0 ;;
            *) printf '无效选择\n' ;;
        esac
    done
}

_menu_run_project() {
    require_config_for_project_cmds || return $?
    local id; _project_list
    read -r -p '项目 ID: ' id || return 0
    if ! config_project_exists "$id"; then fail "项目不存在: $id"; return 0; fi
    SELECTED_PROJECT="$id" cmd_run --interactive --project "$id" || true
}

project_menu() {
    while :; do
        ui_reset
        printf '\n%s管理备份项目%s\n' "$C_BOLD" "$C_RESET"
        printf '1. 查看项目\n2. 添加项目\n3. 修改项目\n4. 启用项目\n5. 禁用项目\n'
        printf '6. 删除项目\n7. 管理 exclude\n8. 管理 protect\n0. 返回\n'
        local c; read -r -p '请选择: ' c || return 0
        case "$c" in
            1) _project_list ;;
            2) _project_add ;;
            3) _project_edit ;;
            4) _project_toggle "" true ;;
            5) _project_toggle "" false ;;
            6) _project_remove ;;
            7) _project_pathlist "exclude" ;;
            8) _project_pathlist "protect" ;;
            0) return 0 ;;
        esac
    done
}

remote_menu() {
    while :; do
        ui_reset
        printf '\n%sOneDrive 管理%s\n' "$C_BOLD" "$C_RESET"
        printf '1. 查看容量\n2. 测试连接\n3. 查看备份日期/run\n4. 校验指定 run\n5. 预览清理\n6. 清理过期 legacy 备份\n0. 返回\n'
        local c; read -r -p '请选择: ' c || return 0
        case "$c" in
            1) cmd_remote status ;;
            2) cmd_remote status ;;
            3) cmd_remote list ;;
            4) read -r -p 'date (YYYY-MM-DD): ' d || continue; read -r -p 'run_id: ' r || continue; cmd_remote verify --date "$d" --run "$r" ;;
            5) _remote_preview_cleanup ;;
            6) cmd_remote purge --legacy-expired ;;
            0) return 0 ;;
        esac
    done
}

_remote_preview_cleanup() {
    require_config_for_project_cmds || return 0
    printf '远端清理预览:\n'
    local cutoff; cutoff="$(date -d "-${GLOBAL[remote_retention_days]} days" +%Y-%m-%d)"
    printf '  retention 截止: %s (早于此日期的快照将在下次成功备份后清理)\n' "$cutoff"
    printf '  最少保留成功快照: %s\n' "${GLOBAL[min_remote_success_backups]}"
    printf '  旧扁平目录清理: %s\n' "$([[ "${GLOBAL[cleanup_legacy]:-false}" == "true" ]] && echo 启用 || echo 保留)"
    local date run
    while IFS= read -r date; do
        [[ -z "$date" ]] && continue
        if remote_is_legacy_date "$date"; then
            if [[ "${GLOBAL[cleanup_legacy]:-false}" == "true" && "$date" < "$cutoff" ]]; then
                printf '  [将清理] %s (legacy)\n' "$date"
            else
                printf '  [保留]   %s (legacy)\n' "$date"
            fi
            continue
        fi
        while IFS= read -r run; do
            [[ -z "$run" ]] && continue
            remote_run_has_marker "$date" "$run" "RUN_COMPLETE" || continue
            if [[ "$date" < "$cutoff" ]]; then printf '  [将清理] %s/%s\n' "$date" "$run";
            else printf '  [保留]   %s/%s\n' "$date" "$run"; fi
        done < <(remote_list_runs "$date")
    done < <(remote_list_dates)
}

# =============================================================================
# 帮助 / 版本
# =============================================================================

print_version() { printf '%s %s\n' "$BACKUP_MANAGER_NAME" "$BACKUP_MANAGER_VERSION"; }

print_help() {
    cat <<EOF
$BACKUP_MANAGER_NAME $BACKUP_MANAGER_VERSION — 智能服务器备份管理工具

用法: backupctl [命令] [选项]

命令:
  (无参数)                打开交互管理界面 (需要 TTY)
  help                    显示帮助
  --version               显示版本
  init                    初始化配置与目录
  run [--automatic|--dry-run] [--project ID]
                          执行备份
  status                  查看备份状态
  check                   系统检查 (doctor)
  project list|add|edit|enable|disable|remove|exclude|protect
  restore [--local|--remote] [--run R] [--date D] [--project ID]
  restore --rollback | --history | --list
  remote status|list|verify|purge [--legacy <date>|--legacy-expired]
  schedule install|modify|status|run|remove
  logs [行数]             查看最近日志
  config rollback|show

退出码: 0 SUCCESS 1 GENERAL 2 CONFIG 3 BACKUP 4 UPLOAD 5 VERIFY
        6 CAPACITY 7 HOOK 8 LOCKED 9 RESTORE 10 MAINTENANCE
EOF
}

# =============================================================================
# CLI Router
# =============================================================================

main() {
    bm_colors_init
    local cmd="${1:-}"
    shift || true

    case "$cmd" in
        "" )
            ensure_dirs
            if [[ -t 0 && -t 1 ]]; then
                main_menu
                return 0
            else
                print_help
                return 0
            fi ;;
        help|-h|--help) print_help; return 0 ;;
        --version|-V|version) print_version; return 0 ;;
        init) cmd_init; return $? ;;
        run) cmd_run "$@"; return $? ;;
        status) cmd_status; return $? ;;
        check) cmd_check; return $? ;;
        project) cmd_project "$@"; return $? ;;
        restore) cmd_restore "$@"; return $? ;;
        remote) cmd_remote "$@"; return $? ;;
        schedule) cmd_schedule "$@"; return $? ;;
        logs) cmd_logs "${1:-40}"; return $? ;;
        config) cmd_config "$@"; return $? ;;
        *) fail "未知命令: $cmd"; print_help; return "$E_GENERAL" ;;
    esac
}

main "$@"

