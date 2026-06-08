# 响应格式

每条命令都恰好向 stdout 打印**一个** JSON 信封，别无其它，因此 agent 能确定性地
解析结果。

## 信封

```json
{
  "ok": true,
  "command": "plan",
  "data": { "...": "命令相关的载荷" },
  "error": null
}
```

| 字段 | 类型 | 含义 |
| --- | --- | --- |
| `ok` | bool | 成功为 `true`，失败为 `false`。 |
| `command` | string | 产生该信封的命令。 |
| `data` | object \| null | 成功时为命令相关载荷；失败时为 `null`。 |
| `error` | object \| null | 失败时为结构化错误；成功时为 `null`。 |

## error 对象

```json
{
  "ok": false,
  "command": "apply",
  "data": null,
  "error": {
    "kind": "not_approved",
    "message": "high-risk plan requires approval before apply",
    "risk_level": "high",
    "next_action": "run `nbx-guard approve --plan <plan_id>` first"
  }
}
```

| 字段 | 含义 |
| --- | --- |
| `kind` | 稳定、机器可读的错误类别（见下）。 |
| `message` | 人类可读的说明。 |
| `risk_level` | `low` 或 `high`。 |
| `next_action` | agent（或人）下一步该做什么。 |

## 错误类别（error.kind）

`error.kind` 始终是以下之一：

| 类别 | 典型原因 |
| --- | --- |
| `invalid_args` | 未知命令，或参数缺失/非法。 |
| `config_error` | 配置问题（例如必需场景下缺少 token）。 |
| `policy_denied` | 请求改动的字段不可写（默认拒绝）。 |
| `invalid_field` | 字段取值不可接受。 |
| `needs_approval` | plan 是高风险且尚未审批。 |
| `not_approved` | 对未审批的高风险 plan 执行了 `apply`。 |
| `plan_not_found` | 没有对应 id 的 plan。 |
| `approval_not_found` | 没有对应 id 的 approval。 |
| `backup_not_found` | 没有对应 id 的 backup。 |
| `plan_state_error` | plan 状态不适合此操作。 |
| `netbox_error` | NetBox 返回错误或不可达。 |
| `conflict` | 资源在 plan 之下被改动了。 |
| `io_error` | 本地状态读写失败。 |
| `not_implemented` | 此构建中尚不可用的功能。 |

## 退出码

| 码 | 含义 |
| --- | --- |
| `0` | 成功。 |
| `2` | 客户端 / 策略 / 状态错误（你的输入或本地状态）。 |
| `3` | 上游 / 配置 / IO 错误（NetBox、环境、磁盘）。 |

这样调用方可以先按退出码分支，再读 `error.kind` 看细节。
