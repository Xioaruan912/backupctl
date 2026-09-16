# 安全策略

## 支持的版本

| 版本 | 是否支持 |
|------|----------|
| 2.x  | 是       |
| < 2.0 | 否      |

## 报告漏洞

请**不要**为安全问题开公开 issue。请通过电子邮件私下报告至
`security@example.com`，并包含：

- 问题的描述及其影响；
- 复现步骤（最好能基于测试套件复现）；
- 相关的配置，**但请移除其中的密钥**。

我们会在 72 小时内确认收到，并争取在 30 天内给出修复或缓解措施。除非你希望
匿名，我们会在更新日志中致谢。

## 安全模型

Backup Manager 基于以下假设与保证设计。

**信任的部分：**

- `root` 和宿主文件系统。
- systemd 服务以 root 身份运行，`UMask=0077`。

**配置被当作惰性数据：**

- `backup.conf` 由专门实现的 INI 解析器处理，**绝不**被 `source`。包含
  `$()`、反引号或 `${}` 的值会按字面保存。
- 唯一会执行任何东西的配置字段是四个钩子字段（`backup_pre_hook`、
  `backup_post_hook`、`restore_pre_hook`、`restore_post_hook`）。钩子通过
  `bash -o pipefail -c` 执行，并受 `timeout` 限制。
- `backup.conf` 必须由 `root` 拥有且权限为 `600`；否则自动任务会拒绝启动。

**破坏性操作：**

- 所有递归删除都经过 `safe_remove_tree`，它会拒绝空路径、`/`、系统级根目录、
  管理器根目录、路径穿越，以及 `backup_dir`、`cache`、`restore-history`
  之外的路径。
- 保留策略不会删到低于 `min_local_success_backups` /
  `min_remote_success_backups`，并且在备份失败或部分失败后完全不执行。
- legacy 备份会被识别并排除在自动清理之外。

**启发式：**

- 自动排除需要同时满足：高分、没有硬保护文件（数据库、密钥、`.env`）、远端
  确实存在容量压力，以及用户没有 `protect`。仅凭目录名字永远不会触发排除。

**备份：**

- 归档先以 `.partial` 创建，通过 `tar -tzf` 校验、计算 SHA256，之后才原子
  重命名。
- `tar --one-file-system` 与 `du -x` 防止跨越文件系统边界。

## 运维加固清单

- 保持 `backup.conf` 为 `root:600`；用 `backupctl config show` 审查改动。
- 为存在运行中数据库的服务配置 `backup_pre_hook`。
- 确保 rclone 配置（`~/.config/rclone/rclone.conf`）仅 root 可读。
- 在后端支持的情况下，优先使用只读或仅追加的远端凭据。
- 监控 `state/last-run.conf` 的 `status` 以及 systemd 单元结果。
