# 配置参考

`backup.conf` 位于安装根目录（默认 `/root/backup-manager/backup.conf`）。
它使用 INI 风格语法，只被**解析，不被执行**。权限必须是 `root:600`。

```bash
backupctl config show       # 打印当前文件
backupctl config rollback   # 从 backup.conf.bak 恢复
```

## 语法规则

- 段名：`[global]` 与 `[project:<id>]`。
- 赋值使用**第一个** `=` 作为分隔符；值可以包含 `=` 和空格。
- 忽略空行。以 `#` 或 `;` 开头的行是注释。
- 不做任何 shell 展开：`$VAR`、`${VAR}`、`$(...)`、反引号都按字面处理。
- 未知字段和非法值都视为配置错误。
- 项目 ID 必须匹配 `^[a-z0-9][a-z0-9._-]{0,63}$`。
- `exclude` / `protect` 接受空格或逗号分隔的相对路径，可以重复出现，值会累加。
- 相对路径不能是绝对路径、不能是 `.`、`..`，也不能包含路径穿越。

## `[global]`

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `backup_dir` | `/root/backup/backup` | 本地备份根目录（绝对路径）。 |
| `onedrive_remote` | `onedrive:backup` | rclone 远端 + 前缀。 |
| `local_retention_days` | `7` | 本地成功快照保留天数，超过则清理。 |
| `remote_retention_days` | `4` | 远端成功快照保留天数。 |
| `partial_retention_days` | `2` | 失败/部分运行及 `.partial` 文件的保留天数。 |
| `min_local_success_backups` | `2` | 本地成功快照的最低保留数量。 |
| `min_remote_success_backups` | `2` | 远端成功快照的最低保留数量。 |
| `retry_count` | `3` | 可恢复错误的最大重试次数。 |
| `retry_delay` | `10` | 重试基础间隔（秒），指数退避。 |
| `heuristic_mode` | `smart` | `smart`（自动）/ `manual`（仅提示）/ `off`。 |
| `heuristic_scan_depth` | `2` | 启发式扫描的目录深度。 |
| `heuristic_auto_exclude_score` | `85` | 自动排除的最低分数。 |
| `onedrive_reserved_space_gb` | `2` | 远端预留空间（GiB）。 |
| `hook_timeout_seconds` | `300` | 每个钩子命令的超时时间。 |
| `log_retention_days` | `30` | 本地日志保留天数。 |
| `cleanup_legacy` | `false` | 是否按保留策略清理旧版扁平日期目录（legacy 备份）。开启后过期即可清理，并可用于容量预清理；始终保留至少 1 个快照。 |

## `[project:<id>]`

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `name` | - | 显示名称（可包含中文）。 |
| `enabled` | `true` | `true` / `false`。 |
| `type` | `dir` | `dir` 或 `file`。 |
| `source` | - | 绝对源路径。备份时拒绝符号链接。 |
| `heuristic` | `true` | 是否为该项目启用启发式分析。 |
| `exclude` | - | 始终排除的相对路径，可重复。 |
| `protect` | - | 永不自动排除的相对路径，可重复。 |
| `backup_pre_hook` | - | 备份前的 shell 命令（可用于停服务）。 |
| `backup_post_hook` | - | 备份后的 shell 命令；即使备份失败也会执行。 |
| `restore_pre_hook` | - | 恢复前的 shell 命令。 |
| `restore_post_hook` | - | 恢复后的 shell 命令。 |

> `protect` 优先级最高：被保护的路径永远不会被启发式自动排除。

## 钩子

钩子是唯一会作为 shell 执行的字段。执行方式：

```bash
timeout "$hook_timeout_seconds" bash -o pipefail -c "$command"
```

暴露的环境变量：

| 变量 | 含义 |
|------|------|
| `BACKUP_PROJECT_ID` | 项目 ID |
| `BACKUP_PROJECT_NAME` | 显示名称 |
| `BACKUP_SOURCE` | 源路径 |
| `BACKUP_RUN_ID` | 当前 run ID |
| `BACKUP_WORK_DIR` | run 工作目录 |
| `BACKUP_PHASE` | `backup_pre`、`backup_post`、`restore_pre`、`restore_post` |

数据库钩子示例：

```ini
backup_pre_hook=sqlite3 /opt/example-app/data/app.db ".backup '/tmp/app.db'"
backup_post_hook=rm -f /tmp/app.db
```

## 示例

```ini
[global]
backup_dir=/root/backup/backup
onedrive_remote=onedrive:backup
local_retention_days=7
remote_retention_days=4
onedrive_reserved_space_gb=2
cleanup_legacy=false

[project:example-app]
name=Example App
enabled=true
type=dir
source=/opt/example-app
heuristic=true
exclude=downloads
```
