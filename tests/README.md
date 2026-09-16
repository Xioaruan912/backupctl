# 测试

运行全部测试：

```bash
make test
# 或
bash tests/run-all.sh
```

每个 `tests/tNN_*.sh` 都是独立的测试文件。`run-all.sh` 会全部执行，只要有文件
失败就以非 0 退出。

## 隔离

每个测试都会调用 `tests/lib.sh` 里的 `sandbox_init <名称>`，它在
`/tmp/bm-tests/<名称>` 下创建一个隔离目录，并导出：

- `BACKUPCTL_TEST_MODE=1`
- `BACKUP_MANAGER_ROOT`
- `BACKUP_MANAGER_LOCK_FILE`
- `FAKE_RCLONE_STATE_DIR`
- `FAKE_FREE_BYTES`、`FAKE_TOTAL_BYTES`

测试绝不触碰真实的 `/root`、真实 OneDrive 或真实 systemd 单元。systemd 操作
会写入 `$BACKUP_MANAGER_ROOT/test-systemd`。

## 伪造 rclone

`tests/fakebin/rclone` 被放在 `PATH` 最前面，基于一个本地目录实现了
`about`、`copy`、`copyto`、`check`、`lsf`、`purge`、`rmdir`、`size`。
行为开关：

| 变量 | 作用 |
|------|------|
| `FAKE_RCLONE_ABOUT_FAIL=1` | `about` 失败 |
| `FAKE_RCLONE_UPLOAD_FAIL=1` | `copy`/`copyto` 失败 |
| `FAKE_RCLONE_CHECK_FAIL=1` | `check` 失败 |
| `FAKE_FREE_BYTES` | 报告的可用字节数 |
| `FAKE_TOTAL_BYTES` | 报告的总字节数 |

## 测试文件

| 文件 | 覆盖范围 |
|------|----------|
| `t01_config.sh` | 配置解析与校验 |
| `t02_lock.sh` | 单实例锁 |
| `t03_backup_hooks.sh` | 备份引擎、钩子、半包归档 |
| `t04_heuristics.sh` | 评分、硬保护、自动排除各场景 |
| `t05_remote.sh` | 上传、校验、容量、标记 |
| `t06_retention.sh` | 本地/远端清理的安全保证 |
| `t07_restore.sh` | 本地/远端恢复、回滚、拒绝 |
| `t08_systemd.sh` | timer 生成与管理 |
| `t09_manifest.sh` | manifest 与 SHA256 |
| `t10_cli.sh` | CLI 行为与非交互模式 |

## 新增测试

新建 `tests/tNN_名称.sh`：

```bash
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

sandbox_init tNN
mkdir -p "$SB_PROJ/data"; echo hi > "$SB_PROJ/data/a.txt"

write_conf <<EOF
[global]
backup_dir=$SB_BACKUP
onedrive_remote=onedrive:backup
heuristic_mode=off
[project:p1]
name=P1
enabled=true
type=dir
source=$SB_PROJ
heuristic=false
EOF

bm_capture run --automatic
assert_rc "$BM_RC" 0 "运行成功"

exit $(( FAIL > 0 ? 1 : 0 ))
```

`lib.sh` 中可用的辅助函数：`assert_eq`、`assert_ne`、`assert_file`、
`assert_not_file`、`assert_dir`、`assert_not_dir`、`assert_contains`、
`assert_not_contains`、`assert_rc`、`bm`、`bm_capture`、`write_conf`。
