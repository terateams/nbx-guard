# 01 · 自检、看清能做什么、发现 id、只读取数

先确认环境与权限边界，再去找资源 id，最后只读。**只读命令不改任何东西**，可放心多跑。

## 自检环境（无需 token）

```sh
nbxg version
```

回显生效配置：`token_configured`、`token_source`（env/cmd/file/none）、`auto_approve`、`branch` 等。
排查认证/分支问题时第一条就跑它。

## 看清「现在能做什么」

```sh
nbxg config show
```

用大白话列出：token 来源、连接、受治理类型、免审批可写字段、需审批字段、读敏感字段、是否自动审批，
以及「想做更多该跑哪条 `config set`」。**不确定某事能不能做时，先看它。**

```json
{
  "ok": true,
  "command": "config",
  "data": {
    "summary": "This is exactly what the agent may do right now. To do more, the agent proposes a change with `nbxg config set` ...",
    "token": { "configured": true, "source": "cmd" },
    "connection": { "netbox_url": "https://netbox.example.com", "branching": false },
    "governance": { "auto_approve": false, "governed_resource_types": ["device", "interface", "ip-address", "..."] }
  },
  "error": null
}
```

## 发现资源 id（先找 id，再操作）

```sh
# 已知确切标识：直接解析成 id（歧义会给候选列表，绝不替你瞎选）
nbxg resolve ip-address --address 192.0.2.10/32

# 只有模糊关键词：搜索
nbxg search ip-address -q 192.0.2 --limit 5

# 浏览某类型：列表（简要识别字段，低风险读）
nbxg list-resources device --limit 10
```

`resolve` 命中唯一时（结构以实际为准）：

```json
{ "ok": true, "command": "resolve",
  "data": { "resolved": { "type": "ip-address", "id": 42, "display": "192.0.2.10/32" } },
  "error": null }
```

歧义时返回候选列表（`data.candidates[]`）让你**自己挑一个 id**，不会静默选。

## 读取单个资源

```sh
nbxg get ip-address 42                 # basic：默认打码敏感字段
nbxg inspect ip-address 42             # 在 get 基础上叠加「每个字段的读/写策略」
```

> 想整体读出敏感字段（`--fields all`）需要一次**读审批**（`approve-read`），见 05 与 SKILL.md「读取策略」。

## 要点

- 这些都是只读，退出码 `0` 即成功；`netbox_error` 多为连通性/权限/分支问题，读 `error.message`。
- `resolve` 歧义不是错误，是要你定夺——从 `candidates` 里选定再继续。
- 拿到 id 后，改动走 02（低风险）或 03（高风险）。
