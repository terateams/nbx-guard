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

## 动作

只允许 **`update`** 动作。`create`、`delete`、`bulk_delete` 都会被策略引擎拒绝，并且
[NetBox 客户端](./architecture.md)只暴露 `GET` 与 `PATCH`——根本不存在能发出 `DELETE`
或调用任意端点的代码路径。

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

## 运行时查看策略

- `nbxg help` 列出允许字段、高风险字段以及支持的资源类型。
- `nbxg inspect <type> <id>` 返回带有策略标注的实时资源，让 agent 能针对每个资源
  看到自己被允许提议改动哪些字段。
