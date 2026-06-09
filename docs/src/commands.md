# 命令参考

每条命令都恰好打印**一个** JSON 信封（见[响应格式](./responses.md)）并设置退出码。
读写 NetBox 的命令都需要 `NETBOX_TOKEN`。

```text
nbxg version                          打印版本与当前生效配置
nbxg help                             显示帮助
nbxg config show                      用大白话说明当前配置允许 Agent 做什么、以及如何放宽（无需 token）
nbxg config set <key=value> ...       提案一项治理/连接变更（人工审批 + 全程审计；绝不自动审批）
nbxg doctor [--skill <dir>]           自检：安装的二进制与 SKILL.md/源码是否一致（离线）
nbxg get <type> <id> [--fields basic|all] [--plan-read] [--plan <id>]
                                      读取资源；basic（默认）脱敏读敏感字段，all 需读审批
nbxg inspect <type> <id> [--fields basic|all]  读取资源并标注读/写字段策略
nbxg describe [<type>] [--source options|openapi] [--refresh] [--offline]
                                      自描述：可写字段 / 输入输出 schema，实时对齐 NetBox
nbxg list-resources <type> [选项]     发现资源（brief 标识字段；只读）
nbxg search <type> [-q text] [选项]   按文本/字段过滤搜索资源（只读）
nbxg resolve <type> [--name|--slug|--address v | k=v]
                                      人类可读标识 -> 对象 id（歧义返回候选列表，绝不静默挑选）
nbxg export <type> [选项]             只读批量导出匹配资源（full 档脱敏读敏感字段）
nbxg snapshot <type> <id> [--fields basic|all] [--plan-read] [--plan <id>] [--out p]
                                      只读快照单个资源（basic 默认脱敏，all 需读审批）
nbxg plan <type> <id> --set k=v ... | --data '{...}'   创建变更计划（做策略 + 风险校验）
nbxg create <type> --set k=v ... | --data '{...}'      创建新对象的计划（仅限算子开启的类型；始终需审批）
nbxg approve --plan <id> [--note x]   审批一个高风险 plan（绑定 plan_hash）
nbxg approve-read --plan <id> [--note x]  审批一次敏感对象的整体读取（绑定 plan_hash）
nbxg reject --plan <id> [--note x]    驳回一个 plan（之后 apply 会被拒绝）
nbxg apply --plan <id>                先备份，再应用一个已审批/低风险的 plan
nbxg restore --backup <id>            从备份快照回滚资源
nbxg audit [--plan <id>]              显示审计日志
nbxg list <plans|approvals|backups>   列出本地状态
```

## `version`

打印版本与当前生效配置（`netbox_url`、`branching`、`state_dir`、`token_configured`）。
不访问网络。也可用 `--version` / `-v`。

## `help`

打印用法、命令列表、支持的资源类型、允许/高风险**写**字段、**读敏感**字段列表，以及可识别的环境变量。
也可用 `--help` / `-h`。不带参数运行时打印帮助。

## `config show`

用大白话回答「当前这套配置允许 Agent 做什么」，不访问网络、无需 token。输出包含：token 来源
（`env`/`cmd`/`file`/`none`）、连接（`netbox_url`/`branching`/`branch`/`state_dir`/`http_timeout_ms`）、
配置文件路径与是否存在、是否自动审批、受治理资源类型、免审批可写字段、需审批字段、读敏感字段、可创建类型，
以及一个 `capabilities`（现在能做什么）与 `to_change`（想做更多该跑哪条 `config set`）的清单。

**遇到不确定能不能做某事时，先 `config show`**：能做就直接做，不能做再用 `config set` 提案。

## `config set <key=value> ...`

Agent **提案**一项治理/连接变更，**不立即改动任何东西**，而是生成一个 `pending_approval` 的 plan，
列出改什么、从什么值到什么值、风险等级与影响。随后由**人类** `approve`、再由 Agent `apply` 写入配置
（自动备份旧配置到 `<state_dir>/config-backups/`、可回滚），全程审计（`config_applied`）。

可设置的键（值语法）：

```text
auto_approve=true|false            # 自动审批开关（高风险）
creatable_resources=site,vlan      # 开启 create 的类型（逗号分隔，* 表示任意）
allowed_fields=serial,asset_tag    # 追加免审批可写字段
high_risk_fields=tenant            # 追加需审批可写字段
read_sensitive_fields=serial       # 追加读敏感字段（只收紧）
extra_resources=site:dcim/sites,tenant:tenancy/tenants   # 治理更多类型（type:app/endpoint）
netbox_url=https://netbox.example.com
token_file=/run/secrets/netbox_token
token_cmd=security find-generic-password -s netbox -w
state_dir=/var/lib/nbx-guard
branching=true   branch=<schema_id>   http_timeout_ms=15000
```

**关键安全约束**：配置变更**永远不会被自动审批**——即使 `auto_approve` 已开启，`config set` 生成的 plan
仍是 `pending_approval`，需人工 `approve`，Agent 无法借此自我提权。明文 token（`netbox_token`/`token`）
被拒绝；未知键、非法值同样被拒。完整链路：`config set`（提案）→ `approve`（人类）→ `apply`（写入）。

## `doctor [--skill <dir>]`

**一致性自检**（离线，不访问网络，无需 token）：比对当前**二进制自带**的版本、支持的资源类型、
低/高风险策略字段与**安装的 `SKILL.md`**，并在仓库内运行时附带对比源码 `build.zig.zon` 的版本。
用于发现「安装的二进制」与「文档/源码」之间的版本漂移（例如二进制还停在旧版本、文档已新增
`contact` 资源类型）。

`data` 下给出：

- `status`：`consistent`（一致）/ `drift`（存在漂移）/ `skill_not_found`（未找到可比对的 `SKILL.md`）。
- `consistent`：布尔总览。
- `binary`：二进制自带的 `version` / `resource_types` / `low_risk_fields` / `high_risk_fields` 与调用路径 `path`。
- `source`：源码 `build.zig.zon` 版本与是否匹配（仅在仓库内运行时存在）。
- `skill_doc`：定位到的 `SKILL.md` 的 `path` / `source` / `sha256` / `size` 及其文档化的类型与字段。
- `readme`：同目录 `README.md` 的校验和（若存在）。
- `checks`：逐项比对结果（`resource_types` / `low_risk_fields` / `high_risk_fields`，含 `binary_only` / `doc_only` 差异）。
- `issues`：人类可读的不一致清单；`next_action`：修复建议。

默认按以下顺序查找 `SKILL.md`：`--skill <dir>` 指定项 → `NBX_GUARD_SKILL_DIR` →
二进制所在目录（绝对路径直接调用时）→ `~/.agents/skills/nbx-guard/` → 当前仓库布局
（`skills/nbx-guard/SKILL.md`）。一致时退出码为 `0`，发现漂移时为 `2`。

```sh
nbxg doctor
nbxg doctor --skill ~/.agents/skills/nbx-guard
```

## `get <type> <id> [--fields basic|all] [--plan-read] [--plan <id>]`

从 NetBox 读取一个资源，返回在 `data.resource` 下。需要 token。读取面**分级**（默认最小化）：

- `--fields basic`（**默认**）：返回对象，但把**读敏感字段**（`phone`、`email`、`comments`、
  `custom_fields`、`tenant`，可由 `NBX_GUARD_READ_SENSITIVE_FIELDS` 扩展）替换为
  `[redacted: read approval required]`。`data.read_policy.redacted_fields` 列出被脱敏的字段。低风险。
- `--fields all`：请求整对象。若对象含读敏感字段，则默认拒绝（`needs_approval`），需走读审批：
  1. `--plan-read`：创建一个读 plan（`rplan_…`，`status: pending_approval`）并返回脱敏预览。
  2. `nbxg approve-read --plan <plan_id>`：人工审批（绑定 `plan_hash`）。
  3. `nbxg get <type> <id> --fields all --plan <plan_id>`：披露整对象（写 `read_served` 审计）。

```sh
nbxg get device 123                                  # basic：敏感字段脱敏
nbxg get device 123 --fields all --plan-read         # 创建读 plan
nbxg approve-read --plan rplan_...                    # 人工审批
nbxg get device 123 --fields all --plan rplan_...     # 披露整对象
```

## `inspect <type> <id> [--fields basic|all]`

与 `get` 相同的读取分级，但额外在响应中标注**写**字段策略（`policy.allowed_fields`、
`policy.high_risk_fields`）以及**读**策略（`read_policy`），让 agent 能同时看到自己可读到什么、
可提议改什么。需要 token。

## `list-resources <type> [选项]`

**资源发现**：在做 id 级操作（`get`/`plan`）之前，先**列出**某类型的对象，拿到它们的
`id`。只读，需要 token。

默认返回 NetBox 的 `brief` 视图（仅 `id`/`url`/`display`/`name`/`description` 等标识字段），
属低风险读取。响应在 `data` 下给出：

- `count`：NetBox 侧匹配总数；`returned`：本页条数；`has_more`：是否还有下一页。
- `results`：对象数组；`query`：本次实际使用的 `limit`/`offset`/`brief`/`filters`。

| 选项 | 含义 |
|---|---|
| `--limit <n>` | 本页条数（默认 50，范围 1–1000） |
| `--offset <n>` | 起始偏移，用于翻页 |
| `--all-fields` | 关闭 `brief`，返回完整对象（字段更多，谨慎用于大列表） |
| `--filter key=value` | 透传任意 NetBox 过滤器，可重复（如 `--filter status=active`） |

```sh
nbxg list-resources ip-address --limit 20
nbxg list-resources device --filter site=hq --filter status=active
nbxg list-resources contact --all-fields --offset 50
```

## `search <type> [选项]`

`list-resources` 的「模糊搜索」变体：用 NetBox 通用 `q` 参数按文本检索。其余选项与
`list-resources` 完全一致。

- `-q` / `--query <text>` / `--name <text>`：三者均映射到 NetBox 的 `q`（即便某类型没有
  `name` 字段，`--name` 也可用）。

```sh
nbxg search contact -q alice         # 按文本模糊搜索联系人
nbxg search ip-address --name 192.0.2 # --name 也走 q
nbxg search device -q core --filter status=active
```

> 读取（`get`/`inspect`/`list-resources`/`search`）不触发审批；写入仍必须 `plan`。
> 先用 `resolve`/`search`/`list-resources` 发现 `id`，再对该 `id` 走 `plan → apply`。

## `resolve <type> [选项]`

把**人类可读标识**（`name` / `slug` / `address` / `display`，或任意 NetBox 字段）解析为
后续命令（`get`/`inspect`/`plan`）所需的**对象 id**。这是一次确定性的、只读身份查询：
请求 NetBox 的 `brief` 表示（仅 id/url/display 等标识字段，**绝不**包含读敏感字段），
因此**无需读审批**。

选择器（至少一个，多个之间是 AND 关系）：

- `--name <v>` / `--slug <v>` / `--address <v>` / `--display <v>`：常用身份字段的便捷写法。
- `--filter <k>=<v>` / 裸 `key=value` 位置参数：解析任意资源特有字段（如 `serial=...`、
  `asset_tag=...`、`mac_address=...`、`vid=...`）。

三种结果是**刻意确定**的，便于 agent 分支：

| 命中数 | `ok` | 退出码 | 输出 |
| --- | --- | --- | --- |
| 恰好 1 | `true` | 0 | `data.status="resolved"`、`data.resolved.{id,display,url}` |
| 多条 | `false` | 2 | `error.kind="ambiguous"`、`data.status="ambiguous"`、`data.candidates[]`（候选列表，**绝不静默挑选**） |
| 0 条 | `false` | 2 | `error.kind="not_found"` |

> 歧义时**不会**替你挑一个 id：非零退出码会中断 `&&` 链，候选列表告诉 agent 必须在
> 哪些 id 之间做选择。请明确选定一个 id 后再继续。

```sh
nbxg resolve device --name edge-router      # 唯一命中 -> data.resolved.id
nbxg resolve site --slug tokyo              # 按 slug 解析
nbxg resolve ip-address --address 192.0.2.10/32
nbxg resolve device serial=SN-12345         # 任意字段：裸 key=value
```

## `export <type> [选项]`

**只读导出/快照**：把匹配某类型的对象批量抓取为带**来源元数据**的工件，用于变更前评审、
审计证据、离线审批与变更后对比。只读，需要 token。会**自动翻页**抓全所有匹配对象（受 `--limit`
或安全上限约束）。

| 选项 | 含义 |
|---|---|
| `--filter key=value` | 透传任意 NetBox 过滤器，可重复（如 `--filter site=tokyo`） |
| `-q` / `--query` / `--name <text>` | NetBox 通用 `q` 模糊检索 |
| `--fields basic\|full` | 读取面分级：`basic`（默认，NetBox `brief` 最小读取面）或 `full`（完整属性）；`--all-fields` 等同 `full` |
| `--format json\|jsonl` | `--out` 文件编码：`json`（默认，`{metadata, records}`）或 `jsonl`（首行 `{"_meta":…}`，其后每行一个对象） |
| `--out <path>` | 写入文件（自动创建父目录）；省略时记录嵌入响应的 `data` |
| `--limit <n>` | 最多导出多少条；省略时导出全部匹配 |
| `--offset <n>` | 起始偏移 |

响应/工件的 `metadata` 包含：`resource_type`、`filters`、`query`、`field_profile`、`format`、
`count`、`generated_at`（秒）、`netbox_url_hash`（NetBox URL 的 SHA-256 前 16 位指纹）、
`netbox_instance`（host[:port] 标签）、`nbxg_version`，启用分支时的 `branch`，以及
`redacted_fields`（`full` 档下被脱敏的读敏感字段名）。token 绝不写入工件。

> **读敏感策略**：批量导出**永不披露原始敏感值**——一个集合没有逐对象的读审批绑定。`full`
> 档会对**每条记录**的读敏感字段（`phone`/`email`/`comments`/`custom_fields`/`tenant`）脱敏为
> `[redacted: read approval required]`；`basic` 档用 NetBox `brief`，本就不含这些字段。要读取
> 原始敏感值，请对**单个对象**用 `get`/`snapshot` 并走读审批。

```sh
nbxg export device --filter site=tokyo --fields basic --format json
nbxg export prefix --filter status=active --format jsonl --out snapshots/prefixes.jsonl
nbxg export device --limit 10
```

## `snapshot <type> <id> [--fields basic|all] [--plan-read] [--plan <id>] [--out <path>]`

**只读单对象快照**：抓取某个对象的当前状态，附带与 `export` 相同的来源元数据，用于变更前评审与
变更后对比。只读，需要 token。给 `--out` 则写文件（`{metadata, resource}`，自动建父目录），否则
把快照嵌入响应的 `data`。

快照的读取面与 `get` **同等门禁**（见上文 `get`）：

- `--fields basic`（**默认**）：脱敏读敏感字段，无需审批；`data.read_policy.redacted_fields`
  列出被脱敏的字段，`metadata.redacted_fields` 同步记录在工件里。
- `--fields all`：请求整对象。若含读敏感字段，则默认拒绝（`needs_approval`），需走读审批：
  `--plan-read`（创建读 plan）→ `nbxg approve-read --plan <plan_id>` → `--fields all --plan <plan_id>`
  （披露整对象，写 `read_served` 审计）。读 plan 与 `get` 的读 plan 通用（同为 `action: read`）。

```sh
nbxg snapshot device 123 --out snapshots/device-123.json     # 默认 basic：敏感字段脱敏
nbxg snapshot contact 7 --fields all --plan-read             # 创建读 plan
nbxg snapshot contact 7 --fields all --plan rplan_...        # 已审批后披露整对象
```

## `describe [<type>] [--source options|openapi] [--refresh] [--offline]`

**自描述**：让 agent 在动手前了解「某类型能改什么、输入输出 schema 是什么」，并把字段元数据
**实时对齐真实 NetBox**。

- 不带 `<type>`：列出全部受治理的资源类型及其低/高风险字段（**离线，无需 token**）。
- 带 `<type>`：返回该类型的 `action`、可写 `fields`（`name`/`class`/`json_type`/示例/是否需审批/
  实时 `netbox` 元数据）、`input`（如何写 `--set`）、`output`（信封与 plan 字段）、`examples`，
  并在 `netbox_sync` 下附带本次同步结果。

### 同步来源 `--source`

| 来源 | 取数方式 | 适用 | 说明 |
|---|---|---|---|
| `options`（默认） | `OPTIONS /api/<endpoint>/` | token 具写权限 | 轻量（约 32KB/类型），`choices` 带 `display_name` |
| `openapi` | `GET /api/schema/?format=json` | 只读 token 亦可 | NetBox 官方 OpenAPI 描述文件，权威；整份约 10MB，**本地缓存 6 小时** |

- `--refresh`：忽略缓存强制重新抓取。
- `--offline`：跳过实时同步，仅返回内置静态 schema（`netbox_sync.status = skipped`）。
- `openapi` 来源缓存于 `<state_dir>/cache/openapi-schema.json`；`netbox_sync` 会带
  `component`（动态解析出的 PATCH 组件名）、`cached`、`fetched_at`。

### 漂移提示

`netbox_sync.missing_in_netbox` 列出「内置策略收录、但当前 NetBox 上不存在」的字段——例如
NetBox 4.2+ 的 `prefix` 用通用 `scope` 取代了直接的 `site`。agent 应**以 `describe` 的实时结果
为准**来决定提议哪些字段。

```sh
nbxg describe                          # 列出所有类型（离线）
nbxg describe device                   # 默认 OPTIONS 同步
nbxg describe device --source openapi  # 用 OpenAPI 描述文件同步（只读 token 即可）
nbxg describe device --offline         # 仅静态 schema
```

## `plan <type> <id> --set field=value ... | --data '{...}'`

创建一个变更计划。需要 token。步骤：

1. 校验资源类型。
2. 把 `--set` 键值对、和/或 `--data` 传入的 JSON 对象，合并成一个 changes 对象。
3. 运行策略引擎；被拒绝的字段会中止流程并返回 `policy_denied`。
4. 读取一次当前资源，记录将被改动字段的**基线值（base_values）**，供 apply 时做漂移检测。
5. **空变更守卫**：若全部 `--set` 值已与当前状态完全一致，则返回 `no_change`（退出码 2），
   **不创建任何 plan**，也不产生审批/备份/审计；只要有任一字段不同（部分变更）即照常建计划。
6. 存储该 plan，并追加一条 `plan_created` 审计记录。

响应包含完整的 `plan`、策略 `evaluation`，以及一个 `next_action`，告诉你下一步该
`approve`（高风险）还是 `apply`（低风险）。`no_change` 失败信封仍带 `data`（含 `requested`
与 `current` 两组值），方便你判断要改成什么。

### `--set` 取值解析

取值在可能时按 JSON 解析，否则当作字符串：

```sh
nbxg plan device 1 --set description="edge router"   # 字符串
nbxg plan device 1 --set status=active               # 字符串 "active"
nbxg plan device 1 --set tags='["core"]'             # JSON 数组
nbxg plan vlan 10 --set custom_fields='{"x":1}'      # JSON 对象
```

`--set k=v`、`--set=k=v`，以及裸写的 `k=v` 都被接受。

### 用一整段 JSON 传字段（`--data`）

字段多、或本来就拿着一份 JSON 时，可以用 `--data` 传一个 JSON 对象，免去逐个 `--set`：

```sh
nbxg create site --data '{"name":"POP3","slug":"pop3"}'        # 内联 JSON 字符串
nbxg create site --data @site.json                            # 读文件（@ 前缀）
nbxg create site --data-file site.json                        # 读文件（等价写法）
echo '{"description":"edge router"}' | nbxg plan device 1 --data @-   # 读 stdin
nbxg create site --data @site.json --set status=active        # 混用：--data 打底，--set 覆盖
```

要点：

- `--data` 顶层必须是 JSON 对象（`{字段: 值}`）；数组/字符串/数字会被拒绝（`invalid_args`）。
- 它和 `--set` 走**同一条**管道——策略、风险、`plan_hash`、漂移、备份、审计行为完全一致。
- 可与 `--set` 自由混用，**从左到右、后者覆盖前者**（便于用一份模板打底，再覆盖个别字段）。
- 非法 JSON → `invalid_args`「--data is not valid JSON」；源文件读不到 → `invalid_args`
  「could not read --data source」。

## `create <type> --set field=value ... | --data '{...}'`

为**创建一个新对象**生成计划（不带 `<id>`）。治理点是**类型开关 + 强制审批 + 审计 + 可回滚**：

1. 校验资源类型（必须有端点映射）。
2. **类型默认拒绝**：仅当算子在 `creatable_resources` / `NBX_GUARD_CREATABLE_RESOURCES`
   中开启该类型（`*`=任意类型）时才放行，否则 `policy_denied`。
3. 把 `--set` 和/或 `--data` 解析成新对象的 changes（不做逐字段拒绝——新对象需要 `name`/`slug` 等标识字段，
   由 NetBox 校验必填/取值）。
4. 生成 plan：`action=create`、`resource_id=(new)`（创建前还没有 id）、`risk_level=high`、
   `requires_approval=true`、`status=pending_approval`、`base_values=null`。
5. 存储 plan，追加 `plan_created` 审计。

**生成 plan 不需要 token**（没有现状可读）；`approve` 后用 `apply` 执行 POST 才需要 token。

```sh
nbxg create site --set name=POP3 --set slug=pop3 --set status=active
nbxg approve --plan plan_...
nbxg apply   --plan plan_...        # POST 创建；data.resource_id = 新对象 id
nbxg restore --backup bkp_...       # 撤销：删除刚创建的对象
```

## `approve --plan <id> [--note <text>]`

审批一个处于 `pending_approval` 的 plan。创建一份绑定到该 plan 的 `plan_hash` 的
审批记录，把 plan 推进到 `approved`，并追加一条 `approved` 审计记录。审批者取自
`$USER`（否则为 `cli`）。审批一个并不在等待审批的 plan 会失败，返回 `plan_state_error`。
审批一个**读 plan** 会被拒绝（提示改用 `approve-read`）。

## `approve-read --plan <id> [--note <text>]`

审批一个由 `get/inspect <type> <id> --fields all --plan-read` 创建的**读 plan**（`action: read`，
`status: pending_approval`）。与 `approve` 同源：创建一份绑定 `plan_hash` 的审批记录，把读 plan
推进到 `approved`，并追加一条 `read_approved` 审计记录。之后 `get … --fields all --plan <plan_id>`
即可披露整对象。审批一个写 plan 会被拒绝（提示改用 `approve`）。

## `reject --plan <id> [--note <text>]`驳回一个 plan，把它置为 `rejected`，并追加一条 `rejected` 审计记录。被驳回的 plan
之后再 `apply` 会被拒绝（`plan_state_error`）。已经 `applied` 的 plan 不能被驳回。
驳回者取自 `$USER`（否则为 `cli`）。

## `apply --plan <id>`

应用一个 plan。需要 token。步骤：

1. 若 plan 是**读 plan**（`action: read`），拒绝（`plan_state_error`，提示用 `get … --plan`）。
2. 若 plan 已是 `applied`，拒绝（`plan_state_error`）。
3. 若 plan 已被 `rejected`，拒绝（`plan_state_error`）。
4. 若高风险 plan 尚未 `approved`，拒绝（`not_approved`）。
5. 重新计算 `plan_hash` 并与存储值比对，检测 plan 文件被篡改；高风险 plan 还会校验
   审批记录绑定的是同一个 `plan_hash`（不一致则 `conflict`）。
6. 针对已存储的 changes 重新校验策略。
7. 获取当前资源；若被改动字段的当前值与 plan 记录的基线值不一致（外部漂移），
   在写入任何备份或变更之前拒绝（`conflict`）。
8. 写入一份 **backup**（快照 + 原值）。
9. 用 changes 对 NetBox 执行 `PATCH`。
10. 成功时：把 plan 标记为 `applied`，关联 `backup_id`，追加一条 `applied` 审计记录，
    并返回一个 `diff`（`before` / `after`）以及更新后的 `resource`。

如果 NetBox 拒绝该变更或连接失败，会写入一条 `apply_failed` 审计记录，并以
`netbox_error` 上报。NetBox 把认证失败与权限不足都返回 HTTP 403，其响应体 `detail`
会透传到 `error.message`（如 `Invalid v2 token` 表示凭据问题、`You do not have
permission …` 表示权限问题），据此区分而非盲目重试。

**create plan**（`action: create`）走一条简化路径：没有现状可快照、也没有漂移检测，直接
`POST` 到集合端点；成功后记录一份 `action=create` 的 backup（含新对象 id），返回的
`data.resource_id` 即 NetBox 分配的新 id。

## `restore --backup <id>`

通过对备份中捕获的**原值**执行 `PATCH` 来回滚一个资源。需要 token。追加一条
`restored` 审计记录，并返回回滚后的资源。备份 id 不存在时失败，返回 `backup_not_found`。
若备份的 `action=create`（回滚一次创建），则改为 `DELETE` 删除该对象（NetBox 返回 204；
对象已不存在时按已回滚处理）。

## `audit [--plan <id>]`

打印审计日志，可用 `--plan <id>` 过滤到单个 plan。返回一个 `count` 和匹配的 `entries`。

## `list <plans|approvals|backups>`

列出指定种类的已存储 JSON 记录。返回 `kind`、`count` 以及原始 `items`。目录为空或
不存在时返回 `count: 0`。
