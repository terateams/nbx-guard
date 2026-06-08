# 快速开始

## 环境要求

- **Zig 0.16.0**（从源码构建时需要）
- 一个可访问的 **NetBox** 实例及 API token（任何涉及 NetBox 的命令都需要）

## 构建与测试

```sh
zig build           # 生成 ./zig-out/bin/nbxg
zig build test      # 运行单元测试
zig build run -- version
```

[Releases 页面](https://github.com/terateams/nbx-guard/releases)上发布的二进制是为
Linux、macOS、Windows（x86_64 与 aarch64）静态交叉编译的；下载对应平台的归档，
把 `nbxg` 放到 `PATH` 即可。

## 首次运行

`version` 和 `help` 不需要连接 NetBox：

```sh
nbxg version
nbxg help
```

`version` 会回显当前生效的配置，便于确认 CLI 是否读到了你的环境：

```json
{
  "ok": true,
  "command": "version",
  "data": {
    "name": "nbxg",
    "version": "0.4.0",
    "description": "Agent-only NetBox safe-change gateway (Zig)",
    "netbox_url": "http://localhost:8000",
    "branching": false,
    "state_dir": ".nbx-guard",
    "token_configured": false,
    "principle": "Agent proposes intent; the CLI decides what is allowed."
  },
  "error": null
}
```

## 连接 NetBox

设置 URL 与 token，然后读取一个资源：

```sh
export NETBOX_URL=https://netbox.example.com
export NETBOX_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

nbxg get device 1
```

全部变量见[配置](./configuration.md)。

## 第一次安全变更

```sh
# 1. 提出意图（做策略 + 风险校验，此时不写入任何东西）
nbxg plan device 1 --set description="edge router"

# 2. 应用它（先快照一份备份，再 PATCH 到 NetBox）
nbxg apply --plan plan_...

# 3. 需要时回滚
nbxg restore --backup bkp_...
```

低风险字段无需审批即可应用；高风险字段必须先经过审批。完整的低风险与高风险
路径见[工作流](./workflows.md)。
