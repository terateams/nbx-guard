#!/usr/bin/env bash
#
# nbxg 安装器 —— 把 nbx-guard 技能（SKILL.md）与 nbxg 二进制安装到本机，供 Agent 调用。
#
#   特性：
#     * 自动判断系统类型（OS / 架构）
#     * 询问安装目录（默认 ~/.agents/skills），安装进 <目录>/nbx-guard/
#     * 若目标已存在，询问是否移除并重装
#     * 安装完成后执行 `nbxg --help` 验证
#
#   用法：
#     bash scripts/installer.sh                 # 交互安装（仓库内）
#     NBXG_INSTALL_DIR=~/skills bash scripts/installer.sh   # 预设安装目录
#     NBXG_ASSUME_YES=1 bash scripts/installer.sh           # 非交互：全部用默认/重装
#
#   二进制来源（按优先级自动选择）：
#     1. 与本脚本同目录的 nbxg（发布包内）
#     2. 仓库内已构建的 zig-out/bin/nbxg
#     3. 仓库内用 `zig build` 现场构建（需要 zig）
#     4. 从 GitHub Release 下载匹配的预编译包（私有仓库优先用 gh）
#
set -euo pipefail

REPO_SLUG="terateams/nbx-guard"
SKILL_NAME="nbx-guard"
BIN_NAME="nbxg"
DEFAULT_INSTALL_DIR="$HOME/.agents/skills"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"

# 颜色（非 TTY 时自动关闭）
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s✅ %s%s\n' "$C_OK" "$*" "$C_RST"; }
warn() { printf '%s⚠️  %s%s\n' "$C_WARN" "$*" "$C_RST"; }
die()  { printf '%s❌ %s%s\n' "$C_ERR" "$*" "$C_RST" >&2; exit 1; }

# 是否可交互（无 TTY 或设置 NBXG_ASSUME_YES 时走默认）
ASSUME_YES="${NBXG_ASSUME_YES:-0}"
is_interactive() { [ "$ASSUME_YES" != "1" ] && [ -t 0 ]; }

# ask <提示> <默认值> -> 回显用户输入或默认值
ask() {
  local prompt="$1" default="$2" reply
  if is_interactive; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
    read -r reply || reply=""
    [ -n "$reply" ] && printf '%s' "$reply" || printf '%s' "$default"
  else
    printf '%s' "$default"
  fi
}

# confirm <提示> （默认 yes）-> 0=yes 1=no
confirm() {
  local prompt="$1" reply
  if is_interactive; then
    printf '%s [Y/n]: ' "$prompt" >&2
    read -r reply || reply=""
    case "$reply" in [nN]|[nN][oO]) return 1 ;; *) return 0 ;; esac
  else
    return 0
  fi
}

# --- 1) 判断系统类型 -------------------------------------------------------
detect_platform() {
  local s m
  s="$(uname -s)"; m="$(uname -m)"
  case "$s" in
    Linux)   OS="linux" ;;
    Darwin)  OS="macos" ;;
    MINGW*|MSYS*|CYGWIN*) OS="windows" ;;
    *) die "不支持的操作系统: $s" ;;
  esac
  case "$m" in
    x86_64|amd64)  ARCH="x86_64" ;;
    arm64|aarch64) ARCH="aarch64" ;;
    *) die "不支持的 CPU 架构: $m" ;;
  esac
  EXE=""; [ "$OS" = "windows" ] && EXE=".exe"
  ok "系统：${OS}/${ARCH}"
}

# --- 2) 获取 nbxg 二进制 ---------------------------------------------------
# 成功后设置 SRC_BIN 指向可用的二进制路径。
acquire_binary() {
  # 2.1 发布包：与脚本同目录
  if [ -f "$SELF_DIR/${BIN_NAME}${EXE}" ]; then
    SRC_BIN="$SELF_DIR/${BIN_NAME}${EXE}"
    info "${C_DIM}使用随包二进制：$SRC_BIN${C_RST}"; return
  fi
  # 2.2 仓库内已构建
  if [ -f "$REPO_ROOT/zig-out/bin/${BIN_NAME}${EXE}" ]; then
    SRC_BIN="$REPO_ROOT/zig-out/bin/${BIN_NAME}${EXE}"
    info "${C_DIM}使用已构建二进制：$SRC_BIN${C_RST}"; return
  fi
  # 2.3 仓库内现场构建
  if [ -f "$REPO_ROOT/build.zig" ] && command -v zig >/dev/null 2>&1; then
    info "未找到二进制，使用 zig 现场构建 ..."
    ( cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe )
    SRC_BIN="$REPO_ROOT/zig-out/bin/${BIN_NAME}${EXE}"
    [ -f "$SRC_BIN" ] && { ok "构建完成"; return; }
  fi
  # 2.4 远程下载（私有仓库优先用 gh）
  download_release && return
  die "无法获取 ${BIN_NAME} 二进制：请在仓库内运行（需 zig），或把发布包里的 ${BIN_NAME} 放到脚本同目录。"
}

download_release() {
  local ver asset tmp url
  ver="${NBXG_VERSION:-latest}"
  asset="${BIN_NAME}-VERSION-${ARCH}-${OS}.tar.gz"
  tmp="$(mktemp -d)"
  if command -v gh >/dev/null 2>&1; then
    info "通过 gh 从 Release 下载（${ver}）..."
    local tag="$ver"
    [ "$ver" = "latest" ] && tag="$(gh release view --repo "$REPO_SLUG" --json tagName -q .tagName 2>/dev/null || true)"
    [ -n "$tag" ] || { warn "无法确定最新 Release 标签"; return 1; }
    asset="${BIN_NAME}-${tag}-${ARCH}-${OS}.tar.gz"
    gh release download "$tag" --repo "$REPO_SLUG" --pattern "$asset" --dir "$tmp" 2>/dev/null || {
      warn "gh 下载失败：$asset"; return 1; }
  else
    [ "$ver" = "latest" ] && { warn "未安装 gh，无法解析 latest；请设 NBXG_VERSION=vX.Y.Z"; return 1; }
    asset="${BIN_NAME}-${ver}-${ARCH}-${OS}.tar.gz"
    url="https://github.com/${REPO_SLUG}/releases/download/${ver}/${asset}"
    info "下载 $url ..."
    curl -fsSL "$url" -o "$tmp/$asset" || { warn "curl 下载失败"; return 1; }
  fi
  tar -xzf "$tmp/$asset" -C "$tmp"
  SRC_BIN="$(find "$tmp" -type f -name "${BIN_NAME}${EXE}" | head -1)"
  [ -n "$SRC_BIN" ] && [ -f "$SRC_BIN" ] || { warn "发布包内未找到 ${BIN_NAME}"; return 1; }
  ok "下载完成"
}

# --- 定位 SKILL.md ---------------------------------------------------------
find_skill_md() {
  local c
  for c in "$SELF_DIR/SKILL.md" "$REPO_ROOT/skills/${SKILL_NAME}/SKILL.md"; do
    [ -f "$c" ] && { printf '%s' "$c"; return; }
  done
  die "找不到 SKILL.md（在 $SELF_DIR 或 $REPO_ROOT/skills/${SKILL_NAME}/）"
}

# --- 3) 安装目录与重装确认 -------------------------------------------------
main() {
  info "${C_DIM}nbxg 安装器 · 仓库 ${REPO_SLUG}${C_RST}"
  detect_platform

  local install_root target
  install_root="${NBXG_INSTALL_DIR:-$(ask "请输入安装目录" "$DEFAULT_INSTALL_DIR")}"
  # 展开起始的 ~
  install_root="${install_root/#\~/$HOME}"
  target="$install_root/$SKILL_NAME"

  if [ -e "$target" ]; then
    warn "目标已存在：$target"
    if confirm "是否移除并重新安装？"; then
      rm -rf "$target"
      ok "已移除旧安装"
    else
      die "已取消安装（保留现有目录）。"
    fi
  fi

  acquire_binary
  local skill_md; skill_md="$(find_skill_md)"

  # --- 安装文件 ---
  mkdir -p "$target"
  install -m 0755 "$SRC_BIN" "$target/${BIN_NAME}${EXE}"
  install -m 0644 "$skill_md" "$target/SKILL.md"
  [ -f "$REPO_ROOT/README.md" ] && install -m 0644 "$REPO_ROOT/README.md" "$target/README.md" || true
  install -m 0755 "${BASH_SOURCE[0]}" "$target/installer.sh"
  ok "已安装技能到：$target"

  # --- 尝试把 nbxg 暴露到 PATH（best-effort）---
  local linked=""
  local bindir="$HOME/.local/bin"
  if mkdir -p "$bindir" 2>/dev/null; then
    if ln -sf "$target/${BIN_NAME}${EXE}" "$bindir/${BIN_NAME}${EXE}" 2>/dev/null; then
      linked="$bindir/${BIN_NAME}${EXE}"
    fi
  fi

  local run_bin="$target/${BIN_NAME}${EXE}"
  if [ -n "$linked" ]; then
    ok "已链接到 PATH：$linked"
    case ":$PATH:" in
      *":$bindir:"*) run_bin="${BIN_NAME}" ;;
      *) warn "$bindir 不在 PATH 中；请加入：export PATH=\"$bindir:\$PATH\"" ;;
    esac
  else
    warn "未能写入 ~/.local/bin；可直接使用：$run_bin"
  fi

  # --- 4) 验证：nbxg --help ---
  info ""
  info "${C_DIM}$ ${run_bin} --help${C_RST}"
  "$run_bin" --help || die "运行 ${BIN_NAME} --help 失败"
  info ""
  ok "安装完成。把该技能告知你的 Agent：$target/SKILL.md"
}

main "$@"
