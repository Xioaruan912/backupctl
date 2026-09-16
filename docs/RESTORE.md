# 恢复与回滚

Backup Manager 可以从本地或 OneDrive 恢复。每次恢复都经过校验且可回滚。

## 交互方式

```bash
backupctl
# 5. 恢复备份
#   ├── 从本地选择
#   ├── 从 OneDrive 选择
#   ├── 查看恢复历史
#   └── 回滚最近一次恢复
```

## 非交互方式

```bash
backupctl restore --list
backupctl restore --local  --run 20260916-030001 --project example-app
backupctl restore --remote --date 2026-09-16 --run 20260916-030001 --project example-app
backupctl restore --rollback        # 撤销最近一次恢复
backupctl restore --history         # 列出恢复历史文件
```

## 恢复时会发生什么

1. 校验归档：
   - `sha256sum -c manifest.sha256`（或单个归档的哈希），
   - `tar -tzf` 完整性。
   被拒绝的恢复会记录为 `REJECTED`，目标保持不变。
2. 检查可用磁盘空间。
3. 执行 `restore_pre_hook`。
4. 把现有目标重命名为 `<target>.before-restore-<YYYYMMDD-HHMMSS>`。
5. 把归档解压回原位置。
6. 执行 `restore_post_hook`。
7. 记录 `restore-history/restore-*.conf`。

## 远端恢复

run 目录会先下载到 `cache/` 下的暂存区，然后走同样的校验与解压流程。远端数据
永远不会被修改。

## 失败处理

- **SHA256 / 完整性失败：** 在触碰目标之前就中止恢复。
- **解压失败：** 把解压了一半的数据移到
  `<target>.failed-restore-<ts>`（保留以便排查），再把 `before-restore`
  目录移回原位。
- **POST 钩子失败：** 恢复后的数据和 `before-restore` 目录都会保留；运行以
  `HOOK_ERROR (7)` 退出，情况会记入恢复历史。

旧目录永远不会被自动删除。

## 回滚

```bash
backupctl restore --rollback
```

把当前目标重命名为 `<target>.rolledback-<ts>`，再把 `before-restore` 目录
移回原位。

## 恢复历史

每次恢复都会写入 `restore-history/restore-<YYYYMMDD-HHMMSS>.conf`：

```
time=...
run_id=...
project_id=...
source=...
target=...
rollback_path=...
sha256_status=OK|MISMATCH|VERIFY_FAILED
hook_status=ok|pre_failed|post_failed|none
final_status=SUCCESS|ABORTED|REJECTED|ROLLED_BACK|OK_WITH_HOOK_WARNING
```
