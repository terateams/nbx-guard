# 本地状态

nbx-guard 把它的全部状态保存在单一目录里（默认 `.nbx-guard/`，可用
`NBX_GUARD_STATE_DIR` 覆盖）。一切都是纯 JSON / JSONL，便于查看、备份和审计。

```text
.nbx-guard/
├── plans/<plan_id>.json
├── approvals/<approval_id>.json
├── backups/<backup_id>.json
└── audit.jsonl
```

## 标识符

id 带前缀且按时间排序，因此它们会按时间顺序排列，在日志里也易于辨认：

| 前缀 | 示例 | 由谁创建 |
| --- | --- | --- |
| `plan_` | `plan_1730000000_a1b2c3` | `plan` |
| `req_` | `req_1730000000_d4e5f6` | 每条会改动状态的命令 |
| `appr_` | `appr_1730000000_7890ab` | `approve` |
| `bkp_` | `bkp_1730000000_cdef01` | `apply` |

格式为 `<前缀>_<unix 秒>_<6 位十六进制随机数>`。

## Plans

每个 plan 文件存储意图与裁决：`plan_id`、`request_id`、`plan_hash`、`resource_type`、
`resource_id`、`action`、`changes`、`risk_level`、`requires_approval`、`status`、
可选的 `approval_id` / `backup_id`、`created_at`，以及 `netbox_url`。

## Approvals

一份 approval 绑定到某个 plan 的 `plan_hash`：`approval_id`、`plan_id`、`plan_hash`、
`resource_type`、`resource_id`、`risk_level`、`status`、`approver`、`created_at`，以及
可选的 `note`。因为它带着哈希，所以一份 approval 无法被移植到另一个（被篡改的）plan 上。

## Backups

一份 backup 捕获回滚所需的一切：`backup_id`、`plan_id`、`resource_type`、`resource_id`、
紧接应用前所取的完整 `snapshot`、被改动字段的 `prior_values`、`created_at`，以及
`netbox_url`。`restore` 会重放 `prior_values`：因为 NetBox 在 GET 时把选择字段返回成
`{value,label}`、关联对象返回成 `{id,...}`，而写入只接受 slug / id，所以还原时会先把这些
表示折叠回可写形态（选择字段取 `value`、关联对象取 `id`），高风险字段才能被可靠回滚。

## 审计日志

`audit.jsonl` 是**只追加（append-only）**的；每行一个 JSON 对象。事件包括
`plan_created`、`approved`、`rejected`、`applied`、`apply_failed` 和 `restored`。每条记录
都带一个时间戳，以及相应的 `request_id`、`plan_id`、`approval_id`、`backup_id`，因此任何
变更都能从意图一路追溯到结果（乃至它的回滚）。

## 写入的崩溃安全与并发

- **原子写入**：所有状态文件都先写入同目录下的临时文件，再 `rename` 覆盖目标。进程即使
  在写入中途被杀，也不会留下被截断的文件（被截断的 backup 会导致无法回滚），读取方永远
  只会看到旧文件或新文件。
- **互斥锁**：每条会改动状态的命令（`plan`/`approve`/`reject`/`apply`/`restore`）在运行
  期间持有 `<state_dir>/.lock` 上的独占建议锁，因此并发调用会串行化，而不是相互竞争导致
  审计丢条目或重复 apply。进程退出时操作系统会自动释放该锁。

## 运维提示

- 把状态目录当作“谁、改了什么”的**唯一可信来源**；生产环境中请存放在持久、有访问控制
  的地方。
- 该目录不含任何密钥——NetBox token 绝不会持久化在这里。
- 仓库的 `.gitignore` 排除了 `.nbx-guard/`，因此本地运行不会被提交。
