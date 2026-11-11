#!/usr/bin/env bash
# =============================================================================
# repro-gitcdn-rebuild.sh —— git-cdn-rebuild chart 灰度验证（ADR-0015）
#
# 被测变更（ascend-ci-deployment#2567）：
#   ① 删除 patch-git-cdn init container / git-cdn-pkg emptyDir / GIT_CONFIG_GLOBAL，
#      运行时补丁全部上移到镜像源码；
#   ② client_max_size 改由 env CLIENT_MAX_SIZE_MB 配置（源码读取，默认 1024MB）；
#   ③ Dockerfile 系统 gitconfig 内置 uploadpack.allowfilter / SHA1-in-want；
#   ④ cache-warmer sidecar 移除，改为镜像内 WARM_ENABLED 后台预热；
#   ⑤ Patch 5（排除 refs/pull/*、clone 后跳过重复 fetch，#2529）已上游化。
#
# 对应断言（全部通过 HTTP/git 协议从 runner 侧观测，不需要 kubeconfig）：
#   live         GET / 返回 200 且含 "live"                     —— 服务起来且 readiness 口径正确
#   metrics      GET /metrics 200 且含多进程指标                —— PACK_CACHE_MULTI 生效（WARN 不判红）
#   bigbody      POST 2MB 请求体不得 413                        —— 补丁 ②，aiohttp 默认上限 1MB
#   filter       带 --filter=blob:none 的 clone 必须成功且真跳过 blob
#                                                                —— 补丁 ③，服务端没配 allowfilter 会整包下发
#   pullrefs     ls-remote 'refs/pull/*' 只作留档                —— 见下方「口径说明」
#   cache        同仓两次 --depth 1 clone 第二次不慢于第一次     —— 补丁 ②③ + 预热（WARN 不判红）
#   warm         /metrics 里的 warm / pack_cache 指标留档        —— 预热可观测性（不判红）
#
# 口径说明（两处必须 git UA）：
#   * git_cdn.redirect_browsers()：User-Agent 不含 "git"/"aiohttp" 时一律 308 跳
#     上游。用 curl 裸访问会被跳走（看到 308 而不是真实处理结果），所以所有 curl
#     都要带 `-A git/2.55.0`。
#   * pullrefs 不能用 ls-remote 判定：mirror 是代理，refs/pull 由上游广告透传，
#     即使 Patch 5 生效也会列出来。真正的判据是 mirror 本地是否存在 refs/pull，
#     只能在 pod 内 `git --git-dir=<WORKDIR>/git/<repo>.git for-each-ref refs/pull`
#     取证，故本用例只留档不判红（2026-11-11 集群内取证：pytorch/pytorch = 0 条）。
#
# 判定：live / bigbody / filter 任一失败 → FAIL；metrics / cache 记 WARN；
#      git-cdn 完全不可达 → SKIP（退出码 2）。
#
# 执行方式：test-gitcdn.yaml 的 gitcdn-rebuild job（opt-in）
#           本地：GIT_CDN_BASE=http://127.0.0.1:8000/ bash repro-gitcdn-rebuild.sh
# 可覆盖：GIT_CDN_BASE / SMALL_REPO / CACHE_REPO / FILTER_REPO / PULL_REPO
#         / RESULTS / WORK
# =============================================================================
set -uo pipefail

GIT_CDN_BASE="${GIT_CDN_BASE:-http://git-cdn-service.git-cdn.svc.cluster.local:8000/}"
BASE="${GIT_CDN_BASE%/}"                             # 去掉尾部斜杠，避免拼出 //
UA="git/2.55.0"                                      # 必须像 git，否则被 308 跳上游
SMALL_REPO="${SMALL_REPO:-octocat/Hello-World}"      # 极小仓：bigbody 用
CACHE_REPO="${CACHE_REPO:-${GITHUB_REPOSITORY:-ascend-gha-runners/squid-gha-integration-test}}"
                                                     # 本仓库必然在 mirror 里，缓存对照才有意义
FILTER_REPO="${FILTER_REPO:-vllm-project/vllm}"      # 大 blob 仓：--filter=blob:none 才看得出差别
PULL_REPO="${PULL_REPO:-pytorch/pytorch}"            # refs/pull 数量巨大，留档用
RESULTS="${RESULTS:-${RESULTS_DIR:-/tmp/test-squid-results}/gitcdn-rebuild}"
WORK="${WORK:-/tmp/gitcdn-rebuild}"
mkdir -p "$RESULTS"
rm -rf "$WORK"; mkdir -p "$WORK"

TSV="$RESULTS/gitcdn-rebuild.tsv"      # case verdict ms detail
: >"$TSV"
FAIL=0; WARN=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }
now_ms() { date +%s%3N; }
rec() {  # rec <case> <verdict> <ms> <detail>
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$TSV"
}

# ---------------------------------------------------------------------------
# 0. 可达性：连不上就 SKIP（不判红，集群未开灰度时属正常）
# ---------------------------------------------------------------------------
if ! code=$(curl -sS -A "$UA" -o /dev/null -w '%{http_code}' --max-time 15 "$BASE/" 2>/dev/null); then
    log "⚠️ git-cdn 不可达（$BASE/），SKIP"
    rec reachable SKIP 0 "unreachable $BASE/"
    echo "SKIP" >"$RESULTS/verdict"
    exit 2
fi

# ---------------------------------------------------------------------------
# 1. live：GET / 必须 200 且含 live（values.yaml 里 livenessProbe 的口径）
# ---------------------------------------------------------------------------
t0=$(now_ms); body=$(curl -sS -A "$UA" --max-time 15 "$BASE/" 2>/dev/null); rc=$?
ms=$(( $(now_ms) - t0 ))
if [ "$rc" = 0 ] && printf '%s' "$body" | grep -qi 'live'; then
    rec live PASS "$ms" "http=$code,body=${body:0:20}"
else
    rec live FAIL "$ms" "rc=$rc,http=$code,body=${body:0:40}"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 2. metrics：/metrics 可达 + 有多进程收集器（PACK_CACHE_MULTI=true 时才有）
# ---------------------------------------------------------------------------
t0=$(now_ms); mbody=$(curl -sS -A "$UA" --max-time 20 "$BASE/metrics" 2>/dev/null); rc=$?
ms=$(( $(now_ms) - t0 ))
if [ "$rc" = 0 ] && printf '%s' "$mbody" | grep -q '^# HELP'; then
    if printf '%s' "$mbody" | grep -qi 'multiprocess'; then
        rec metrics PASS "$ms" "multiprocess collector found"
    else
        rec metrics WARN "$ms" "metrics ok, but no multiprocess collector"
        WARN=$((WARN + 1))
    fi
    printf '%s\n' "$mbody" | grep -iE 'warm|pack_cache|pack_cache_hit' | head -10 \
        >"$RESULTS/metrics-warm.txt" 2>/dev/null || true
    rec warm INFO 0 "lines=$(wc -l <"$RESULTS/metrics-warm.txt" 2>/dev/null || echo 0)"
else
    rec metrics WARN "$ms" "rc=$rc,/metrics 不可用"
    WARN=$((WARN + 1))
fi

# ---------------------------------------------------------------------------
# 3. bigbody：2MB 请求体不得被 aiohttp 默认 1MB 上限拦成 413（补丁 ②）
#    用 git-upload-pack：这条路由在 git-cdn 本地处理（receive-pack 会被跳上游或
#    需要鉴权，测不到 body 上限）。返回 200/"Wrong upload pack input" 都算通过——
#    说明服务端完整读了 2MB body；只有 413 才说明 CLIENT_MAX_SIZE_MB 未生效。
# ---------------------------------------------------------------------------
big="$WORK/payload.bin"
head -c 2097152 /dev/zero >"$big" 2>/dev/null
t0=$(now_ms)
code=$(curl -sS -A "$UA" -o "$WORK/big.out" -w '%{http_code}' --max-time 120 \
    -X POST -H 'Content-Type: application/x-git-upload-pack-request' \
    -H 'Git-Protocol: version=2' \
    --data-binary "@$big" "$BASE/$SMALL_REPO.git/git-upload-pack" 2>/dev/null)
ms=$(( $(now_ms) - t0 ))
detail=$(head -c 120 "$WORK/big.out" 2>/dev/null | tr '\n' ' ')
case "$code" in
    413) rec bigbody FAIL "$ms" "http=413（client_max_size 仍为默认 1MB，CLIENT_MAX_SIZE_MB 未生效）"
         FAIL=$((FAIL + 1)) ;;
    308) rec bigbody FAIL "$ms" "http=308（被 redirect_browsers 跳走，UA 未带 git）" ; FAIL=$((FAIL + 1)) ;;
    000|'') rec bigbody FAIL "$ms" "请求未完成（rc 非 0）" ; FAIL=$((FAIL + 1)) ;;
    *)   rec bigbody PASS "$ms" "http=$code,body=${detail:0:60}" ;;
esac

# ---------------------------------------------------------------------------
# 4. filter：--filter=blob:none 必须被服务端接受，且 blob 真的未下发（补丁 ③）
#    判据：clone 成功 且 `git rev-list --objects --missing=print` 出现 missing blob；
#    若服务端忽略 filter（allowfilter 未开），所有 blob 都会落地 → 无 missing 行。
# ---------------------------------------------------------------------------
d="$WORK/filter"
t0=$(now_ms)
if git -c protocol.version=2 clone --quiet --filter=blob:none --no-checkout \
        "$BASE/$FILTER_REPO.git" "$d" 2>"$WORK/filter.err"; then
    missing=$(git -C "$d" rev-list --objects --all --missing=print 2>/dev/null | grep -c '^?')
    ms=$(( $(now_ms) - t0 ))
    if [ "${missing:-0}" -gt 0 ]; then
        rec filter PASS "$ms" "missing_objects=$missing（服务端按 filter 裁剪）"
    else
        rec filter FAIL "$ms" "missing_objects=0（服务端未按 filter 裁剪，allowfilter 可能未生效）"
        FAIL=$((FAIL + 1))
    fi
else
    ms=$(( $(now_ms) - t0 ))
    rec filter FAIL "$ms" "clone 失败：$(head -c 120 "$WORK/filter.err" | tr '\n' ' ')"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 5. pullrefs：只留档。mirror 是代理，refs/pull 由上游广告透传，Patch 5 生效时
#    ls-remote 仍会列出；真判据只能在 pod 内查 mirror 本地 refs（见文件头说明）。
# ---------------------------------------------------------------------------
t0=$(now_ms)
pull_out=$(timeout 120 git -c protocol.version=2 ls-remote \
    "$BASE/$PULL_REPO.git" 'refs/pull/*' 2>"$WORK/pull.err")
rc=$?
ms=$(( $(now_ms) - t0 ))
n_pull=$(printf '%s\n' "$pull_out" | grep -c 'refs/pull/' 2>/dev/null || echo 0)
rec pullrefs INFO "$ms" "ls-remote refs/pull=$n_pull,rc=$rc（上游广告，非 mirror 内容）"

# ---------------------------------------------------------------------------
# 6. cache：同仓两次 --depth 1 clone，第二次应不慢于第一次（浅包缓存 + 流式转发）
#    只记 WARN：小仓本身几秒，抖动可能盖过收益
# ---------------------------------------------------------------------------
for i in 1 2; do
    rm -rf "$WORK/c$i"
    t0=$(now_ms)
    git -c protocol.version=2 clone --quiet --depth 1 \
        "$BASE/$CACHE_REPO.git" "$WORK/c$i" 2>"$WORK/c$i.err"
    printf '%s\n' "$(( $(now_ms) - t0 ))" >>"$WORK/cache.ms"
done
t1=$(sed -n 1p "$WORK/cache.ms"); t2=$(sed -n 2p "$WORK/cache.ms")
if [ "${t2:-999999}" -le "${t1:-0}" ]; then
    rec cache PASS "$t2" "cold=${t1}ms warm=${t2}ms（$CACHE_REPO）"
else
    rec cache WARN "$t2" "cold=${t1}ms warm=${t2}ms（第二次不快，可能仍回源；$CACHE_REPO）"
    WARN=$((WARN + 1))
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
log "===== 汇总：FAIL=$FAIL WARN=$WARN ====="
awk -F'\t' '{printf "  %-10s %-5s %7sms  %s\n", $1, $2, $3, $4}' "$TSV"
echo "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)" >"$RESULTS/verdict"
[ "$FAIL" -eq 0 ]
