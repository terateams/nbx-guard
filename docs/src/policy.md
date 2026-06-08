# 策略

策略引擎采用**默认拒绝（default-deny）**：只有被明确分类的字段才可写入。这是
nbx-guard 的核心——即便是完全可信的 agent，也无法改动一个策略并不认识的字段。

## 字段分类

| 分类 | 字段 | 行为 |
| --- | --- | --- |
| 允许（低风险） | `description`、`comments`、`tags`、`custom_fields`、`title`、`phone`、`email`、`link` | 直接应用。 |
| 高风险 | `status`、`role`、`site`、`rack`、`prefix`、`address`、`groups` | 需要审批。 |
| 其它一切 | — | **拒绝。** |

## plan 如何被评估

当你创建一个 plan 时，`--set` 里的每个字段都会被分类：

1. 只要**任一**字段被拒绝 → 整个 plan 被拒，返回 `error.kind = "policy_denied"`，
   不存储任何东西。
2. 否则，只要**任一**字段是高风险 → 该 plan 的风险等级为 `high`，进入
   `pending_approval`。
3. 否则 → 该 plan 风险等级为 `low`，状态为 `planned`，可直接应用。

在 `apply` 时，会再次针对*已存储*的 changes 重新评估（纵深防御），因此一个不再满足
策略的 plan 不会被应用。

## 读取策略（读暴露分级）

读取与写入**分开分级**。同一个字段在写侧可能是低风险（如 `comments`、`custom_fields`、`phone`、
`email`），但把它们**整体读出到 agent 转录里**仍可能泄露敏感信息。因此读取面默认最小化：

| 分类 | 字段 | 行为 |
| --- | --- | --- |
| 基本（低风险读） | `id`、`name`、`display`、`status`、`serial` 等标识/非敏感字段 | `--fields basic`（默认）直接返回 |
| 读敏感 | `phone`、`email`、`comments`、`custom_fields`、`tenant` | `basic` 下以 `[redacted: read approval required]` 脱敏；整对象读取（`--fields all`）需读审批 |

`get` / `inspect` 的字段分级：

- `--fields basic`（**默认**）：返回对象，但把读敏感字段**脱敏**，并在 `data.read_policy.redacted_fields`
  里列出被脱敏的字段。低风险、不触发审批。
- `--fields all`：请求整对象。
  - 若对象**不含**读敏感字段 → 直接返回完整对象（低风险）。
  - 若**含**读敏感字段 → 默认拒绝（`error.kind = "needs_approval"`）。需走读审批路径：
    1. `nbxg get <type> <id> --fields all --plan-read` 创建一个**读 plan**（`action: "read"`，
       `status: "pending_approval"`），并返回脱敏预览。
    2. `nbxg approve-read --plan <plan_id>` 由人工审批（绑定 `plan_hash`，与写审批同源）。
    3. 重新 `nbxg get <type> <id> --fields all --plan <plan_id>` 披露整对象；该披露写入审计
       （`read_served`）。

读 plan 与写 plan 隔离：`approve` / `apply` 会拒绝读 plan（提示改用 `approve-read`），
`approve-read` 也只接受读 plan。读 plan 仍可被 `reject` 驳回。

> **覆盖所有完整对象读面**：同一套读分级对 `get`/`inspect`/`snapshot` 一致生效——`snapshot`
> 默认 `basic` 脱敏，`--fields all` 含敏感字段时同样需 `--plan-read` → `approve-read` → `--plan`。
> 批量 `export` 则**永不披露原始敏感值**（集合无逐对象读审批）：`full` 档对每条记录脱敏，
> `basic` 档用 `brief`。要读原始敏感值，请对单对象用 `get`/`snapshot` 走读审批。

### 算子扩展读敏感字段

| 环境变量 | 作用 | 示例 |
|---|---|---|
| `NBX_GUARD_READ_SENSITIVE_FIELDS` | 追加读敏感字段（逗号/空格分隔），整对象读取需审批 | `serial,asset_tag` |

读侧同样 **fail-safe**：环境变量只能让字段**更受保护**（内置读敏感字段不会被降级），
未列出的字段保持「基本」可读。放行后的读敏感字段会自动出现在 `describe` / `help` 的
`read_policy.sensitive_fields` 中。

## 动作

`update` 走字段策略（下文）。`create` 默认拒绝，仅对算子在 `creatable_resources` /
`NBX_GUARD_CREATABLE_RESOURCES` 中开启的类型放行（`*` 表示任意已登记类型），且**每次创建
都必须经审批**——`create` 生成的 plan 一律高风险、`requires_approval=true`。创建不做逐字段
拒绝（新对象需要 `name`/`slug` 等标识字段，由 NetBox 校验）；其治理点是**类型开关 + 强制审批 +
审计 + 可回滚**（创建的回滚 = 删除，由 `restore` 执行）。

`delete` / `bulk_delete` 不作为 agent 动作暴露——[NetBox 客户端](./architecture.md)的
`DELETE` 仅供 `restore` 回滚一次创建时内部使用，没有面向 agent 的删除命令或任意端点调用路径。

## 支持的资源类型

| 类型 | NetBox 端点 |
| --- | --- |
| `device` | `dcim/devices` |
| `interface` | `dcim/interfaces` |
| `ip-address` | `ipam/ip-addresses` |
| `prefix` | `ipam/prefixes` |
| `vlan` | `ipam/vlans` |
| `contact` | `tenancy/contacts` |

不在此集合内的资源类型，会在任何网络调用之前就被拒绝。

## 算子扩展（默认拒绝之外的显式放行）

内置的类型与字段允许清单是「**安全下限**」，不是上限。**人工算子**（不是 agent）可以在
不削弱默认拒绝的前提下，用环境变量临时扩大治理范围。这些变量由部署/运维方控制，agent
无法自行设置，因此**写入仍然只能由人工放行的范围内发生**，且全程经过 plan / 审批 / 备份 /
漂移 / 审计 / 还原。

| 环境变量 | 作用 | 示例 |
|---|---|---|
| `NBX_GUARD_EXTRA_RESOURCES` | 新增受治理类型（`类型=端点` 列表） | `site=dcim/sites,tenant=tenancy/tenants` |
| `NBX_GUARD_ALLOWED_FIELDS` | 追加低风险字段（逗号/空格分隔） | `facility,asset_tag` |
| `NBX_GUARD_HIGH_RISK_FIELDS` | 追加高风险字段（需审批） | `tenant,region` |
| `NBX_GUARD_CREATABLE_RESOURCES` | 开启 `create` 的类型（`*`=任意类型；创建仍逐次审批） | `site,vlan` 或 `*` |

安全约束（**fail-safe**）：

- **内置分类永远优先**——内置的高风险字段不会被环境变量降级为低风险。
- 当同一字段同时出现在两个清单里时，**高风险优先于低风险**。
- 身份类字段（如 `name`）不在任何清单里，因此即便对扩展类型也始终被拒绝，agent 不能改名/改身份。
- 扩展类型的 `describe` 会合成一份最小文档（低风险 = 通用 `description`/`comments`/`tags`/
  `custom_fields` + 算子放行字段；高风险 = 算子放行的高风险字段），并照常做实时 NetBox
  同步，让 agent 看到真实 schema。
- **自描述与执行一致**：算子放行的字段会**自动出现在** `describe <type>`、`inspect <type> <id>`
  与 `help` 的字段清单里（并经实时同步标注 `present_in_netbox`），无需改源码——agent 因此能
  「发现」算子刚放行的字段，而不是靠盲试。内置类型（如给 `device` 放行 `serial`）同样适用。

```sh
export NBX_GUARD_EXTRA_RESOURCES="site=dcim/sites"
export NBX_GUARD_ALLOWED_FIELDS="facility"
export NBX_GUARD_HIGH_RISK_FIELDS="tenant"
nbxg describe site                 # 合成文档 + 实时同步
nbxg list-resources site           # 发现 id
nbxg plan site 1 --set facility="Building A"   # 低风险，直接可 apply
nbxg plan site 1 --set tenant=3    # 高风险，需 approve
nbxg plan site 1 --set name=foo    # 仍被 policy_denied
```

在**内置类型**上放行一个新字段（例如要改设备序列号 `serial`），同样只需一行 env、无需改源码：

```sh
export NBX_GUARD_ALLOWED_FIELDS="serial"     # 或放到 *_HIGH_RISK_FIELDS 走审批
nbxg describe device          # serial 现在出现在字段清单，present_in_netbox=true
nbxg plan device 1 --set serial=NEW-SN-001   # 低风险，可直接 apply（自动备份）
```

### 用配置文件代替环境变量（`~/.nbx-guard/config.json`）

不想导出三个环境变量时，算子可以把同样的治理扩展写进一个 JSON 配置文件。默认路径是
`~/.nbx-guard/config.json`（可用环境变量 `NBX_GUARD_CONFIG` 指向其它路径）：

```json
{
  "extra_resources":      { "site": "dcim/sites", "tenant": "tenancy/tenants" },
  "allowed_fields":       ["serial", "asset_tag"],
  "high_risk_fields":     ["tenant"],
  "read_sensitive_fields": ["serial"],
  "creatable_resources":  ["site", "vlan"]
}
```

- 五个键分别等价于 `NBX_GUARD_EXTRA_RESOURCES` / `NBX_GUARD_ALLOWED_FIELDS` /
  `NBX_GUARD_HIGH_RISK_FIELDS` / `NBX_GUARD_READ_SENSITIVE_FIELDS` /
  `NBX_GUARD_CREATABLE_RESOURCES`；行为、fail-safe 约束、
  自描述一致性与环境变量**完全相同**。
- **只放治理扩展，不放密钥**：`NETBOX_URL` / `NETBOX_TOKEN` 仍只从环境变量读取，绝不写进此文件。
- **文件与环境变量取并集**（都是增量放行）；`extra_resources` 键冲突时**环境变量优先**。
- 路径解析：显式 `NBX_GUARD_CONFIG`（若设置但文件不存在 → `config_error`）→ 否则默认
  `~/.nbx-guard/config.json`（不存在则静默跳过，完全向后兼容）。
- JSON 格式非法 → 以 `config_error`（退出码 3）失败并给出修复提示，绝不静默忽略。
- 注意：`~/.nbx-guard/`（家目录，算子配置）与默认**状态目录** `.nbx-guard/`（项目本地，
  plans/backups/审计）是两个不同目录。

```sh
mkdir -p ~/.nbx-guard
cat > ~/.nbx-guard/config.json <<'JSON'
{ "extra_resources": { "site": "dcim/sites" }, "allowed_fields": ["serial"] }
JSON
nbxg describe device          # serial 已出现（与 env 等价）
nbxg describe site            # 扩展类型可见
```

## 运行时查看策略

- `nbxg help` 列出允许字段、高风险字段以及支持的资源类型。
- `nbxg inspect <type> <id>` 返回带有策略标注的实时资源，让 agent 能针对每个资源
  看到自己被允许提议改动哪些字段。
