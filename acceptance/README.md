# 验收（Acceptance）

针对**真实 NetBox**（容器）跑 nbx-guard 的端到端验收：完整走一遍
`plan → approve → apply → restore`，校验默认拒绝、高风险审批、先备份后变更、
审计可追溯等安全语义。**用完即停、可重复执行。**

## 运行

```bash
bash acceptance/run.sh
```

脚本会：

1. `zig build` 构建 `nbx-guard`；
2. 用 `docker compose` 拉起一次性 NetBox 栈（postgres + redis + netbox）；
3. 等待 NetBox API 就绪；
4. 创建一个 `ip-address` 作为测试数据；
5. 跑全部验收用例（见 `run.sh`）；
6. **无论成功失败，退出时通过 `docker compose down -v` 销毁容器。**

## 参数

| 参数 | 说明 |
| --- | --- |
| `--keep` | 验收后保留容器（调试用，不自动销毁） |
| `--no-build` | 跳过 `zig build`，复用已构建二进制 |
| `--down` | 仅销毁可能残留的验收栈后退出 |
| `NBX_NETBOX_PORT=8088` | 自定义映射到宿主机的端口（默认 `8000`） |
| `NBX_READY_TIMEOUT=480` | 等待 NetBox 就绪的秒数上限 |

## 在 CI 中执行

GitHub Actions 工作流 `.github/workflows/acceptance.yml` 会在 `ubuntu-latest`
上跑同一套验收（runner 自带 Docker / Compose v2 / jq / curl，拉取的是原生
amd64 镜像）。触发时机：

- **手动**：Actions 页面 → Acceptance → Run workflow（`workflow_dispatch`）；
- **定时**：每周一 03:00 UTC，检测 NetBox API 漂移；
- **改动相关代码时**：`src/**`、`build.zig*`、`acceptance/**` 或该工作流自身
  发生变化的 push / pull request。

无需任何 secret（NetBox 为一次性实例、Token 为固定测试值），fork 上也能跑。
该工作流独立于快速 CI（构建 / 测试 / 格式检查），不拖慢日常提交。

## 说明

- NetBox 固定到 **4.2（`netbox-docker` 3.2.1）**，沿用经典 API Token 机制，
  与 nbx-guard 的 `Authorization: Token <token>` 兼容。
- 固定项目名 `nbx-guard-acceptance` + 每次启动前后都 `down -v`，
  保证干净初始状态与可重复性。
- 只依赖 `docker` / `zig` / `jq` / `curl`。
- 首次运行需拉取 NetBox 镜像并执行数据库迁移，可能耗时数分钟。
- 验收仅覆盖 NetBox 官方镜像内置能力；Branching 插件不在镜像内，
  其路由逻辑由单元测试与 mock 覆盖。
