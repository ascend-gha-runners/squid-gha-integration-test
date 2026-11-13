#!/usr/bin/env bash
# =============================================================================
# repro-submodule-jobs-bench.sh —— 第一层子模块：git 原生 --jobs 32 vs 手动 32 并发
#
# 目的：验证「git 的 --jobs 到底有没有把第一层扇出跑满」。
#   腿 A：git submodule update --init --depth 1 --jobs 32（不带 --recursive）
#   腿 B：git submodule init（串行写 .git/config）+ xargs -P 32 每个路径单独
#         git submodule update --init --depth 1 -- <path>
#
# 两条腿都：同一主仓、同一 git-cdn 基址、同一 insteadOf 重写、同一 --depth 1，
# 只改「谁负责扇出」。
#
# 判定：任一条腿残留未初始化子模块（'-' 前缀）、或两腿子模块数量不一致 → FAIL；
#       基址不可达 → SKIP（退出码 2）。
#
# 输出：$RESULTS/subjobs.tsv（leg/verdict/ms/detail）
#       $RESULTS/sub-times-manual.tsv（腿 B 逐个子模块耗时，供分布对照）
# =============================================================================
set -uo pipefail

GIT_CDN_BASE="${GIT_CDN_BASE:-http://git-cdn-service.git-cdn.svc.cluster.local:8000/}"
BASE="${GIT_CDN_BASE%/}"
REPO="${REPO:-pytorch/pytorch}"
JOBS="${JOBS:-32}"
WORK="${WORK:-/tmp/subjobs-bench}"
RESULTS="${RESULTS:-${RESULTS_DIR:-/tmp/test-squid-results}/subjobs}"
mkdir -p "$RESULTS"
rm -rf "$WORK"; mkdir -p "$WORK"

TSV="$RESULTS/subjobs.tsv"
MANUAL_TSV="$RESULTS/sub-times-manual.tsv"
: >"$TSV"; : >"$MANUAL_TSV"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
now_ms() { date +%s%3N; }
rec() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >>"$TSV"; }

# ---------------------------------------------------------------------------
# 0. 可达性（git 协议探测，三种基址都成立）
# ---------------------------------------------------------------------------
if ! git -c protocol.version=2 ls-remote --heads "$BASE/$REPO.git" >/dev/null 2>"$WORK/reach.err"; then
    log "⚠️ 基址不可达（$BASE/$REPO.git）——记 SKIP：$(head -c 160 "$WORK/reach.err" | tr '\n' ' ')"
    rec reachable SKIP 0 "unreachable $BASE"
    echo SKIP >"$RESULTS/verdict"
    exit 2
fi

prep() {  # prep <dir>
    rm -rf "$1"
    git -c protocol.version=2 clone --quiet --depth 1 "$BASE/$REPO.git" "$1" 2>"$1.err" || return 1
    git -C "$1" config url."$BASE/".insteadOf https://github.com/
}

first_layer() {  # first_layer <dir> → 每行一个第一层子模块路径
    git -C "$1" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}'
}

count_uninit() { git -C "$1" submodule status 2>/dev/null | grep -c '^-'; }
count_done()   { git -C "$1" submodule status 2>/dev/null | grep -vc '^-'; }

# ---------------------------------------------------------------------------
# 腿 A：git 原生 --jobs
# ---------------------------------------------------------------------------
log "腿 A：git submodule update --init --depth 1 --jobs $JOBS（第一层，不带 --recursive）"
if ! prep "$WORK/a"; then
    log "❌ 主仓克隆失败：$(head -c 160 "$WORK/a.err" | tr '\n' ' ')"
    rec git-natives-jobs FAIL 0 "主仓克隆失败"
    echo "FAIL" >"$RESULTS/verdict"; exit 1
fi
n_first=$(first_layer "$WORK/a" | wc -l)
t0=$(now_ms)
git -C "$WORK/a" -c protocol.version=2 submodule update --init --depth 1 --jobs "$JOBS" \
    >"$WORK/a.log" 2>&1
rcA=$?
msA=$(( $(now_ms) - t0 ))
okA=$(count_done "$WORK/a"); unA=$(count_uninit "$WORK/a")
if [ "$rcA" -eq 0 ] && [ "$unA" -eq 0 ]; then
    rec git-native-jobs PASS "$msA" "jobs=$JOBS,submodules=$okA/$n_first"
else
    rec git-native-jobs FAIL "$msA" "rc=$rcA,uninit=$unA/$n_first,log=$(tail -c 160 "$WORK/a.log" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# 腿 B：手动 32 并发（跨路径 xargs -P）
# ---------------------------------------------------------------------------
log "腿 B：init 串行 + xargs -P $JOBS 逐路径 submodule update"
if ! prep "$WORK/b"; then
    log "❌ 主仓克隆失败：$(head -c 160 "$WORK/b.err" | tr '\n' ' ')"
    rec manual-parallel FAIL 0 "主仓克隆失败"
    echo "FAIL" >"$RESULTS/verdict"; exit 1
fi

init_ms=0
if [ "$n_first" -gt 0 ]; then
    t0=$(now_ms)
    git -C "$WORK/b" submodule init >"$WORK/b.init.log" 2>&1
    init_ms=$(( $(now_ms) - t0 ))
fi

t0=$(now_ms)
first_layer "$WORK/b" | xargs -P "$JOBS" -I{} bash -c '
    d="$1"; p="$2"; out="$3"
    s=$(date +%s%3N)
    git -C "$d" -c protocol.version=2 submodule update --init --depth 1 --checkout -- "$p" \
        >/dev/null 2>&1
    rc=$?
    e=$(date +%s%3N)
    printf "%s\t%s\t%s\n" "$p" "$rc" "$((e - s))" >>"$out"
    exit "$rc"
' _ "$WORK/b" {} "$MANUAL_TSV"
rcB=$?
msB=$(( $(now_ms) - t0 ))
okB=$(count_done "$WORK/b"); unB=$(count_uninit "$WORK/b")
if [ "$rcB" -eq 0 ] && [ "$unB" -eq 0 ]; then
    rec manual-parallel PASS "$msB" "jobs=$JOBS,init=${init_ms}ms,submodules=$okB/$n_first"
else
    rec manual-parallel FAIL "$msB" "rc=$rcB,uninit=$unB/$n_first"
fi

# ---------------------------------------------------------------------------
# 对照：体积应基本一致（证明两腿拉的是同样内容）
# ---------------------------------------------------------------------------
size_a=$(du -sm "$WORK/a" 2>/dev/null | awk '{print $1}')
size_b=$(du -sm "$WORK/b" 2>/dev/null | awk '{print $1}')
rec size INFO 0 "git-native=${size_a}MB manual=${size_b}MB"

ratio=$(awk -v a="$msA" -v b="$msB" 'BEGIN{ if (b > 0) printf "%.2f", a / b; else print "n/a" }')
rec compare INFO 0 "git-native/manual=${ratio}x（<1 表示 git 原生更快）"

if [ "$okA" != "$okB" ]; then
    rec parity FAIL 0 "git-native=$okA manual=$okB 子模块数量不一致"
fi

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
log "===== 汇总 ====="
awk -F'\t' '{printf "  %-16s %-5s %8sms  %s\n", $1, $2, $3, $4}' "$TSV"
if [ -s "$MANUAL_TSV" ]; then
    log "腿 B 逐项：n=$(wc -l <"$MANUAL_TSV") p50=$(sort -t$'\t' -k3,3n "$MANUAL_TSV" | awk -F'\t' '{a[NR]=$3} END{print (NR? a[int((NR+1)/2)] : 0)}')ms " \
        "max=$(sort -t$'\t' -k3,3nr "$MANUAL_TSV" | head -1 | cut -f3)ms"
fi

if grep -q $'\tFAIL\t' "$TSV"; then
    echo FAIL >"$RESULTS/verdict"; exit 1
fi
echo PASS >"$RESULTS/verdict"
