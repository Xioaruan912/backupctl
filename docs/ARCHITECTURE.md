# 架构

Backup Manager 是一个 Bash 程序加上数据与测试。运行时核心刻意保持单文件
（`backup.sh`），这样复制到任何服务器都能直接用，无需构建。

## 目录布局

```
/root/backup-manager/
├── backup.sh              单文件核心
├── backup.conf            root:600
├── backup.conf.bak        上一份配置
├── logs/                  backup-YYYYMMDD-HHMMSS.log
├── state/
│   ├── last-run.conf      最近一次运行摘要
│   ├── last-success.conf  最近一次完整校验通过
│   └── heuristics.conf    启发式历史
├── cache/                 每次运行的临时文件
└── restore-history/       restore-YYYYMMDD-HHMMSS.conf

/usr/local/bin/backupctl -> /root/backup-manager/backup.sh

/root/backup/backup/YYYY-MM-DD/RUN_ID/          本地
onedrive:backup/YYYY-MM-DD/RUN_ID/              远端
```

## run 目录

每次运行会生成：

```
manifest.conf      元数据 + 各项目结果
manifest.sha256    兼容 sha256sum -c
summary.txt        人类可读摘要
<project>-<RUN_ID>.tar.gz
backup-manager-meta-<RUN_ID>.tar.gz   自身备份
RUN_COMPLETE | RUN_PARTIAL            标记（远端，本地也有）
```

## `backupctl run` 的生命周期

1. root / 依赖 / 配置检查，`umask 077`
2. 获取 `flock /run/lock/backup-manager.lock`
3. 创建 run 目录与工作目录
4. 查询远端容量（`rclone about`）
5. 启发式扫描 + 容量感知决策
6. 按顺序逐个项目：
   - 源预检（缺失/符号链接/不可读 => 永久失败）
   - `backup_pre_hook`
   - `tar` 写入 `.partial` → 完整性校验 → SHA256 → 原子重命名（带重试）
   - `backup_post_hook`（由 trap 保证执行）
7. 自身元数据备份
8. 写入 `manifest.conf`、`manifest.sha256`、`summary.txt`
9. 二次容量检查；仅在需要时做安全预清理
10. `rclone copy` → `rclone check` → 写入标记
11. 完整成功时：更新 `last-success`，执行保留清理
12. 写入 `last-run.conf`，打印摘要，返回稳定退出码

## 安全不变量

- 失败或部分失败的运行绝不删除健康历史，也绝不更新 `last-success`。
- 只有 `tar -tzf` 和 SHA256 都成功，本地归档才算有效。
- 配置是惰性数据；只有钩子字段会执行。
- 所有递归删除都经过 `safe_remove_tree`。
- 同一时刻只允许一个备份/恢复运行（`flock`）。

## 信号

`INT` 和 `TERM` 会触发安全收尾：执行待完成的 `backup_post_hook`，清理临时
文件，释放锁。trap 绝不会删除已验证的归档或历史快照。

## 代码分区

`backup.sh` 按以下顺序组织：常量、全局、工具、日志、安全、配置、状态、锁、
项目、钩子、启发式、备份、Manifest、OneDrive、清理、恢复、systemd、交互
界面、CLI 路由、主流程。

## 退出码

| 码 | 含义 |
|----|------|
| 0 | 成功 |
| 1 | 一般错误 |
| 2 | 配置错误 |
| 3 | 备份错误（部分失败） |
| 4 | 远端上传错误 |
| 5 | 远端校验错误 |
| 6 | 容量错误 |
| 7 | 钩子错误 |
| 8 | 已加锁 |
| 9 | 恢复错误 |
| 10 | 维护错误（备份成功但有警告） |
