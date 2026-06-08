# 架构

nbx-guard 是一个小巧、分层的 Zig 程序。agent 只能触达**命令层（command layer）**；
每一项保证都在其下层被强制执行，并且只有一个组件可以与 NetBox 通信。

```text
        argv
          │
   ┌──────▼───────┐
   │   cli.zig    │  解析、编排工作流、打印一个 JSON 信封
   └──┬───┬───┬───┘
      │   │   │
 policy  plan/approval/backup/audit        netbox.zig ── 仅 GET / PATCH ──> NetBox
 (拒绝)  (状态经 store.zig + ids.zig)
```

## 源码布局

| 文件 | 职责 |
| --- | --- |
| `src/main.zig` | 入口；构建 `Context`，分发命令，设置退出码。 |
| `src/cli.zig` | 命令层 / 工作流编排。 |
| `src/context.zig` | 共享上下文 + JSON 响应信封 + 错误模型。 |
| `src/config.zig` | 由环境变量驱动的配置。 |
| `src/policy.zig` | 默认拒绝的字段策略引擎。 |
| `src/plan.zig` | plan 模型、changes 解析、确定性 `plan_hash`。 |
| `src/approval.zig` | 绑定到 `plan_hash` 的审批记录。 |
| `src/backup.zig` | 应用前快照与原值捕获。 |
| `src/audit.zig` | 只追加的 JSONL 审计日志。 |
| `src/netbox.zig` | NetBox REST 客户端（仅 GET / PATCH）。 |
| `src/store.zig` | 本地 JSON/JSONL 状态存储。 |
| `src/ids.zig` | id 生成与 SHA-256 哈希。 |
| `src/root.zig` | 库的再导出与单元测试聚合。 |

## 强制这些保证的设计取舍

- **只有一个写动词。** `netbox.zig` 只暴露 `get`（GET）和 `patch`（PATCH）。不存在执行
  DELETE 或调用任意路径的函数，因此“无原始访问 / 无删除”是一种结构性属性，而非运行时检查。
- **策略被检查两次。** 在 `plan` 时，以及在 `apply` 时再次针对*已存储*的 changes，因此
  一个 plan 不会在提议与应用之间漂移出策略之外。
- **审批绑定到 `plan_hash`。** 由于该哈希覆盖了规范化的
  `{resource_type, resource_id, action, changes}`，一个已审批的 plan 无法在不令该绑定
  失效的情况下被编辑后重新应用。
- **备份先于写入。** `apply` 总是先快照再 PATCH，因此每个已应用的变更都可经 `restore`
  回滚。
- **单一输出契约。** `context.zig` 是唯一负责打印的地方；每条命令都恰好发出一个
  `{ ok, command, data, error }` 信封。

## 技术栈

- 语言：**Zig 0.16**
- HTTP：`std.http.Client`
- JSON：`std.json`
- 哈希：`std.crypto.hash.sha2.Sha256`
- 状态：本地 JSON 文件 + 一份 JSONL 审计日志

## 构建与 CI

`zig build` 产出 `zig-out/bin/nbxg`；`zig build test` 运行聚合在 `root.zig` 里的
单元测试。仓库附带三条 GitHub Actions 工作流：

- **CI**——在每次 push/PR 时于 Linux 和 macOS 上构建、测试，并检查 `zig fmt`。
- **Release**——在打 `v*` 标签时，为 Linux、macOS、Windows（x86_64 + aarch64）交叉编译
  `ReleaseSafe` 二进制，连同校验和打包，并发布一个 release。
- **Docs**——构建本 mdBook 站点并部署到 GitHub Pages。

## NetBox Branching

`NBX_GUARD_BRANCHING` / `NBX_GUARD_BRANCH` 把受控变更路由进
[NetBox Branching](https://github.com/netboxlabs/netbox-branching) 插件。两者都设置时，
NetBox 客户端会给每个请求加上 `X-NetBox-Branch: <schema_id>` 头，于是读取、应用前备份
以及 apply 的 PATCH 都在该分支内运作，而不是 `main`。因此该变更会保持隔离，直到有人
审查并合并该分支。

分支的创建以及 `sync` / `merge` / `revert` 生命周期刻意**不**属于本网关——它们是通过
NetBox 自身 Branching API 执行的审批者级别操作。nbx-guard 永远只*瞄准*一个已存在的
分支；它从不合并分支。
