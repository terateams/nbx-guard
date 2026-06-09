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
# 隔离 HOME，使验收不读取开发者本机的 ~/.nbx-guard/config.json（否则算子配置会污染
# 默认拒绝断言）。所有 guard* 调用都用这个空 HOME；显式用 NBX_GUARD_CONFIG 的用例不受影响。
HHOME="$STATE_DIR/hermetic-home"
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
mkdir -p "$HHOME"   # 空 HOME：隔离本机 ~/.nbx-guard/config.json，避免污染默认拒绝断言

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
  GOUT=$(HOME="$HHOME" NBX_GUARD_STATE_DIR="$STATE_DIR" NETBOX_URL="$BASE" NETBOX_TOKEN="$TOKEN" "$GUARD" "$@" 2>/dev/null)
  GRC=$?
  set -e
}
# 不带 token 运行（验证 token 门禁）
guard_notoken() {
  set +e
  GOUT=$(HOME="$HHOME" NBX_GUARD_STATE_DIR="$STATE_DIR" NETBOX_URL="$BASE" "$GUARD" "$@" 2>/dev/null)
  GRC=$?
  set -e
}
# 用 key 合法但 secret 错误的 v2 token 运行，触发 NetBox 的 403（"Invalid v2 token"）。
# NetBox 把"认证失败"与"权限不足"都压成 403，仅靠响应体 detail 区分；用于校验 CLI 会把
# detail 透传到 message，并给出指向凭据/权限（而非"检查资源"）的 next_action。
guard_badtoken() {
  set +e
  GOUT=$(HOME="$HHOME" NBX_GUARD_STATE_DIR="$STATE_DIR" NETBOX_URL="$BASE" \
    NETBOX_TOKEN="nbt_badkey000001.deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "$GUARD" "$@" 2>/dev/null)
  GRC=$?
  set -e
}
# 算子扩展运行：通过 NBX_GUARD_EXTRA_RESOURCES / *_FIELDS 让人工算子在默认拒绝之外
# 显式放行更多受治理类型与字段（site/tenant + facility/tenant 字段）。
guard_ext() {
  set +e
  GOUT=$(HOME="$HHOME" NBX_GUARD_STATE_DIR="$STATE_DIR" NETBOX_URL="$BASE" NETBOX_TOKEN="$TOKEN" \
    NBX_GUARD_EXTRA_RESOURCES="site=dcim/sites,tenant=tenancy/tenants" \
    NBX_GUARD_ALLOWED_FIELDS="facility" \
    NBX_GUARD_HIGH_RISK_FIELDS="tenant" \
    "$GUARD" "$@" 2>/dev/null)
  GRC=$?
  set -e
}
# 算子在内置类型上扩展一个字段（dns_name 默认被拒，算子放行为低风险）。
# 用于校验：自描述（describe/inspect）会同步反映算子放行的字段，避免 enforce 与 describe 不一致。
guard_extfield() {
  set +e
  GOUT=$(HOME="$HHOME" NBX_GUARD_STATE_DIR="$STATE_DIR" NETBOX_URL="$BASE" NETBOX_TOKEN="$TOKEN" \
    NBX_GUARD_ALLOWED_FIELDS="dns_name" \
    "$GUARD" "$@" 2>/dev/null)
  GRC=$?
  set -e
}
# 算子改用 ~/.nbx-guard/config.json 等价物（NBX_GUARD_CONFIG 指向临时 JSON 文件）扩展治理，
# 不再导出三个 env 变量。用于校验：配置文件与 env 行为完全一致。
CFG_FILE="$STATE_DIR/operator-config.json"
guard_cfgfile() {
  set +e
  GOUT=$(HOME="$HHOME" NBX_GUARD_STATE_DIR="$STATE_DIR" NETBOX_URL="$BASE" NETBOX_TOKEN="$TOKEN" \
    NBX_GUARD_CONFIG="$CFG_FILE" \
    "$GUARD" "$@" 2>/dev/null)
  GRC=$?
  set -e
}
# 配置文件 + env 并存：file 提供 site 类型，env 追加 tenant 类型，校验二者取并集。
guard_cfgunion() {
  set +e
  GOUT=$(HOME="$HHOME" NBX_GUARD_STATE_DIR="$STATE_DIR" NETBOX_URL="$BASE" NETBOX_TOKEN="$TOKEN" \
    NBX_GUARD_CONFIG="$CFG_FILE" \
    NBX_GUARD_EXTRA_RESOURCES="tenant=tenancy/tenants" \
    "$GUARD" "$@" 2>/dev/null)
  GRC=$?
  set -e
}
# 算子开启 create（NBX_GUARD_CREATABLE_RESOURCES）。create 默认拒绝，仅放行此处列出的类型，
# 且每次创建仍需审批；用于端到端 create -> approve -> apply(POST) -> restore(DELETE 回滚) 验证。
guard_create() {
  set +e
  GOUT=$(HOME="$HHOME" NBX_GUARD_STATE_DIR="$STATE_DIR" NETBOX_URL="$BASE" NETBOX_TOKEN="$TOKEN" \
    NBX_GUARD_CREATABLE_RESOURCES="vlan" \
    "$GUARD" "$@" 2>/dev/null)
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
check "version: 版本号" "$(j '.data.version')" "0.10.0"
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
check "describe(目录): 含 contact 类型" \
  "$(j '.data.resource_types | map(.resource_type) | index("contact") != null')" "true"

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

# 4d) describe contact（受治理类型 contact -> tenancy/contacts，校验字段与实时同步）
guard describe contact
check "describe contact: ok=true" "$(j '.ok')" "true"
check "describe contact: endpoint=tenancy/contacts" "$(j '.data.netbox_endpoint')" "tenancy/contacts"
check "describe contact: email 为低风险" \
  "$(j '.data.fields[] | select(.name=="email") | .class')" "allowed"
check "describe contact: groups 为高风险" \
  "$(j '.data.fields[] | select(.name=="groups") | .class')" "high_risk"
check "describe contact: 实时同步 status=ok" "$(j '.data.netbox_sync.status')" "ok"
check "describe contact: email 已对齐 NetBox" \
  "$(j '.data.fields[] | select(.name=="email") | .present_in_netbox')" "true"
check "describe contact: 无漂移字段（含 groups M2M）" \
  "$(j '.data.netbox_sync.missing_in_netbox | length')" "0"

guard describe contact --source openapi
check "describe contact --source openapi: 同步 status=ok" "$(j '.data.netbox_sync.status')" "ok"
check "describe contact --source openapi: 解析出 component" \
  "$(j '.data.netbox_sync.component != null')" "true"
check "describe contact --source openapi: 无漂移字段" \
  "$(j '.data.netbox_sync.missing_in_netbox | length')" "0"

# 4e) list-resources / search（资源发现：Agent 先发现 id，再做 id 级操作）
IP2_ID=$(curl -fsS -X POST "$BASE/api/ipam/ip-addresses/" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d '{"address":"192.0.2.20/24","status":"active","description":"discovery-target"}' | jq -r '.id')

guard list-resources ip-address --limit 50
check "list-resources: ok=true" "$(j '.ok')" "true"
check "list-resources: endpoint=ipam/ip-addresses" "$(j '.data.netbox_endpoint')" "ipam/ip-addresses"
check "list-resources: 默认 brief=true" "$(j '.data.query.brief')" "true"
check "list-resources: count>=2" "$(j 'if .data.count >= 2 then "yes" else "no" end')" "yes"
check "list-resources: brief 仅含标识字段（无 dns_name）" \
  "$(j '.data.results[0] | has("dns_name")')" "false"

guard search ip-address -q discovery-target
check "search: ok=true" "$(j '.ok')" "true"
check "search: query.text=discovery-target" "$(j '.data.query.text')" "discovery-target"
check "search: 命中刚建的 ip" "$(j "[.data.results[] | select(.id==$IP2_ID)] | length")" "1"

guard search ip-address --name discovery-target
check "search --name 别名映射到 q(text)" "$(j '.data.query.text')" "discovery-target"

guard list-resources ip-address --all-fields --limit 1
check "list-resources --all-fields: brief=false" "$(j '.data.query.brief')" "false"
check "list-resources --all-fields: 含完整字段 dns_name" "$(j '.data.results[0] | has("dns_name")')" "true"

guard list-resources nope
check "list-resources(未知类型): 退出码 2" "$GRC" "2"
check "list-resources(未知类型): invalid_args" "$(j '.error.kind')" "invalid_args"

# 4f) 算子扩展受治理类型/字段（NBX_GUARD_EXTRA_RESOURCES / *_FIELDS，人工算子显式放行；
#     默认拒绝与全部工作流控制不变，Agent 自身无法扩展）
SITE_ID=$(curl -fsS -X POST "$BASE/api/dcim/sites/" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d '{"name":"Acceptance HQ","slug":"acc-hq","status":"active"}' | jq -r '.id')

# 未配置扩展时 site 属未知类型 —— 类型级默认拒绝仍生效
guard get site "$SITE_ID"
check "未扩展 get site: 退出码 2" "$GRC" "2"
check "未扩展 get site: invalid_args（默认拒绝）" "$(j '.error.kind')" "invalid_args"

# 配置扩展后可只读
guard_ext get site "$SITE_ID"
check "扩展后 get site: ok=true" "$(j '.ok')" "true"
check "扩展后 get site: 名称正确" "$(j '.data.resource.name')" "Acceptance HQ"

# describe 目录纳入扩展类型
guard_ext describe --offline
check "describe(目录): 含算子扩展类型 site" \
  "$(j '.data.resource_types | map(.resource_type) | index("site") != null')" "true"

# describe site：合成文档 + 实时 OPTIONS 同步
guard_ext describe site --source options
check "describe site(扩展): endpoint=dcim/sites" "$(j '.data.netbox_endpoint')" "dcim/sites"
check "describe site(扩展): 实时同步 status=ok" "$(j '.data.netbox_sync.status')" "ok"
check "describe site(扩展): facility 实时存在" \
  "$(j '.data.fields[] | select(.name=="facility") | .present_in_netbox')" "true"
check "describe site(扩展): 无漂移字段" "$(j '.data.netbox_sync.missing_in_netbox | length')" "0"

# 发现扩展类型
guard_ext list-resources site
check "list-resources site(扩展): ok=true" "$(j '.ok')" "true"
check "list-resources site(扩展): count>=1" "$(j 'if .data.count >= 1 then "yes" else "no" end')" "yes"

# 写路径：算子放行的低风险字段 facility 走 plan->apply（仍经计划/备份/审计）
guard_ext plan site "$SITE_ID" --set facility="Bldg A"
check "plan site facility(扩展低风险): ok=true" "$(j '.ok')" "true"
check "plan site facility: requires_approval=false" "$(j '.data.plan.requires_approval')" "false"
SITE_PLAN=$(j '.data.plan.plan_id')
guard_ext apply --plan "$SITE_PLAN"
check "apply site facility(扩展): status=applied" "$(j '.data.status')" "applied"
check "apply site facility: NetBox 侧实写" \
  "$(curl -fsS -H "$NB_AUTH" "$BASE/api/dcim/sites/$SITE_ID/" | jq -r '.facility')" "Bldg A"

# 算子高风险字段 tenant —— 需审批
guard_ext plan site "$SITE_ID" --set tenant=1
check "plan site tenant(扩展高风险): requires_approval=true" "$(j '.data.plan.requires_approval')" "true"

# 默认拒绝不可被削弱：身份字段 name 即使在扩展类型上仍被拒
guard_ext plan site "$SITE_ID" --set name=renamed
check "plan site name(扩展类型仍拒绝): 退出码 2" "$GRC" "2"
check "plan site name: policy_denied" "$(j '.error.kind')" "policy_denied"

# 4g) 自描述与 enforce 一致性：算子在内置类型上放行的字段，describe/inspect 必须能反映出来，
#     否则 Agent 无法发现该字段。dns_name 默认被拒，放行后应在自描述中出现并实时对齐 NetBox。
guard describe ip-address --offline
check "describe(无 env): dns_name 不在字段列表（默认拒绝）" \
  "$(j '[.data.fields[].name] | index("dns_name") != null')" "false"

guard_extfield describe ip-address --source options
check "describe(算子放行): dns_name 出现且为低风险" \
  "$(j '.data.fields[] | select(.name=="dns_name") | .class')" "allowed"
check "describe(算子放行): dns_name 实时存在于 NetBox" \
  "$(j '.data.fields[] | select(.name=="dns_name") | .present_in_netbox')" "true"

guard_extfield inspect ip-address "$IP_ID"
check "inspect(算子放行): allowed_fields 含 dns_name" \
  "$(j '.data.policy.allowed_fields | index("dns_name") != null')" "true"

guard_extfield plan ip-address "$IP_ID" --set dns_name=host.acceptance.local
check "plan(算子放行 dns_name): 低风险可直接应用" "$(j '.data.plan.requires_approval')" "false"

guard help
check "help(无 env): high_risk_fields 不含 serial" \
  "$(j '.data.high_risk_fields | index("serial") != null')" "false"

# 4h) 配置文件治理扩展（~/.nbx-guard/config.json 等价物，经 NBX_GUARD_CONFIG）：
#     与三个 env 变量行为完全一致，且 file 与 env 取并集；坏 JSON 走 config_error。
mkdir -p "$STATE_DIR"
cat > "$CFG_FILE" <<'JSON'
{
  "extra_resources": { "site": "dcim/sites" },
  "allowed_fields": ["facility"],
  "high_risk_fields": ["tenant"]
}
JSON

# describe 目录纳入配置文件扩展类型
guard_cfgfile describe --offline
check "cfg describe(目录): 含配置文件扩展类型 site" \
  "$(j '.data.resource_types | map(.resource_type) | index("site") != null')" "true"

# describe site：合成文档 + 实时同步，facility 由配置文件放行
guard_cfgfile describe site --source options
check "cfg describe site: endpoint=dcim/sites" "$(j '.data.netbox_endpoint')" "dcim/sites"
check "cfg describe site: 实时同步 status=ok" "$(j '.data.netbox_sync.status')" "ok"
check "cfg describe site: facility 为低风险（配置文件放行）" \
  "$(j '.data.fields[] | select(.name=="facility") | .class')" "allowed"

# 写路径：配置文件放行的 facility 走 plan->apply（与 env 完全一致）
guard_cfgfile plan site "$SITE_ID" --set facility="Cfg Bldg"
check "cfg plan site facility: ok=true" "$(j '.ok')" "true"
check "cfg plan site facility: requires_approval=false" "$(j '.data.plan.requires_approval')" "false"
CFG_PLAN=$(j '.data.plan.plan_id')
guard_cfgfile apply --plan "$CFG_PLAN"
check "cfg apply site facility: status=applied" "$(j '.data.status')" "applied"
check "cfg apply site facility: NetBox 侧实写" \
  "$(curl -fsS -H "$NB_AUTH" "$BASE/api/dcim/sites/$SITE_ID/" | jq -r '.facility')" "Cfg Bldg"

# 配置文件 high_risk_fields 生效：tenant 字段需审批
guard_cfgfile plan site "$SITE_ID" --set tenant=1
check "cfg plan site tenant(配置文件高风险): requires_approval=true" "$(j '.data.plan.requires_approval')" "true"

# 默认拒绝不可削弱：身份字段 name 仍被拒
guard_cfgfile plan site "$SITE_ID" --set name=renamed
check "cfg plan site name: policy_denied" "$(j '.error.kind')" "policy_denied"

# 并集：file 提供 site，env 追加 tenant，describe 目录应同时含两者
guard_cfgunion describe --offline
check "cfg+env 并集: 目录含 site（来自文件）" \
  "$(j '.data.resource_types | map(.resource_type) | index("site") != null')" "true"
check "cfg+env 并集: 目录含 tenant（来自 env）" \
  "$(j '.data.resource_types | map(.resource_type) | index("tenant") != null')" "true"

# 坏 JSON：任何命令都应以 config_error 退出 3
echo 'not json{' > "$CFG_FILE"
guard_cfgfile describe --offline
check "cfg 坏 JSON: 退出码 3" "$GRC" "3"
check "cfg 坏 JSON: error.kind=config_error" "$(j '.error.kind')" "config_error"
rm -f "$CFG_FILE" 2>/dev/null || true

# 显式 NBX_GUARD_CONFIG 指向不存在文件：config_error
guard_cfgfile describe --offline
check "cfg 文件缺失(显式路径): 退出码 3" "$GRC" "3"
check "cfg 文件缺失(显式路径): config_error" "$(j '.error.kind')" "config_error"

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

# 8b) --data：字段也能用一整段 JSON 传（与 --set 同一条管道）。仅建 plan，不改 NetBox。
guard plan ip-address "$IP_ID" --data '{"description":"acceptance-data"}'
check "plan(--data 内联): 退出码 0" "$GRC" "0"
check "plan(--data 内联): status=planned" "$(j '.data.plan.status')" "planned"
check "plan(--data 内联): changes.description" "$(j '.data.plan.changes.description')" "acceptance-data"

echo '{"description":"acceptance-stdin"}' | guard plan ip-address "$IP_ID" --data @-
check "plan(--data @- stdin): 退出码 0" "$GRC" "0"
check "plan(--data @- stdin): changes.description" "$(j '.data.plan.changes.description')" "acceptance-stdin"

# --data 打底 + --set 覆盖（从左到右，后者覆盖前者）
guard plan ip-address "$IP_ID" --data '{"description":"from-data"}' --set description=from-set
check "plan(--data+--set 覆盖): changes.description" "$(j '.data.plan.changes.description')" "from-set"

# --data 顶层非对象 -> invalid_args（退出码 2）
guard plan ip-address "$IP_ID" --data '[1,2,3]'
check "plan(--data 非对象): 退出码 2" "$GRC" "2"
check "plan(--data 非对象): error.kind=invalid_args" "$(j '.error.kind')" "invalid_args"

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

# 4i) read-policy（读侧隐私分层：默认 basic 脱敏敏感字段；--fields all 需读审批；
#     算子可经 config.json / env 的 read_sensitive_fields 追加敏感字段）
CONTACT_ID=$(curl -fsS -X POST "$BASE/api/tenancy/contacts/" \
  -H "$NB_AUTH" -H "Content-Type: application/json" \
  -d '{"name":"Read Policy Contact","phone":"+1-555-0100","email":"rp@example.com"}' | jq -r '.id')
[ -n "$CONTACT_ID" ] && [ "$CONTACT_ID" != "null" ] || { echo "❌ 创建 contact 失败" >&2; exit 3; }

# 默认 basic：敏感字段被脱敏，无需审批
guard get contact "$CONTACT_ID"
check "read-policy get(默认): ok=true" "$(j '.ok')" "true"
check "read-policy get(默认): field_profile=basic" "$(j '.data.read_policy.field_profile')" "basic"
check "read-policy get(默认): phone 被脱敏" "$(j '.data.resource.phone')" "[redacted: read approval required]"
check "read-policy get(默认): redacted_fields 含 phone" \
  "$(j '.data.read_policy.redacted_fields | index("phone") != null')" "true"

# --fields all 未审批：被读门禁拦截
guard get contact "$CONTACT_ID" --fields all
check "read-policy get(all 未审批): 退出码 2" "$GRC" "2"
check "read-policy get(all 未审批): needs_approval" "$(j '.error.kind')" "needs_approval"

# --fields all --plan-read：创建读计划（pending_approval）
guard get contact "$CONTACT_ID" --fields all --plan-read
check "read-policy plan-read: ok=true" "$(j '.ok')" "true"
check "read-policy plan-read: action=read" "$(j '.data.plan.action')" "read"
check "read-policy plan-read: status=pending_approval" "$(j '.data.plan.status')" "pending_approval"
RPLAN=$(j '.data.plan.plan_id')

# approve-read：人工审批读计划（绑定 plan_hash）
guard approve-read --plan "$RPLAN" --note "acceptance read"
check "read-policy approve-read: 退出码 0" "$GRC" "0"
check "read-policy approve-read: plan_status=approved" "$(j '.data.plan_status')" "approved"

# 凭已审批读计划披露完整对象：phone 还原为真实值
guard get contact "$CONTACT_ID" --fields all --plan "$RPLAN"
check "read-policy get(已审批 all): ok=true" "$(j '.ok')" "true"
check "read-policy get(已审批 all): field_profile=all" "$(j '.data.read_policy.field_profile')" "all"
check "read-policy get(已审批 all): phone 披露真实值" "$(j '.data.resource.phone')" "+1-555-0100"

# config.json 的 read_sensitive_fields 扩展读敏感字段集（finding A：与 env 等价、取并集）
mkdir -p "$STATE_DIR"
cat > "$CFG_FILE" <<'JSON'
{ "read_sensitive_fields": ["serial"] }
JSON
guard_cfgfile describe contact --offline
check "read-policy cfg: sensitive_fields 含内置 phone" \
  "$(j '.data.read_policy.sensitive_fields | index("phone") != null')" "true"
check "read-policy cfg: sensitive_fields 含配置文件追加的 serial" \
  "$(j '.data.read_policy.sensitive_fields | index("serial") != null')" "true"
rm -f "$CFG_FILE" 2>/dev/null || true

# 4j) resolve（人类可读标识 -> 对象 id；单一/未命中/歧义三态确定，绝不静默挑选）
# 单一命中：按 address 精确解析到唯一 id
guard resolve ip-address --address 192.0.2.10/24
check "resolve(单一): ok=true" "$(j '.ok')" "true"
check "resolve(单一): status=resolved" "$(j '.data.status')" "resolved"
check "resolve(单一): resolved.id 命中 IP_ID" "$(j '.data.resolved.id')" "$IP_ID"
check "resolve(单一): match_count=1" "$(j '.data.match_count')" "1"

# 未命中：返回 not_found，退出码 2
guard resolve ip-address --address 198.51.100.200/32
check "resolve(未命中): 退出码 2" "$GRC" "2"
check "resolve(未命中): error.kind=not_found" "$(j '.error.kind')" "not_found"

# 歧义：多条命中只给候选列表，绝不静默挑选；退出码 2 阻断 && 链
guard resolve ip-address --filter status=active
check "resolve(歧义): 退出码 2" "$GRC" "2"
check "resolve(歧义): error.kind=ambiguous" "$(j '.error.kind')" "ambiguous"
check "resolve(歧义): status=ambiguous" "$(j '.data.status')" "ambiguous"
check "resolve(歧义): match_count>=2" "$(j 'if .data.match_count >= 2 then "yes" else "no" end')" "yes"
check "resolve(歧义): 给出候选列表" "$(j 'if (.data.candidates | length) >= 2 then "yes" else "no" end')" "yes"
check "resolve(歧义): 不含 resolved（未静默挑选）" "$(j '.data | has("resolved")')" "false"

# 算子扩展类型同样可解析（site 按 slug，复用 endpointFor 的扩展能力）
guard_ext resolve site --slug acc-hq
check "resolve(扩展类型 site): ok=true" "$(j '.ok')" "true"
check "resolve(扩展类型 site): resolved.id 命中 SITE_ID" "$(j '.data.resolved.id')" "$SITE_ID"

# 参数校验：缺少选择器
guard resolve ip-address
check "resolve(无选择器): 退出码 2" "$GRC" "2"
check "resolve(无选择器): invalid_args" "$(j '.error.kind')" "invalid_args"

# 4k) NetBox 认证/权限失败（403）：CLI 必须透传 NetBox 的 detail 并把 next_action 指向
#     凭据/权限，而不是误导去"检查资源"。NetBox 对认证失败与权限不足都返回 403。
echo ""
echo "-- 4k) netbox 403：透传 detail + 指向凭据/权限 --"
guard_badtoken get device 1
check "403(坏 token): 退出码 3" "$GRC" "3"
check "403(坏 token): error.kind=netbox_error" "$(j '.error.kind')" "netbox_error"
check "403(坏 token): message 含 HTTP 403" "$(j '.error.message | contains("403")')" "true"
check "403(坏 token): message 透传 NetBox detail" "$(j '.error.message | contains("Invalid")')" "true"
check "403(坏 token): next_action 指向 NETBOX_TOKEN" "$(j '.error.next_action | contains("NETBOX_TOKEN")')" "true"

# 4l) snapshot / export 读敏感策略（#14：所有"完整对象"读面必须与 get --fields all 同等门禁；
#     snapshot 默认脱敏、--fields all 走读审批；export 批量永不披露原始敏感值，full 档逐条脱敏）
echo ""
echo "-- 4l) snapshot/export 读敏感策略（#14）--"
# snapshot 默认 basic：敏感字段脱敏，无需审批
guard snapshot contact "$CONTACT_ID"
check "snapshot(默认): ok=true" "$(j '.ok')" "true"
check "snapshot(默认): field_profile=basic" "$(j '.data.read_policy.field_profile')" "basic"
check "snapshot(默认): phone 被脱敏" "$(j '.data.resource.phone')" "[redacted: read approval required]"
check "snapshot(默认): metadata.redacted_fields 含 phone" \
  "$(j '.data.metadata.redacted_fields | index("phone") != null')" "true"

# snapshot --fields all 未审批：被读门禁拦截（与 get 同等）
guard snapshot contact "$CONTACT_ID" --fields all
check "snapshot(all 未审批): 退出码 2" "$GRC" "2"
check "snapshot(all 未审批): needs_approval" "$(j '.error.kind')" "needs_approval"

# snapshot --fields all --plan-read：snapshot 自身即可创建读计划
guard snapshot contact "$CONTACT_ID" --fields all --plan-read
check "snapshot plan-read: ok=true" "$(j '.ok')" "true"
check "snapshot plan-read: action=read" "$(j '.data.plan.action')" "read"
check "snapshot plan-read: status=pending_approval" "$(j '.data.plan.status')" "pending_approval"
SRPLAN=$(j '.data.plan.plan_id')

# approve-read 后凭计划披露完整对象：phone 还原真实值，并记入审计
guard approve-read --plan "$SRPLAN" --note "acceptance snapshot read"
check "snapshot approve-read: 退出码 0" "$GRC" "0"
guard snapshot contact "$CONTACT_ID" --fields all --plan "$SRPLAN"
check "snapshot(已审批 all): ok=true" "$(j '.ok')" "true"
check "snapshot(已审批 all): field_profile=all" "$(j '.data.read_policy.field_profile')" "all"
check "snapshot(已审批 all): phone 披露真实值" "$(j '.data.resource.phone')" "+1-555-0100"
check "snapshot(已审批 all): disclosed_fields 含 phone" \
  "$(j '.data.read_policy.disclosed_fields | index("phone") != null')" "true"

# export --fields full：逐条脱敏敏感字段，metadata.redacted_fields 汇报（批量永不披露原始值）
guard export contact --filter id="$CONTACT_ID" --fields full
check "export(full): ok=true" "$(j '.ok')" "true"
check "export(full): 命中目标 contact" "$(j '.data.records[0].id')" "$CONTACT_ID"
check "export(full): phone 被脱敏" "$(j '.data.records[0].phone')" "[redacted: read approval required]"
check "export(full): metadata.redacted_fields 含 phone" \
  "$(j '.data.metadata.redacted_fields | index("phone") != null')" "true"

# 4m) plan no_change（#13：所有 --set 值与当前状态完全一致 -> 拒绝建计划，不产生可应用计划，
#     不产生审批/备份/审计；部分变更或真实变更仍正常建计划）
echo ""
echo "-- 4m) plan no_change（#13）--"
# 先把 contact.title 设为已知值（低风险字段，计划->应用，建立确定基线）
guard plan contact "$CONTACT_ID" --set title="NoOp Title"
check "no_change 准备: plan ok=true" "$(j '.ok')" "true"
NOOP_PLAN=$(j '.data.plan.plan_id')
guard apply --plan "$NOOP_PLAN"
check "no_change 准备: apply 退出码 0" "$GRC" "0"
check "no_change 准备: status=applied" "$(j '.data.status')" "applied"

# 用相同值再次 plan：必须 no_change、退出码 2、且不产生 plan
guard plan contact "$CONTACT_ID" --set title="NoOp Title"
check "no_change(同值): 退出码 2" "$GRC" "2"
check "no_change(同值): ok=false" "$(j '.ok')" "false"
check "no_change(同值): error.kind=no_change" "$(j '.error.kind')" "no_change"
check "no_change(同值): data.status=no_change" "$(j '.data.status')" "no_change"
check "no_change(同值): 未创建 plan（无 plan 键）" "$(j '.data | has("plan")')" "false"
check "no_change(同值): 回传 requested.title" "$(j '.data.requested.title')" "NoOp Title"

# 部分变更（一个字段同值、另一个字段不同）：仍正常建计划
guard plan contact "$CONTACT_ID" --set title="NoOp Title" --set description="partial change"
check "no_change(部分变更): ok=true 仍建计划" "$(j '.ok')" "true"
check "no_change(部分变更): 有 plan_id" "$(j '.data.plan.plan_id | length > 0')" "true"

# 真实变更（值不同）：仍正常建计划
guard plan contact "$CONTACT_ID" --set title="Changed Title"
check "no_change(异值): ok=true 仍建计划" "$(j '.ok')" "true"

# 4n) create（受治理创建：类型默认拒绝 -> 算子开启 -> 始终需审批 -> apply 经 POST 创建 ->
#     restore 经 DELETE 删除回滚）
echo ""
echo "-- 4n) create（受治理创建）--"
# 未开启该类型 -> policy_denied（即便是内置类型，create 也默认拒绝）
guard create vlan --set name=AccVlan --set vid=3999
check "create(未开启): 退出码 2" "$GRC" "2"
check "create(未开启): ok=false" "$(j '.ok')" "false"
check "create(未开启): error.kind=policy_denied" "$(j '.error.kind')" "policy_denied"

# 算子开启 vlan：create 生成 plan（始终 high/pending_approval，resource_id=(new)）
guard_create create vlan --set name=AccVlan --set vid=3999
check "create(已开启): ok=true" "$(j '.ok')" "true"
check "create(已开启): action=create" "$(j '.data.plan.action')" "create"
check "create(已开启): resource_id=(new)" "$(j '.data.plan.resource_id')" "(new)"
check "create(已开启): risk=high" "$(j '.data.plan.risk_level')" "high"
check "create(已开启): requires_approval=true" "$(j '.data.plan.requires_approval')" "true"
check "create(已开启): status=pending_approval" "$(j '.data.plan.status')" "pending_approval"
CREATE_PLAN=$(j '.data.plan.plan_id')

# 未审批即 apply -> 拒绝
guard_create apply --plan "$CREATE_PLAN"
check "create apply(未审批): 退出码 2" "$GRC" "2"
check "create apply(未审批): error.kind=not_approved" "$(j '.error.kind')" "not_approved"

# approve -> apply：POST 创建，data.resource_id = NetBox 新分配 id
guard_create approve --plan "$CREATE_PLAN" --note "acceptance create"
check "create approve: plan_status=approved" "$(j '.data.plan_status')" "approved"
guard_create apply --plan "$CREATE_PLAN"
check "create apply(已审批): 退出码 0" "$GRC" "0"
check "create apply(已审批): status=applied" "$(j '.data.status')" "applied"
check "create apply(已审批): action=create" "$(j '.data.action')" "create"
NEW_VLAN_ID=$(j '.data.resource_id')
CREATE_BKP=$(j '.data.backup_id')
check "create apply(已审批): 返回新对象 id（非 (new)）" \
  "$([ -n "$NEW_VLAN_ID" ] && [ "$NEW_VLAN_ID" != '(new)' ] && [ "$NEW_VLAN_ID" != 'null' ] && echo yes || echo no)" "yes"
# 直接查 NetBox：该 vlan 确已创建，vid 正确
check "create: NetBox 侧 vlan 已创建（vid=3999）" \
  "$(curl -fsS -H "$NB_AUTH" "$BASE/api/ipam/vlans/$NEW_VLAN_ID/" | jq -r '.vid')" "3999"

# restore：撤销创建 = DELETE，NetBox 侧对象消失
guard_create restore --backup "$CREATE_BKP"
check "create restore: 退出码 0" "$GRC" "0"
check "create restore: action=delete" "$(j '.data.action')" "delete"
check "create restore: NetBox 侧 vlan 已删除（404）" \
  "$(curl -s -o /dev/null -w '%{http_code}' -H "$NB_AUTH" "$BASE/api/ipam/vlans/$NEW_VLAN_ID/")" "404"

# --- 汇总 ------------------------------------------------------------------
echo ""
echo "================ 验收汇总 ================"
echo "   通过: $PASS   失败: $FAIL"
if [ "$FAIL" -ne 0 ]; then
  echo "❌ 验收未通过"
  exit 1
fi
echo "✅ 全部验收通过"
