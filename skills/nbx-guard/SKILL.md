---
name: nbx-guard
description: >-
  通过 nbxg CLI 安全地读取、发现与变更 NetBox（DCIM/IPAM/Tenancy）。当需要查看、搜索或修改 NetBox 中的
  device / interface / ip-address / prefix / vlan / contact（如改 description、status、role、
  site、address、phone、email 等字段），或需要先发现资源 id（list-resources/search，或用 resolve
  把名称/slug/address 解析为 id）、受控的
  「计划→审批→应用→回滚」变更流程、字段级默认拒绝、变更前备份与审计时使用本技能。Agent 只提出变更意图，由 nbxg 决定是否放行。
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
| `NBX_GUARD_EXTRA_RESOURCES` | 否 | — | **算子专用**：扩展受治理类型（`类型=端点`，逗号分隔，如 `site=dcim/sites`）。Agent 不应设置。 |
| `NBX_GUARD_ALLOWED_FIELDS` | 否 | — | **算子专用**：追加低风险字段（逗号/空格分隔）。 |
| `NBX_GUARD_HIGH_RISK_FIELDS` | 否 | — | **算子专用**：追加高风险字段（需审批）。 |
| `NBX_GUARD_READ_SENSITIVE_FIELDS` | 否 | — | **算子专用**：追加读敏感字段（整对象读取需 `approve-read`）。Agent 不应设置。 |
| `NBX_GUARD_CONFIG` | 否 | `~/.nbx-guard/config.json` | **算子专用**：治理扩展配置文件路径覆盖。 |

> token 绝不会被写入状态目录，也绝不会在输出里打印。`nbxg version` 只报告 `token_configured: true|false`。

> `NBX_GUARD_EXTRA_RESOURCES` / `*_FIELDS` 由**人工运维方**控制，用于在默认拒绝之外显式放行更多
> 类型/字段；**Agent 不要自行设置这些变量**。默认拒绝、内置高风险分类与全部工作流控制（plan/审批/
> 备份/漂移/审计/还原）始终不变。遇到「类型/字段不在治理范围」时，应**提示人工算子**去配置，而不是绕过。

> **算子配置文件**：上面四个治理扩展变量也可等价地写进 `~/.nbx-guard/config.json`
> （`{ "extra_resources": {"site":"dcim/sites"}, "allowed_fields": ["serial"], "high_risk_fields": ["tenant"], "read_sensitive_fields": ["serial"] }`），
> 与环境变量取并集。**密钥（`NETBOX_TOKEN`）只走环境变量，绝不写进此文件。** 这同样是算子的职责，
> Agent 不应创建或修改该文件。

---

## 命令速查

```text
nbxg version                          打印版本与当前生效配置（无需 token）
nbxg help                             机器可读的帮助（命令/字段/环境变量）
nbxg doctor [--skill <dir>]           自检：安装的二进制与 SKILL.md/源码是否一致（离线、无需 token）
nbxg get <type> <id> [--fields basic|all] [--plan-read] [--plan <id>]  读取资源（basic 默认脱敏读敏感字段）
nbxg inspect <type> <id> [--fields basic|all]  读取资源并标注读/写字段策略
nbxg list-resources <type> [选项]     列出某类型的对象以发现 id（默认 brief 只读）
nbxg search <type> -q <text> [选项]   按 NetBox q 模糊搜索某类型的对象（发现 id）
nbxg resolve <type> [--name|--slug|--address v | k=v]  人类可读标识 -> 对象 id（歧义返回候选列表，绝不静默挑选）
nbxg export <type> [选项]             只读导出/快照匹配资源（含来源元数据，供评审/审计/对比）
nbxg snapshot <type> <id> [--out p]   只读快照单个资源（含来源元数据）
nbxg describe [<type>] [--source options|openapi] [--refresh] [--offline]
                                      自描述：列出可写字段 / 输入输出 schema，并实时对齐 NetBox
nbxg plan <type> <id> --set k=v ...   创建变更计划（做策略 + 风险 + 漂移基线）
nbxg approve --plan <id> [--note x]   审批一个高风险 plan（绑定 plan_hash）
nbxg approve-read --plan <id> [--note x]  审批一次敏感对象的整体读取（绑定 plan_hash）
nbxg reject  --plan <id> [--note x]   驳回一个 plan（之后 apply 会被拒）
nbxg apply   --plan <id>              先备份，再应用一个已审批/低风险 plan
nbxg restore --backup <id>           从变更前备份回滚资源
nbxg audit   [--plan <id>]            查看审计日志
nbxg list    <plans|approvals|backups>  列出本地状态
```

**支持的资源类型**：`device`、`interface`、`ip-address`、`prefix`、`vlan`、`contact`。
人工算子可通过 `NBX_GUARD_EXTRA_RESOURCES` 扩展更多类型（见上）。

---

## 资源发现（先找 id，再操作）

`get`/`inspect`/`plan` 都需要 `<id>`。当你只知道名称/描述、不知道 id 时，先用发现命令（**只读、
不触发审批**）：

- `nbxg list-resources <type> [--limit n] [--offset n] [--filter k=v ...] [--all-fields]`
  列出对象。默认 `brief`（仅 `id`/`display`/`name`/`description` 等标识字段，低风险）。响应给出
  `count`（总数）/`returned`（本页）/`has_more`（是否还有下一页）。
- `nbxg search <type> -q <text>`：用 NetBox 通用 `q` 参数模糊搜索；`--query` / `--name` 是 `-q`
  的别名（即便类型没有 `name` 字段也可用）。
- `nbxg resolve <type> --name|--slug|--address <v>`（或任意 `k=v`，如 `serial=SN-1`）：把一个**确切的**
  人类可读标识解析为 id。这是确定性查询，结果只有三态：恰好 1 条 → `data.resolved.id`（`ok=true`）；
  多条 → `error.kind=ambiguous` + `data.candidates[]`（退出码 2，**绝不替你挑一个**，必须自己选定一个 id）；
  0 条 → `error.kind=not_found`（退出码 2）。已知准确名称/slug 时优先用 `resolve`；只有模糊关键词时才用 `search`。

```text
nbxg resolve device --name edge-router       # 确切名称 -> 唯一 id
nbxg resolve site --slug tokyo               # 确切 slug -> 唯一 id
nbxg search contact -q alice                 # 只有关键词时用模糊搜索
nbxg list-resources ip-address --filter status=active --limit 20
nbxg get contact 3                           # 用上一步发现的 id 读取
```

**Agent 用法**：需要对「某个名字/描述」的对象动手时——已知确切标识就 `resolve` 拿到唯一 `id`
（歧义时按候选列表显式选定，**不要**盲猜），只有关键词就 `search`/`list-resources`；再
`describe <type>` 确认可写字段，最后 `plan → apply`。除非确有需要，避免 `--all-fields`
（返回面更大），优先用默认 `brief`。

---

## 只读导出与快照（评审 / 审计 / 对比）

变更前评审、审计证据、离线审批与变更后对比时，用 `export`/`snapshot` 把当前状态固化为带**来源
元数据**的工件（只读、不触发审批、需要 token）：

- `nbxg export <type> [--filter k=v ...] [-q text] [--fields basic|full] [--format json|jsonl] [--out path] [--limit n]`
  自动翻页抓全所有匹配对象。`--fields basic`（默认）走 NetBox `brief` 最小读取面；`full` 返回完整属性。
- `nbxg snapshot <type> <id> [--out path]`：抓取单个对象的当前状态。

工件/响应里的 `metadata` 含 `resource_type`、`filters`、`field_profile`、`format`、`count`、
`generated_at`、`netbox_url_hash`（NetBox URL 指纹）、`netbox_instance`、`nbxg_version`（启用分支时
还含 `branch`）。token 绝不写入工件。给 `--out` 写文件（自动建父目录），否则把内容嵌入响应 `data`。

```text
nbxg export device --filter site=tokyo --fields basic --format json
nbxg export prefix --filter status=active --format jsonl --out snapshots/prefixes.jsonl
nbxg snapshot device 123 --out snapshots/device-123.json
```

---

## 字段策略（默认拒绝）

只有被策略显式收录的字段才能写入：

- **低风险（直接放行，无需审批）**：`description`、`comments`、`tags`、`custom_fields`、`title`、`phone`、`email`、`link`。
- **高风险（必须经 `approve` 才能 apply）**：`status`、`role`、`site`、`rack`、`prefix`、`address`、`groups`。
- **其它一切字段**：拒绝（`error.kind = policy_denied`）。
- **动作**：仅允许 `update`；`create`/`delete`/`bulk_delete` 一律拒绝。

> **需要的字段被 `policy_denied`？** 不要反复重试，也不要自行设置 env 绕过。请**提示人工算子**用
> `NBX_GUARD_ALLOWED_FIELDS`（低风险）或 `NBX_GUARD_HIGH_RISK_FIELDS`（需审批）放行该字段（例如设备
> `serial` 序列号），或等价地写进 `~/.nbx-guard/config.json`。放行后该字段会**自动出现在**
> `describe`/`inspect`/`help` 的字段清单中（并实时标注 `present_in_netbox`），你即可照常
> `plan → apply`，无需改源码。

`--set` 取值解析：默认按**字符串**；合法 JSON 的数组/对象按 JSON 解析。

```sh
nbxg plan device 1 --set description="edge router"   # 字符串
nbxg plan device 1 --set status=active               # 字符串 "active"
nbxg plan device 1 --set tags='["core"]'             # JSON 数组
nbxg plan vlan   10 --set custom_fields='{"x":1}'    # JSON 对象
```

---

## 读取策略（读取也分级，默认最小化）

读取与写入**分开分级**。`get`/`inspect` 默认 `--fields basic`，把**读敏感字段**脱敏，避免把
敏感数据整体倾倒进转录；要整对象读取须走读审批。

- **读敏感字段**（`basic` 下脱敏，整对象读取需审批）：`phone`、`email`、`comments`、
  `custom_fields`、`tenant`（人工算子可用 `NBX_GUARD_READ_SENSITIVE_FIELDS` 追加）。
- `--fields basic`（**默认**）：返回对象，读敏感字段替换为 `[redacted: read approval required]`；
  `data.read_policy.redacted_fields` 列出被脱敏字段。低风险、不触发审批。
- `--fields all`：请求整对象。对象**不含**读敏感字段时直接返回；**含**读敏感字段时默认拒绝
  （`error.kind = needs_approval`），需走读审批路径：

```text
nbxg get device 123                                 # basic：phone/email/comments… 被脱敏
nbxg get device 123 --fields all                    # 含敏感字段 -> needs_approval
nbxg get device 123 --fields all --plan-read        # 创建读 plan（rplan_…），返回脱敏预览
nbxg approve-read --plan rplan_... --note "ok"       # 人工审批（绑定 plan_hash）
nbxg get device 123 --fields all --plan rplan_...     # 披露整对象（写 read_served 审计）
```

> 读 plan 与写 plan 隔离：`approve`/`apply` 会拒绝读 plan（提示用 `approve-read`/`get --plan`），
> `approve-read` 只接受读 plan。**Agent 不应自我审批**：在 `needs_approval` 处停下，请人类授权。
> 默认优先用 `basic`，仅在确有必要披露敏感字段时才申请 `--fields all` 读审批。

---

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

### 0) 发现 + 自描述（推荐）

```sh
nbxg resolve ip-address --address 192.0.2.10/32  # 已知确切标识 -> data.resolved.id（歧义会给候选列表，自己选定）
nbxg search ip-address -q 192.0.2          # 只有模糊关键词时再用搜索，拿到 data.results[].id
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
- **审计链**：`audit.jsonl` 只追加，事件含 `plan_created/approved/rejected/applied/apply_failed/restored`，
  以及读取侧的 `read_plan_created/read_approved/read_served`（敏感字段的整体披露可追溯）。

---

## Agent 行为约定

**要**：

1. 每步都解析 stdout 的 JSON，依据 `.ok`、`.error.kind`、退出码决策，而不是猜测。
2. 从 `plan` 响应取 `plan_id`；从 `apply` 响应取 `backup_id` 并留存以备回滚。
3. 遇 `conflict`（漂移）：重新 `get`/`inspect` 看现状，再决定是否重新 `plan`。
4. 高风险变更在 `approve` 前停下，向人类申请审批。
5. `apply` 后用 `get`/`inspect` 核对结果符合预期。
6. 不知道 `id` 时：已知确切名称/slug/address 用 `resolve`（歧义按候选列表显式选定），只有关键词用
   `search`/`list-resources`——不要凭空猜测 id，也不要在 `resolve` 返回 `ambiguous` 时随便选一个。

**不要**：

1. 不要绕过 `nbxg` 直连 NetBox API。
2. 不要对 `policy_denied` 的字段反复重试——那是设计上的默认拒绝。
3. 不要在未经授权时自行 `approve` 高风险计划。
4. 不要忽略退出码 `2/3` 当作成功。
5. 不要自行设置 `NBX_GUARD_EXTRA_RESOURCES` / `NBX_GUARD_ALLOWED_FIELDS` /
   `NBX_GUARD_HIGH_RISK_FIELDS`，也不要自行创建/修改 `~/.nbx-guard/config.json` 来绕过默认拒绝
   ——这些是人工算子的职责。遇到类型/字段不在治理范围（`invalid_args` 未知类型、或
   `policy_denied`），应**请人工算子去配置**。

---

## 故障排查

- `config_error` 且 `token_configured:false`：未设 `NETBOX_TOKEN`。
- `netbox_error` 且超时：NetBox 不可达；检查 `NETBOX_URL`、网络，必要时调
  `NBX_GUARD_HTTP_TIMEOUT_MS`。
- 401/403 类 `netbox_error`：token 无效或权限不足（v2 token 形如 `nbt_<key>.<secret>`，
  请原样粘贴，不要截断）。
- 想快速自检环境：`nbxg version`（无需 token，回显生效配置）。
- 怀疑安装的二进制与本技能文档/源码不一致（版本漂移）：`nbxg doctor`（离线、无需 token）。
  它会比对二进制自带的版本、资源类型、策略字段与安装的 `SKILL.md`（以及源码 `build.zig.zon`
  版本），输出 `data.status`（`consistent` / `drift` / `skill_not_found`）、逐项 `checks`、
  人类可读的 `issues` 与修复建议 `next_action`；发现漂移时退出码为 `2`。如检测失败，按
  `next_action` 重跑 `scripts/installer.sh` 重装，使二进制与文档对齐。默认会在二进制所在目录、
  `~/.agents/skills/nbx-guard/` 与当前仓库布局中查找 `SKILL.md`，也可用 `--skill <dir>` 指定。
