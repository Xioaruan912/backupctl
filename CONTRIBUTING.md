# 参与贡献

感谢你愿意改进 Backup Manager。这个项目处理的是别人的数据，所以正确性和
安全性永远优先于功能数量。

## 基本原则

- **数据安全第一。** 拿不准时，多备份、少删除。
- 绝不允许出现"新备份失败后继续删除历史有效备份"的代码路径。
- 绝不让启发式自动丢掉包含数据库、密钥或用户 `protect` 路径的目录。
- 核心保持单文件 Bash（`backup.sh`）。不要引入 Python、Node、jq、数据库等
  重量依赖。
- 不要提交密钥、token、rclone 配置或真实服务器数据。

## 环境要求

- Bash >= 4.4
- `git`
- `shellcheck`（推荐）
- GNU coreutils / tar / gzip / flock

## 开发

```bash
git clone https://github.com/Xioaruan912/backupctl.git
cd backupctl
make check     # bash -n + shellcheck
make test      # 全部测试（使用 fake rclone，不触碰真实 OneDrive）
```

测试全部在 `/tmp/bm-tests` 内以 `BACKUPCTL_TEST_MODE=1` 运行，绝不能碰真实
的 `/root`、真实 OneDrive 或真实 systemd 单元。

## 代码风格

- 全程 `set -Eeuo pipefail`；理解它的坑，对"允许失败"的命令显式写
  `if`。
- 所有变量加引号；构造命令用数组，禁止 `eval`。
- 函数保持小而职责单一。
- 按 `backup.sh` 现有的分区组织代码（常量、日志、安全、配置、状态、锁、
  项目、钩子、启发式、备份、Manifest、OneDrive、清理、恢复、systemd、
  交互界面、CLI 路由、主流程）。
- 每个 bug 修复和每个新行为都要补测试。

## 新增测试

在 `tests/` 下新建 `tests/tNN_*.sh`，`source tests/lib.sh`，然后运行
`bash tests/run-all.sh`。`run-all.sh` 会执行所有 `tests/t*.sh`。

测试必须：

1. 先调用 `sandbox_init <名称>`；
2. 用 `write_conf` 创建隔离的 `backup.conf`；
3. 用 `lib.sh` 里的断言（`assert_eq`、`assert_file` 等）；
4. 失败时以非 0 退出。

## 提交信息

用简短、祈使语气的标题，可选地加作用域：

```
backup: 部分失败时绝不清理历史
heuristics: 降低源码目录的分数
docs: 澄清 OneDrive 预留空间
```

## 使用 AI 助手

`AGENTS.md` 描述了架构、安全不变量和常见改动路径，AI 编码助手可以据此参与
贡献而不破坏数据安全保证。把你的工具指向它，或直接使用该文件末尾的提示词
模板。

## 拉取请求

- 说明问题、所选方案以及对安全性的影响。
- 关联相关 issue。
- 确保 `make check` 和 `make test` 通过。
- 改动尽量聚焦；重构和行为变更分开提交。

## 报告问题

漏洞请见 [SECURITY.md](SECURITY.md)。普通 bug 请使用提供的 issue 模板。
