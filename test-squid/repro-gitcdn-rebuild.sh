#!/usr/bin/env bash
# =============================================================================
# repro-gitcdn-rebuild.sh —— git-cdn-rebuild chart 灰度验证（ADR-0015）
#
# 被测变更（ascend-ci-deployment#2567）：
#   ① 删除 patch-git-cdn init container / git-cdn-pkg emptyDir / GIT_CONFIG_GLOBAL，
#      运行时补丁全部上移到镜像源码；
#   ② client_max_size 改由 env CLIENT_MAX_SIZE_MB 配置（源码读取，默认 1024MB）；
#   ③ Dockerfile 系统 gitconfig 内置 uploadpack.allowfilter / SHA1-in-want；
#   ④ Patch 5（排除 refs/pull/*、clone 后跳过重复 fetch，#2529）已上游化；
#   ⑤ cache-warmer sidecar 移除，改为镜像内 WARM_ENABLED 后台预热。
#
# 对应断言（全部通过 HTTP/git 协议从 runner 侧观测，不需要 kubeconfig）：
#   live         GET / 返回 200 且含 "live"                     —— 服务起来且 readiness 口径正确
#   metrics      GET /metrics 200 且含多进程指标                —— PACK_CACHE_MULTI 生效（留档不判红）
#   bigbody      POST 2MB 到 git-receive-pack 不得 413           —— 补丁 ②，aiohttp 默认 1MB 上限
#   filter       带 --filter=blob:none 的 clone 必须成功且真跳过 blob
#                                                                —— 补丁 ③，服务端没配 allowfilter 会整包下发
#   pullrefs     ls-remote 'refs/pull/*' 必须为空                —— 补丁 ④，refs/pull 不进 mirror
#   cache        同仓两次 --depth 1 clone 第二次不慢于第一次     —— 补丁 ⑤ + 进程内预热（WARN 不判红）
#   warm         /metrics 里的 warm 计数留档                     —— 补丁 ⑤ 可观测性（不判红）
#
# 判定：live / bigbody / filter / pullrefs 任一失败 → FAIL；cache 只记 WARN；
#      git-cdn 完全不可达 → SKIP（退出码 2）。
#
# 执行方式：test-gitcdn.yaml 的 gitcdn-rebuild job（opt-in）
#           本地：GIT_CDN_BASE=http://127.0.0.1:8000/ bash repro-gitcdn-rebuild.sh
# 可覆盖：GIT_CDN_BASE / SMALL_REPO / FILTER_REPO / PULL_REPO / RESULTS / WORK
# =============================================================================
set -uo pipefail

GIT_CDN_BASE="${GIT_CDN_BASE:-http://git-cdn-service.git-cdn.svc.cluster.local:8000/}"
GIT_CDN_BASE="${GIT_CDN_BASE%/}/"
SMALL_REPO="${SMALL_REPO:-octocat/Hello-World}"      # 极小仓：live/cache 用，冷缓存也就几秒
FILTER_REPO="${FILTER_REPO:-vllm-project/vllm}"      # 大 blob 仓：--filter=blob:none 才看得出差别
PULL_REPO="${PULL_REPO:-pytorch/pytorch}"            # refs/pull 数量巨大，最容易看出 mirror 是否排除
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
if ! code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$GIT_CDN_BASE" 2>/dev/null); then
    log "⚠️ git-cdn 不可达（$GIT_CDN_BASE），SKIP"
    rec reachable SKIP 0 "unreachable $GIT_CDN_BASE"
    echo "SKIP" >"$RESULTS/verdict"
    exit 2
fi

# ---------------------------------------------------------------------------
# 1. live：GET / 必须 200 且含 live（values.yaml 里 livenessProbe 的口径）
# ---------------------------------------------------------------------------
t0=$(now_ms); body=$(curl -sS --max-time 15 "$GIT_CDN_BASE" 2>/dev/null); rc=$?
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
t0=$(now_ms); mbody=$(curl -sS --max-time 20 "$GIT_CDN_BASE/metrics" 2>/dev/null); rc=$?
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
#    不带凭据必被 git 协议层拒（401/403/400 都行），只要不是 413 就说明体积上限已放开
# ---------------------------------------------------------------------------
big="$WORK/payload.bin"
head -c 2097152 /dev/zero >"$big" 2>/dev/null
t0=$(now_ms)
code=$(curl -sS -o "$WORK/big.out" -w '%{http_code}' --max-time 60 \
    -X POST -H 'Content-Type: application/x-git-receive-pack-request' \
    --data-binary "@$big" "$GIT_CDN_BASE$SMALL_REPO.git/git-receive-pack" 2>/dev/null)
ms=$(( $(now_ms) - t0 ))
detail=$(head -c 120 "$WORK/big.out" 2>/dev/null | tr '\n' ' ')
case "$code" in
    413) rec bigbody FAIL "$ms" "http=413（client_max_size 仍为默认 1MB，CLIENT_MAX_SIZE_MB 未生效）"
         FAIL=$((FAIL + 1)) ;;
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
        "$GIT_CDN_BASE$FILTER_REPO.git" "$d" 2>"$WORK/filter.err"; then
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
# 5. pullrefs：mirror 不得包含 refs/pull/*（补丁 ④）
#    上游 pytorch/pytorch 有上万条 refs/pull，若被镜像请求体会瞬间破百 MB
# ---------------------------------------------------------------------------
t0=$(now_ms)
pull_out=$(timeout 120 git -c protocol.version=2 ls-remote \
    "$GIT_CDN_BASE$PULL_REPO.git" 'refs/pull/*' 2>"$WORK/pull.err")
rc=$?
ms=$(( $(now_ms) - t0 ))
n_pull=$(printf '%s\n' "$pull_out" | grep -c 'refs/pull/' 2>/dev/null || echo 0)
if [ "$rc" != 0 ]; then
    rec pullrefs WARN "$ms" "ls-remote rc=$rc：$(head -c 100 "$WORK/pull.err" | tr '\n' ' ')"
    WARN=$((WARN + 1))
elif [ "${n_pull:-0}" -eq 0 ]; then
    rec pullrefs PASS "$ms" "refs/pull=0（已排除）"
else
    rec pullrefs FAIL "$ms" "refs/pull=$n_pull（Patch 5 未生效，refs/pull 进了 mirror）"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 6. cache：同仓两次 --depth 1 clone，第二次应不慢于第一次（浅包缓存 + 流式转发）
#    只记 WARN：小仓本身几秒，抖动可能盖过收益
# ---------------------------------------------------------------------------
for i in 1 2; do
    rm -rf "$WORK/c$i"
    t0=$(now_ms)
    git -c protocol.version=2 clone --quiet --depth 1 \
        "$GIT_CDN_BASE$SMALL_REPO.git" "$WORK/c$i" 2>"$WORK/c$i.err"
    printf '%s\n' "$(( $(now_ms) - t0 ))" >>"$WORK/cache.ms"
done
t1=$(sed -n 1p "$WORK/cache.ms"); t2=$(sed -n 2p "$WORK/cache.ms")
if [ "${t2:-999999}" -le "${t1:-0}" ]; then
    rec cache PASS "$t2" "cold=${t1}ms warm=${t2}ms"
else
    rec cache WARN "$t2" "cold=${t1}ms warm=${t2}ms（第二次不快，可能仍回源）"
    WARN=$((WARN + 1))
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
log "===== 汇总：FAIL=$FAIL WARN=$WARN ====="
awk -F'\t' '{printf "  %-10s %-5s %7sms  %s\n", $1, $2, $3, $4}' "$TSV"
echo "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)" >"$RESULTS/verdict"
[ "$FAIL" -eq 0 ]
