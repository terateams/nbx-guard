# 命令参考

每条命令都恰好打印**一个** JSON 信封（见[响应格式](./responses.md)）并设置退出码。
读写 NetBox 的命令都需要 `NETBOX_TOKEN`。

```text
nbxg version                          打印版本与当前生效配置
nbxg help                             显示帮助
nbxg doctor [--skill <dir>]           自检：安装的二进制与 SKILL.md/源码是否一致（离线）
nbxg get <type> <id> [--fields basic|all] [--plan-read] [--plan <id>]
                                      读取资源；basic（默认）脱敏读敏感字段，all 需读审批
nbxg inspect <type> <id> [--fields basic|all]  读取资源并标注读/写字段策略
nbxg describe [<type>] [--source options|openapi] [--refresh] [--offline]
                                      自描述：可写字段 / 输入输出 schema，实时对齐 NetBox
nbxg export <type> [选项]             只读导出/快照匹配资源（含来源元数据）
nbxg snapshot <type> <id> [--out p]   只读快照单个资源（含来源元数据）
nbxg plan <type> <id> --set k=v ...   创建变更计划（做策略 + 风险校验）
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
> 先用 `search`/`list-resources` 发现 `id`，再对该 `id` 走 `plan → apply`。

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
`netbox_instance`（host[:port] 标签）、`nbxg_version`，以及启用分支时的 `branch`。token 绝不写入工件。

```sh
nbxg export device --filter site=tokyo --fields basic --format json
nbxg export prefix --filter status=active --format jsonl --out snapshots/prefixes.jsonl
nbxg export device --limit 10
```

## `snapshot <type> <id> [--out <path>]`

**只读单对象快照**：抓取某个对象的当前状态，附带与 `export` 相同的来源元数据，用于变更前评审与
变更后对比。只读，需要 token。给 `--out` 则写文件（`{metadata, resource}`，自动建父目录），否则
把快照嵌入响应的 `data`。

```sh
nbxg snapshot device 123 --out snapshots/device-123.json
nbxg snapshot ip-address 42
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

## `plan <type> <id> --set field=value ...`

创建一个变更计划。需要 token。步骤：

1. 校验资源类型。
2. 把 `--set` 键值对解析成一个 changes 对象。
3. 运行策略引擎；被拒绝的字段会中止流程并返回 `policy_denied`。
4. 读取一次当前资源，记录将被改动字段的**基线值（base_values）**，供 apply 时做漂移检测。
5. 存储该 plan，并追加一条 `plan_created` 审计记录。

响应包含完整的 `plan`、策略 `evaluation`，以及一个 `next_action`，告诉你下一步该
`approve`（高风险）还是 `apply`（低风险）。

### `--set` 取值解析

取值在可能时按 JSON 解析，否则当作字符串：

```sh
nbxg plan device 1 --set description="edge router"   # 字符串
nbxg plan device 1 --set status=active               # 字符串 "active"
nbxg plan device 1 --set tags='["core"]'             # JSON 数组
nbxg plan vlan 10 --set custom_fields='{"x":1}'      # JSON 对象
```

`--set k=v`、`--set=k=v`，以及裸写的 `k=v` 都被接受。

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
`netbox_error` 上报。

## `restore --backup <id>`

通过对备份中捕获的**原值**执行 `PATCH` 来回滚一个资源。需要 token。追加一条
`restored` 审计记录，并返回回滚后的资源。备份 id 不存在时失败，返回 `backup_not_found`。

## `audit [--plan <id>]`

打印审计日志，可用 `--plan <id>` 过滤到单个 plan。返回一个 `count` 和匹配的 `entries`。

## `list <plans|approvals|backups>`

列出指定种类的已存储 JSON 记录。返回 `kind`、`count` 以及原始 `items`。目录为空或
不存在时返回 `count: 0`。
