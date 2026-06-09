# Agent.md — nbx-guard 开发规范

> 本文件是**所有在本仓库工作的 AI Agent 的开发契约**。开始任何改动前先读完第 0 节，
> 提交前对照第 3、5、7 节自检。本仓库的产物会被运维人员用来对生产 NetBox 做变更，
> 因此**安全性优先于一切便利**——任何削弱安全模型的"优化"都不可接受。

---

## 0. 必读铁律（TL;DR）

1. **每完成一个目标，必须输出一份详细的中文交付报告**——见第 8 节。报告**只在对话里呈现给本人看，
   不写入任何文件、不落盘、不提交**。禁止为此新建 `.md`/日志/笔记文件。
2. **绝不削弱安全模型**：default-deny、`plan → approve → apply → audit` 四步、字段级治理、
   配置变更永不自动审批。详见第 5 节。任何放宽都必须由人类显式批准，而不是 agent 自作主张。
3. **绝不提交任何机密**：token / 口令 / 真实内网 URL / 真实主机名都不许进代码、配置文件或提交历史。
   配置文件里出现明文 `netbox_token`/`token` 会被代码主动拒绝（`error.SecretInConfig`）——不要绕过它。
4. **提交前三项必须全绿**（与 CI 完全一致）：
   - `zig build`
   - `zig build test`
   - `zig fmt --check build.zig src`
5. **改了行为就同步文档与一致性**：内置资源类型 / 字段分类一旦变化，必须同步 `skills/nbx-guard/SKILL.md`，
   并用 `nbxg doctor` 确认 `"consistent": true`（见第 6 节）。
6. **最小、外科手术式改动**：只动与目标相关的代码，不顺手重排/重命名无关内容，不制造与目标无关的 diff。
7. **不替用户做提交/推送决定**：除非用户明确说"提交/push"，否则只改文件、保持工作区可供 review。
8. **完成任务后触发 Acceptance 端到端验收**（仅当本次改了 `src/**` / `build.zig*` / `acceptance/**`）：
   `gh workflow run acceptance.yml --ref main`。它**不随 PR/push 自动跑**（太慢、会阻塞合并）；
   **验收失败作为单独事项跟进，不阻塞本次合并**。详见第 3 节。

---

## 1. 这是什么项目 · 安全哲学

`nbx-guard`（命令 `nbxg`）是一个**面向 AI Agent 的 NetBox 安全变更网关**。核心模型一句话：

> **Agent 只提出意图，由 CLI 决定能不能做。**（The agent proposes intent; the CLI decides what's allowed.）

- **默认拒绝（default-deny）**：未显式授权的资源类型、字段、创建操作一律拒绝。
- **四步闭环**：写操作必须 `plan`（生成计划）→ `approve`（人工审批）→ `apply`（应用）→ 全程 `audit`（审计）。
- **不是"安全的尸体"**：拒绝时不能把人挡在门外，要给出**可执行的下一步**（例如指向 `nbxg config set ...`），
  让"Agent 提案 → 人类审批 → 自动执行 → 全程审计"成为顺畅路径。便利与安全二者都要，靠"透明 + 审计 + 人类选择"调和。

理解这套哲学，是在本仓库写任何代码的前提。改动若与之冲突，**停下来**，在交付报告里说明并请人类定夺。

---

## 2. 代码地图

库逻辑全部在 `src/`，并由 `src/root.zig` 聚合（库与 CLI 入口分离，便于独立单测）。

| 文件 | 职责 |
| --- | --- |
| `src/root.zig` | 库根：re-export 各模块 + 聚合所有单测的 `test {}` 块。**新增模块要在这里登记测试。** |
| `src/main.zig` | CLI 可执行入口（产物名 `nbxg`）。 |
| `src/cli.zig` | 命令分发与所有子命令实现（最大的文件）。响应统一走 `ctx.ok/fail/failData` 封套。 |
| `src/context.zig` | 运行上下文：配置、token 来源、状态目录、`config_path` 等。 |
| `src/config.zig` | `config.json` schema 与 `parseExtJson`；拒绝明文 token（`SecretInConfig`）。 |
| `src/policy.zig` | 能力分类：受治理字段（allowed/high_risk）、可读敏感字段、可创建类型、auto_approve。 |
| `src/plan.zig` | `Plan` 结构、`computeHash`、`save/load`、状态常量。配置变更也复用它。 |
| `src/approval.zig` | 审批记录与绑定（approval 绑定 `plan_hash`，防篡改）。 |
| `src/store.zig` | 状态存储原语：目录、文件锁、原子写入、子目录。 |
| `src/audit.zig` | append-only 审计日志。 |
| `src/backup.zig` | NetBox 资源的变更前备份（**配置变更不用它**，配置走独立的 `config-backups/`）。 |
| `src/netbox.zig` | NetBox HTTP 客户端。 |
| `src/ids.zig` | ID 生成（plan id 等）。 |
| `src/schema.zig` | 资源类型与端点映射。 |
| `src/doctor.zig` | 自检：比对二进制与 `SKILL.md` 的资源类型/字段列表是否一致。 |

其它目录：`skills/nbx-guard/`（Agent 手册 SKILL.md + 默认配置）、`docs/`（mdBook 文档）、
`acceptance/`（真实 NetBox 端到端验收）、`scripts/installer.sh`（安装器）、`.github/workflows/`（CI）。

---

## 3. 构建 · 测试 · 格式化 · 验收

要求 **Zig 0.16.0**（与 CI `mlugg/setup-zig@v2 version: 0.16.0` 一致）。

```bash
zig build                         # 构建，产物在 zig-out/bin/nbxg
zig build test                    # 跑全部单测（聚合在 root.zig）
zig fmt build.zig src             # 自动格式化（提交前务必跑）
zig fmt --check build.zig src     # 仅检查（CI 用，不通过会 fail）
zig build run -- <args>           # 直接运行 CLI
```

**实操坑（务必记住）**：`.zig-cache/o/...` 下的二进制可能是**旧的**。要拿到可靠的新二进制，
用 `zig build --prefix ./zig-out` 后执行 `./zig-out/bin/nbxg`，不要直接跑 cache 里的产物。

**单测约定**：每个模块在自己文件里写 `test "..."`，然后在 `src/root.zig` 的 `test {}` 块里
`_ = @import("xxx.zig");` 登记。新增模块别忘了登记，否则它的测试不会被执行。

**手动 e2e / 冒烟必须隔离环境**，绝不对真实 NetBox 跑 plan/apply。用独立 HOME 与状态目录，并清掉会"泄漏"进来的真实变量：

```bash
env -u NETBOX_TOKEN -u NETBOX_URL -u NBX_GUARD_CONFIG \
    -u NBX_GUARD_BRANCHING -u NBX_GUARD_BRANCH \
    HOME=/tmp/nbxg-smoke/home NBX_GUARD_STATE_DIR=/tmp/nbxg-smoke/state \
    ./zig-out/bin/nbxg config show
```

跑完**清理临时目录**。

**验收（重，不随 PR 自动跑）**：端到端验收 `acceptance/run.sh` 针对 Docker 里的真实 NetBox 容器运行
（见 `acceptance/README.md`）。因为它慢且依赖外部 NetBox，**已从 push / pull_request 触发中移除**，
不再阻塞 PR 合并——工作流只保留 `workflow_dispatch`（手动触发）与每周一次的定时漂移检测。

**完成任务后由你（agent）手动触发验收**（仅当本次改动涉及 `src/**` / `build.zig*` / `acceptance/**`）：

```bash
gh workflow run acceptance.yml --ref main          # 触发
gh run list --workflow=acceptance.yml --limit 1    # 看最近一次（拿 run-id / 状态）
gh run watch <run-id>                              # 跟踪（约 25 分钟）
```

**验收失败要单独处理**：它**不阻塞**当前任务 / PR 合并；把失败当作独立事项——在交付报告里记录
（run 链接、失败现象、初步判断），再单独排查修复，并区分是「我们引入的回归」还是「NetBox API 漂移」。
本地可选自测：`acceptance/run.sh`（需 Docker）。

---

## 4. Zig 0.16 开发约定与坑

- **内存**：命令多用 arena 分配；优先用调用方传入的 allocator，别自己藏全局状态。
- **错误集要显式且窄**：函数返回的 `error{...}` 只列真正可能的错误，便于调用方穷举处理。
- **JSON**：用 `std.json`。构建对象用 `std.json.ObjectMap`（`.empty` + `try obj.put(arena, k, v)`，
  重复键覆盖）；数组用 `std.json.Array.init(arena)` + `.append(v)`；序列化用
  `std.json.Stringify.valueAlloc(arena, value, .{ .whitespace = .indent_2 })`。
- **响应封套**：所有面向 agent 的输出统一走 `ctx.ok` / `ctx.fail` / `ctx.failData`，
  错误归类沿用既有 `ErrKind`（`policy_denied` / `invalid_args` / `not_approved` / `plan_state_error` /
  `config_error` 等），不要自创裸 `print`。每个错误都尽量带**可执行的 `next_action`**。
- **原子写入与锁**：写状态文件走 `store` 的原子写入 + 文件锁，别用裸 `writeFile` 破坏并发安全。
- **绝对路径**：`std.Io.Dir.cwd()` 配绝对路径时会忽略 dirfd——配置文件用绝对路径定位，注意这点。
- 改完跑 `zig fmt`，让格式与 CI 一致。

---

## 5. 安全红线（绝不可破坏的不变量）

违反以下任意一条都视为严重缺陷，**即使测试通过也不能合入**：

1. **写操作必须经过 `plan → approve → apply`**，不得有"直写"后门。
2. **审批绑定计划哈希**：`approval` 绑定 `plan_hash`，apply 前校验完整性；不得跳过或伪造。
3. **配置变更永不自动审批**：即便 `auto_approve` 开启，`config set` 也必须人工审批——
   防止 agent 给自己提权（self-grant）。这是关键不变量，已有测试守护，**不要移除或绕过**。
4. **token 不入配置文件**：`config.json` 出现明文 `netbox_token`/`token` 必须被拒绝。
   token 只能来自环境变量或 `token_file` / `token_cmd`（可对接系统钥匙链）。
5. **字段级 default-deny**：未在 allowed/high_risk 列表里的字段不可写；高风险字段需审批。
6. **审计 append-only**：审计日志只追加、不可改写；每个关键动作都要落审计。
7. **已 apply / 已 reject 的计划不可重放**；篡改过的计划/审批必须被拒。
8. **拒绝要给出路**：默认拒绝时，`next_action` 要指向合法的授权途径（如 `nbxg config set ...`），
   不要只丢一句"不允许"。

如果目标确实需要调整治理边界，正确做法是**让人类通过 `config set` 审批**，而不是在代码里放宽默认值。

---

## 6. 文档与一致性

- **SKILL.md 是 Agent 的权威手册**（`skills/nbx-guard/SKILL.md`）。改了面向 agent 的行为、命令、
  资源类型或字段分类，**必须同步**它，否则等于发布了错误的契约。
- **doctor 一致性**：`doctor` 会比对二进制与 SKILL.md 的资源类型与字段列表。改了这些后跑：
  ```bash
  ./zig-out/bin/nbxg doctor --skill skills/nbx-guard
  ```
  必须看到 `"consistent": true`。命令列表/环境变量表的增改不影响 doctor，但仍要让文档与实现一致。
- **用户文档**：`README.md`、`docs/src/*`、`.env.example`、`skills/nbx-guard/config.default.json`
  要与新行为保持一致。文档以**中文**为主（与现有风格一致）。
- 文档类改动无需 build/test，但涉及代码的改动要按第 3 节自检。

---

## 7. 提交规范

- 仅在**用户明确要求**时提交/推送。默认保持工作区干净可 review。
- **提交前**：第 3 节三项全绿；跑泄漏自检，确认 diff 里没有真实 token/URL/主机名。
- **提交信息**用 Conventional Commits（与历史一致）：`feat:` / `fix:` / `docs:` / `refactor:` /
  `chore:` / `test:` / `release:`。标题用英文、祈使句；正文可用中文详述动机与影响。
- **一个提交聚焦一个主题**；安全相关改动要在正文里点明影响到的不变量。
- AI 协助的提交在结尾带上：
  ```
  Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
  ```

---

## 8. 交付报告（强制）

> **这是本仓库对 Agent 的硬性要求，优先级等同安全红线。**

**每当 Agent 完成一个开发目标**（一个任务 / 里程碑 / 用户可验收的成果），都要**立即输出一份详细的中文报告**。

报告的处置方式：

- **只在对话中呈现给本人看。**
- **不用保存、不写入任何文件、不落盘、不提交。** 禁止为此创建 `report.md`、日志或笔记文件。
- 它是给人看的"收尾说明"，不是项目产物。

报告应当详尽、具体、用中文，至少覆盖：

1. **目标**：这次要解决什么、验收标准是什么。
2. **做了什么**：改了哪些文件 / 新增了哪些命令或逻辑（具体到模块/函数）。
3. **为什么这么做**：关键设计决策与取舍，尤其是被否决的备选方案及原因。
4. **验证证据**：`zig build` / `zig build test` / `zig fmt --check` 结果，跑过的 e2e/冒烟步骤与现象；
   若改了 `src/**`，是否已 `gh workflow run acceptance.yml` 触发 Acceptance（附 run 链接）、结果如何。
5. **安全影响**：是否触及第 5 节的任何不变量，如何确保没有被削弱。
6. **文档与一致性**：是否同步了 SKILL.md / docs，doctor 是否 `consistent`。
7. **遗留与风险**：未覆盖的边界、已知限制、潜在隐患。
8. **下一步建议**：是否需要人工审批、是否建议提交/推送、后续可做的改进。

报告要让本人**不看代码也能判断这次改动是否可信、是否可以提交**。简短敷衍的总结不满足本条要求。

---

## 9. 不要做的事

- ❌ 为放宽治理而修改默认 allow 列表（应走 `config set` 由人类审批）。
- ❌ 绕过 plan/approve/apply 直接改 NetBox 或直接改状态文件。
- ❌ 让配置变更走自动审批通道。
- ❌ 把 token/口令/真实 URL 写进代码、配置或提交历史。
- ❌ 为"计划/笔记/进度/报告"创建 Markdown 文件（交付报告只在对话里给本人看）。
- ❌ 与目标无关的大范围重构、重命名、格式化（制造噪音 diff）。
- ❌ 未经用户明确同意就提交或 push。
- ❌ 对真实生产 NetBox 跑 plan/apply 做"试验"。
