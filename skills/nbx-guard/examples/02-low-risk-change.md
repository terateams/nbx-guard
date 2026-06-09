# 02 · 低风险改字段：plan → apply（免审批）

像 `description` / `comments` / `tags` 这类低风险字段，`plan` 后**不需要人工审批**，直接 `apply`。

## 流程

```sh
# 1) 提计划（策略 + 风险校验）
nbxg plan ip-address 42 --set description="reserved for spine-1"
#  -> data.plan.plan_id、risk_level:"low"、requires_approval:false
#     next_action: low-risk: run `nbxg apply --plan <plan_id>`

# 2) 应用（先备份，再 PATCH，写审计）
nbxg apply --plan plan_8f3a...
#  -> data.backup_id  ← 记住它，回滚要用（见 05）
```

`plan` 的响应（结构以实际为准）：

```json
{
  "ok": true,
  "command": "plan",
  "data": {
    "plan": {
      "plan_id": "plan_8f3a2c10",
      "plan_hash": "sha256:…",
      "resource": { "type": "ip-address", "id": 42 },
      "changes": [ { "field": "description", "from": "", "to": "reserved for spine-1" } ],
      "risk_level": "low",
      "requires_approval": false,
      "status": "planned"
    }
  },
  "next_action": "low-risk: run `nbxg apply --plan plan_8f3a2c10`",
  "error": null
}
```

`apply` 成功：

```json
{ "ok": true, "command": "apply",
  "data": { "applied": true, "backup_id": "bkp_5d91…", "resource": { "type": "ip-address", "id": 42 } },
  "error": null }
```

## 要点

- **照着 `next_action` 走**：低风险时它直接让你 `apply`，无需 `approve`。
- 一个 `--set` 可带多个字段：`--set description="x" comments="y"`；只要全是低风险就仍免审批，
  混入高风险字段则整条计划升级为高风险（见 03）。
- `apply` 前 CLI 会做**漂移检测**：若资源在 `plan` 之后被外部改动，`apply` 以 `conflict` 拒绝且
  不产生半成品变更——这时重新 `get`/`plan`，**别盲目重试**。
- 改错了用 `data.backup_id` 回滚（见 05）。
