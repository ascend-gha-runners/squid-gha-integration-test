#!/usr/bin/env bash
# =============================================================================
# pressure-gitcdn-clone.sh —— git-cdn 并发 clone 压测（8x/16x/32x/64x/128x/256x）
#
# 目的：回答「git-cdn 在 N 个并发 clone 下是否仍全部成功、耗时如何」。只压
# 缓存服务本体：显式打 $GIT_CDN_BASE，不经 squid、不依赖 runner 的 insteadOf。
#
# 仓库清单来源：
#   ① 仓库自身：opensourceways/ascend-ci-deployment#2048 里跑在本套 runner 上的
#      构建仓（vllm-ascend / triton-ascend / sglang / verl / pytorch ...）；
#   ② 仓库的依赖仓：这些仓库 CI 会 clone/submodule 的依赖
#      （vllm、triton、catlass、pto-isa、AscendNPU-IR）。
#   条目写 `owner/repo` 走 GitHub 上游（$GIT_CDN_BASE）；
#   写 `gitcode:owner/repo` 走 gitcode 上游（$GIT_CDN_GITCODE_BASE）。
#
# 流程：
#   ① 前置：$GIT_CDN_BASE 可达（不可达 = 本集群没部署 git-cdn → SKIP，退出码 2）
#   ② 预热 + 量体积：每个仓库 --depth 1 --single-branch clone 一次，记录耗时/体积
#      后删除——同时把对象灌进 git-cdn 缓存，压测量到的才是缓存命中吞吐
#   ③ 分级压测：并发度 N 同时发起 N 个 clone，仓库按体积预算轮询选择
#      （大仓库只出现在低并发，高层级自动只用小仓库，避免 256×大仓库打爆磁盘）
#   ④ 判定：任一级出现 clone 失败 → FAIL；全部成功 → PASS
#
# 可覆盖：
#   GIT_CDN_BASE           GitHub 上游 git-cdn 基址（默认 gy-006 的 svc 域名）
#   GIT_CDN_GITCODE_BASE   gitcode 上游 git-cdn 基址（默认 git-cdn-gitcode 命名空间）
#   REPOS                  仓库清单（空格/换行分隔，支持 gitcode: 前缀）
#   LADDER                 并发阶梯（默认 "8 16 32 64 128 256"）
#   CLONE_TIMEOUT          单个 clone 超时秒（默认 300）
#   DISK_MIN_MB            剩余磁盘下限 MB（低于此值跳过后续层级，默认 5120）
#   RESULTS / WORK         结果目录 / 临时 clone 目录
#
# 退出码：0=PASS；1=FAIL（有 clone 失败）；2=SKIP（git-cdn 不可达/无可用仓库）
# =============================================================================
set -uo pipefail

GIT_CDN_BASE="${GIT_CDN_BASE:-http://git-cdn-service.git-cdn.svc.cluster.local:8000/}"
GIT_CDN_GITCODE_BASE="${GIT_CDN_GITCODE_BASE:-http://git-cdn-service.git-cdn-gitcode.svc.cluster.local:8000/}"
LADDER="${LADDER:-8 16 32 64 128 256}"
CLONE_TIMEOUT="${CLONE_TIMEOUT:-300}"
DISK_MIN_MB="${DISK_MIN_MB:-5120}"
RESULTS="${RESULTS:-${RESULTS_DIR:-/tmp/test-squid-results}/gitcdn-pressure}"
WORK="${WORK:-/tmp/gitcdn-pressure}"

# 默认仓库清单：
#   ① 仓库自身（ascend-ci-deployment#2048 里跑在本套 runner 上的构建仓）
#   ② 仓库的依赖仓（这些仓库 CI 会 clone / submodule 的对象）
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
# ---- 依赖仓：vllm-ascend / triton-ascend / sgl-kernel-npu 的 CI 依赖 ----
vllm-project/vllm
triton-lang/triton
gitcode:cann/catlass
gitcode:cann/pto-isa
gitcode:Ascend/AscendNPU-IR
"
REPOS="${REPOS:-$DEFAULT_REPOS}"
REPOS="${REPOS//,/ }"
# 去掉清单里的注释行/行尾注释，并归一化空白分隔
REPOS=$(printf '%s\n' "$REPOS" | sed 's/#.*//' | tr -s '[:space:]' ' ')

export GIT_TERMINAL_PROMPT=0
mkdir -p "$RESULTS"
rm -rf "$WORK"; mkdir -p "$WORK"

TSV="$RESULTS/timings.tsv"      # level wall ok fail p50 p95 max repos rc
DETAIL="$RESULTS/clones.tsv"    # level idx repo rc ms mb reason
: > "$TSV"; : > "$DETAIL"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
now_ms() { date +%s%3N; }
free_mb() { df -Pm "$WORK" | awk 'NR==2{print $4}'; }

FAILED=0
CLONED=0

# 单个 clone：rc / 耗时ms / 体积MB 写入 <res>，stderr 落 <res 去掉 .res>.err
clone_one() {  # clone_one <url> <dir> <res>
    local url="$1" dir="$2" res="$3" err="${3%.res}.err" s e rc
    s=$(now_ms)
    timeout "$CLONE_TIMEOUT" git clone --quiet --depth 1 --single-branch "$url" "$dir" 2>"$err"
    rc=$?
    e=$(now_ms)
    printf '%s\t%s\t%s\n' "$rc" "$((e-s))" "$(du -sm "$dir" 2>/dev/null | cut -f1)" >"$res"
}

classify() {  # classify <errfile> <rc> —— 失败归类（压测要能区分缺陷类型）
    local err="$1" rc="$2"
    grep -qi 'not our ref' "$err" 2>/dev/null && { echo "not-our-ref"; return; }
    grep -qiE 'timed out|timeout' "$err" 2>/dev/null && { echo "timeout"; return; }
    grep -qiE 'early EOF|RPC failed|unexpected disconnect|connection reset' "$err" 2>/dev/null && { echo "transport"; return; }
    grep -qiE 'Could not resolve host|unable to access|Connection refused' "$err" 2>/dev/null && { echo "network"; return; }
    echo "rc=$rc"
}

repo_url() {  # repo_url <owner/repo | gitcode:owner/repo> → 完整 clone URL
    local slug="$1"
    case "$slug" in
        gitcode:*) echo "${GIT_CDN_GITCODE_BASE}${slug#gitcode:}.git" ;;
        *)         echo "${GIT_CDN_BASE}${slug}.git" ;;
    esac
}

# ---------------------------------------------------------------------------
# 前置：git-cdn 可达（github 上游必须具备；gitcode 上游缺失只降级依赖仓）
# ---------------------------------------------------------------------------
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$GIT_CDN_BASE" 2>/dev/null) || code="000"
if [ "$code" != "200" ]; then
    log "⚠️ git-cdn 不可达（$GIT_CDN_BASE GET=$code）——本集群无 git-cdn 实例，记 SKIP"
    printf 'pressure-gitcdn\t0\tSKIP\n' >>"$TSV"
    exit 2
fi
gcode=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$GIT_CDN_GITCODE_BASE" 2>/dev/null) || gcode="000"
GITCODE_OK=0; [ "$gcode" = "200" ] && GITCODE_OK=1
[ "$GITCODE_OK" = 0 ] && log "⚠️ git-cdn(gitcode) 不可达（$GIT_CDN_GITCODE_BASE GET=$gcode）——清单里的 gitcode: 依赖仓将跳过"
started=$(date '+%Y-%m-%dT%H:%M:%S%z')
log "git-cdn(github)=$GIT_CDN_BASE 阶梯=$(echo $LADDER) 磁盘剩余=$(free_mb)MB 开始=$started"

# ---------------------------------------------------------------------------
# ② 预热 + 量体积（同时把对象灌进缓存）
# ---------------------------------------------------------------------------
declare -a OK_REPOS=() OK_URL=() OK_SIZE=() OK_MSEC=()
mkdir -p "$WORK/warm"
i=0
for slug in $REPOS; do
    i=$((i+1))
    if [ "$(free_mb)" -lt "$DISK_MIN_MB" ]; then
        log "⚠️ 剩余磁盘 $(free_mb)MB 低于下限 ${DISK_MIN_MB}MB——停止预热与压测"
        printf 'warm\t%s\t%s\t-\t-\t-\tdisk-low\n' "$i" "$slug" >>"$DETAIL"
        break
    fi
    case "$slug" in
        gitcode:*)
            if [ "$GITCODE_OK" = 0 ]; then
                log "预热 $slug —— gitcode 上游不可达，跳过"
                printf 'warm\t%s\t%s\t-\t-\t-\tgitcode-base-unreachable\n' "$i" "$slug" >>"$DETAIL"
                continue
            fi ;;
    esac
    url=$(repo_url "$slug")
    log "预热 $slug ($url)"
    clone_one "$url" "$WORK/warm/$i" "$WORK/warm/$i.res"
    rc=""; ms=""; mb=""
    [ -s "$WORK/warm/$i.res" ] && IFS=$'\t' read -r rc ms mb <"$WORK/warm/$i.res"
    if [ "${rc:-1}" = "0" ] && [ "${mb:-0}" -gt 0 ]; then
        log "  ✅ ${ms}ms ${mb}MB"
        OK_REPOS+=("$slug"); OK_URL+=("$url"); OK_SIZE+=("$mb"); OK_MSEC+=("$ms")
        printf 'warm\t%s\t%s\t0\t%s\t%s\t-\n' "$i" "$slug" "$ms" "$mb" >>"$DETAIL"
    else
        reason=$(classify "$WORK/warm/$i.err" "${rc:-1}")
        log "  ⚠️ 预热失败（$reason）——该仓库不参与压测"
        printf 'warm\t%s\t%s\t%s\t%s\t-\t%s\n' "$i" "$slug" "${rc:-1}" "${ms:-0}" "$reason" >>"$DETAIL"
    fi
    rm -rf "$WORK/warm/$i" "$WORK/warm/$i.res" "$WORK/warm/$i.err"
done

if [ ${#OK_REPOS[@]} -eq 0 ]; then
    log "⚠️ 没有任何仓库预热成功——无法压测，记 SKIP"
    printf 'pressure-gitcdn\t0\tSKIP\n' >>"$TSV"
    exit 2
fi
log "预热完成：${#OK_REPOS[@]}/${i} 个仓库可用"

# ---------------------------------------------------------------------------
# ③ 分级压测
# ---------------------------------------------------------------------------
for N in $LADDER; do
    free=$(free_mb)
    budget=$(( (free - DISK_MIN_MB) * 8 / 10 / N ))
    if [ "$budget" -le 0 ]; then
        log "并发 $N：剩余磁盘 ${free}MB 不足（下限 ${DISK_MIN_MB}MB）——SKIP 该级"
        printf '%s\t0\t0\t0\t-\t-\t-\t-\t1\n' "$N" >>"$TSV"
        continue
    fi

    # 体积预算内的仓库参与本级（大仓库自动只出现在低并发）
    declare -a use=()
    for idx in "${!OK_REPOS[@]}"; do
        [ "${OK_SIZE[$idx]}" -le "$budget" ] && use+=("$idx")
    done
    if [ ${#use[@]} -eq 0 ]; then
        log "并发 $N：没有仓库体积 ≤ 预算 ${budget}MB——SKIP 该级"
        printf '%s\t0\t0\t0\t-\t-\t-\t-\t1\n' "$N" >>"$TSV"
        continue
    fi

    ld="$WORK/level-$N"; mkdir -p "$ld"; : >"$ld/times.txt"
    log "并发 $N：启动 ${N} 个 clone（预算 ${budget}MB/仓，候选 ${#use[@]} 仓）"
    wall_s=$(now_ms)
    for j in $(seq 1 "$N"); do
        idx=${use[$(( (j-1) % ${#use[@]} ))]}
        slug=${OK_REPOS[$idx]}
        printf '%s\n' "$slug" >"$ld/$j.slug"
        ( clone_one "${OK_URL[$idx]}" "$ld/$j" "$ld/$j.res"; rm -rf "$ld/$j" ) &
    done
    wait
    wall_ms=$(( $(now_ms) - wall_s ))

    ok=0; bad=0; total_mb=0
    for j in $(seq 1 "$N"); do
        slug=$(cat "$ld/$j.slug" 2>/dev/null || echo "?")
        rc=""; ms=""; mb=""
        [ -s "$ld/$j.res" ] && IFS=$'\t' read -r rc ms mb <"$ld/$j.res"
        if [ "${rc:-1}" = "0" ] && [ "${mb:-0}" -gt 0 ]; then
            ok=$((ok+1)); CLONED=$((CLONED+1)); total_mb=$((total_mb+mb))
            echo "${ms:-0}" >>"$ld/times.txt"
            printf '%s\t%s\t%s\t0\t%s\t%s\t-\n' "$N" "$j" "$slug" "${ms:-0}" "$mb" >>"$DETAIL"
        else
            bad=$((bad+1)); FAILED=$((FAILED+1))
            reason=$(classify "$ld/$j.err" "${rc:-1}")
            printf '%s\t%s\t%s\t%s\t%s\t-\t%s\n' "$N" "$j" "$slug" "${rc:-1}" "${ms:-0}" "$reason" >>"$DETAIL"
            log "  ❌ [$N/$j] $slug 失败：$reason"
        fi
    done

    if [ -s "$ld/times.txt" ]; then
        sort -n "$ld/times.txt" >"$ld/times.sorted"
        read -r p50 p95 pmax < <(awk '
            {a[NR]=$1} END{n=NR; if(n==0){print "- - -"; exit}
             printf "%.2f %.2f %.2f\n", a[int((n-1)*0.50)+1]/1000, a[int((n-1)*0.95)+1]/1000, a[n]/1000}' "$ld/times.sorted")
    else
        p50="-"; p95="-"; pmax="-"
    fi
    rc=0; [ "$bad" -gt 0 ] && rc=1
    log "并发 $N：ok=$ok fail=$bad wall=$((wall_ms/1000))s p50=${p50}s p95=${p95}s max=${pmax}s 体积=${total_mb}MB"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$N" "$((wall_ms/1000))" "$ok" "$bad" "$p50" "$p95" "$pmax" "${#use[@]}" "$rc" >>"$TSV"
    rm -rf "$ld"
done

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
rm -rf "$WORK"
log "===== git-cdn 压测汇总：成功 clone=$CLONED 失败=$FAILED ====="
awk -F'\t' '{printf "  并发 %s\twall=%ss\tok=%s\tfail=%s\tp50=%ss\tp95=%ss\tmax=%ss\trc=%s\n",
    $1, $2, $3, $4, $5, $6, $7, $9}' "$TSV"
if [ "$FAILED" -gt 0 ]; then
    log "❌ 有 $FAILED 个 clone 失败（明细见 clones.tsv）"
    awk -F'\t' '$4!="0" && $1!="warm"{printf "   %s/%s %s rc=%s %s\n", $1, $2, $3, $4, $7}' "$DETAIL" | head -20
    exit 1
fi
log "✅ 全部并发层级 clone 成功"
exit 0
