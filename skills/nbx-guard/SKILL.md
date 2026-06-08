---
name: nbx-guard
description: >-
  通过 nbxg CLI 安全地读取与变更 NetBox（DCIM/IPAM/Tenancy）。当需要查看或修改 NetBox 中的
  device / interface / ip-address / prefix / vlan / contact（如改 description、status、role、
  site、address、phone、email 等字段），或需要受控的「计划→审批→应用→回滚」变更流程、字段级默认拒绝、
  变更前备份与审计时使用本技能。Agent 只提出变更意图，由 nbxg 决定是否放行。
---

# nbx-guard（`nbxg`）——面向 Agent 的 NetBox 安全变更网关

`nbxg` 是 Agent 与 NetBox 之间的安全网关。**Agent 永远不能直接调用 NetBox API**，
只能通过 `nbxg` 提出变更*意图*；CLI 负责策略校验、风险分级、变更前备份、审计与回滚。
每条命令都向 stdout 输出**一个 JSON 对象**，并用退出码表达结果——请始终解析 JSON 再行动。

## 何时使用

- 读取 NetBox 资源（只读）：`get` / `inspect`。
- 了解某类型能改什么、输入输出 schema（实时对齐 NetBox）：`describe`。
- 修改受支持资源的受控字段：走 `plan → (approve) → apply` 流程。
- 出错或改坏了：用 `restore` 从变更前备份回滚。
- 查看做过什么：`audit` / `list`。

## 何时**不要**使用

- 创建或删除对象（`nbxg` 只允许 `update`，不提供 create/delete/bulk/raw）。
- 改动策略未收录的字段（默认拒绝，见下）。
- 直接访问 NetBox REST API 绕过网关——这违背本技能的全部意义。

---

## 安装

```sh
# 在仓库内（需要 zig 构建，或已存在 zig-out/bin/nbxg）：
bash scripts/installer.sh
```

安装器会：自动判断系统类型 → 询问安装目录（默认 `~/.agents/skills`）→ 若已存在则询问是否
移除重装 → 安装 `nbxg` 与本 `SKILL.md` 到 `<目录>/nbx-guard/` → 尝试把 `nbxg` 链接进
`~/.local/bin` → 最后执行 `nbxg --help` 验证。

调用方式（二选一）：

- 若已在 PATH：直接 `nbxg <command>`。
- 否则用绝对路径：`~/.agents/skills/nbx-guard/nbxg <command>`。

---

## 配置（环境变量）

| 变量 | 必需 | 默认 | 说明 |
| --- | --- | --- | --- |
| `NETBOX_URL` | 是 | `http://localhost:8000` | NetBox 基础 URL（末尾斜杠会被去掉）。 |
| `NETBOX_TOKEN` | 读写均需 | — | API token。`nbt_<key>.<secret>` 形态（NetBox 4.5+ 的 v2）自动用 `Bearer`，否则用 `Token`（v1）。原样填入即可。 |
| `NBX_GUARD_STATE_DIR` | 否 | `.nbx-guard` | 本地状态目录（plans/approvals/backups/audit）。生产建议指向持久、有访问控制的位置。 |
| `NBX_GUARD_HTTP_TIMEOUT_MS` | 否 | `15000` | NetBox 连接超时（毫秒）；`0` 关闭。 |
| `NBX_GUARD_BRANCHING` | 否 | `0` | 设为 `1/true` 时把写入路由进 NetBox Branching 分支。 |
| `NBX_GUARD_BRANCH` | 否 | — | 生效分支的 schema id（作为 `X-NetBox-Branch` 头发送）。 |

> token 绝不会被写入状态目录，也绝不会在输出里打印。`nbxg version` 只报告 `token_configured: true|false`。

---

## 命令速查

```text
nbxg version                          打印版本与当前生效配置（无需 token）
nbxg help                             机器可读的帮助（命令/字段/环境变量）
nbxg get <type> <id>                  读取资源（只读）
nbxg inspect <type> <id>              读取资源并对每个字段标注策略类别
nbxg describe [<type>] [--source options|openapi] [--refresh] [--offline]
                                      自描述：列出可写字段 / 输入输出 schema，并实时对齐 NetBox
nbxg plan <type> <id> --set k=v ...   创建变更计划（做策略 + 风险 + 漂移基线）
nbxg approve --plan <id> [--note x]   审批一个高风险 plan（绑定 plan_hash）
nbxg reject  --plan <id> [--note x]   驳回一个 plan（之后 apply 会被拒）
nbxg apply   --plan <id>              先备份，再应用一个已审批/低风险 plan
nbxg restore --backup <id>           从变更前备份回滚资源
nbxg audit   [--plan <id>]            查看审计日志
nbxg list    <plans|approvals|backups>  列出本地状态
```

**支持的资源类型**：`device`、`interface`、`ip-address`、`prefix`、`vlan`、`contact`。

---

## 字段策略（默认拒绝）

只有被策略显式收录的字段才能写入：

- **低风险（直接放行，无需审批）**：`description`、`comments`、`tags`、`custom_fields`、`title`、`phone`、`email`、`link`。
- **高风险（必须经 `approve` 才能 apply）**：`status`、`role`、`site`、`rack`、`prefix`、`address`、`groups`。
- **其它一切字段**：拒绝（`error.kind = policy_denied`）。
- **动作**：仅允许 `update`；`create`/`delete`/`bulk_delete` 一律拒绝。

`--set` 取值解析：默认按**字符串**；合法 JSON 的数组/对象按 JSON 解析。

```sh
nbxg plan device 1 --set description="edge router"   # 字符串
nbxg plan device 1 --set status=active               # 字符串 "active"
nbxg plan device 1 --set tags='["core"]'             # JSON 数组
nbxg plan vlan   10 --set custom_fields='{"x":1}'    # JSON 对象
```

---

## 自描述（describe）—— Agent 先问再做

`describe` 让 Agent 在动手前先了解「这个类型能做什么、输入输出长什么样」，并把字段元数据
**实时对齐真实 NetBox**，避免凭空猜字段或用过期的取值。

- `nbxg describe`：列出全部受治理的资源类型及其低/高风险字段（**离线、无需 token**）。
- `nbxg describe <type>`：给出该类型的 `action`、可写 `fields`（含 `json_type`/示例/是否需审批）、
  `input`（怎么写 `--set`）、`output`（信封与 plan 字段）、`examples`，并在 `netbox_sync`
  下附带实时同步结果。

### 两种同步来源（`--source`）

| 来源 | 取数方式 | 适用 | 说明 |
|---|---|---|---|
| `options`（默认） | `OPTIONS /api/<endpoint>/` | token 具备写权限 | 轻量（约 32KB/类型），`choices` 带 `display_name`，结构化最佳 |
| `openapi` | `GET /api/schema/?format=json` | 只读 token 也可用 | NetBox 官方 OpenAPI 描述文件，权威；整份约 10MB，**本地缓存 6 小时** |

- `--refresh`：强制重新抓取（忽略缓存）。
- `--offline`：完全跳过实时同步，仅返回内置静态 schema（`netbox_sync.status = skipped`）。
- `openapi` 来源会把 schema 缓存到 `<state_dir>/cache/openapi-schema.json`，`netbox_sync`
  里会带 `component`（动态解析出的 PATCH 组件名）、`cached`、`fetched_at`。

### 漂移提示

`netbox_sync.missing_in_netbox` 列出「内置策略收录、但当前 NetBox 上不存在」的字段。
例如 NetBox 4.2+ 的 `prefix` 用通用 `scope` 取代了直接的 `site`，对应版本上 `describe prefix`
就不会再列出 `site`。Agent 应**以 `describe` 的实时结果为准**来决定提议哪些字段。

```sh
nbxg describe                          # 列出所有类型（离线）
nbxg describe device                   # 默认 OPTIONS 同步
nbxg describe device --source openapi  # 用 OpenAPI 描述文件同步（只读 token 即可）
nbxg describe device --offline         # 仅静态 schema
```

**Agent 用法**：在 `plan` 之前先 `describe <type>`，按返回的字段名、`json_type`、`choices`/`enum`
组织 `--set`，可显著降低 `policy_denied` 与 NetBox 校验失败。

成功：

```json
{ "ok": true, "command": "plan", "data": { /* ... */ }, "error": null }
```

失败：

```json
{ "ok": false, "command": "apply", "data": null,
  "error": { "kind": "not_approved", "message": "...", "risk_level": "high",
             "next_action": "run `nbxg approve --plan <plan_id>` first" } }
```

`error.kind` 取值（稳定、可判定）：

| kind | 含义 | 典型处理 |
| --- | --- | --- |
| `invalid_args` | 参数缺失/格式错误 | 按 `next_action` 修正命令 |
| `config_error` | 缺 token / URL 等配置 | 设置 `NETBOX_TOKEN` / `NETBOX_URL` |
| `policy_denied` | 字段不在策略内（默认拒绝） | 不要重试该字段；换允许字段或请人评估 |
| `invalid_field` | 字段值非法 | 修正取值 |
| `needs_approval` | 高风险计划尚未审批 | 先 `approve`（人工把关） |
| `not_approved` | 计划未审批就 apply | 先 `approve` 再 `apply` |
| `plan_not_found` / `approval_not_found` / `backup_not_found` | 找不到对应记录 | 用 `list` 核对 id |
| `plan_state_error` | 计划状态不允许该操作（如重复 apply、已驳回） | 重新 `plan` |
| `conflict` | **漂移**：plan 之后资源被外部改动 | 重新 `get`/`plan`，**不要**盲目重试 |
| `netbox_error` | NetBox 返回非 2xx 或不可达 | 检查连通性/权限；读 message |
| `io_error` | 本地状态读写失败 | 检查 `NBX_GUARD_STATE_DIR` 权限 |
| `not_implemented` | 未支持的能力 | 放弃该路径 |

**退出码**：`0` 成功；`2` 客户端/策略/状态错误（你的请求有问题）；`3` 上游/IO/配置错误
（NetBox 或环境的问题）。请同时检查退出码与 `.ok`。

---

## 标准工作流

### 0) 先自描述（推荐）

```sh
nbxg describe ip-address --source openapi
#  -> data.fields[].name/json_type/class、data.netbox_sync.status:"ok"
#     按返回的字段与 choices/enum 组织下面的 --set，减少 policy_denied / 校验失败
```

### 1) 低风险变更（直接应用）

```sh
nbxg plan ip-address 42 --set description="reserved for spine-1"
#  -> data.plan.plan_id、risk_level:"low"、requires_approval:false
#     next_action: low-risk: run `nbxg apply --plan <plan_id>`
nbxg apply --plan plan_...      # 先备份再 PATCH，写审计 + backup
#  -> data.backup_id  ← 记住它，回滚要用
```

### 2) 高风险变更（需人工审批）

```sh
nbxg plan ip-address 42 --set status=deprecated
#  -> risk_level:"high"、requires_approval:true、status:"pending_approval"
nbxg apply --plan plan_...      # 此时会被拒：error.kind = "not_approved"
nbxg approve --plan plan_... --note "approved by netops"
nbxg apply --plan plan_...      # 现在放行
```

> 审批是人在回路的关卡。**Agent 不应自我审批后直接 apply**：除非用户/人类明确授权，
> 否则在 `needs_approval`/`not_approved` 处停下并请求审批。

### 3) 回滚

```sh
nbxg restore --backup bkp_...   # 用变更前快照把资源 PATCH 回去
```

### 4) 审计 / 查询

```sh
nbxg audit --plan plan_...      # 某个 plan 的完整事件链
nbxg list backups               # 已存储的备份
```

---

## 安全保证（Agent 可以依赖）

- **plan_hash 绑定**：approval 绑定到具体 plan 的哈希，篡改计划会使审批失效。
- **漂移检测**：`plan` 记录基线；若 `apply` 前资源被外部改动，apply 以 `conflict` 拒绝，
  且**在写入/备份之前**就拦截——不会产生半成品变更。
- **变更前备份**：每次 `apply` 先抓取并存储完整快照与被改字段的原值，`restore` 据此回滚。
- **原子写入 + 互斥锁**：状态文件原子落盘；写命令串行化，避免审计丢条目或重复 apply。
- **审计链**：`audit.jsonl` 只追加，事件含 `plan_created/approved/rejected/applied/apply_failed/restored`。

---

## Agent 行为约定

**要**：

1. 每步都解析 stdout 的 JSON，依据 `.ok`、`.error.kind`、退出码决策，而不是猜测。
2. 从 `plan` 响应取 `plan_id`；从 `apply` 响应取 `backup_id` 并留存以备回滚。
3. 遇 `conflict`（漂移）：重新 `get`/`inspect` 看现状，再决定是否重新 `plan`。
4. 高风险变更在 `approve` 前停下，向人类申请审批。
5. `apply` 后用 `get`/`inspect` 核对结果符合预期。

**不要**：

1. 不要绕过 `nbxg` 直连 NetBox API。
2. 不要对 `policy_denied` 的字段反复重试——那是设计上的默认拒绝。
3. 不要在未经授权时自行 `approve` 高风险计划。
4. 不要忽略退出码 `2/3` 当作成功。

---

## 故障排查

- `config_error` 且 `token_configured:false`：未设 `NETBOX_TOKEN`。
- `netbox_error` 且超时：NetBox 不可达；检查 `NETBOX_URL`、网络，必要时调
  `NBX_GUARD_HTTP_TIMEOUT_MS`。
- 401/403 类 `netbox_error`：token 无效或权限不足（v2 token 形如 `nbt_<key>.<secret>`，
  请原样粘贴，不要截断）。
- 想快速自检环境：`nbxg version`（无需 token，回显生效配置）。
