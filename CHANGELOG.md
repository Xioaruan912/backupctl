# 更新日志

本项目所有值得记录的改动都会写在这里。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

## [2.1.0] - 2026-09-16

### 新增

- 全局字段 `cleanup_legacy`（默认 `false`）：开启后，过期的旧版扁平日期目录
  （legacy 备份）会像普通快照一样按保留策略清理，并可用于上传前的容量预清理。
  清理时始终保留至少 1 个快照。
- `backupctl remote purge --legacy <YYYY-MM-DD>` 与 `--legacy-expired`，用于手动
  清理旧扁平备份；`--yes` 支持非交互。
- `ui_reset()`：交互菜单与表单在 TTY 下清屏重绘（`BM_NO_CLEAR=1` 可关闭）。
- `project list` 增加「名称」列，便于确认修改。
- `AGENTS.md`，面向 AI 二次开发的说明文档。

### 变更

- `project edit` / `project add` 改为清屏表单，输入后重绘当前值，不再堆叠滚动
  输出。
- 远端清理预览会区分 legacy 目录的「将清理 / 保留」状态。

### 修复

- 旧扁平备份此前只能永久保留，无法通过 CLI 清理。

## [2.0.0] - 2026-09-16

完整重构。原先那个 `while true` 无限重试的脚本，被一个以安全为先、可无人
值守的备份管理器取代。

### 新增

- 单文件 Bash 核心（`backup.sh`），不依赖 Python / jq / 数据库。
- 安全 INI 配置解析器（绝不 `source`）、严格的字段与类型校验、`root:600`
  权限强制、原子写入与 `config rollback`。
- 项目模型，支持 `dir` 与 `file` 两种类型，以及 `exclude` / `protect`
  相对路径列表。
- 备份引擎：`RUN_ID` 目录、`.partial` → `tar` → 完整性校验 → SHA256 →
  原子重命名，带退避的有限重试。
- 钩子生命周期（`backup_pre` / `backup_post` / `restore_pre` /
  `restore_post`），带 `timeout`，并用 trap 保证 POST 在成功、失败、
  `SIGINT`、`SIGTERM` 下都会执行。
- 每次运行的 `manifest.conf`、`manifest.sha256` 与 `summary.txt`。
- 启发式容量管理：目录打分、文件类型抽样、硬保护（数据库、密钥、`.env`、
  用户 `protect`）以及容量感知的自动排除（五个必要条件）。
- OneDrive + rclone 集成：`rclone about` 容量解析、上传、`rclone check`
  校验，以及 `RUN_COMPLETE` / `RUN_PARTIAL` 标记。
- 安全保留策略，保证最少成功快照数量；失败运行绝不删除历史；legacy 备份受
  保护。
- 本地与 OneDrive 恢复，带 SHA256 校验、`before-restore` 重命名、失败回滚
  和恢复历史。
- systemd timer 管理（安装 / 修改 / 查看 / 执行 / 删除），带
  `Persistent=true`。
- 中文交互 CLI，以及完整的非交互命令集和稳定的退出码。
- `flock` 单实例锁。
- 对管理器自身的元数据备份。
- 带 fake rclone 和 `BACKUPCTL_TEST_MODE=1` 的测试套件。
- 文档、CI 工作流与打包文件。

### 安全

- 配置只作为惰性数据解析；没有 `eval`、命令替换或 shell 展开。
- `umask 077`，受保护的递归删除（`safe_remove_tree`）。
- `tar --one-file-system` 与 `du -x`，避免跨越文件系统。
- 默认拒绝符号链接来源。

[未发布]: https://github.com/Xioaruan912/backupctl/compare/v2.1.0...HEAD
[2.1.0]: https://github.com/Xioaruan912/backupctl/releases/tag/v2.1.0
[2.0.0]: https://github.com/Xioaruan912/backupctl/releases/tag/v2.0.0
