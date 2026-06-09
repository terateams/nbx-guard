# 05 · 回滚、读审批、查审计

改坏了怎么退回，敏感字段怎么整体读，做过什么怎么查。

## 回滚：用变更前快照还原

每次 `apply` 都会先存一份**变更前备份**，`apply` 成功的响应里给 `data.backup_id`。回滚就用它：

```sh
nbxg restore --backup bkp_5d91...    # 把资源 PATCH 回变更前的值
```

```json
{ "ok": true, "command": "restore",
  "data": { "restored": true, "resource": { "type": "ip-address", "id": 42 } },
  "error": null }
```

> 对一笔 `create` 的回滚 = 删除刚创建的对象（见 04）。

找不到 backup_id 时先列出来：

```sh
nbxg list backups
```

## 整体读取敏感字段：需要读审批

默认 `get`/`inspect` 会**打码**敏感字段。要整体读出真实值（`--fields all`），先提一个**读计划**，
人工 `approve-read` 后再读：

```sh
nbxg get device 7 --fields all --plan-read     # 生成读计划 rplan_...，返回打码预览
#  -> status:"pending_approval"
nbxg approve-read --plan rplan_...              # 人工批准这次完整读取
nbxg get device 7 --fields all --plan rplan_... # 凭已批准的读计划读出真实值
```

读也分级、默认最小化：能用 basic 就别申请 all。

## 查审计 / 列状态

```sh
nbxg audit --plan plan_8f3a...   # 某个 plan 的完整事件链（created/approved/applied/...）
nbxg audit                       # 全量审计日志
nbxg list plans                  # 列计划
nbxg list approvals              # 列审批
nbxg list backups                # 列备份
```

`audit.jsonl` 只追加，事件含 `plan_created / approved / rejected / applied / apply_failed /
restored / config_applied` 等——这是「谁、何时、对什么、做了什么」的可信链路。

## 要点

- 回滚本身也会被审计；它不是"偷偷改回去"，而是一次有记录的还原。
- `restore` 也走漂移检测：若当前值与备份基线冲突，会提示而非盲目覆盖。
- 凡是 `pending_approval`（写计划或读计划），都**停下等人**，别自我审批。
