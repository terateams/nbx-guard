# 00 · 先确认 nbxg 可用；缺失时提案安装

**为什么先做这一步**：如果本技能是通过 `npx skills add terateams/nbx-guard` 装的，那么**只有这份
文档、没有 `nbxg` 二进制**。任何 `nbxg` 命令都会失败。所以第一次用本技能、或久未使用时，**先探测，
再决定是直接干活还是提案安装**。

---

## 第 0 步：探测二进制

按顺序探测，任一成功即就绪（先看 PATH，再看技能默认目录）：

```sh
nbxg version 2>/dev/null || ~/.agents/skills/nbx-guard/nbxg version
```

**已就绪**——输出 JSON（含 `"version"`），直接按其它 example 干活：

```json
{
  "ok": true,
  "command": "version",
  "data": {
    "name": "nbxg",
    "version": "0.8.0",
    "token_configured": false,
    "token_source": "none",
    "auto_approve": false,
    "config_file": "/home/you/.nbx-guard/config.json",
    "principle": "Agent proposes intent; the CLI decides what is allowed."
  },
  "error": null
}
```

**二进制缺失**——shell 报错、非 JSON、非零退出：

```text
bash: nbxg: command not found
bash: /home/you/.agents/skills/nbx-guard/nbxg: No such file or directory
```

→ 多半是 `npx skills` 只装了文档。**不要硬跑后续命令，也不要静默安装。** 走下面的提案流程。

---

## 第 1 步：提案安装（Agent 提案 → 人类批准 → 执行）

和本技能改 NetBox 的姿态一致：Agent 不自作主张，先说清楚、等批准。给用户这样一段话：

> 技能文档已就位，但缺 `nbxg` 二进制（`npx skills` 只装文档，不含可执行文件）。
> 建议用官方远程安装器装上预编译版——它会：到 GitHub Release 找与本机架构匹配的 `nbxg`
> （自动取最新版）→ 下载并校验 SHA256 → 装到 `~/.agents/skills/nbx-guard/` 并软链
> `~/.local/bin` → 写一份默认配置（**绝不覆盖**已有配置）。是否执行？

**唯一的远程安装命令**（等用户点头再跑）：

```sh
curl -fsSL https://raw.githubusercontent.com/terateams/nbx-guard/main/scripts/install.sh | bash
```

可选：`NBXG_VERSION=vX.Y.Z` 锁版本；`NBXG_INSTALL_DIR` / `NBXG_BINDIR` 改安装/软链目录。

## 第 2 步：装完复验

```sh
nbxg version
```

拿到含 `"version"` 的 JSON 即成功；若 `~/.local/bin` 不在 PATH，安装器会提示加：
`export PATH="$HOME/.local/bin:$PATH"`，或直接用绝对路径
`~/.agents/skills/nbx-guard/nbxg version`。

---

## 兜底：手动到 Release 页面下载（受限环境 / 想逐步核验）

不能 `curl | bash`（无网管道、要人工核验校验和）时，手动下对应资产即可——一样是
「去 Release 页面找对应版本」，只是每步可见、可审计：

```sh
# 1) 认平台
OS=$(uname -s | tr '[:upper:]' '[:lower:]'); case "$OS" in darwin) OS=macos;; esac
ARCH=$(uname -m); case "$ARCH" in arm64) ARCH=aarch64;; amd64) ARCH=x86_64;; esac

# 2) 选版本（latest 见 Release 页面，或写死）
TAG=v0.8.0
base="https://github.com/terateams/nbx-guard/releases/download/$TAG"
asset="nbxg-$TAG-$ARCH-$OS.tar.gz"     # Windows 用 nbxg-$TAG-$ARCH-windows.zip

# 3) 下载 + 校验 SHA256 + 解压
curl -fsSLO "$base/$asset"
curl -fsSL "$base/SHA256SUMS" | grep "$asset" | shasum -a 256 -c -   # Linux 用 sha256sum -c -
tar -xzf "$asset"

# 4) 安装到技能目录并软链进 PATH
mkdir -p ~/.agents/skills/nbx-guard ~/.local/bin
install -m 0755 nbxg ~/.agents/skills/nbx-guard/nbxg
ln -sf ~/.agents/skills/nbx-guard/nbxg ~/.local/bin/nbxg

# 5) 复验
nbxg version
```

> 同样**先把命令和校验步骤摆给用户、等批准再执行**。校验和对不上就停手，别装。

---

## 要点

- 探测失败 ≠ 配置出错。它只说明二进制没装上（常见于 npx 只装文档）。
- 安装本身也走「提案 → 批准 → 执行」，与本技能治理理念一致。
- 装好后建议顺手 `nbxg doctor`（离线）确认二进制与本 `SKILL.md` 版本一致，再开始干活。
