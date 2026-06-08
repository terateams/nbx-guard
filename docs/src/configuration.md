# 配置

所有**密钥与运行参数**都从进程环境变量读取（参见仓库中的 `.env.example`）。没有 token
就不会向 NetBox 写入任何东西。**治理扩展**（新增类型/字段）既可用环境变量，也可用一个
可选的 JSON 配置文件 `~/.nbx-guard/config.json`（见下文「算子配置文件」）。

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `NETBOX_URL` | `http://localhost:8000` | NetBox 基础 URL，末尾的斜杠会被去掉。 |
| `NETBOX_TOKEN` | _（未设置）_ | API token；`get` / `inspect` / `plan` / `apply` / `restore` **必需**。 |
| `NBX_GUARD_STATE_DIR` | `.nbx-guard` | 本地状态目录（plans、approvals、backups、审计日志）。 |
| `NBX_GUARD_HTTP_TIMEOUT_MS` | `15000` | 单次 NetBox 请求的连接超时（毫秒），避免 NetBox 不可达时 CLI 永久挂起；`0` 关闭。 |
| `NBX_GUARD_BRANCHING` | `0` | 将读写路由进某个 NetBox Branching 分支。 |
| `NBX_GUARD_BRANCH` | _（未设置）_ | 生效分支的 schema id，作为 `X-NetBox-Branch` 头发送。 |
| `NBX_GUARD_EXTRA_RESOURCES` | _（未设置）_ | 算子新增受治理类型（`类型=端点` 列表）。详见[策略](./policy.md#算子扩展默认拒绝之外的显式放行)。 |
| `NBX_GUARD_ALLOWED_FIELDS` | _（未设置）_ | 算子追加的低风险可写字段（逗号/空格分隔）。 |
| `NBX_GUARD_HIGH_RISK_FIELDS` | _（未设置）_ | 算子追加的高风险字段（写入需审批）。 |
| `NBX_GUARD_READ_SENSITIVE_FIELDS` | _（未设置）_ | 算子追加的读敏感字段（默认读取脱敏，整对象读取需 `approve-read`）。 |
| `NBX_GUARD_CREATABLE_RESOURCES` | _（未设置）_ | 算子开启 `create` 的类型（逗号/空格分隔，`*` 表示任意类型）。默认空=禁止创建；每次创建仍需审批。 |
| `NBX_GUARD_CONFIG` | _（未设置）_ | 算子配置文件路径覆盖；默认 `~/.nbx-guard/config.json`。 |

## 布尔值解析

`NBX_GUARD_BRANCHING` 在取值为 `1`、`true`、`yes`、`on`（不区分大小写）时视为 **true**。
其它任何值——包括未设置——都视为 **false**。

## `.env` 示例

```sh
export NETBOX_URL=https://netbox.example.com
export NETBOX_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export NBX_GUARD_STATE_DIR=.nbx-guard
export NBX_GUARD_HTTP_TIMEOUT_MS=15000
export NBX_GUARD_BRANCHING=0
```

## 算子配置文件（治理扩展）

除环境变量外，**人工算子**还可以把治理扩展写进一个 JSON 文件，免去导出三个环境变量。
默认路径 `~/.nbx-guard/config.json`（用 `NBX_GUARD_CONFIG` 可改路径）：

```json
{
  "extra_resources":      { "site": "dcim/sites", "tenant": "tenancy/tenants" },
  "allowed_fields":       ["serial", "asset_tag"],
  "high_risk_fields":     ["tenant"],
  "read_sensitive_fields": ["serial"],
  "creatable_resources":  ["site", "vlan"]
}
```

- 五个键分别等价于 `NBX_GUARD_EXTRA_RESOURCES` / `NBX_GUARD_ALLOWED_FIELDS` /
  `NBX_GUARD_HIGH_RISK_FIELDS` / `NBX_GUARD_READ_SENSITIVE_FIELDS` /
  `NBX_GUARD_CREATABLE_RESOURCES`，行为完全一致；
  文件与环境变量**取并集**（键冲突时环境变量优先）。
- `creatable_resources` 开启 `nbxg create` 的类型（`*` 表示任意已登记类型）；创建始终需审批。
- **只放治理扩展，密钥仍只走环境变量**：不要把 `NETBOX_URL` / `NETBOX_TOKEN` 写进此文件。
- 文件不存在则静默跳过（向后兼容）；JSON 非法或 `NBX_GUARD_CONFIG` 指向的文件缺失 →
  以 `config_error`（退出码 3）失败。
- `~/.nbx-guard/`（算子配置）与状态目录 `.nbx-guard/`（plans/backups/审计）是两个不同目录。

完整语义与 fail-safe 约束见[策略 · 算子扩展](./policy.md#算子扩展默认拒绝之外的显式放行)。

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

> NetBox 4.5 起新建 token 默认是 v2，且服务端必须配置 `API_TOKEN_PEPPERS` 才能创建/校验
> v2 token（netbox-docker 通过 `API_TOKEN_PEPPER_1` 提供）——这是 NetBox 侧的部署要求，
> 与 nbx-guard 无关。

token **绝不**写入本地状态目录，也绝不在命令输出中打印——`version` 只报告
`token_configured: true|false`。

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
