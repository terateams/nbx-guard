# 介绍

**nbx-guard** 是一个面向 agent 的 [NetBox](https://netbox.dev/) 安全变更网关，
使用 [Zig](https://ziglang.org/) 实现。

<p align="center">
  <img src="nbx-guard.png" alt="nbx-guard" width="720">
</p>

> **设计原则：** agent 只提出变更*意图*；究竟能不能做、怎么做，由 CLI 决定。

nbx-guard 位于 LLM/agent 与 NetBox 之间。agent 永远无法直接调用 NetBox API——
它只能请求 nbx-guard 去*规划（plan）*一次变更。随后由 CLI 来执行策略校验、
基于风险的审批、应用前备份、审计日志与回滚。即使 agent 声称自己拥有全部权限，
审批规则也在这里被强制执行。

```text
Agent / LLM ──> nbxg CLI (Zig) ──> NetBox REST API
                      │                  NetBox Branching
                      └─> 本地状态：plans / backups / approvals / audit
                                         ▲
                                     人工审批者
```

## 核心保证

- **默认拒绝（default-deny）**——只有被策略明确分类的字段才可写。
- **先规划（plan first）**——没有已存储的 `plan` 就不会发生任何写入；`apply` 只接受 `plan_id`。
- **审批门禁**——高风险字段需要一份绑定到该 plan 的 `plan_hash` 的审批。
- **应用前备份**——每次 apply 都会对资源及其原字段值做快照。
- **全程审计**——只追加（append-only）的 JSONL 轨迹；每条事件都关联
  `plan_id` / `approval_id` / `backup_id` / `request_id`。
- **可回滚**——任何已应用的变更都能从其备份恢复。
- **无原始访问 / 无删除**——只允许 `update`；`delete` / `bulk_delete` / 原始 API
  访问一律不暴露。
- **对 agent 友好的 JSON**——每条命令都打印一个信封（envelope），包含 `ok`、`data`，
  以及携带 `kind`、`risk_level`、`next_action` 的 `error`。

## 适合谁用

- **平台 / 网络运维团队**：希望让 agent 提出 NetBox 变更，但不给它不受约束的写权限。
- **agent 作者**：需要一个确定性的、机器可读的契约（每条命令一个 JSON 信封）来提出并应用变更。

## 状态

MVP。启用 NetBox Branching 后，受控变更会通过 `X-NetBox-Branch` 头路由进某个分支；
分支生命周期（`diff` / `sync` / `merge`）通过 NetBox 自身的 Branching API 处理。
未启用分支时，默认的应用方式是对 `main` 直接 PATCH。

继续阅读[快速开始](./getting-started.md)。
