# 实战案例

把常见的运维场景串成**可直接照抄**的命令序列。每个案例都标了**看点**——这一步到底
被哪条保证拦住、或为什么放行。命令里的 `plan_…` / `bkp_…` / `rplan_…` 都是占位 id，
换成上一步返回的真实值；注释里 `-> …` 表示该命令返回信封的关键字段。

> **先决条件**：已设好连接（`NETBOX_URL` + token，见[配置](./configuration.md)）。
> 不确定能不能做某件事？**先 `nbxg config show`**——能做就直接做，不能再提案（[案例 7](#case-7)）。

## 场景速查

| 我想…… | 看这个 |
| --- | --- |
| 先找到对象 id、看清能改什么 | [案例 1](#case-1) |
| 改个备注 / 标签（免审批） | [案例 2](#case-2) |
| 改状态 / 角色（要人批） | [案例 3](#case-3) |
| 新建一个对象 | [案例 4](#case-4) |
| 看被打码的敏感字段 | [案例 5](#case-5) |
| 变更前后取证、对比 | [案例 6](#case-6) |
| 被默认拒绝挡住了 | [案例 7](#case-7) |
| 在自己分支里批量改、免逐条审批 | [案例 8](#case-8) |
| 命令报错了怎么办 | [案例 9](#case-9) |
| 撤销一次误操作、追溯过程 | [案例 10](#case-10) |

<a id="case-1"></a>

## 案例 1 · 先发现 id，再看清能改什么

所有 id 级操作（`get`/`plan`）都要先有 id。别猜，用 `search`/`resolve` 拿准。

```sh
# 只有模糊关键词：先搜（命中列表里挑）
nbxg search device -q core --filter status=active
#  -> data.results[]：每条带 id / display

# 已知确切名字/地址：直接解析成 id
nbxg resolve device --name edge-router
#  -> ok:true, data.resolved.id = 123
#  歧义时 -> ok:false, error.kind:"ambiguous", data.candidates[]（你来定，绝不替你瞎选）

# 看清这个对象：能读到什么、能改什么
nbxg inspect device 123
#  -> data.resource（读敏感字段默认打码）
#     data.policy.allowed_fields（免审批可改） / high_risk_fields（要人批）
```

**看点**：读取（`search`/`resolve`/`inspect`）不触发审批。`resolve` 歧义时退出码 `2`，会
中断 shell 的 `&&` 链，逼你显式选定一个 id——这是刻意设计，避免「猜错对象」这种昂贵错误。

<a id="case-2"></a>

## 案例 2 · 改个备注/标签（低风险，一气呵成）

只动 `description` / `comments` / `tags` / `custom_fields` 这类低风险字段，免审批。

```sh
nbxg plan device 123 --set description="汇聚层 · 二号机房"
#  -> data.plan.plan_id, risk_level:"low", status:"planned"
#     next_action: low-risk: run `nbxg apply --plan <plan_id>`

nbxg apply --plan plan_a1b2
#  -> 先存 backup，再 PATCH，写 applied 审计；返回 diff(before/after) 与 backup_id
```

**看点**：低风险也照样「先备份、后改动、全程审计」。如果 `--set` 的值跟线上**完全一样**，
会返回 `no_change`（退出码 `2`）且压根不建 plan——信封的 `data` 里给 `requested` 与 `current`
两组值，方便你判断到底要改成什么。

<a id="case-3"></a>

## 案例 3 · 改状态/角色（高风险，要人批）

碰到 `status` / `role` / `site` / `rack` / `prefix` / `address` 任一个，就必须人工审批。

```sh
nbxg plan device 123 --set status=offline
#  -> risk_level:"high", status:"pending_approval", requires_approval:true

nbxg apply --plan plan_c3d4
#  直接 apply 被拒 -> ok:false, error.kind:"not_approved"

# 人来批（审批绑定这份 plan 的 plan_hash）
nbxg approve --plan plan_c3d4 --note "netops 已确认"
nbxg apply   --plan plan_c3d4
#  -> 通过。apply 前重算 plan_hash、核对审批绑定、比对线上现值，全过才动手
```

**看点**：高风险必须人批，且审批和这份 plan 的哈希**绑死**，没法批了 A 偷偷应用 B。若对象
在你建 plan 之后被别处改过（漂移），apply 会在写任何备份/变更**之前**以 `conflict` 拒绝，
绝不覆盖你没预期到的状态。

<a id="case-4"></a>

## 案例 4 · 新建一个对象（create，逐次审批 + 建错可回滚）

```sh
# 类型默认禁；先确认 site 在 creatable_resources 白名单里（不在 -> 见案例 7）
nbxg create site --set name=POP3 --set slug=pop3 --set status=active
#  -> action:"create", risk_level:"high", status:"pending_approval"

nbxg approve --plan plan_e5f6
nbxg apply   --plan plan_e5f6
#  -> POST 创建；data.resource_id = NetBox 分配的新 id

# 建错了？回滚一次创建 = 删掉刚建的对象
nbxg restore --backup bkp_...
```

**看点**：创建**永远是高风险、永远要批、每次单独批**。agent 自己没有 `delete` 权限——
回滚一次创建时，由 nbxg 内部用一次 `DELETE` 完成，agent 接触不到这把「删除」的刀。

<a id="case-5"></a>

## 案例 5 · 看被打码的敏感字段（读审批流程）

`phone` / `email` / `comments` / `custom_fields` / `tenant` 默认打码。要看原值，走读审批。

```sh
nbxg get contact 7                          # 默认 basic：敏感字段 -> [redacted: read approval required]
nbxg get contact 7 --fields all --plan-read
#  -> 建「读 plan」rplan_…, status:"pending_approval"，仍只给脱敏预览

nbxg approve-read --plan rplan_...          # 人工审批（注意是 approve-read，不是 approve）
nbxg get contact 7 --fields all --plan rplan_...
#  -> 披露整对象，写一条 read_served 审计
```

**看点**：读敏感是一条**独立的「数据外泄」风险轴**——即便开了 autopilot（[案例 8](#case-8)）也
不放行，必须单独 `approve-read`。批量 `export` / `list` 则**永不**披露原值（一个集合没有逐对象
的读审批绑定）。

<a id="case-6"></a>

## 案例 6 · 变更前后取证、对比（snapshot / export）

```sh
# 改之前给单个对象拍快照存档
nbxg snapshot device 123 --out snapshots/device-123-before.json

# 整批盘点：自动翻页抓全，带来源元数据（token 绝不写进文件）
nbxg export device --filter site=tokyo --fields basic --format jsonl \
  --out snapshots/tokyo-devices.jsonl
```

**看点**：工件的 `metadata` 里带 `generated_at` / `netbox_instance` / `nbxg_version` 等溯源
信息，适合做变更评审、离线审批和事后对比。`--fields full` 档会**逐条**给读敏感字段打码——
要看单个对象的原值，仍走[案例 5](#case-5)的读审批。

<a id="case-7"></a>

## 案例 7 · 被默认拒绝挡住了——提案改配置

默认拒绝不是终点。普通人也能在**保留审计**的前提下，让 agent 提案、你点头来扩权限。

```sh
nbxg config show
#  -> capabilities（现在能做什么） + to_change（想做更多跑哪条 config set）

# 例：把 serial 加进免审批可写字段；或开启某类型的创建
nbxg config set allowed_fields=serial
#  -> 不立即生效，而是生成 pending_approval 的 plan，列出 改什么 / 从→到 / 风险 / 影响

nbxg approve --plan plan_...      # 人来批
nbxg apply   --plan plan_...      # 写入配置（旧配置自动备份到 config-backups/，可回滚），写 config_applied 审计
```

**看点**：`config set` **永不被自动审批**——哪怕 autopilot 开着，改配置也必须人批，agent
没法借此自我提权。明文 token（`netbox_token`/`token`）、未知键、非法值一律拒绝。完整链路：
`config set`（agent 提案）→ `approve`（人）→ `apply`（写入）。

<a id="case-8"></a>

## 案例 8 · 在自己分支里批量改（autopilot + 分支）

在自己的分支/沙箱里清洗数据时，逐条审批很烦。**人工算子**可以开自动审批，只留审计。

```sh
# 这些 NBX_GUARD_* 是算子开关，agent 不应自行设置
export NBX_GUARD_BRANCHING=1
export NBX_GUARD_BRANCH=<schema_id>     # 八字符，不含 branch_ 前缀
export NBX_GUARD_AUTO_APPROVE=1
nbxg version                            # 确认 data.branch 已回显、auto_approve:true

nbxg plan device 123 --set role=core
#  -> 高风险，但自动落一条 approver:"auto" 的审批，status 直接到 "approved"
nbxg apply --plan plan_...              # 直接应用；改动落在隔离分支，不是 main
```

**看点**：autopilot 只省掉「逐条人批」这一步——`plan_hash` 校验、漂移检测、备份、审计
一个不少（还多一条独立的 `auto_approved` 事件）。**强烈建议配合分支**：变更先攒在隔离分支，
最后由人在 NetBox 里 `sync`/`merge`，保留「人工合并」这道安全网。读敏感披露不受此开关影响。

<a id="case-9"></a>

## 案例 9 · 命令报错了怎么办（按 error.kind / 退出码排错）

先看退出码分大类，再读 `error.kind` 看细节，最后照 `error.next_action` 做。

| 现象 | `error.kind` | 退出码 | 怎么办 |
| --- | --- | --- | --- |
| 想改的字段被挡 | `policy_denied` | 2 | 字段不在白名单——换字段，或[案例 7](#case-7)提案放行 |
| apply 说要审批 | `not_approved` | 2 | 先 `approve`（高风险），再 apply（[案例 3](#case-3)） |
| apply 报冲突 | `conflict` | 2 | 对象被别处改过（漂移）或哈希不符——重新 `plan` 再来 |
| `resolve` 命中多个 | `ambiguous` | 2 | 看 `data.candidates[]`，显式选定一个 id |
| plan 没建出来 | `no_change` | 2 | `--set` 的值跟现状一样；看 `data.current` 决定改成啥 |
| 搜不到 / 查不到数据 | `not_found`（或 `count:0`） | 2 / 0 | 数据可能在某**分支**里——设 `BRANCHING`+`BRANCH` 重试（[案例 8](#case-8)） |
| NetBox 报错 | `netbox_error` | 3 | 读 `message` 里 NetBox 透传的 `detail`：`Invalid v2 token`=凭据问题；`You do not have permission …`=权限问题，据此处理而非盲目重试 |

**看点**：退出码 `2` = 你的输入 / 本地状态问题；`3` = NetBox / 环境 / 磁盘问题。调用方可以先按
退出码分支，无需解析 JSON 就能决定「重试 vs 改输入 vs 找人」。

<a id="case-10"></a>

## 案例 10 · 撤销一次误操作、追溯整个过程

```sh
# 用那次 apply 返回的 backup_id 回滚
nbxg restore --backup bkp_...
#  -> 按备份里的原值 PATCH 回去，写一条 restored 审计

# 端到端追溯这次变更的每一步
nbxg audit --plan plan_...
#  -> plan_created -> approved -> applied -> restored，每条都挂 request_id / backup_id
nbxg list backups          # 忘了 backup id？在这儿找
```

**看点**：每个会写状态的命令都生成一个 `request_id`，把 plan / approve / apply / restore
串成一条链。任何一次改动，都能照备份还原、并在审计里端到端复盘——这正是「敢让 agent 上手」
的底气。

---

> 这些案例覆盖日常的发现、读写、创建、取证、扩权、回滚与排错。更精简的「最小路径」见
> [工作流](./workflows.md)；命令的完整参数见[命令参考](./commands.md)；每个字段为什么这么分类
> 见[策略](./policy.md)。
