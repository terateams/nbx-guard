# 06 · 默认拒绝挡路时：提案改配置（人工批准 + 审计）

`nbxg` 默认拒绝是为了安全，但一个**只会拒绝**的工具会把人挡在门外。正确做法不是绕过，而是把
「改门禁」这件事本身**透明化、受治理**：Agent 用 `config set` **提案**，人类批准，全程审计。

## 何时走这条路

当你撞上 `policy_denied`（字段不可写）、类型不在治理范围、或创建被拒（类型未开启）——
**不要自行 `export` 环境变量绕过**。先看清现状，再提案。

```sh
nbxg config show     # 先搞清楚：现在到底允许什么、想做更多该改哪个键
```

## 提案一项配置变更

```sh
# 例：把某低风险字段加入白名单 / 开启某类型的创建 / 追加受治理类型
nbxg config set allowed_fields=serial
nbxg config set creatable_resources=site
nbxg config set extra_resources=site:dcim/sites
nbxg config set auto_approve=true        # 高风险：开自动审批（仅建议在隔离分支）
```

`config set` **不立即改任何东西**，而是生成一个 `pending_approval` 的计划，列清楚：改哪个键、
从什么值到什么值、风险等级、用户要承担什么：

```json
{
  "ok": true,
  "command": "config",
  "data": {
    "plan": {
      "plan_id": "plan_cfg_77aa…",
      "changes": [ { "key": "allowed_fields", "from": "[]", "to": "[serial]", "risk": "medium" } ],
      "status": "pending_approval"
    }
  },
  "next_action": "explain impact to the human, then `nbxg approve --plan plan_cfg_77aa…`",
  "error": null
}
```

## 关键安全约束

- **配置变更永远不会被自动审批**——即使 `auto_approve` 已开，`config set` 生成的计划仍是
  `pending_approval`。这样 Agent 无法借"自动审批"给自己提权。
- **Agent 绝不自我审批自己的配置提案**：`config set` 之后**停下**，向人类说明「改什么、为什么、
  风险与责任」，等人类跑 `nbxg approve --plan <id>`，再由 Agent `nbxg apply --plan <id>` 写入。

## 完整链路

```sh
nbxg config set allowed_fields=serial     # ① Agent 提案 -> pending_approval
# ②（人类）审阅影响后批准：
nbxg approve --plan plan_cfg_77aa...
nbxg apply   --plan plan_cfg_77aa...       # ③ Agent 执行写入（自动备份旧配置，可回滚）
#  -> 审计记录 config_applied
```

## 要点

- 重要的不是"拒绝"，而是**让用户清楚自己在批准什么**。把代价讲明白，由人决定。
- 写入配置前会自动备份旧配置，改错了可 `restore`。
- 想撤销已开的放宽，再 `config set` 设回更严的值，同样走审批。
