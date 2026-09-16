SHELL      := /bin/bash
VERSION    := $(shell cat VERSION 2>/dev/null || echo 0.0.0)
PREFIX     ?= /root/backup-manager
BIN_DIR    ?= /usr/local/bin
DIST_DIR   := dist
NAME       := backup-manager
SH_FILES   := backup.sh install.sh $(wildcard tests/*.sh) tests/fakebin/rclone

.DEFAULT_GOAL := help

.PHONY: help check lint syntax test install uninstall dist clean version

help: ## 显示帮助
	@printf '\n%s %s\n\n' '$(NAME)' '$(VERSION)'
	@printf '用法: make <目标>\n\n'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

check: syntax lint ## 语法检查 + shellcheck

syntax: ## 对核心脚本执行 bash -n
	@bash -n backup.sh && echo "bash -n: OK"

lint: ## shellcheck 全部脚本（warning 级）
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -S warning $(SH_FILES) && echo "shellcheck: OK"; \
	else \
		echo "未安装 shellcheck，跳过"; \
	fi

test: ## 运行全部测试
	@bash tests/run-all.sh

install: ## 安装到 PREFIX（需要 root）
	@bash install.sh --dest "$(PREFIX)" --bin-dir "$(BIN_DIR)"

uninstall: ## 卸载（保留 backup.conf 与数据）
	@if [[ ! -f "$(PREFIX)/backup.sh" ]]; then echo "未安装在 $(PREFIX)"; exit 1; fi
	@rm -f "$(BIN_DIR)/backupctl"
	@echo "已删除 $(BIN_DIR)/backupctl"
	@echo "已保留 $(PREFIX)（包含配置与数据），如需清除请手动删除。"

dist: ## 在 dist/ 生成发布压缩包
	@mkdir -p $(DIST_DIR)
	@tar --exclude='$(NAME)/$(DIST_DIR)' --exclude='$(NAME)/.git' \
		--exclude='$(NAME)/logs' --exclude='$(NAME)/state' \
		--exclude='$(NAME)/cache' --exclude='$(NAME)/restore-history' \
		--exclude='$(NAME)/backup.conf' --exclude='$(NAME)/*.bak' \
		--exclude='$(NAME)/backup.conf.bak.*' \
		-czf $(DIST_DIR)/$(NAME)-$(VERSION).tar.gz \
		-C .. $(NAME)
	@echo "已生成 $(DIST_DIR)/$(NAME)-$(VERSION).tar.gz"

clean: ## 清理本地测试/构建产物
	@rm -rf $(DIST_DIR) /tmp/bm-tests
	@echo "已清理"

version: ## 打印版本
	@echo $(VERSION)
