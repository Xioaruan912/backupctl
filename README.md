# backupctl

**Backup Manager** —— 纯 Bash 编写、以数据安全为先的无人值守服务器备份工具。

[![CI](https://github.com/Xioaruan912/backupctl/actions/workflows/ci.yml/badge.svg)](https://github.com/Xioaruan912/backupctl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/shellcheck-passing-brightgreen.svg)](https://www.shellcheck.net/)
[![Bash](https://img.shields.io/badge/bash-%3E%3D%204.4-blue.svg)](https://www.gnu.org/software/bash/)
[![Platform](https://img.shields.io/badge/platform-linux-lightgrey.svg)](#运行要求)

它把目录打包成经过校验的 `tar.gz`，用 `rclone` 上传到 OneDrive，验证之后
再清理旧快照。更重要的是它知道什么时候该停手：备份失败时不会删除健康的历史
备份，不会把写了一半的归档当成有效备份，也不会悄悄丢掉包含数据库、密钥或你
明确保护的文件。

> **设计优先级：** 数据安全 > 可恢复性 > 可靠性 > 简单性 > 性能 > UI。

---

## 目录

- [为什么用它](#为什么用它)
- [功能特性](#功能特性)
- [运行要求](#运行要求)
- [安装](#安装)
- [快速开始](#快速开始)
- [命令](#命令)
- [配置](#配置)
- [启发式](#启发式)
- [一次备份的过程](#一次备份的过程)
- [恢复](#恢复)
- [计划任务](#计划任务)
- [退出码](#退出码)
- [安全](#安全)
- [开发](#开发)
- [文档](#文档)
- [参与贡献](#参与贡献)
- [许可证](#许可证)

---

## 为什么用它

很多"简单"的备份脚本是悄悄出问题的：cron 任务一直无限重试，`tar` 中途挂掉
但文件看起来正常，云盘被塞满，等你想恢复时才发现只剩下损坏的备份。
Backup Manager 建立在相反的直觉上：

- **拿不准某个目录要不要排除时，就备份它。**
- **新备份不健康时，保留旧的。**
- **目标空间不够时，直接停下——不要传一半。**
- **为了备份停掉的服务，一定要重新拉起来。**

## 功能特性

- **纯 Bash 核心**，单文件，不需要 Python / jq / 数据库，只要有 Bash >= 4.4
  的 GNU 环境即可运行。
- **安全配置解析**：`backup.conf` 永远不被 `source`，只当作惰性数据解析，
  `$()`、反引号、`${}` 都保持字面含义。
- **原子且经过校验的归档**：`.partial` → `tar` → 可读性校验 → SHA256 →
  原子重命名。写了一半的归档永远不可能被当成有效备份。
- **一定有保障的钩子**：失败、`SIGINT`、`SIGTERM` 时 `backup_post_hook`
  依然会执行，被停掉的服务总能重新启动。
- **启发式容量管理**：能识别 `downloads`、`dl`、各类缓存等可重新下载的大目录，
  并且**只在远端真的存在容量压力**、且目录内没有数据库、密钥、`.env` 时才自动
  排除。
- **安全保留策略**：始终保留至少 N 个成功快照，只清理已过期的，PARTIAL 运行
  完全跳过清理。
- **通过 rclone 支持 OneDrive**：容量检查、`rclone check` 校验，以及
  `RUN_COMPLETE` / `RUN_PARTIAL` 标记。
- **可回滚的恢复**：本地或远端恢复，SHA256 校验，`before-restore` 备份，
  失败自动回滚，并记录恢复历史。
- **为无人值守而设计**：`backupctl run --automatic` 绝不询问；带
  `Persistent=true` 的 systemd timer 能在重启后补跑错过的任务。
- **Manifest 与状态**：每次运行都会写入 `manifest.conf`、`manifest.sha256`、
  `summary.txt`、`last-run.conf`、`last-success.conf`。
- **兼容旧备份**：能识别老的扁平备份目录并加以保护，升级时绝不误删。
- **有测试覆盖**：100 多条断言，使用 fake rclone，不触碰真实远端或 systemd。

## 运行要求

- Linux + GNU coreutils
- Bash >= 4.4
- `tar`、`gzip`、`sha256sum`、`du`、`df`、`stat`、`find`、`grep`、`sed`、
  `awk`、`flock`、`timeout`、`base64`
- `rclone`（用于 OneDrive 上传 / 恢复）
- `systemd`（用于计划任务）
- `shellcheck`（仅开发时使用）

## 安装

```bash
git clone https://github.com/Xioaruan912/backupctl.git
cd backupctl
sudo bash install.sh --init
```

安装器会把程序复制到 `/root/backup-manager`，创建运行期目录，链接
`/usr/local/bin/backupctl`，并在带 `--init` 时生成默认 `backup.conf`。

选项：

```
--dest DIR      安装目录       (默认 /root/backup-manager)
--bin-dir DIR   命令目录       (默认 /usr/local/bin)
--init          配置不存在时自动执行 backupctl init
--force         覆盖已有的 backup.sh（会保留 .bak 备份）
```

检查：

```bash
backupctl check
```

## 快速开始

```bash
backupctl                 # 交互菜单（需要 TTY）
backupctl check           # 系统检查
backupctl run --dry-run   # 完整预演，不做任何修改
backupctl run             # 立即备份
backupctl schedule install 03:30
```

`--dry-run` 输出示例：

```
[example-app] 绝对路径: /opt/example-app  预计大小: 9.20 GiB
  downloads                       8.80 GiB  score=90  HIGH
  data                            12.30 MiB  score=0   NORMAL  [保护: app.db]

决策预览
  WARN 远端容量压力: 预计备份 9,879,879,879 字节 > 安全可用 1,073,741,824 字节
  WARN 预计自动排除: example-app/downloads size=8.80 GiB score=90
Dry-run 完成 (未做任何修改)。
```

## 命令

```
backupctl                     交互菜单
backupctl help | --version
backupctl init                创建 backup.conf 和目录
backupctl run [--automatic|--dry-run] [--project ID]
backupctl status
backupctl check
backupctl project list|add|edit|enable|disable|remove|exclude|protect
backupctl restore [--local|--remote] [--run R] [--date D] [--project ID]
backupctl restore --rollback | --history | --list
backupctl remote status|list|verify|purge [--legacy <date>|--legacy-expired]
backupctl schedule install|modify|status|run|remove
backupctl logs [行数]
backupctl config rollback|show
```

非交互环境下不会阻塞：没有 TTY 时，直接执行 `backupctl` 会打印帮助后退出。

## 配置

`/root/backup-manager/backup.conf` 使用 INI 风格格式，只被解析、不被执行，
权限必须是 `root:600`。

```ini
[global]
backup_dir=/root/backup/backup
onedrive_remote=onedrive:backup
local_retention_days=7
remote_retention_days=4
min_local_success_backups=2
min_remote_success_backups=2
heuristic_mode=smart
onedrive_reserved_space_gb=2
cleanup_legacy=false

[project:example-app]
name=Example App
enabled=true
type=dir
source=/opt/example-app
heuristic=true
exclude=downloads
backup_pre_hook=
backup_post_hook=
```

全部字段与钩子环境变量见 [docs/CONFIGURATION.md](docs/CONFIGURATION.md)。

## 启发式

启发式会给候选子目录打分（大小、在项目中的占比、名称特征、抽样文件类型），
只有在**同时满足五个条件**时才自动排除：分数超过阈值、没有硬保护、远端确实
存在容量压力、排除它确实能缓解压力、用户没有 `protect`。目录名字本身永远不
会单独触发排除。

详见 [docs/HEURISTICS.md](docs/HEURISTICS.md)。

## 一次备份的过程

```
检查 → 加锁 → 建 run 目录 → 容量检查 → 启发式
  → 逐项目: pre 钩子 → tar.partial → 完整性校验 → sha256 → 重命名 → post 钩子
  → 自身元数据备份 → manifest + summary
  → 二次容量检查 → 上传 → rclone check → 写入标记
  → (仅完整成功) 更新 last-success + 清理 → last-run → 退出码
```

细节见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)。

## 恢复

```bash
backupctl restore --list
backupctl restore --local  --run 20260916-030001 --project example-app
backupctl restore --remote --date 2026-09-16 --run 20260916-030001 --project example-app
backupctl restore --rollback
```

每次恢复都会先校验 SHA256 和归档完整性，把现有目标重命名为
`*.before-restore-*`，并记录操作历史。详见 [docs/RESTORE.md](docs/RESTORE.md)。

## 计划任务

```bash
backupctl schedule install 03:30
backupctl schedule modify 04:15
backupctl schedule status
backupctl schedule run
backupctl schedule remove
```

timer 使用 `Persistent=true`，服务器关机期间错过的运行会在开机后补跑。

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
| 8 | 已加锁（有任务正在运行） |
| 9 | 恢复错误 |
| 10 | 维护错误（备份成功但有警告） |

## 安全

- 配置是惰性数据；只有四个钩子字段会执行命令，且通过
  `bash -o pipefail -c` 并受 `timeout` 限制。
- `umask 077`；所有递归删除都经过 `safe_remove_tree`。
- `tar --one-file-system` 与 `du -x` 不会跨越文件系统。
- 默认拒绝符号链接来源。
- `flock` 保证同一时刻只有一个备份/恢复任务。

漏洞请私下报告，见 [SECURITY.md](SECURITY.md)。

## 开发

```bash
make check     # bash -n + shellcheck
make test      # 全部测试（fake rclone，不触碰真实远端）
make dist      # 生成发布压缩包
```

测试位于 [tests/](tests/)，运行在 `/tmp/bm-tests` 内，绝不触碰真实数据。
详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 文档

- [配置](docs/CONFIGURATION.md)
- [启发式](docs/HEURISTICS.md)
- [架构](docs/ARCHITECTURE.md)
- [恢复](docs/RESTORE.md)
- [故障排查](docs/TROUBLESHOOTING.md)
- [AI 二次开发](AGENTS.md)
- [更新日志](CHANGELOG.md)

## 参与贡献

欢迎贡献。请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md) 和
[行为准则](CODE_OF_CONDUCT.md)。

## 许可证

[MIT](LICENSE) © Backup Manager contributors
