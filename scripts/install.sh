#!/usr/bin/env bash
#
# nbx-guard 远程一键安装器 —— 无需克隆仓库，一条命令装好 nbxg：
#
#   curl -fsSL https://raw.githubusercontent.com/terateams/nbx-guard/main/scripts/install.sh | bash
#
# 它会从 GitHub Release 下载预编译 nbxg、校验 SHA256，连同技能说明 SKILL.md 一起装到
# ~/.agents/skills/nbx-guard/，软链到 ~/.local/bin，并部署默认配置（绝不覆盖既有配置）。
# 全程非交互，适合直接管道执行；用环境变量定制（全部可选）：
#
#   NBXG_VERSION=v0.9.0      指定版本（默认取 latest）
#   NBXG_INSTALL_DIR=~/x     技能安装根目录（默认 ~/.agents/skills）
#   NBXG_BINDIR=~/bin        PATH 软链目录（默认 ~/.local/bin）
#
set -euo pipefail

REPO_SLUG="terateams/nbx-guard"
BIN_NAME="nbxg"
SKILL_NAME="nbx-guard"
INSTALL_ROOT="${NBXG_INSTALL_DIR:-$HOME/.agents/skills}"
BINDIR="${NBXG_BINDIR:-$HOME/.local/bin}"
INSTALL_ROOT="${INSTALL_ROOT/#\~/$HOME}"
BINDIR="${BINDIR/#\~/$HOME}"

# 颜色（非 TTY 自动关闭）
if [ -t 1 ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""
fi
info() { printf '%s\n' "$*"; }
ok()   { printf '%s✅ %s%s\n' "$C_OK" "$*" "$C_RST"; }
warn() { printf '%s⚠️  %s%s\n' "$C_WARN" "$*" "$C_RST"; }
die()  { printf '%s❌ %s%s\n' "$C_ERR" "$*" "$C_RST" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

fetch() { # fetch <url> <out-file>
  if have curl; then curl -fsSL "$1" -o "$2"
  elif have wget; then wget -qO "$2" "$1"
  else die "需要 curl 或 wget"; fi
}
fetch_stdout() { # fetch_stdout <url>
  if have curl; then curl -fsSL "$1"
  elif have wget; then wget -qO- "$1"
  else die "需要 curl 或 wget"; fi
}

# --- 1) 识别平台 ----------------------------------------------------------
detect_platform() {
  local s m; s="$(uname -s)"; m="$(uname -m)"
  case "$s" in
    Linux)  OS="linux" ;;
    Darwin) OS="macos" ;;
    MINGW*|MSYS*|CYGWIN*)
      die "Windows 暂不支持管道安装：请到 Release 页面下载 *-windows.zip 手动解压到 PATH" ;;
    *) die "不支持的系统: $s" ;;
  esac
  case "$m" in
    x86_64|amd64)  ARCH="x86_64" ;;
    arm64|aarch64) ARCH="aarch64" ;;
    *) die "不支持的 CPU 架构: $m" ;;
  esac
  ok "系统：${OS}/${ARCH}"
}

# --- 2) 解析版本 ----------------------------------------------------------
resolve_version() {
  if [ -n "${NBXG_VERSION:-}" ]; then TAG="$NBXG_VERSION"; return; fi
  info "${C_DIM}解析最新版本 ...${C_RST}"
  TAG="$(fetch_stdout "https://api.github.com/repos/${REPO_SLUG}/releases/latest" \
        | grep -m1 '"tag_name"' \
        | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')"
  [ -n "$TAG" ] || die "无法解析最新版本；请设 NBXG_VERSION=vX.Y.Z 重试"
}

# --- 临时目录与清理 -------------------------------------------------------
TMP=""
cleanup() { [ -n "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true; }
trap cleanup EXIT

# --- 3) 下载并校验二进制 --------------------------------------------------
acquire_binary() {
  TMP="$(mktemp -d)"
  local asset="${BIN_NAME}-${TAG}-${ARCH}-${OS}.tar.gz"
  local base="https://github.com/${REPO_SLUG}/releases/download/${TAG}"
  info "${C_DIM}下载 ${asset} ...${C_RST}"
  fetch "${base}/${asset}" "${TMP}/${asset}" || die "下载失败：${base}/${asset}"

  # SHA256 校验（尽力而为：缺校验和或工具则告警跳过，但下载失败必须中止）
  if fetch "${base}/SHA256SUMS" "${TMP}/SHA256SUMS" 2>/dev/null; then
    local want got
    want="$(grep "$asset" "${TMP}/SHA256SUMS" | head -1 | awk '{print $1}')"
    if [ -n "$want" ]; then
      if have sha256sum; then got="$(sha256sum "${TMP}/${asset}" | awk '{print $1}')"
      elif have shasum; then got="$(shasum -a 256 "${TMP}/${asset}" | awk '{print $1}')"
      else got=""; fi
      if [ -n "$got" ]; then
        if [ "$want" = "$got" ]; then
          ok "SHA256 校验通过"
        else
          die "SHA256 校验失败（期望 ${want}，实得 ${got}）"
        fi
      else
        warn "未找到 sha256 工具，跳过校验"
      fi
    fi
  else
    warn "未取到 SHA256SUMS，跳过校验"
  fi

  tar -xzf "${TMP}/${asset}" -C "${TMP}"
  SRC_BIN="$(find "${TMP}" -type f -name "${BIN_NAME}" | head -1)"
  [ -n "$SRC_BIN" ] && [ -f "$SRC_BIN" ] || die "发布包内未找到 ${BIN_NAME}"
}

# --- 4) 下载技能文件 ------------------------------------------------------
acquire_skill() {
  local raw="https://raw.githubusercontent.com/${REPO_SLUG}/${TAG}/skills/${SKILL_NAME}"
  fetch "${raw}/SKILL.md" "${TMP}/SKILL.md" || die "下载 SKILL.md 失败"
  fetch "${raw}/config.default.json" "${TMP}/config.default.json" 2>/dev/null || true

  # 案例目录（best-effort）：无 jq，从 contents API 抓每个文件的 download_url 再逐个下载。
  # 整条管道用 || true 兜底——老 tag 没有 examples/ 时 grep 无匹配（退出 1）不应中断安装。
  mkdir -p "${TMP}/examples"
  { fetch_stdout "https://api.github.com/repos/${REPO_SLUG}/contents/skills/${SKILL_NAME}/examples?ref=${TAG}" 2>/dev/null \
    | grep -oE '"download_url"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"(https[^"]+)".*/\1/' \
    | while read -r url; do
        [ -n "$url" ] || continue
        fetch "$url" "${TMP}/examples/$(basename "$url")" 2>/dev/null || true
      done ; } || true
}

# --- 5) 安装到本机 --------------------------------------------------------
install_all() {
  local target="${INSTALL_ROOT}/${SKILL_NAME}"
  mkdir -p "$target"
  install -m 0755 "$SRC_BIN" "${target}/${BIN_NAME}"
  install -m 0644 "${TMP}/SKILL.md" "${target}/SKILL.md"
  [ -f "${TMP}/config.default.json" ] && install -m 0644 "${TMP}/config.default.json" "${target}/config.default.json"
  if [ -d "${TMP}/examples" ] && ls "${TMP}/examples/"*.md >/dev/null 2>&1; then
    mkdir -p "${target}/examples"
    install -m 0644 "${TMP}/examples/"*.md "${target}/examples/" 2>/dev/null || true
  fi
  ok "已安装技能到：${target}"

  # 软链进 PATH（best-effort）
  RUN_BIN="${target}/${BIN_NAME}"
  if mkdir -p "$BINDIR" 2>/dev/null && ln -sf "${target}/${BIN_NAME}" "${BINDIR}/${BIN_NAME}" 2>/dev/null; then
    ok "已软链到 PATH：${BINDIR}/${BIN_NAME}"
    case ":$PATH:" in
      *":$BINDIR:"*) RUN_BIN="${BIN_NAME}" ;;
      *) warn "${BINDIR} 不在 PATH 中；加入：export PATH=\"${BINDIR}:\$PATH\"" ;;
    esac
  else
    warn "未能写入 ${BINDIR}；可直接使用：${RUN_BIN}"
  fi

  # 默认配置（登记全部 NetBox 资源类型，开箱即可查询）；绝不覆盖既有配置
  if [ -f "${target}/config.default.json" ]; then
    local cfg_dir="$HOME/.nbx-guard" cfg
    cfg="${cfg_dir}/config.json"
    if mkdir -p "$cfg_dir" 2>/dev/null; then
      if [ ! -f "$cfg" ]; then
        install -m 0644 "${target}/config.default.json" "$cfg"
        ok "已写入默认配置：${cfg}"
      elif cmp -s "${target}/config.default.json" "$cfg"; then
        info "${C_DIM}默认配置已是最新：${cfg}${C_RST}"
      else
        install -m 0644 "${target}/config.default.json" "${cfg}.default"
        warn "已存在配置未覆盖：${cfg}（最新默认另存为 ${cfg}.default）"
      fi
    fi
  fi
}

main() {
  info "${C_DIM}nbx-guard 远程安装器 · ${REPO_SLUG}${C_RST}"
  detect_platform
  resolve_version
  info "${C_DIM}版本：${TAG}${C_RST}"
  acquire_binary
  acquire_skill
  install_all
  info ""
  info "${C_DIM}\$ ${RUN_BIN} version${C_RST}"
  "$RUN_BIN" version || die "运行 ${BIN_NAME} 失败"
  info ""
  ok "安装完成。下一步：设置 NETBOX_URL 与 NETBOX_TOKEN，然后跑 ${BIN_NAME} config show 看当前能做什么。"
  info "${C_DIM}技能说明：${INSTALL_ROOT}/${SKILL_NAME}/SKILL.md —— 已可被 Agent 读取。${C_RST}"
}

main "$@"
