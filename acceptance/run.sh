#!/usr/bin/env bash
#
# nbx-guard 端到端验收：拉起真实 NetBox（容器），针对它跑完整的
# plan → approve → apply → restore 流程，校验默认拒绝/高风险审批/备份还原等
# 安全语义，最后无条件销毁容器。
#
#   特点：
#     * 用完即停  —— 退出时（无论成功失败）通过 trap 执行 `docker compose down -v`
#     * 可重复执行 —— 固定项目名 + 每次启动前后都 down -v，保证干净的初始状态
#     * 自包含    —— 只依赖 docker / zig / jq / curl
#
#   用法：
#     bash acceptance/run.sh              # 构建 + 拉起 + 验收 + 销毁
#     bash acceptance/run.sh --keep       # 验收后保留容器（调试用，不自动销毁）
#     bash acceptance/run.sh --no-build   # 跳过 zig build（复用已构建二进制）
#     bash acceptance/run.sh --down       # 仅销毁可能残留的验收栈后退出
#     NBX_NETBOX_PORT=8088 bash acceptance/run.sh   # 自定义宿主机端口
#
set -euo pipefail

# --- 路径与常量 ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
PROJECT="nbx-guard-acceptance"
PORT="${NBX_NETBOX_PORT:-8000}"
# NetBox 4.5 默认 v2 Token：凭据形如 nbt_<key>.<secret>，以 Bearer 方案鉴权。
# 这里用确定性的 key/secret，由 run.sh 在就绪后植入（见下）。
TOKEN_KEY="nbxguardk001"   # v2 key 固定 12 字符
TOKEN_SECRET="0123456789abcdef0123456789abcdef01234567"
TOKEN="nbt_${TOKEN_KEY}.${TOKEN_SECRET}"
NB_AUTH="Authorization: Bearer ${TOKEN}"
BASE="http://127.0.0.1:${PORT}"
GUARD="$REPO_ROOT/zig-out/bin/nbxg"
STATE_DIR="$SCRIPT_DIR/.state"
READY_TIMEOUT="${NBX_READY_TIMEOUT:-480}"   # 等待 NetBox 就绪的秒数上限

KEEP=0
BUILD=1
DOWN_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --keep) KEEP=1 ;;
    --no-build) BUILD=0 ;;
    --down) DOWN_ONLY=1 ;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

# 避免外部环境变量泄漏进 guard 调用（统一在调用处显式注入）
unset NETBOX_URL NETBOX_TOKEN NBX_GUARD_STATE_DIR || true

dc() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

teardown() {
  if [ "$KEEP" = "1" ]; then
    echo ""
    echo "⚠️  --keep 已指定，保留容器。手动销毁： docker compose -p $PROJECT -f $COMPOSE_FILE down -v"
    return
  fi
  echo ""
  echo "🧹 销毁验收栈 ..."
  dc down -v --remove-orphans >/dev/null 2>&1 || true
}

# --- 仅销毁模式 ------------------------------------------------------------
if [ "$DOWN_ONLY" = "1" ]; then
  echo "🧹 销毁可能残留的验收栈 ..."
  dc down -v --remove-orphans || true
  exit 0
fi

# --- 前置检查 --------------------------------------------------------------
for bin in docker zig jq curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "❌ 缺少依赖: $bin" >&2; exit 3; }
done
docker info >/dev/null 2>&1 || { echo "❌ Docker 守护进程未运行" >&2; exit 3; }

# --- 构建 nbx-guard --------------------------------------------------------
if [ "$BUILD" = "1" ]; then
  echo "🔨 构建 nbx-guard (zig build) ..."
  ( cd "$REPO_ROOT" && zig build )
fi
[ -x "$GUARD" ] || { echo "❌ 找不到二进制: $GUARD（请先 zig build）" >&2; exit 3; }

# 干净的本地状态目录（rm 可能被包装为移入废纸篓，做容错处理）
rm -rf "$STATE_DIR" 2>/dev/null || true
mkdir -p "$STATE_DIR"

# 退出时无条件销毁
trap teardown EXIT

# 启动前先清掉任何同名残留（保证可重复）
dc down -v --remove-orphans >/dev/null 2>&1 || true

echo "🚀 拉起 NetBox 验收栈（端口 ${PORT}）..."
dc up -d

# --- 等待 NetBox 就绪 ------------------------------------------------------
# 轮询 /login/（无需鉴权）。netbox-docker 先迁移+建超级用户、再启动 Web 服务，
# 因此 /login/ 返回 200 即代表迁移完成、admin 已创建，可以安全植入 Token。
echo "⏳ 等待 NetBox 就绪（最多 ${READY_TIMEOUT}s，首次需拉取镜像/迁移，请耐心）..."
deadline=$(( $(date +%s) + READY_TIMEOUT ))
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/login/" || true)
  if [ "$code" = "200" ]; then ready=1; break; fi
  printf '   ... 仍在启动 (HTTP %s)，已等待 %ss\n' "${code:-000}" "$(( $(date +%s) - (deadline - READY_TIMEOUT) ))"
  sleep 10
done
if [ "$ready" != "1" ]; then
  echo "❌ NetBox 在 ${READY_TIMEOUT}s 内未就绪。最近日志："
  dc logs --tail 40 netbox || true
  exit 3
fi

# --- 植入确定性 v2 API Token ----------------------------------------------
# NetBox 4.5 默认签发 v2 Token，且 netbox-docker 自带的 SUPERUSER_API_TOKEN 在 v2
# 下会生成 secret 未知、不可用的 Token。这里直接为 admin 植入 key/secret 均已知的
# v2 Token（key='${TOKEN_KEY}'，secret 即上面的 TOKEN_SECRET）。
echo "🔑 为 admin 植入确定性 v2 API Token ..."
dc exec -T netbox /opt/netbox/netbox/manage.py shell -c "
from users.models import Token, User
u = User.objects.filter(is_superuser=True).order_by('id').first()
Token.objects.filter(key='${TOKEN_KEY}').delete()
Token(user=u, version=2, key='${TOKEN_KEY}', token='${TOKEN_SECRET}').save()
print('seeded v2 token for', u.username)
" >/dev/null 2>&1 || { echo "❌ 植入 v2 Token 失败。最近日志："; dc logs --tail 40 netbox || true; exit 3; }

# --- 确认 Token 生效 ------------------------------------------------------
code=$(curl -s -o /dev/null -w '%{http_code}' -H "$NB_AUTH" "$BASE/api/ipam/ip-addresses/?limit=1" || true)
if [ "$code" != "200" ]; then
  echo "❌ v2 Token 鉴权失败 (HTTP ${code:-000})。最近日志："
  dc logs --tail 40 netbox || true
  exit 3
fi
echo "✅ NetBox API 就绪，v2 Token 生效。"

# --- 测试辅助函数 ----------------------------------------------------------
PASS=0; FAIL=0
GOUT=""; GRC=0
pass() { printf '   \033[32m✅ PASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '   \033[31m❌ FAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

# 运行 nbx-guard（注入 URL/Token/State），捕获 stdout 与退出码
guard() {
  set +e
  GOUT=$(NBX_GUARD_STATE_DIR="$STATE_DIR" NETBOX_URL="$BASE" NETBOX_TOKEN="$TOKEN" "$GUARD" "$@" 2>/dev/null)
  GRC=$?
  set -e
}
# 不带 token 运行（验证 token 门禁）
guard_notoken() {
  set +e
  GOUT=$(NBX_GUARD_STATE_DIR="$STATE_DIR" NETBOX_URL="$BASE" "$GUARD" "$@" 2>/dev/null)
  GRC=$?
  set -e
}
j() { printf '%s' "$GOUT" | jq -r "$1"; }
# 直接查 NetBox（校验副作用）
nb_field() { curl -fsS -H "$NB_AUTH" "$BASE/api/ipam/ip-addresses/$IP_ID/" | jq -r "$1"; }

# check <描述> <实际> <期望>
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (期望 '$3'，实得 '$2')"; fi; }

echo ""
echo "🌱 准备测试数据：创建一个 ip-address ..."
IP_ID=$(curl -fsS -X POST "$BASE/api/ipam/ip-addresses/" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d '{"address":"192.0.2.10/24","status":"active","description":"seed"}' | jq -r '.id')
[ -n "$IP_ID" ] && [ "$IP_ID" != "null" ] || { echo "❌ 创建 ip-address 失败" >&2; exit 3; }
echo "   ip-address id = $IP_ID"

echo ""
echo "================ 验收用例 ================"

# 1) version（无需 token）
guard version
check "version: 退出码 0" "$GRC" "0"
check "version: ok=true" "$(j '.ok')" "true"
check "version: 版本号" "$(j '.data.version')" "0.1.1"
check "version: token_configured=true" "$(j '.data.token_configured')" "true"

# 2) help
guard help
check "help: ok=true" "$(j '.ok')" "true"

# 3) get（只读）
guard get ip-address "$IP_ID"
check "get: ok=true" "$(j '.ok')" "true"
check "get: 返回正确资源 id" "$(j '.data.resource.id')" "$IP_ID"

# 4) inspect（带策略标注）
guard inspect ip-address "$IP_ID"
check "inspect: ok=true" "$(j '.ok')" "true"
check "inspect: 暴露 allowed_fields(description)" \
  "$(j '.data.policy.allowed_fields | index("description") != null')" "true"

# 4b) describe（自描述：静态 schema + 实时 NetBox 同步）
guard describe
check "describe(目录): ok=true" "$(j '.ok')" "true"
check "describe(目录): 含 ip-address 类型" \
  "$(j '.data.resource_types | map(.resource_type) | index("ip-address") != null')" "true"

guard describe ip-address
check "describe ip-address: ok=true" "$(j '.ok')" "true"
check "describe ip-address: action=update" "$(j '.data.action')" "update"
check "describe ip-address: status 为 high_risk" \
  "$(j '.data.fields[] | select(.name=="status") | .class')" "high_risk"
check "describe ip-address: 实时同步 status=ok" "$(j '.data.netbox_sync.status')" "ok"
check "describe ip-address: status 已对齐 NetBox" \
  "$(j '.data.fields[] | select(.name=="status") | .present_in_netbox')" "true"
check "describe ip-address: status 暴露 NetBox 元数据" \
  "$(j '.data.fields[] | select(.name=="status") | .netbox != null')" "true"
check "describe ip-address: status 暴露 NetBox choices" \
  "$(j '.data.fields[] | select(.name=="status") | .netbox.choices != null')" "true"
check "describe ip-address: 无漂移字段" \
  "$(j '.data.netbox_sync.missing_in_netbox | length')" "0"

guard describe ip-address --offline
check "describe --offline: 跳过实时同步" "$(j '.data.netbox_sync.status')" "skipped"

# 4c) describe --source openapi（用 NetBox OpenAPI 描述文件作为同步来源）
guard describe device --source openapi
check "describe --source openapi: ok=true" "$(j '.ok')" "true"
check "describe --source openapi: source_kind=openapi" \
  "$(j '.data.netbox_sync.source_kind')" "openapi"
check "describe --source openapi: 同步 status=ok" "$(j '.data.netbox_sync.status')" "ok"
check "describe --source openapi: 动态解析出 component" \
  "$(j '.data.netbox_sync.component != null')" "true"
check "describe --source openapi: status 暴露 NetBox enum" \
  "$(j '.data.fields[] | select(.name=="status") | .netbox.enum != null')" "true"
check "describe --source openapi: 无漂移字段" \
  "$(j '.data.netbox_sync.missing_in_netbox | length')" "0"

# 第二次调用应命中本地缓存（cached=true），避免重复抓取数 MB 的 schema
guard describe vlan --source openapi
check "describe --source openapi: 复用磁盘缓存 cached=true" \
  "$(j '.data.netbox_sync.cached')" "true"

# 5) token 门禁：不带 token 的 get 应被拒
guard_notoken get ip-address "$IP_ID"
check "无 token get: 退出码 3" "$GRC" "3"
check "无 token get: error.kind=config_error" "$(j '.error.kind')" "config_error"

# 6) plan 低风险（description）
guard plan ip-address "$IP_ID" --set description=acceptance-low
check "plan(低风险): 退出码 0" "$GRC" "0"
check "plan(低风险): status=planned" "$(j '.data.plan.status')" "planned"
check "plan(低风险): requires_approval=false" "$(j '.data.plan.requires_approval')" "false"
check "plan(低风险): risk_level=low" "$(j '.data.plan.risk_level')" "low"
PLAN_LOW=$(j '.data.plan.plan_id')

# 7) apply 低风险 —— 无需审批
guard apply --plan "$PLAN_LOW"
check "apply(低风险): 退出码 0" "$GRC" "0"
check "apply(低风险): status=applied" "$(j '.data.status')" "applied"
BKP=$(j '.data.backup_id')
check "apply(低风险): 生成 backup_id" "$([ -n "$BKP" ] && [ "$BKP" != "null" ] && echo yes || echo no)" "yes"
check "apply(低风险): NetBox 侧 description 已更新" "$(nb_field '.description')" "acceptance-low"

# 8) restore —— 从备份还原
guard restore --backup "$BKP"
check "restore: 退出码 0" "$GRC" "0"
check "restore: ok=true" "$(j '.ok')" "true"
check "restore: NetBox 侧 description 已还原" "$(nb_field '.description')" "seed"

# 9) plan 高风险（status）—— 需要审批
guard plan ip-address "$IP_ID" --set status=deprecated
check "plan(高风险): 退出码 0" "$GRC" "0"
check "plan(高风险): status=pending_approval" "$(j '.data.plan.status')" "pending_approval"
check "plan(高风险): requires_approval=true" "$(j '.data.plan.requires_approval')" "true"
check "plan(高风险): risk_level=high" "$(j '.data.plan.risk_level')" "high"
PLAN_HIGH=$(j '.data.plan.plan_id')

# 10) 未审批即 apply —— 必须被拒
guard apply --plan "$PLAN_HIGH"
check "apply(未审批): 退出码 2" "$GRC" "2"
check "apply(未审批): error.kind=not_approved" "$(j '.error.kind')" "not_approved"
check "apply(未审批): NetBox 侧 status 未变" "$(nb_field '.status.value')" "active"

# 11) approve
guard approve --plan "$PLAN_HIGH" --note "acceptance"
check "approve: 退出码 0" "$GRC" "0"
check "approve: plan_status=approved" "$(j '.data.plan_status')" "approved"

# 12) apply 高风险（已审批）
guard apply --plan "$PLAN_HIGH"
check "apply(已审批): 退出码 0" "$GRC" "0"
check "apply(已审批): status=applied" "$(j '.data.status')" "applied"
check "apply(已审批): NetBox 侧 status=deprecated" "$(nb_field '.status.value')" "deprecated"
BKP_HR=$(j '.data.backup_id')

# 12b) restore 高风险 choice 字段 —— 校验写形归一化：备份里 status 存的是
#      GET 形态 {value,label}，还原必须 PATCH 回 slug，使 status 复位为 active
guard restore --backup "$BKP_HR"
check "restore(高风险): 退出码 0" "$GRC" "0"
check "restore(高风险): NetBox 侧 status 还原为 active" "$(nb_field '.status.value')" "active"

# 13) 重复 apply —— 已应用的计划必须被拒
guard apply --plan "$PLAN_HIGH"
check "apply(重复): 退出码 2" "$GRC" "2"
check "apply(重复): error.kind=plan_state_error" "$(j '.error.kind')" "plan_state_error"

# 14) plan 被拒字段（dns_name 不在策略内）—— 默认拒绝
guard plan ip-address "$IP_ID" --set dns_name=evil.example.com
check "plan(越权字段): 退出码 2" "$GRC" "2"
check "plan(越权字段): error.kind=policy_denied" "$(j '.error.kind')" "policy_denied"

# 15) approve 不存在的计划
guard approve --plan plan_does_not_exist
check "approve(不存在): error.kind=plan_not_found" "$(j '.error.kind')" "plan_not_found"

# 16) audit —— 审计链可见
guard audit
check "audit: ok=true" "$(j '.ok')" "true"
check "audit: 含 applied 事件" "$(j '[.data.entries[] | select(.event=="applied")] | length >= 2')" "true"
check "audit: 含 approved 事件" "$(j '[.data.entries[] | select(.event=="approved")] | length >= 1')" "true"
check "audit: 含 restored 事件" "$(j '[.data.entries[] | select(.event=="restored")] | length >= 1')" "true"

# 17) list
guard list plans
check "list plans: count>=2" "$(j '.data.count >= 2')" "true"
guard list approvals
check "list approvals: count>=1" "$(j '.data.count >= 1')" "true"
guard list backups
check "list backups: count>=1" "$(j '.data.count >= 1')" "true"

# 18) reject —— 被拒的计划永不可 apply
guard plan ip-address "$IP_ID" --set description=will-reject
check "plan(待拒): 退出码 0" "$GRC" "0"
PLAN_REJ=$(j '.data.plan.plan_id')
guard reject --plan "$PLAN_REJ" --note "not needed"
check "reject: 退出码 0" "$GRC" "0"
check "reject: status=rejected" "$(j '.data.status')" "rejected"
guard apply --plan "$PLAN_REJ"
check "apply(已拒): 退出码 2" "$GRC" "2"
check "apply(已拒): error.kind=plan_state_error" "$(j '.error.kind')" "plan_state_error"
check "apply(已拒): NetBox 侧 description 未变" "$(nb_field '.description')" "seed"
guard audit
check "audit: 含 rejected 事件" "$(j '[.data.entries[] | select(.event=="rejected")] | length >= 1')" "true"

# 19) drift —— 计划创建后资源被外部改动，apply 必须拒绝（且在写入/备份前即拦截）
guard list backups; BKP_BEFORE=$(j '.data.count')
guard plan ip-address "$IP_ID" --set description=planned-desc
check "plan(漂移前): 退出码 0" "$GRC" "0"
PLAN_DRIFT=$(j '.data.plan.plan_id')
curl -fsS -X PATCH "$BASE/api/ipam/ip-addresses/$IP_ID/" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d '{"description":"changed-externally"}' >/dev/null
guard apply --plan "$PLAN_DRIFT"
check "apply(漂移): 退出码 2" "$GRC" "2"
check "apply(漂移): error.kind=conflict" "$(j '.error.kind')" "conflict"
check "apply(漂移): 未写入（NetBox 仍为外部值）" "$(nb_field '.description')" "changed-externally"
guard list backups
check "apply(漂移): 未新增备份记录" "$(j '.data.count')" "$BKP_BEFORE"

# --- 汇总 ------------------------------------------------------------------
echo ""
echo "================ 验收汇总 ================"
echo "   通过: $PASS   失败: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "❌ 验收未通过"
  exit 1
fi
echo "✅ 全部验收通过"
