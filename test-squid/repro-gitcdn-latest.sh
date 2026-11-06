#!/usr/bin/env bash
# =============================================================================
# repro-gitcdn-latest.sh —— git-cdn「最新 commit 可服务性」滚动校验
#
# 每轮对清单内每个仓库做三件事（模拟正常使用 github.com 的姿势）：
#   ① 先取上游最新 commit 作为真值（GitHub API / gitcode ls-remote）
#   ② 再经 git-cdn 取默认分支 HEAD：fetch --depth 1 + checkout
#   ③ 若 cdn 的 HEAD 落后于真值，再按真值 SHA 经 git-cdn 回源取一次
#      —— 成功 = 回源健康；`not our ref` = 2026-11-04 事故形态（判红）
#
# 判定：每个仓库都必须能拿到「上游最新 commit」（HEAD 命中，或按 SHA 回源成功），
#      且 checkout 成功；任一仓库失败 → FAIL。真值取不到（API 异常）记 WARN。
#
# 仓库清单同压测：ascend-ci-deployment#2048 的构建仓 + 其依赖仓
# （github 走 $GIT_CDN_BASE；gitcode: 前缀走 $GIT_CDN_GITCODE_BASE）。
#
# 执行方式：test-gitcdn.yaml 的 gitcdn-latest job 每 30 分钟调度一次；
#           也可手动：REPOS="vllm-project/vllm-ascend" bash repro-gitcdn-latest.sh
#
# 可覆盖：GIT_CDN_BASE / GIT_CDN_GITCODE_BASE / REPOS / CLONE_TIMEOUT /
#         RESULTS / WORK / GH_TOKEN
#
# 退出码：0=PASS；1=FAIL（有仓库取不到最新 commit）；2=SKIP（git-cdn 不可达）
# =============================================================================
set -uo pipefail

GIT_CDN_BASE="${GIT_CDN_BASE:-http://git-cdn-service.git-cdn.svc.cluster.local:8000/}"
GIT_CDN_GITCODE_BASE="${GIT_CDN_GITCODE_BASE:-http://git-cdn-service.git-cdn-gitcode.svc.cluster.local:8000/}"
CLONE_TIMEOUT="${CLONE_TIMEOUT:-300}"
RESULTS="${RESULTS:-${RESULTS_DIR:-/tmp/test-squid-results}/gitcdn-latest}"
WORK="${WORK:-/tmp/gitcdn-latest}"

DEFAULT_REPOS="
vllm-project/vllm-ascend
vllm-ascend/vllm-ascend-recipes
sgl-project/sglang
sgl-project/sglang-omni
sgl-project/sgl-kernel-npu
triton-lang/triton-ascend
verl-project/verl
verl-project/verl-omni
verl-project/verl-SpeCo
verl-project/uni-agent
areal-project/AReaL
alibaba/ROLL
hiyouga/LlamaFactory
modelscope/ms-swift
fla-org/flash-linear-attention
pt-ecosystem/flash-linear-attention-dev
tile-ai/tilelang-mlir-ascend
Ascend/pytorch
Ascend/sglang
Ascend/cann-container-image
Ascend/AscendNPU-IR
vllm-project/vllm
triton-lang/triton
gitcode:cann/catlass
gitcode:cann/pto-isa
gitcode:Ascend/AscendNPU-IR
"
REPOS="${REPOS:-$DEFAULT_REPOS}"
REPOS="${REPOS//,/ }"
REPOS=$(printf '%s\n' "$REPOS" | sed 's/#.*//' | tr -s '[:space:]' ' ')

export GIT_TERMINAL_PROMPT=0
mkdir -p "$RESULTS"
rm -rf "$WORK"; mkdir -p "$WORK"

TSV="$RESULTS/latest.tsv"   # repo family truth cdn_head head verdict note ms
: >"$TSV"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
now_ms() { date +%s%3N; }

repo_url() {  # repo_url <owner/repo | gitcode:owner/repo> → 完整 clone URL
    local slug="$1"
    case "$slug" in
        gitcode:*) echo "${GIT_CDN_GITCODE_BASE}${slug#gitcode:}.git" ;;
        *)         echo "${GIT_CDN_BASE}${slug}.git" ;;
    esac
}

# 上游最新 commit（真值）：GitHub 走 API（有 token 不受 60/h 限制），gitcode 走 ls-remote
truth_sha() {  # truth_sha <slug>
    local slug="$1" body auth=()
    case "$slug" in
        gitcode:*)
            git ls-remote "https://gitcode.com/${slug#gitcode:}" HEAD 2>/dev/null | awk '{print $1; exit}' ;;
        *)
            # 空 token 会触发 401，必须按有无 token 分支
            [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GH_TOKEN}")
            body=$(curl -sS --max-time 30 "${auth[@]}" \
                -H 'Accept: application/vnd.github+json' \
                "https://api.github.com/repos/${slug}/commits?per_page=1" 2>/dev/null)
            printf '%s' "$body" | jq -r 'if type=="array" and length>0 then .[0].sha else empty end' 2>/dev/null ;;
    esac
}

classify() {  # classify <errfile> <rc>
    local err="$1" rc="$2"
    grep -qi 'not our ref' "$err" 2>/dev/null && { echo "not-our-ref"; return; }
    grep -qiE 'timed out|timeout' "$err" 2>/dev/null && { echo "timeout"; return; }
    grep -qiE 'early EOF|RPC failed|unexpected disconnect|connection reset' "$err" 2>/dev/null && { echo "transport"; return; }
    grep -qiE 'Could not resolve host|unable to access|Connection refused' "$err" 2>/dev/null && { echo "network"; return; }
    echo "rc=$rc"
}

# ---------------------------------------------------------------------------
# 前置：git-cdn(github) 可达，否则本集群没有 git-cdn，记 SKIP
# ---------------------------------------------------------------------------
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$GIT_CDN_BASE" 2>/dev/null) || code="000"
if [ "$code" != "200" ]; then
    log "⚠️ git-cdn 不可达（$GIT_CDN_BASE GET=$code）——记 SKIP"
    printf 'gitcdn-latest\t-\t-\t-\t-\tSKIP\n' >>"$TSV"
    exit 2
fi
gcode=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$GIT_CDN_GITCODE_BASE" 2>/dev/null) || gcode="000"
GITCODE_OK=0; [ "$gcode" = "200" ] && GITCODE_OK=1
[ "$GITCODE_OK" = 0 ] && log "⚠️ git-cdn(gitcode) 不可达（GET=$gcode）——gitcode: 仓库将跳过"
log "开始滚动校验：$(echo $REPOS | wc -w) 个仓库，cdn=$GIT_CDN_BASE"

PASS=0; FAIL=0; WARN=0; SKIP=0
i=0
for slug in $REPOS; do
    i=$((i+1))
    family=github; case "$slug" in gitcode:*) family=gitcode ;; esac
    if [ "$family" = gitcode ] && [ "$GITCODE_OK" = 0 ]; then
        log "$slug —— gitcode 上游不可达，跳过"
        printf '%s\t%s\t-\t-\t-\tSKIP\tgitcode-base-unreachable\t0\n' "$slug" "$family" >>"$TSV"
        SKIP=$((SKIP+1)); continue
    fi

    url=$(repo_url "$slug")
    t0=$(now_ms)
    truth=$(truth_sha "$slug")
    if [ -z "$truth" ] || [ "$truth" = "null" ]; then
        log "$slug —— ⚠️ 取不到上游最新 commit（API/ls-remote 异常），留档"
        printf '%s\t%s\t-\t-\t-\tWARN\ttruth-unavailable\t%s\n' "$slug" "$family" "$(( $(now_ms) - t0 ))" >>"$TSV"
        WARN=$((WARN+1)); continue
    fi

    d="$WORK/$i"; mkdir -p "$d"; git -C "$d" init -q
    # ② 经 git-cdn 取默认分支 HEAD（正常 fetch 姿势）
    timeout "$CLONE_TIMEOUT" git -C "$d" fetch -q --depth 1 "$url" HEAD 2>"$d/fetch.err"; rc=$?
    if [ "$rc" != 0 ]; then
        reason=$(classify "$d/fetch.err" "$rc")
        log "$slug —— ❌ fetch 失败：$reason"
        printf '%s\t%s\t%s\t-\t-\tFAIL\t%s\t%s\n' "$slug" "$family" "$truth" "$reason" "$(( $(now_ms) - t0 ))" >>"$TSV"
        FAIL=$((FAIL+1)); rm -rf "$d"; continue
    fi
    cdn_head=$(git -C "$d" rev-parse FETCH_HEAD 2>/dev/null)
    note="-"; verdict=PASS

    if [ "$cdn_head" != "$truth" ]; then
        # ③ refs 落后：按真值 SHA 回源（CI 的 checkout 就按 SHA 取，事故形态在此暴露）
        timeout "$CLONE_TIMEOUT" git -C "$d" fetch -q --depth 1 "$url" "$truth" 2>"$d/sha.err"; rc=$?
        if [ "$rc" = 0 ]; then
            note="refs-lag(sha-ok)"
        else
            reason=$(classify "$d/sha.err" "$rc")
            note="refs-lag(sha-$reason)"
            verdict=FAIL
        fi
    fi

    # 真值 commit 必须能 checkout（对象完整）
    if [ "$verdict" = PASS ]; then
        cur=$(git -C "$d" rev-parse FETCH_HEAD 2>/dev/null)
        if ! git -C "$d" checkout -q --detach "$cur" 2>"$d/co.err"; then
            note="checkout-$(classify "$d/co.err" 1)"; verdict=FAIL
        elif ! git -C "$d" ls-tree --name-only "$cur" >/dev/null 2>&1; then
            note="tree-missing"; verdict=FAIL
        fi
    fi

    ms=$(( $(now_ms) - t0 ))
    case "$verdict" in
        PASS) PASS=$((PASS+1)); log "$slug —— ✅ 最新 commit ${truth:0:9}（$note，${ms}ms）" ;;
        *)    FAIL=$((FAIL+1)); log "$slug —— ❌ $note（truth=${truth:0:9} cdn=${cdn_head:0:9}）" ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$family" "$truth" "$cdn_head" "${cur:-$cdn_head}" "$verdict" "$note" "$ms" >>"$TSV"
    rm -rf "$d"
done

rm -rf "$WORK"
log "===== 滚动校验汇总：PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP ====="
awk -F'\t' '$6!="PASS"{printf "  %s\t%s\t%s\t%s\n", $1, $6, $7, $3}' "$TSV" | head -30
[ "$FAIL" -gt 0 ] && { log "❌ 有 $FAIL 个仓库取不到最新 commit"; exit 1; }
log "✅ 全部仓库均可经 git-cdn 取到上游最新 commit"
exit 0
