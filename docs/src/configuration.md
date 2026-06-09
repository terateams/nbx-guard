# 配置

所有配置都有两个等价来源：**进程环境变量**，或一个 **JSON 配置文件
`~/.nbx-guard/config.json`**（见下文「算子配置文件」）。两者可混用，**环境变量始终优先**。
怕环境变量太多、记不住？把它们一次性写进配置文件即可——安装器已为你生成这个文件。
唯一不能进文件的是明文 token（见 [token 的来源](#token-的来源钥匙链友好)）。

| 变量 | config.json 键 | 默认值 | 用途 |
| --- | --- | --- | --- |
| `NETBOX_URL` | `netbox_url` | `http://localhost:8000` | NetBox 基础 URL，末尾的斜杠会被去掉。 |
| `NETBOX_TOKEN` | _（禁止入文件）_ | _（未设置）_ | API token；`get` / `inspect` / `plan` / `apply` / `restore` **必需**。 |
| `NETBOX_TOKEN_FILE` | `token_file` | _（未设置）_ | 从文件读取 token（Docker/K8s secret、systemd credentials、Vault agent 文件）。 |
| `NETBOX_TOKEN_CMD` | `token_cmd` | _（未设置）_ | 执行命令、用其 stdout 作为 token（对接系统钥匙链）。优先级：`NETBOX_TOKEN` > `NETBOX_TOKEN_CMD` > `NETBOX_TOKEN_FILE`。 |
| `NBX_GUARD_STATE_DIR` | `state_dir` | `.nbx-guard` | 本地状态目录（plans、approvals、backups、审计日志）。 |
| `NBX_GUARD_HTTP_TIMEOUT_MS` | `http_timeout_ms` | `15000` | 单次 NetBox 请求的连接超时（毫秒），避免 NetBox 不可达时 CLI 永久挂起；`0` 关闭。 |
| `NBX_GUARD_BRANCHING` | `branching` | `0` | 将读写路由进某个 NetBox Branching 分支。 |
| `NBX_GUARD_BRANCH` | `branch` | _（未设置）_ | 生效分支的 schema id，作为 `X-NetBox-Branch` 头发送。 |
| `NBX_GUARD_AUTO_APPROVE` | `auto_approve` | `0` | 算子自动审批开关：高风险 `update` 与 `create` 在 plan 时自动审批，仍写完整审计与备份。详见[自动审批](#自动审批-autopilot)。 |
| `NBX_GUARD_EXTRA_RESOURCES` | `extra_resources` | _（未设置）_ | 算子新增受治理类型（`类型=端点` 列表）。详见[策略](./policy.md#算子扩展默认拒绝之外的显式放行)。 |
| `NBX_GUARD_ALLOWED_FIELDS` | `allowed_fields` | _（未设置）_ | 算子追加的低风险可写字段（逗号/空格分隔）。 |
| `NBX_GUARD_HIGH_RISK_FIELDS` | `high_risk_fields` | _（未设置）_ | 算子追加的高风险字段（写入需审批）。 |
| `NBX_GUARD_READ_SENSITIVE_FIELDS` | `read_sensitive_fields` | _（未设置）_ | 算子追加的读敏感字段（默认读取脱敏，整对象读取需 `approve-read`）。 |
| `NBX_GUARD_CREATABLE_RESOURCES` | `creatable_resources` | _（未设置）_ | 算子开启 `create` 的类型（逗号/空格分隔，`*` 表示任意类型）。默认空=禁止创建；每次创建仍需审批。 |
| `NBX_GUARD_CONFIG` | _（即本文件路径）_ | _（未设置）_ | 算子配置文件路径覆盖；默认 `~/.nbx-guard/config.json`。 |

## 布尔值解析

`NBX_GUARD_BRANCHING` 与 `NBX_GUARD_AUTO_APPROVE` 在取值为 `1`、`true`、`yes`、`on`
（不区分大小写）时视为 **true**。其它任何值——包括未设置——都视为 **false**。

## `.env` 示例

环境变量是一种选择；也可以用[算子配置文件](#算子配置文件一个文件搞定)把同样的设置一个文件写完。

```sh
export NETBOX_URL=https://netbox.example.com
export NETBOX_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# 或者把 token 留在钥匙链/文件里，而不是环境变量：
# export NETBOX_TOKEN_CMD='security find-generic-password -s netbox -w'
# export NETBOX_TOKEN_FILE=/run/secrets/netbox_token
export NBX_GUARD_STATE_DIR=.nbx-guard
export NBX_GUARD_HTTP_TIMEOUT_MS=15000
export NBX_GUARD_BRANCHING=0
```

## 算子配置文件（一个文件搞定）

不想导出一堆环境变量？把它们写进一个 JSON 文件即可。默认路径
`~/.nbx-guard/config.json`（用 `NBX_GUARD_CONFIG` 可改路径），**安装器已自动生成一份**，
按提示改两行就能用：

```json
{
  "netbox_url":           "https://netbox.example.com",
  "token_cmd":            "security find-generic-password -s netbox -w",
  "auto_approve":         false,

  "extra_resources":      { "site": "dcim/sites", "tenant": "tenancy/tenants" },
  "allowed_fields":       ["serial", "asset_tag"],
  "high_risk_fields":     ["tenant"],
  "read_sensitive_fields": ["serial"],
  "creatable_resources":  ["site", "vlan"]
}
```

文件里的键分两类，**环境变量始终优先**（文件只是默认值，不是锁）：

- **连接 / 运行**：`netbox_url`、`token_file`、`token_cmd`、`state_dir`、`branching`
  （布尔）、`branch`、`http_timeout_ms`（整数）、`auto_approve`（布尔）。各自等价于上表
  对应的环境变量；连接类是标量（环境变量直接覆盖文件）。
- **治理扩展**：`extra_resources` / `allowed_fields` / `high_risk_fields` /
  `read_sensitive_fields` / `creatable_resources`。这类与环境变量**取并集**
  （键冲突时环境变量优先）；`creatable_resources` 的 `*` 表示任意已登记类型，创建始终需审批。

约束：

- **明文 token 绝不入文件**：出现 `netbox_token`（或 `token`）键会以 `config_error` 拒绝。
  要免环境变量，就用 `token_cmd`（钥匙链）或 `token_file`（文件）这两个**指针**。
- 空字符串视为未设置（如占位的 `"token_cmd": ""` 是无害空操作）。
- 文件不存在则静默跳过（向后兼容）；JSON 非法、含明文 token、或 `NBX_GUARD_CONFIG`
  指向的文件缺失 → 以 `config_error`（退出码 3）失败。
- `~/.nbx-guard/`（算子配置）与状态目录 `.nbx-guard/`（plans/backups/审计）是两个不同目录。

完整语义与 fail-safe 约束见[策略 · 算子扩展](./policy.md#算子扩展默认拒绝之外的显式放行)。

## 让 Agent 提案修改配置（人工审批 + 审计）

人工运维方不必手动编辑 `~/.nbx-guard/config.json`：当默认拒绝挡住正当工作时，Agent 可以用
`nbxg config set` **提案**修改，由人类审批后生效、全程审计。一个只会拒绝的工具会把普通运维挡在门外，
而这条路径让「改门禁」本身透明且受治理。

- **`nbxg config show`**：用大白话说明当前配置允许 Agent 做什么，并给出「想做更多该跑哪条 `config set`」。
- **`nbxg config set <key=value> ...`**：提案一项变更（如 `auto_approve=true`、`allowed_fields=serial`、
  `creatable_resources=site`、`extra_resources=site:dcim/sites`）。它不立即改动任何东西，而是生成一个
  `pending_approval` 的 plan，列出改什么、从什么到什么、风险与责任。

链路与数据变更一致：`config set`（Agent 提案）→ `approve`（人类授权）→ `apply`（Agent 写入，自动备份
旧配置到 `<state_dir>/config-backups/`）→ 审计 `config_applied`。**关键安全约束**：配置变更**永不自动审批**
——即使 `auto_approve` 已开启，`config set` 仍需人工 `approve`，Agent 无法借此自我提权；明文 token 永不入
文件。命令细节见[命令 · `config set`](./commands.md#config-set-keyvalue-)。

## 状态存放在哪里

默认情况下，nbx-guard 把 plans、approvals、backups 和审计日志写到当前工作目录下的
`.nbx-guard/`。如果你希望审计轨迹跨多次运行持久保留、或被团队共享，就把
`NBX_GUARD_STATE_DIR` 指向一个持久、有访问控制的位置。磁盘布局见
[本地状态](./state.md)。

## token 的处理

token 从环境读取，并作为 Authorization 头发送给 NetBox。nbx-guard 会按 token 形态
自动选择鉴权方案，与 NetBox 自身的判定一致：

- **v2 token（NetBox 4.5+，默认）**：凭据形如 `nbt_<key>.<secret>`，以
  `Authorization: Bearer nbt_<key>.<secret>` 发送。
- **v1 token（旧版 / 升级遗留）**：40 字符的明文值，以 `Authorization: Token <token>`
  发送。

判定规则很简单：`NETBOX_TOKEN` 以 `nbt_` 开头则用 `Bearer`，否则用 `Token`。因此你只需
把 NetBox 签发给你的 token 原样填入 `NETBOX_TOKEN` 即可，无需关心版本。

### token 的来源（钥匙链友好）

不想把明文 token 放进环境变量？另有两个来源，**优先级
`NETBOX_TOKEN` > `NETBOX_TOKEN_CMD` > `NETBOX_TOKEN_FILE`**，读取后裁掉尾部空白：

- **`NETBOX_TOKEN_FILE`**：把 token 放进一个文件，由 nbx-guard 读取。适配 Docker / Kubernetes
  secret、systemd `LoadCredential`、Vault agent 渲染出的文件等——secret 永不进入环境块。
- **`NETBOX_TOKEN_CMD`**：执行一条命令、用其 **stdout** 作为 token。这是直接对接操作系统
  钥匙链的方式：

  ```sh
  export NETBOX_TOKEN_CMD='security find-generic-password -s netbox -w'   # macOS Keychain
  export NETBOX_TOKEN_CMD='secret-tool lookup service netbox'             # Linux libsecret
  export NETBOX_TOKEN_CMD='pass show netbox/token'                        # pass
  ```

  命令通过平台 shell（`/bin/sh -c`，Windows 为 `cmd /c`）执行；非零退出或空产出会以
  `config_error`（退出码 3）失败。命令期间不设超时，便于钥匙链交互解锁（如 Touch ID）。

`nbxg version` 会回显 `token_source`（`env` / `cmd` / `file` / `none`），便于确认 token 实际
来自哪里。

> NetBox 4.5 起新建 token 默认是 v2，且服务端必须配置 `API_TOKEN_PEPPERS` 才能创建/校验
> v2 token（netbox-docker 通过 `API_TOKEN_PEPPER_1` 提供）——这是 NetBox 侧的部署要求，
> 与 nbx-guard 无关。

token **绝不**写入本地状态目录，也绝不在命令输出中打印——`version` 只报告
`token_configured: true|false` 与来源 `token_source`。

## 自动审批 (autopilot)

默认每个高风险变更都要人工 `approve`。当你**在自己的分支 / 沙箱里处理数据**、只想保留
审计记录而不想逐条审批时，**人工算子**可以开启自动审批：

```sh
export NBX_GUARD_AUTO_APPROVE=1     # 或 ~/.nbx-guard/config.json: { "auto_approve": true }
```

开启后，`plan`（高风险 `update`）与 `create` 在创建计划的同时**自动生成一条
`approver: "auto"` 的审批记录**并把计划置为 `approved`，于是可直接 `apply`，省去手动
`approve` 这一步。其余所有控制保持不变：

- `plan_hash` 完整性校验与审批绑定；
- apply 前的漂移检测；
- apply 前的资源快照备份（可 `restore` 回滚，创建的回滚=删除）；
- 完整审计——自动审批会落一条独立的 `auto_approved` 事件，`approve` 与 `apply` 全程可追溯。

约束与建议：

- **算子专用、默认关闭（fail-safe）**：与其它 `NBX_GUARD_*` 治理变量同理，agent 不应自行
  设置；取值识别同布尔解析（`1`/`true`/`yes`/`on`）。
- **强烈建议与分支搭配**：配合 `NBX_GUARD_BRANCHING=1` + `NBX_GUARD_BRANCH=<schema_id>`，
  让自动审批的变更落进一个隔离分支，再由人工 `sync`/`merge`，既免去逐条审批、又保留
  「人工合并」这道安全网。
- 读取侧的敏感披露（`approve-read`）**不受**此开关影响，仍需单独审批——它属于数据外泄
  这条独立的风险轴。

`nbxg version` 会回显 `auto_approve: true|false`，便于确认当前是否处于自动审批模式。

## NetBox Branching

当 `NBX_GUARD_BRANCHING` 启用**且** `NBX_GUARD_BRANCH` 含有某个分支的 schema id 时，
nbx-guard 会给每个 NetBox 请求加上 `X-NetBox-Branch: <schema_id>` 头。这样读取、备份
以及 apply 的 PATCH 就都被限定在该分支内，而不是 `main`，于是 agent 的受控变更会在
一个隔离的分支里累积，留待后续审查。

- schema id 是分支 REST API 表示或详情页里显示的那个八字符标识——**不含** `branch_` 前缀。
- 如果分支未启用、或 schema id 为空，则不发送该头，写入直接落到 `main`。
- `version` 会回显解析后生效的分支，便于你确认路由已开启。

创建分支以及运行它的 `sync` / `merge` / `revert` 生命周期，是通过 NetBox 自身的
Branching API 完成的；这些审批者级别的操作刻意不由本网关暴露。参见
[架构](./architecture.md#netbox-branching)。

> **排错：token 有效却查不出数据。** 若 `list-resources`/`search` 返回 `count:0`、或 `resolve`
> 报 `not_found`，但 NetBox UI 里明明有数据——多半是数据在某个**分支**里，而本网关默认查 `main`。
> 按上面设置 `NBX_GUARD_BRANCHING=1` 与 `NBX_GUARD_BRANCH=<schema_id>` 后重试，并用 `nbxg version`
> 确认 `data.branch` 已回显。次要可能是 token 用户的对象级权限约束过滤掉了全部结果。
