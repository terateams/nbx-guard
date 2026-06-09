# 03 · 高风险改字段：plan → approve → apply（人工批准）

像 `status` / `role` / `site` 这类高风险字段，`plan` 会标 `requires_approval:true`，**必须人工
`approve` 后才能 `apply`**。Agent 不应自我审批。

## 流程

```sh
# 1) 提计划：判定为高风险，进入待批准
nbxg plan ip-address 42 --set status=deprecated
#  -> risk_level:"high"、requires_approval:true、status:"pending_approval"

# 2) 此时直接 apply 会被拒
nbxg apply --plan plan_a1b2...
#  -> ok:false、error.kind:"not_approved"

# 3) 人工批准（绑定 plan_hash）
nbxg approve --plan plan_a1b2... --note "approved by netops"

# 4) 现在放行
nbxg apply --plan plan_a1b2...
#  -> data.backup_id
```

`plan` 的高风险响应（结构以实际为准）：

```json
{
  "ok": true,
  "command": "plan",
  "data": {
    "plan": {
      "plan_id": "plan_a1b2c3d4",
      "risk_level": "high",
      "requires_approval": true,
      "status": "pending_approval"
    }
  },
  "next_action": "high-risk: get human approval via `nbxg approve --plan plan_a1b2c3d4`",
  "error": null
}
```

未批准就 apply：

```json
{ "ok": false, "command": "apply",
  "data": null,
  "error": { "kind": "not_approved", "message": "plan requires approval before apply" } }
```

## 谁来按 approve？

- **人类运维**：在 `pending_approval` 处停下，把「改什么、从什么到什么、风险」讲清楚，请人跑
  `nbxg approve`。Agent **绝不**替人类按下这一步。
- **算子开了自动审批**（`nbxg version` 里 `auto_approve:true`，通常在隔离分支）：`plan` 响应里会是
  `auto_approved:true` 且 `next_action` 直接是 `apply`——这时**跳过 approve**，直接 `apply`。
  审计、备份、审批记录（approver=`auto`）照常完整写入。Agent 自己**绝不**去开这个开关。

## 拒绝一个计划

```sh
nbxg reject --plan plan_a1b2... --note "wrong target"   # 之后该计划永不可 apply
```

## 要点

- 同时检查退出码与 `.ok`：被拒时退出码 `2`，`error.kind` 告诉你为什么。
- `approve` 绑定 `plan_hash`；若计划被篡改，审批自动失效。
- 批准后仍有漂移检测：`apply` 前资源被外部改动会以 `conflict` 拒绝。
