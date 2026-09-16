# 故障排查

先执行：

```bash
backupctl check
backupctl status
backupctl logs 80
```

## `backupctl check` 报"无法访问 OneDrive"

- 确认 rclone 可用：`rclone about onedrive:`
- 确认 `onedrive_remote` 里的远端名与 `rclone listremotes` 一致。
- token 过期时重新认证：`rclone config reconnect onedrive:`
- 确保 `~/.config/rclone/rclone.conf` 对 root 可读。

## 退出码 8（已加锁）

已有备份或恢复任务在运行。`backupctl status` 会显示 PID、开始时间和模式。
等它结束即可。如果进程异常退出（锁只是咨询锁，`flock` 会随进程退出自动释放），
检查是否有残留进程。

## 退出码 6（容量错误）

在扣除 `onedrive_reserved_space_gb` 预留后，远端没有足够空间。

- 释放空间：`backupctl remote list`，确认后用
  `backupctl remote purge <date> <run>` 清理旧快照。
- 旧版扁平日期目录（legacy）默认受保护。开启 `cleanup_legacy=true` 后它们会按
  保留策略自动清理，也可手动执行 `backupctl remote purge --legacy <date>` 或
  `backupctl remote purge --legacy-expired`（`--yes` 供非交互）。
- 本地备份会保留；`last-success` 不会更新。

## 远端清理预览显示 `[保留] (legacy)`

旧版扁平日期目录（日期目录下直接是 `*-backup-*.tar.gz`）默认不参与自动清理，
这是「升级不误删旧备份」的保护。若确认不再需要，把 `backupctl config` 里的
`cleanup_legacy` 设为 `true`，或在 OneDrive 管理菜单选择「清理过期 legacy
备份」。容量预清理也会在开启后使用它们腾出空间。

## 退出码 3（部分失败）

至少有一个项目失败。`backupctl status` 会列出 `failed_projects`；run 的
`summary.txt` 和 `manifest.conf` 会说明每个失败原因。成功的归档仍会上传并标
记为 `RUN_PARTIAL`。在出现一次完整成功之前，历史清理会被跳过。

## 退出码 4 / 5（上传/校验错误）

网络或远端问题。本地备份会保留，历史不受影响。稍后重试即可；rclone 的重试
次数是有意做成有限的。

## 某个目录被自动排除，但我不同意

1. 查看决策：`backupctl run --dry-run`。
2. 给项目加 `protect=<相对路径>`（最高优先级）：
   `backupctl project protect <id> add <path>`。
3. 或改用 `heuristic_mode=manual`，或对单个项目关闭启发式。

请记住：自动排除只在远端真的存在容量压力时发生，并且永远不会作用于包含
数据库、密钥或 `.env` 的目录。

## 备份里的数据库不一致

`tar` 无法对运行中的数据库做原子快照。请配置 `backup_pre_hook`，例如：

```ini
backup_pre_hook=sqlite3 /opt/example-app/data/app.db ".backup '/tmp/app.db'"
```

当项目包含 `*.db` / `*.sqlite*` 却没有 `backup_pre_hook` 时，`check` 会警告。

## systemd timer 没有运行

```bash
systemctl status backup-manager.timer
systemctl list-timers backup-manager.timer
journalctl -u backup-manager.service -n 50
```

`Persistent=true` 表示错过的运行会在开机后补跑。用
`backupctl schedule status` 确认排程。

## 升级后想回退

旧脚本已保留（例如 `/root/backup.sh.legacy-<ts>`），上一份配置是
`backup.conf.bak`，旧 crontab 是 `/root/crontab.backup-<ts>`。恢复它们，
必要时删除 `/usr/local/bin/backupctl` 即可。
