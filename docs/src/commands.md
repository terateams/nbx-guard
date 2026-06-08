# 命令参考

每条命令都恰好打印**一个** JSON 信封（见[响应格式](./responses.md)）并设置退出码。
读写 NetBox 的命令都需要 `NETBOX_TOKEN`。

```text
nbx-guard version                          打印版本与当前生效配置
nbx-guard help                             显示帮助
nbx-guard get <type> <id>                  读取资源（只读）
nbx-guard inspect <type> <id>              读取资源并标注字段策略
nbx-guard plan <type> <id> --set k=v ...   创建变更计划（做策略 + 风险校验）
nbx-guard approve --plan <id> [--note x]   审批一个高风险 plan（绑定 plan_hash）
nbx-guard reject --plan <id> [--note x]    驳回一个 plan（之后 apply 会被拒绝）
nbx-guard apply --plan <id>                先备份，再应用一个已审批/低风险的 plan
nbx-guard restore --backup <id>            从备份快照回滚资源
nbx-guard audit [--plan <id>]              显示审计日志
nbx-guard list <plans|approvals|backups>   列出本地状态
```

## `version`

打印版本与当前生效配置（`netbox_url`、`branching`、`state_dir`、`token_configured`）。
不访问网络。也可用 `--version` / `-v`。

## `help`

打印用法、命令列表、支持的资源类型、允许/高风险字段列表，以及可识别的环境变量。
也可用 `--help` / `-h`。不带参数运行时打印帮助。

## `get <type> <id>`

从 NetBox 读取一个资源，原样返回在 `data.resource` 下。只读。需要 token。

## `inspect <type> <id>`

与 `get` 类似，但在响应中标注字段策略（`allowed_fields`、`high_risk_fields`），让 agent
能看到自己可以提议哪些字段。需要 token。

## `plan <type> <id> --set field=value ...`

创建一个变更计划。需要 token。步骤：

1. 校验资源类型。
2. 把 `--set` 键值对解析成一个 changes 对象。
3. 运行策略引擎；被拒绝的字段会中止流程并返回 `policy_denied`。
4. 读取一次当前资源，记录将被改动字段的**基线值（base_values）**，供 apply 时做漂移检测。
5. 存储该 plan，并追加一条 `plan_created` 审计记录。

响应包含完整的 `plan`、策略 `evaluation`，以及一个 `next_action`，告诉你下一步该
`approve`（高风险）还是 `apply`（低风险）。

### `--set` 取值解析

取值在可能时按 JSON 解析，否则当作字符串：

```sh
nbx-guard plan device 1 --set description="edge router"   # 字符串
nbx-guard plan device 1 --set status=active               # 字符串 "active"
nbx-guard plan device 1 --set tags='["core"]'             # JSON 数组
nbx-guard plan vlan 10 --set custom_fields='{"x":1}'      # JSON 对象
```

`--set k=v`、`--set=k=v`，以及裸写的 `k=v` 都被接受。

## `approve --plan <id> [--note <text>]`

审批一个处于 `pending_approval` 的 plan。创建一份绑定到该 plan 的 `plan_hash` 的
审批记录，把 plan 推进到 `approved`，并追加一条 `approved` 审计记录。审批者取自
`$USER`（否则为 `cli`）。审批一个并不在等待审批的 plan 会失败，返回 `plan_state_error`。

## `reject --plan <id> [--note <text>]`

驳回一个 plan，把它置为 `rejected`，并追加一条 `rejected` 审计记录。被驳回的 plan
之后再 `apply` 会被拒绝（`plan_state_error`）。已经 `applied` 的 plan 不能被驳回。
驳回者取自 `$USER`（否则为 `cli`）。

## `apply --plan <id>`

应用一个 plan。需要 token。步骤：

1. 若 plan 已是 `applied`，拒绝（`plan_state_error`）。
2. 若 plan 已被 `rejected`，拒绝（`plan_state_error`）。
3. 若高风险 plan 尚未 `approved`，拒绝（`not_approved`）。
4. 重新计算 `plan_hash` 并与存储值比对，检测 plan 文件被篡改；高风险 plan 还会校验
   审批记录绑定的是同一个 `plan_hash`（不一致则 `conflict`）。
5. 针对已存储的 changes 重新校验策略。
6. 获取当前资源；若被改动字段的当前值与 plan 记录的基线值不一致（外部漂移），
   在写入任何备份或变更之前拒绝（`conflict`）。
7. 写入一份 **backup**（快照 + 原值）。
8. 用 changes 对 NetBox 执行 `PATCH`。
9. 成功时：把 plan 标记为 `applied`，关联 `backup_id`，追加一条 `applied` 审计记录，
   并返回一个 `diff`（`before` / `after`）以及更新后的 `resource`。

如果 NetBox 拒绝该变更或连接失败，会写入一条 `apply_failed` 审计记录，并以
`netbox_error` 上报。

## `restore --backup <id>`

通过对备份中捕获的**原值**执行 `PATCH` 来回滚一个资源。需要 token。追加一条
`restored` 审计记录，并返回回滚后的资源。备份 id 不存在时失败，返回 `backup_not_found`。

## `audit [--plan <id>]`

打印审计日志，可用 `--plan <id>` 过滤到单个 plan。返回一个 `count` 和匹配的 `entries`。

## `list <plans|approvals|backups>`

列出指定种类的已存储 JSON 记录。返回 `kind`、`count` 以及原始 `items`。目录为空或
不存在时返回 `count: 0`。
