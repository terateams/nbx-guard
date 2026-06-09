# 04 · 创建新对象：create → approve → apply（逐次审批）

`create` 只能创建算子在 `creatable_resources` 里开启的类型（默认配置为 `["*"]`，即允许任意已登记
类型）。**每次创建都必须审批**——即便类型已开启，也不会免审批。

## 流程

```sh
# 1) 提创建计划（总是高风险、总需审批）
nbxg create ip-address --set address=192.0.2.50/32 status=active description="loopback for spine-2"
#  -> data.plan.plan_id、action:"create"、requires_approval:true、status:"pending_approval"

# 2) 人工批准
nbxg approve --plan plan_c4d5... --note "new loopback approved"

# 3) 应用 = 真正在 NetBox 里创建对象
nbxg apply --plan plan_c4d5...
#  -> data.created.id（新对象 id）、data.backup_id
```

`create` 的响应（结构以实际为准）：

```json
{
  "ok": true,
  "command": "create",
  "data": {
    "plan": {
      "plan_id": "plan_c4d5e6f7",
      "action": "create",
      "resource_type": "ip-address",
      "changes": [
        { "field": "address", "to": "192.0.2.50/32" },
        { "field": "status", "to": "active" }
      ],
      "requires_approval": true,
      "status": "pending_approval"
    }
  },
  "next_action": "get human approval via `nbxg approve --plan plan_c4d5e6f7`",
  "error": null
}
```

## 创建的回滚 = 删除

`nbxg` **不提供** delete 作为 agent 动作。删除只作为「创建」的撤销，由 `restore` 内部执行：

```sh
nbxg restore --backup bkp_...   # 对一笔 create 的回滚，即删除刚创建的对象
```

## 要点

- 想知道某类型有哪些字段、枚举值，先 `nbxg describe <type> --source openapi`，按返回的字段与
  choices 组织 `--set`，减少 `policy_denied` 与校验失败。
- 若类型未开启创建：返回 `policy_denied`，**不要绕过**——用 06 的 `config set` 提案开启，人工批准。
- 默认 `auto_approve:false` 时，创建按上面「人工 approve」走。算子开了 `auto_approve`（通常在隔离
  分支）时，`create` 与高风险 update 一样会 `auto_approved:true`、可跳过 `approve` 直接 `apply`，
  审计与备份照常。Agent 自己**绝不**去开这个开关。
