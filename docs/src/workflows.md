# 工作流

先一次性设置好连接：

```sh
export NETBOX_URL=https://netbox.example.com
export NETBOX_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## 低风险变更

只触及允许字段（`description`、`comments`、`tags`、`custom_fields`）的变更无需审批。

```sh
nbxg plan device 1 --set description="edge router"
# -> { plan_id, plan_hash, risk_level: "low", status: "planned",
#      next_action: "low-risk: run `nbxg apply --plan <plan_id>`" }

nbxg apply --plan plan_...      # 快照一份备份，PATCH，写审计
nbxg restore --backup bkp_...   # 需要时回滚
```

## 高风险变更（需要审批）

触及任一高风险字段（`status`、`role`、`site`、`rack`、`prefix`、`address`）的变更必须
先经过审批。

```sh
nbxg plan device 1 --set status=active
# -> status: "pending_approval", next_action: "...approve... then apply"

nbxg apply --plan plan_...
# 被拒：error.kind = "not_approved"

nbxg approve --plan plan_... --note "approved by netops"
nbxg apply --plan plan_...      # 现在被允许
```

## 驳回 plan（reject）

已创建但你不想执行的 plan，可以显式驳回；之后再 `apply` 会被拒绝：

```sh
nbxg reject --plan plan_... --note "暂不执行"
nbxg apply  --plan plan_...
# 被拒：error.kind = "plan_state_error"
```

## 被拒绝的变更

改动策略之外字段的变更，会在 plan 阶段就被拒绝——不存储任何东西：

```sh
nbxg plan device 1 --set name="core-1"
# -> error.kind = "policy_denied"（name 不是可写字段）
```

## 提议前先 inspect

agent 可以把资源连同策略一起查看，从而决定能安全提议什么：

```sh
nbxg inspect device 1
# data.resource = 实时资源；data.policy = 允许/高风险字段
```

## 审计与列举

```sh
nbxg audit                 # 完整审计轨迹
nbxg audit --plan plan_... # 只看某个 plan 的事件
nbxg list plans            # 已存储的 plans
nbxg list approvals        # 已存储的 approvals
nbxg list backups          # 已存储的 backups
```

## 推荐的 agent 循环

1. `inspect` 资源，了解哪些字段可写。
2. `plan` 出预期的变更。
3. 读取信封里的 `next_action`：
   - `low` 风险 → `apply`。
   - `high` 风险 → 请人工 `approve`，然后 `apply`。
4. 保留返回的 `backup_id`，以便日后 `restore` 该变更。
5. 用 `audit` / `request_id` 确认并追溯结果。
