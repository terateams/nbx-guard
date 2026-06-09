# examples — nbxg 命令实操案例

给 Agent 看的端到端命令案例：每个文件一个场景，包含**要敲的命令**、**预期 JSON 信封**与**要点**
（退出码、`next_action`、该停在哪等批准）。所有命令都遵守本技能的铁律：**Agent 只提案，CLI 决定放行**。

> 约定：示例里的 IP/域名一律用文档占位（RFC 5737 `192.0.2.0/24`、`example.com`、`localhost`），
> token 用一眼假的占位。真实环境请换成你自己的值。涉及 NetBox 的响应标注「结构以实际为准」——
> 字段名、风险分级、信封形状是真的，具体取值随你的实例而变。

| 文件 | 场景 |
| --- | --- |
| [`00-bootstrap-install.md`](00-bootstrap-install.md) | **先确认 `nbxg` 二进制可用**；缺失时提案安装（含手动下载兜底） |
| [`01-discover-and-read.md`](01-discover-and-read.md) | 自检、看清能做什么、发现资源 id、只读取数 |
| [`02-low-risk-change.md`](02-low-risk-change.md) | 低风险改字段：`plan → apply`（免审批） |
| [`03-high-risk-change.md`](03-high-risk-change.md) | 高风险改字段：`plan → approve → apply`（人工批准） |
| [`04-create-object.md`](04-create-object.md) | 创建新对象：`create → approve → apply`（逐次审批） |
| [`05-restore-and-audit.md`](05-restore-and-audit.md) | 出错回滚 `restore`，以及查审计 / 列状态 |
| [`06-config-propose.md`](06-config-propose.md) | 默认拒绝挡路时：`config set` 提案改配置（人工批准 + 审计） |

每条命令都向 stdout 输出**一个 JSON 对象**，并用退出码表达结果：
`0` 成功；`2` 你的请求有问题（策略/状态/客户端）；`3` 上游/IO/配置问题（NetBox 或环境）。
**永远先解析 JSON、看 `ok` 与 `next_action`，再决定下一步。**
