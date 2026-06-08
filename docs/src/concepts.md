# 核心概念

nbx-guard 为每一次变更建模出单一、可审计的生命周期。agent 永远只产生*第一步*
（意图）；之后的一切都由 CLI 掌控。

```text
plan ──> (approve) ──> apply ──> (restore)
  │           │           │           │
 策略       绑定         备份 +       从备份
 + 风险    plan_hash     PATCH        回滚
```

## Plan（计划）

一个 **plan** 捕获 agent 的意图：一个资源（`type` + `id`）、动作（MVP 中恒为
`update`），以及一组字段 `changes`。创建 plan 会运行[策略](./policy.md)引擎并赋予
一个风险等级。此阶段不会向 NetBox 写入任何东西。

每个 plan 都有一个状态：

| 状态 | 含义 |
| --- | --- |
| `planned` | 低风险 plan，可直接 `apply`。 |
| `pending_approval` | 高风险 plan，需先 `approve` 才能应用。 |
| `approved` | 已审批的高风险 plan。 |
| `applied` | 变更已推送到 NetBox。 |
| `rejected` | 预留给被拒绝的 plan。 |

## `plan_hash`

每个 plan 都有一个确定性的 **`plan_hash`**——对规范化的
`{resource_type, resource_id, action, changes}` 求 SHA-256。它是 plan 的防篡改身份：
审批绑定到这个哈希，因此一个已审批的 plan 无法被悄悄篡改后再应用。

## 风险等级

策略引擎对被改动的字段进行分类：

- **low（低）**——只触及允许的（低风险）字段 → 可直接应用。
- **high（高）**——触及至少一个高风险字段 → 需要审批。

如果有任何字段在策略之外，该 plan 会被直接拒绝。参见[策略](./policy.md)。

## Approval（审批）

一份 **approval** 是绑定到某个 plan 的 `plan_hash` 的记录。它记录谁批准的
（`USER`，未设置时为 `cli`）、可选的备注，以及时间戳。只有处于 `pending_approval`
的 plan 才能被审批。

## Backup（备份）

在任何 `apply` 之前，nbx-guard 会先获取当前资源，并存储一份 **backup**，其中包含
完整快照，外加*恰好*那些将被改动字段的*原值（prior values）*。`restore` 正是用它
来回滚。

## Audit（审计）

每一个有意义的事件——`plan_created`、`approved`、`applied`、`apply_failed`、
`restored`——都会被追加到一个只追加（append-only）的 JSONL **审计**日志里。每条记录
都关联相应的 `request_id`、`plan_id`、`approval_id` 和 `backup_id`，因此任何变更都能
被端到端地追溯。

## Request id（请求 id）

每一次会改动状态的命令调用都会生成一个 `request_id`。它出现在响应信封和审计日志中，
为你在 plan、approval、apply、restore 各事件之间提供一个关联句柄。
