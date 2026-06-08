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

## 运行时查看策略

- `nbxg help` 列出允许字段、高风险字段以及支持的资源类型。
- `nbxg inspect <type> <id>` 返回带有策略标注的实时资源，让 agent 能针对每个资源
  看到自己被允许提议改动哪些字段。
