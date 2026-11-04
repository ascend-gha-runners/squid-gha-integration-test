#!/usr/bin/env bash
# =============================================================================
# repro-gitcdn-unsynced-sha.sh —— git-cdn 无法为「尚未同步的 SHA」回源（回归守卫）
#
# 事故（2026-11-04 gy-006，run 41762789640 attempt 1，9/11 job 红）：
#   runner 的 /root/.gitconfig 里有 insteadOf：
#       [url "http://git-cdn-service.git-cdn.svc.cluster.local:8000/"]
#               insteadOf = https://github.com/
#   → actions/checkout 的 URL 在客户端层就变成 git-cdn（不经 squid，squid 的
#     github 302 规则与此无关）；
#   → checkout 执行 `git fetch --depth=1 origin +<新提交SHA>:refs/remotes/origin/main`，
#     客户端带 `Authorization: basic x-access-token:<token>`；
#   → git-cdn 本地缓存仓没有该 SHA，走兜底 fetch_sha/update 回源，而回源 URL 是：
#       https://x-access-token:TOKEN@gh-proxy.test.osinfra.cn/
#         https://x-access-token:TOKEN@github.com/<org>/<repo>.git
#     （git_cdn/util.py:generate_url 对 base 里的每个 "https://" 都插一次凭据，
#       GITSERVER_UPSTREAM 自带 ".../https://github.com/" 两个 https:// → 双拼），
#     gh-proxy 立即 403（rc=128，~0.13s），退避重试全失败；
#   → git-cdn 最终向客户端返回 `upload-pack: not our ref <sha>`，checkout 失败。
#
# 判定（正向断言健康行为，缺陷未修时本阶段红属预期）：
#   ① 造一个「上游可服务、git-cdn 缓存必定没有」的 SHA：用 API 在 <main> 上建
#      一个空提交并挂到临时分支 refs/heads/gitcdn-unsynced-<run>-<attempt>-<pid>
#      （cache-warmer 每 1800s 才同步一次 refs，窗口内必然未同步；结束后删 ref）；
#   ② 对照组：剥离 insteadOf 直连 github.com（经 squid/gh-proxy 透传）取该 SHA
#      —— 成功才说明上游确实有这个对象，否则是环境问题，记 SKIP；
#   ③ 被测面：按真实客户端形态（`http.extraheader: Authorization: basic`）向
#      git-cdn 按 SHA 取 —— 健康 = 成功；当前缺陷下 = 立即 `not our ref`。
#
# 依赖：
#   - 只在注入了 git-cdn insteadOf 的集群成立（gy-006）；git-cdn 不可达 → SKIP
#   - GH_TOKEN 需要 contents: write（建/删临时 ref）；无权限 → SKIP（不误红）
#
# 用法：
#   bash test-squid/repro-gitcdn-unsynced-sha.sh
#
# 可覆盖：
#   GIT_CDN_BASE   git-cdn 基址（默认 gy-006 的 svc 域名）
#   REPO_SLUG      目标仓库（默认 $GITHUB_REPOSITORY）
#   GH_TOKEN       建/删临时 ref 与客户端 Basic 认证用的 token
#   RESULTS        结果目录
#
# 退出码：0=PASS（git-cdn 能回源未同步 SHA）；1=FAIL（缺陷复现）；2=SKIP
# =============================================================================
set -uo pipefail

GIT_CDN_BASE="${GIT_CDN_BASE:-http://git-cdn-service.git-cdn.svc.cluster.local:8000/}"
REPO_SLUG="${REPO_SLUG:-${GITHUB_REPOSITORY:-}}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
API="${GITHUB_API_URL:-https://api.github.com}"
results="${RESULTS:-${RESULTS_DIR:-/tmp/repro-gitcdn-unsynced}}"
mkdir -p "$results"

REF_NAME=""
WD=""
log() { echo "[$(date '+%H:%M:%S')] $*"; }

cleanup() {
    if [ -n "$REF_NAME" ]; then
        local code
        code=$(api_call DELETE "/repos/$REPO_SLUG/git/refs/${REF_NAME#refs/}" >/dev/null 2>&1; echo $?)
        log "清理临时 ref $REF_NAME（rc=$code）"
    fi
    [ -n "$WD" ] && rm -rf "$WD"
}
trap cleanup EXIT

# ---- 前置检查 1：git-cdn 可达（只有注入了 git-cdn 的集群才跑）-----------------
if [ -z "$REPO_SLUG" ]; then log "⚠️ 无 REPO_SLUG（$GITHUB_REPOSITORY 为空）——本地运行，记 SKIP"; exit 2; fi
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$GIT_CDN_BASE" 2>/dev/null) || code="000"
if [ "$code" != "200" ]; then
    log "⚠️ git-cdn 不可达（$GIT_CDN_BASE GET=$code）——本集群未注入 insteadOf → git-cdn，记 SKIP"
    exit 2
fi

# ---- 前置检查 2：runner 实机 gitconfig 确实把 github.com 改写到 git-cdn --------
# 用 `git ls-remote --get-url` 看展开结果（不发网络请求），比直接读 config 更贴近
# 客户端真实行为（insteadOf 可能来自 /root/.gitconfig、/etc/gitconfig 或 include）。
rewritten=$(GIT_TERMINAL_PROMPT=0 git ls-remote --get-url "https://github.com/$REPO_SLUG.git" 2>/dev/null)
case "$rewritten" in
    "$GIT_CDN_BASE"*|http://git-cdn-service.*) : ;;
    *)
        log "⚠️ insteadOf 未指向 git-cdn（展开为 ${rewritten:-空}）——不是被测形态，记 SKIP"
        exit 2
        ;;
esac
log "   insteadOf 展开：https://github.com/$REPO_SLUG.git → $rewritten"

if [ -z "$TOKEN" ]; then log "⚠️ 无 GH_TOKEN（需要 contents: write 建临时 ref）——记 SKIP"; exit 2; fi

api_call() {  # method path [json-body] —— stdout 为响应体+'\n'+HTTP 码
    local method=$1 path=$2 body=${3:-}
    if [ -n "$body" ]; then
        curl -sS -X "$method" -H "Authorization: Bearer $TOKEN" \
            -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' \
            -d "$body" -w '\n%{http_code}' --max-time 30 "$API$path"
    else
        curl -sS -X "$method" -H "Authorization: Bearer $TOKEN" \
            -H 'Accept: application/vnd.github+json' -w '\n%{http_code}' --max-time 30 "$API$path"
    fi
}

resp_field() {  # resp_field <json-keys...> —— 从 stdin 的 JSON 里取嵌套字段，失败输出空
    python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1:]:
    d = d[k] if isinstance(d, dict) else None
    if d is None:
        break
print("" if d is None else d)
' "$@" 2>/dev/null
}

# ---- ① 造一个上游可服务、git-cdn 缓存必定缺失的 SHA ---------------------------
log "① 在 $REPO_SLUG 的 main 上创建一个临时提交 + 临时 ref"
ref_resp=$(api_call GET "/repos/$REPO_SLUG/git/ref/heads/main")
ref_code=${ref_resp##*$'\n'}; ref_body=${ref_resp%$'\n'*}
if [ "$ref_code" != "200" ]; then
    log "⚠️ 读 main ref 失败（HTTP $ref_code）——token 权限/网络问题，记 SKIP"; exit 2
fi
main_sha=$(printf '%s' "$ref_body" | resp_field object sha)
if [ -z "$main_sha" ]; then log "⚠️ main SHA 解析失败，记 SKIP"; exit 2; fi
tree_sha=$(printf '%s' "$(api_call GET "/repos/$REPO_SLUG/git/commits/$main_sha" | sed '$d')" | resp_field tree sha)
if [ -z "$tree_sha" ]; then log "⚠️ main tree SHA 解析失败，记 SKIP"; exit 2; fi

commit_body=$(printf '{"message":"chore(git-cdn probe): ephemeral commit for unsynced-SHA regression case\\n\\ncreated and removed by test-squid/repro-gitcdn-unsynced-sha.sh","tree":"%s","parents":["%s"]}' "$tree_sha" "$main_sha")
commit_resp=$(api_call POST "/repos/$REPO_SLUG/git/commits" "$commit_body")
commit_code=${commit_resp##*$'\n'}; commit_json=${commit_resp%$'\n'*}
if [ "$commit_code" != "201" ]; then
    log "⚠️ 建提交失败（HTTP $commit_code）——token 无 contents: write，记 SKIP"
    printf '%s\n' "$commit_json" | sed 's/^/    /' | head -3
    exit 2
fi
probe_sha=$(printf '%s' "$commit_json" | resp_field sha)
ref_name="refs/heads/gitcdn-unsynced-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"
ref_create=$(api_call POST "/repos/$REPO_SLUG/git/refs" "$(printf '{"ref":"%s","sha":"%s"}' "$ref_name" "$probe_sha")")
ref_create_code=${ref_create##*$'\n'}
if [ "$ref_create_code" != "201" ]; then
    log "⚠️ 建临时 ref 失败（HTTP $ref_create_code），记 SKIP"; exit 2
fi
REF_NAME="$ref_name"
log "   临时 SHA=$probe_sha  ref=$REF_NAME"

# ---- ② 对照组：上游确实能服务该 SHA（剥掉 insteadOf，直连 github.com）--------
WD=$(mktemp -d "${TMPDIR:-/tmp}/gitcdn-probe.XXXXXX")
mkdir -p "$WD/control" "$WD/target"
control_ok=0
for i in 1 2 3 4 5; do
    if GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
        timeout 90 git -C "$WD/control" init -q 2>/dev/null \
        && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
        timeout 90 git -C "$WD/control" fetch --no-tags --depth=1 \
            "https://github.com/$REPO_SLUG.git" "+$probe_sha:refs/probe" \
            >"$results/control.log" 2>&1; then
        control_ok=1; break
    fi
    sleep $((i * 3))
done
if [ "$control_ok" != "1" ]; then
    log "⚠️ 对照组失败：上游直连取不到 $probe_sha —— 非 git-cdn 问题，记 SKIP"
    tail -3 "$results/control.log" | sed 's/^/    /'
    exit 2
fi
log "② 对照组 OK：上游能服务该 SHA（直连 github.com 成功）"

# ---- ③ 被测面：按真实客户端形态（Basic 凭据）向 git-cdn 按 SHA 取 -----------
AUTH_B64=$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
    timeout 180 git -C "$WD/target" init -q
start=$(date +%s)
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 \
    timeout 180 git -C "$WD/target" \
    -c http.extraheader="Authorization: basic $AUTH_B64" \
    -c http.followRedirects=initial \
    fetch --no-tags --depth=1 "$GIT_CDN_BASE$REPO_SLUG.git" "+$probe_sha:refs/probe" \
    >"$results/target.log" 2>&1
rc=$?
sec=$(( $(date +%s) - start ))

if [ "$rc" -eq 0 ]; then
    log "③ 经 git-cdn 按 SHA 取成功（${sec}s）——git-cdn 能回源未同步对象（缺陷已修复）"
    exit 0
fi

if grep -qE 'error: 401|Authentication failed' "$results/target.log"; then
    log "⚠️ git-cdn 返回 401（token 不被上游接受）——复现条件不成立，记 SKIP"
    tail -3 "$results/target.log" | sed 's/^/    /'
    exit 2
fi

log "③ 经 git-cdn 按 SHA 取失败（rc=$rc，${sec}s）——缺陷复现"
log "   预期健康行为：成功（与②对照组同对象）；实际："
tail -5 "$results/target.log" | sed 's/^/    /'
log "   机理：fetch_sha/update 回源 URL 被 generate_url 双拼 token（见文件头），gh-proxy 403 → not our ref"
exit 1
