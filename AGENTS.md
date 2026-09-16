# AGENTS.md

给使用 AI 进行二次开发的协作者的说明。人类开发者同样适用。

本文件遵循 [AGENTS.md](https://agents.md) 约定：把仓库结构、约定和禁区写清楚，
让 AI 编码助手（opencode、Cursor、Claude Code、Codex 等）能安全地继续开发。

---

## 项目是什么

Backup Manager 是一个**单文件 Bash** 的服务器备份管理工具。
核心只做四件事，并且顺序不能变：

1. 把一个目录/文件打包成经过校验的 `tar.gz`；
2. 上传到 OneDrive（rclone）并做远端校验；
3. 在前两者都成功的前提下，安全地清理旧快照；
4. 需要时能可靠地恢复回来。

设计优先级：**数据安全 > 可恢复性 > 可靠性 > 简单性 > 性能 > UI**。

## 不可破坏的安全不变量（最重要的部分）

修改任何代码前，先确认没有违反下面任意一条。违反这些的 PR 会被拒绝：

1. **失败不清理。** 一次失败或 PARTIAL 的运行，绝不删除任何历史健康备份，
   也不更新 `last-success`。
2. **半包无效。** 归档必须先写 `.partial`，通过 `tar -tzf`、算出 SHA256，
   才允许原子 `mv` 成正式文件。
3. **配置是惰性数据。** `backup.conf` 永远不能被 `source`；只有四个 hook
   字段允许执行命令。
4. **删除要过闸。** 任何递归删除必须走 `safe_remove_tree`，它会拒绝空路径、
   `/`、系统目录、管理器根目录、路径穿越和允许范围外的路径。
5. **硬保护优先。** 含数据库/密钥/`.env` 或用户 `protect` 的目录，启发式
   永远不能自动排除。
6. **至少保留 N 个成功快照。** 清理由 `min_local_success_backups` /
   `min_remote_success_backups` 兜底。
7. **POST hook 必须执行。** PRE 成功后无论 backup 成功、失败、
   收到 INT/TERM，都要尝试 POST（靠 trap 保证）。
8. **单实例。** 真正的 backup/restore 只能有一个在跑（`flock`）。
9. **纯 Bash。** 不引入 Python/Node/jq/数据库。标准命令见 README。

## 目录结构

```
backup.sh          运行时核心（单文件，唯一业务逻辑）
backup.conf        配置（root:600，运行时生成，不入库）
tests/             测试套件 + fake rclone
docs/              面向用户的文档
man/backupctl.1    手册页
install.sh         安装器
Makefile           开发命令
AGENTS.md          本文件
```

## backup.sh 的代码分区

保持下列顺序与职责边界，新增逻辑放到对应区块，不要随意跨区调用：

```
Constants / Globals / Utility / Logging / Safety / Config / State / Lock
Project / Hooks / Heuristics / Backup / Manifest / OneDrive / Retention
Restore / Systemd / Interactive UI / CLI Router / Main
```

## 开发约定

- `set -Eeuo pipefail` 全程开启；对“允许失败”的命令必须显式 `if cmd; then`，
  不要靠 `set +e`。
- 所有变量加引号；构造命令用数组，禁止 `eval`。
- **日志走 stderr**（`log_line` 已如此处理），stdout 只放数据。否则会污染
  `$(...)` 命令替换。
- `printf` 的格式串不能以 `-` 开头（会被当参数）；用
  `printf '%s\n' '----'`。
- 不要在 `exec` 那一行追加 `2>/dev/null`，它会永久重定向整个 shell 的 stderr。
- 临时文件放进 `$CACHE_DIR`，并尽量注册到 `TEMP_FILES` 以便收尾清理。
- 日期目录必须是 `YYYY-MM-DD`，run 目录必须是 `YYYYMMDD-HHMMSS`，
  删除前用 `is_valid_date_dir` / `is_valid_run_id` 校验。

## 测试

```bash
make check   # bash -n + shellcheck (warning 级必须 0 告警)
make test    # 全部测试
```

测试通过 `BACKUPCTL_TEST_MODE=1` 运行，所有路径指向 `/tmp/bm-tests/<name>`，
`rclone` 会被 `tests/fakebin/rclone` 替换。**测试绝不允许触碰真实 `/root`、
真实 OneDrive、真实 systemd 或真实业务目录。**

新增功能必须附带测试：在 `tests/` 下加 `tNN_*.sh`，`source tests/lib.sh`，
用 `sandbox_init` 隔离，用 `write_conf` 写配置，用 `assert_*` 断言，
失败时 `exit` 非 0。详见 [tests/README.md](tests/README.md)。

## 常见改动怎么下手

- **新增 CLI 命令**：在 `main()` 里加路由，实现 `cmd_xxx`，在
  `print_help` 补一行；交互菜单按需在 `main_menu` 加项。
- **新增项目类型**：目前只有 `dir` / `file`。在 `validate_config_model`
  的类型白名单、`backup_one_project` 的源检查、`_do_archive` 的打包分支
  三处同步增加，并补测试。
- **新增启发式信号**：改 `heur_score_candidate`（打分）或
  `heur_hard_protect`（保护）。打分只能影响分数，**不能让名称单独触发自动
  排除**；自动排除的五个条件在 `decide_heuristics`，不要绕过。
- **调整保留策略**：只改 `retention_local_cleanup` /
  `retention_remote_cleanup`，并保持“失败不清理、最少 N 个”的不变量。
- **改退出码**：顶部 `E_*` 常量是稳定契约，新增要同时更新
  `README.md`、`docs/ARCHITECTURE.md`、`man/backupctl.1`。
- **改版本号**：同时改 `backup.sh` 的 `BACKUP_MANAGER_VERSION` 和
  `VERSION` 文件（CI 会校验一致性），并在 `CHANGELOG.md` 记录。

## AI 提示词模板

可以直接把下面这段发给 AI 助手：

> 你在维护单文件 Bash 项目 Backup Manager。先读 `AGENTS.md`、
> `docs/ARCHITECTURE.md`，再动手。遵守其中的安全不变量。改动只放在
> `backup.sh` 的对应分区；不要引入新依赖；日志写 stderr。完成后运行
> `make check` 和 `make test`，并为一个新行为新增或更新 `tests/` 用例。
> 如果需求会破坏“失败不清理 / 半包无效 / 硬保护 / 最少保留”中的任何一条，
> 先停下来说明，不要实现。

## 提交

- 一个提交只做一件事；提交信息用简短的祈使句，别写成营销文案。
- 用户可见的改动写进 `CHANGELOG.md` 的 `[Unreleased]`。
- 提交前：`make check && make test` 通过，且没有把密钥、token、真实路径
  或真实数据带进仓库。
