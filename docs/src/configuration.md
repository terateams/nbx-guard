# 配置

所有配置都从**进程环境变量**读取（参见仓库中的 `.env.example`）。没有 token
就不会向 NetBox 写入任何东西。

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `NETBOX_URL` | `http://localhost:8000` | NetBox 基础 URL，末尾的斜杠会被去掉。 |
| `NETBOX_TOKEN` | _（未设置）_ | API token；`get` / `inspect` / `apply` / `restore` **必需**。 |
| `NBX_GUARD_STATE_DIR` | `.nbx-guard` | 本地状态目录（plans、approvals、backups、审计日志）。 |
| `NBX_GUARD_BRANCHING` | `0` | 将读写路由进某个 NetBox Branching 分支。 |
| `NBX_GUARD_BRANCH` | _（未设置）_ | 生效分支的 schema id，作为 `X-NetBox-Branch` 头发送。 |

## 布尔值解析

`NBX_GUARD_BRANCHING` 在取值为 `1`、`true`、`yes`、`on`（不区分大小写）时视为 **true**。
其它任何值——包括未设置——都视为 **false**。

## `.env` 示例

```sh
export NETBOX_URL=https://netbox.example.com
export NETBOX_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
export NBX_GUARD_STATE_DIR=.nbx-guard
export NBX_GUARD_BRANCHING=0
```

## 状态存放在哪里

默认情况下，nbx-guard 把 plans、approvals、backups 和审计日志写到当前工作目录下的
`.nbx-guard/`。如果你希望审计轨迹跨多次运行持久保留、或被团队共享，就把
`NBX_GUARD_STATE_DIR` 指向一个持久、有访问控制的位置。磁盘布局见
[本地状态](./state.md)。

## token 的处理

token 从环境读取，并作为 `Token <token>` 的 Authorization 头发送给 NetBox。它
**绝不**写入本地状态目录，也绝不在命令输出中打印——`version` 只报告
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
