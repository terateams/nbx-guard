# nbx-guard — 面向开发者的友好安装。
#
# 最常用：
#   make install          # 编译最新二进制 → 装到 PATH → 安装技能目录
#   make uninstall        # 移除已安装的二进制与技能目录（保留 ~/.nbx-guard 数据）
#   make                  # 显示全部可用目标
#
# 可用变量覆盖默认值（与 scripts/install.sh 的约定保持一致）：
#   PREFIX     安装前缀，默认 ~/.local        （二进制软链到 $(PREFIX)/bin）
#   BINDIR     PATH 上的目录，默认 $(PREFIX)/bin
#   SKILLS_DIR 技能根目录，默认 ~/.agents/skills（装到 <此目录>/nbx-guard/）
#   CONFIG_DIR 算子配置目录，默认 ~/.nbx-guard
#   OPTIMIZE   Zig 优化模式，默认 ReleaseSafe
#   ZIG        zig 可执行文件，默认 zig
# 例：make install PREFIX=/usr/local SKILLS_DIR=~/skills OPTIMIZE=ReleaseFast

ZIG        ?= zig
OPTIMIZE   ?= ReleaseSafe

PREFIX     ?= $(HOME)/.local
BINDIR     ?= $(PREFIX)/bin
SKILLS_DIR ?= $(HOME)/.agents/skills
CONFIG_DIR ?= $(HOME)/.nbx-guard
DESTDIR    ?=

BIN        := nbxg
SKILL_NAME := nbx-guard
SKILL_SRC  := skills/$(SKILL_NAME)
BUILT_BIN  := zig-out/bin/$(BIN)

SKILL_DST  := $(DESTDIR)$(SKILLS_DIR)/$(SKILL_NAME)
BIN_DST    := $(DESTDIR)$(BINDIR)/$(BIN)

.DEFAULT_GOAL := help

.PHONY: all build test fmt fmt-check run install install-skill install-bin install-config uninstall clean version help

all: build ## 仅编译（等同 build）

build: ## 编译 nbxg（默认 ReleaseSafe），产物在 zig-out/bin/nbxg
	$(ZIG) build -Doptimize=$(OPTIMIZE)

test: ## 运行单元测试
	$(ZIG) build test --summary all

fmt: ## 格式化 build.zig 与 src/
	$(ZIG) fmt build.zig src

fmt-check: ## 仅检查格式（与 CI 一致，不通过即失败）
	$(ZIG) fmt --check build.zig src

run: build ## 构建并运行（make run ARGS="version"）
	./$(BUILT_BIN) $(ARGS)

install: build install-skill install-bin install-config ## 编译最新二进制 → 装到 PATH → 安装技能目录
	@printf '\n'
	@if "$(SKILL_DST)/$(BIN)" version >/dev/null 2>&1; then \
	  printf '✅ 已安装二进制：%s  →  %s/%s\n' "$(BIN_DST)" "$(SKILLS_DIR)/$(SKILL_NAME)" "$(BIN)"; \
	else \
	  printf '⚠️  安装后自检失败（%s version）\n' "$(BIN_DST)"; \
	fi
	@printf '✅ 技能目录：%s\n' "$(SKILL_DST)"
	@case ":$$PATH:" in \
	  *":$(BINDIR):"*) printf '✅ %s 已在 PATH，可直接运行：nbxg --help\n' "$(BINDIR)" ;; \
	  *) printf '⚠️  %s 不在 PATH，请加入：export PATH="%s:$$PATH"\n' "$(BINDIR)" "$(BINDIR)" ;; \
	esac
	@printf 'ℹ️  把技能告知你的 Agent：%s/SKILL.md\n' "$(SKILL_DST)"

install-skill: build ## 安装技能目录（真实二进制 + SKILL.md + README + 默认配置模板）
	@install -d "$(SKILL_DST)"
	@install -m 0755 "$(BUILT_BIN)" "$(SKILL_DST)/$(BIN)"
	@install -m 0644 "$(SKILL_SRC)/SKILL.md" "$(SKILL_DST)/SKILL.md"
	@install -m 0644 "$(SKILL_SRC)/config.default.json" "$(SKILL_DST)/config.default.json"
	@if [ -d "$(SKILL_SRC)/examples" ]; then \
	  install -d "$(SKILL_DST)/examples"; \
	  install -m 0644 "$(SKILL_SRC)/examples/"*.md "$(SKILL_DST)/examples/"; \
	fi
	@[ -f README.md ] && install -m 0644 README.md "$(SKILL_DST)/README.md" || true
	@printf '✅ 技能文件已就位：%s\n' "$(SKILL_DST)"

install-bin: install-skill ## 在 PATH（默认 ~/.local/bin）建指向技能目录二进制的软链接
	@install -d "$(DESTDIR)$(BINDIR)"
	@ln -sf "$(SKILLS_DIR)/$(SKILL_NAME)/$(BIN)" "$(BIN_DST)"
	@printf '✅ 已软链到 PATH：%s\n' "$(BIN_DST)"

install-config: ## 部署默认算子配置到 ~/.nbx-guard/config.json（绝不覆盖既有）
	@install -d "$(DESTDIR)$(CONFIG_DIR)"
	@if [ ! -f "$(DESTDIR)$(CONFIG_DIR)/config.json" ]; then \
	  install -m 0644 "$(SKILL_SRC)/config.default.json" "$(DESTDIR)$(CONFIG_DIR)/config.json"; \
	  printf '✅ 已写入默认算子配置：%s/config.json（开箱即可查询全部 NetBox 资源类型）\n' "$(CONFIG_DIR)"; \
	else \
	  install -m 0644 "$(SKILL_SRC)/config.default.json" "$(DESTDIR)$(CONFIG_DIR)/config.json.default"; \
	  printf 'ℹ️  保留既有配置：%s/config.json（最新默认另存为 config.json.default）\n' "$(CONFIG_DIR)"; \
	fi

uninstall: ## 移除已安装的二进制与技能目录（保留 ~/.nbx-guard 用户数据）
	@rm -f "$(BIN_DST)"
	@rm -rf "$(SKILL_DST)"
	@printf '✅ 已移除：%s 与 %s\n' "$(BIN_DST)" "$(SKILL_DST)"
	@printf 'ℹ️  保留用户数据/审计：%s（如需彻底清理请手动删除）\n' "$(CONFIG_DIR)"

clean: ## 清理构建产物（zig-out、.zig-cache）
	@rm -rf zig-out .zig-cache
	@printf '✅ 已清理 zig-out 与 .zig-cache\n'

version: ## 显示源码版本（取自 build.zig.zon）
	@grep -E '\.version = ' build.zig.zon | sed -E 's/.*"([^"]+)".*/\1/'

help: ## 显示本帮助
	@printf 'nbx-guard — 可用的 make 目标：\n'
	@awk 'BEGIN{FS=":.*## "} /^[a-zA-Z0-9_-]+:.*## /{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)
	@printf '\n变量覆盖示例：make install PREFIX=/usr/local SKILLS_DIR=~/skills\n'
