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

rec env INFO 0 "git=$(git --version | awk '{print $3}'),submodule.fetchJobs=$(git config --get submodule.fetchJobs || echo unset),fetch.parallel=$(git config --get fetch.parallel || echo unset)"
# 任何 ORDER 子集都要能用（set -u 下未跑过的腿不能是未绑定变量）
msA=0; msB=0; msC=0; okA=0; okB=0; okC=0; badA=0; badB=0; badC=0

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

# 从 GIT_TRACE_PERFORMANCE 的 stderr 里按子命令归类，并给出首末时间戳的跨度。
# 目的：验证「clone 集中在开头、fetch 铺满后半段」——即 --jobs 只并行 clone 段。
# 行格式：03:19:49.864991 trace.c:420  performance: 6.315115 s: git command: 'git' 'clone' ...
trace_summary() {  # trace_summary <tracefile>
    local f="$1"
    [ -s "$f" ] || { echo "no-trace"; return; }
    awk '
        /performance: [0-9.]+ s:/ {
            ts = $1
            dur = $0; sub(/.*performance: /, "", dur); sub(/ s:.*/, "", dur)
            cmd = $0; sub(/.*git command: /, "", cmd)
            name = "other"
            if (cmd ~ /index-pack/)      name = "index-pack"
            else if (cmd ~ /clone/)      name = "clone"   # clone 带 --no-checkout，含 checkout，必须先判 clone
            else if (cmd ~ /checkout/)   name = "checkout"
            else if (cmd ~ /fetch/)      name = "fetch"
            else if (cmd ~ /rev-list/)   name = "rev-list"
            n[name]++; t[name] += dur
            split(ts, a, ":"); sec = a[1] * 3600 + a[2] * 60 + a[3]
            if (!(name in lo) || sec < lo[name]) lo[name] = sec
            if (!(name in hi) || sec > hi[name]) hi[name] = sec
        }
        END {
            printf "clone=%d/%.1fs(span=%.1fs) fetch=%d/%.1fs(span=%.1fs) checkout=%d/%.1fs rev-list=%d/%.1fs index-pack=%d/%.1fs",
                n["clone"], t["clone"], (("clone" in hi) ? hi["clone"] - lo["clone"] : 0),
                n["fetch"], t["fetch"], (("fetch" in hi) ? hi["fetch"] - lo["fetch"] : 0),
                n["checkout"], t["checkout"],
                n["rev-list"], t["rev-list"],
                n["index-pack"], t["index-pack"]
        }
    ' "$f" 2>/dev/null
}

# 正确性校验：每个子模块的 HEAD 必须等于父仓 index 里记录的 gitlink SHA。
# 只比体积/数量不够——并发写 .git/config 或 URL 重写出错时，
# 可能 clone 到「另一个仓库的尖端」，体积相近但内容是错的。
verify_leg() {  # verify_leg <superproject-dir> <out-tsv> → 打印 mismatch 条数
    local d="$1" out="$2" p pin head url st
    : >"$out"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        pin=$(git -C "$d" rev-parse "HEAD:$p" 2>/dev/null || true)
        head=$(git -C "$d/$p" rev-parse HEAD 2>/dev/null || true)
        url=$(git -C "$d/$p" ls-remote --get-url origin 2>/dev/null || true)
        st=OK
        if [ -z "$pin" ] || [ "$pin" != "$head" ]; then
            st=MISMATCH
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$p" "$pin" "$head" "$st" "$url" >>"$out"
    done < <(git -C "$d" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')
    awk -F'\t' '$5 != "OK"' "$out" | wc -l
}

# 递归校验：按层遍历全部子模块，比对每个 HEAD 与其**父仓**记录的 gitlink。
# 未初始化的目录 head 为空 → 判 MISMATCH，可用于证明递归确实拉全了。
verify_tree() {  # verify_tree <root> <out-tsv> → 打印 mismatch 条数
    local root="$1" out="$2" r p pin head st
    : >"$out"
    echo "$root" >"$WORK/.vcur"
    while [ -s "$WORK/.vcur" ]; do
        : >"$WORK/.vnext"
        while IFS= read -r r; do
            [ -e "$r/.git" ] || continue
            while IFS= read -r p; do
                [ -n "$p" ] || continue
                pin=$(git -C "$r" rev-parse "HEAD:$p" 2>/dev/null || true)
                head=$(git -C "$r/$p" rev-parse HEAD 2>/dev/null || true)
                st=OK
                if [ -z "$pin" ] || [ "$pin" != "$head" ]; then st=MISMATCH; fi
                printf '%s\t%s\t%s\t%s\t%s\n' "$r" "$p" "$pin" "$head" "$st" >>"$out"
                echo "$r/$p" >>"$WORK/.vnext"
            done < <(git -C "$r" config -f .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}')
        done <"$WORK/.vcur"
        mv "$WORK/.vnext" "$WORK/.vcur"
    done
    awk -F'\t' '$5 != "OK"' "$out" | wc -l
}

# ---------------------------------------------------------------------------
# 腿 A：git 原生 --jobs
# ---------------------------------------------------------------------------
log "腿 A：git submodule update --init --depth 1 --jobs $JOBS（第一层，不带 --recursive）"
leg_a() {
if ! prep "$WORK/a"; then
    log "❌ 主仓克隆失败：$(head -c 160 "$WORK/a.err" | tr '\n' ' ')"
    rec git-natives-jobs FAIL 0 "主仓克隆失败"
    echo "FAIL" >"$RESULTS/verdict"; exit 1
fi
n_first=$(first_layer "$WORK/a" | wc -l)
t0=$(now_ms)
# 并发采样：统计 git 网络子进程的瞬时并发度，用来回答「--jobs 32 到底有没有起 32 路」
# 进程名形如：/usr/lib/git-core/git clone ... / git-remote-https ... / git index-pack ...
count_git_net() {
    ps -eo args= 2>/dev/null |
        grep -E '(^|/)(git|git-remote-https|git-remote-http|git-upload-pack|git-index-pack)[^ ]* .*(clone|fetch|index-pack|remote-https|remote-http|upload-pack)' |
        grep -vc 'grep' || true
}
conc="$WORK/conc-a.txt"; : >"$conc"; rm -f "$WORK/stop-a"
( while [ ! -f "$WORK/stop-a" ]; do
      n=$(count_git_net)
      printf '%s\n' "${n:-0}" >>"$conc"
      sleep 0.2
  done ) &
sampler=$!
GIT_TRACE_PERFORMANCE=1 git -C "$WORK/a" -c protocol.version=2 submodule update --init --depth 1 --jobs "$JOBS" \
    >"$WORK/a.log" 2>&1
rcA=$?
touch "$WORK/stop-a"; wait "$sampler" 2>/dev/null
msA=$(( $(now_ms) - t0 ))
okA=$(count_done "$WORK/a"); unA=$(count_uninit "$WORK/a")
conc_stat=$(awk '{s+=$1; if($1>m)m=$1; if($1>0)c++} END{printf "mean=%.2f max=%d busy=%d/%d", (NR?s/NR:0), m, c, NR}' "$conc" 2>/dev/null)
trA=$(trace_summary "$WORK/a.log")
badA=$(verify_leg "$WORK/a" "$RESULTS/verify-a.tsv")
if [ "$rcA" -eq 0 ] && [ "$unA" -eq 0 ]; then
    rec git-native-jobs PASS "$msA" "jobs=$JOBS,submodules=$okA/$n_first,conc[$conc_stat],trace[$trA]"
else
    rec git-native-jobs FAIL "$msA" "rc=$rcA,uninit=$unA/$n_first,conc[$conc_stat],trace[$trA],log=$(tail -c 160 "$WORK/a.log" | tr '\n' ' ')"
fi
}

# ---------------------------------------------------------------------------
# 腿 B：手动 32 并发（跨路径 xargs -P）
# ---------------------------------------------------------------------------
leg_b() {
log "腿 B：init 串行 + xargs -P $JOBS 逐路径 submodule update"
if ! prep "$WORK/b"; then
    log "❌ 主仓克隆失败：$(head -c 160 "$WORK/b.err" | tr '\n' ' ')"
    rec manual-parallel FAIL 0 "主仓克隆失败"
    echo "FAIL" >"$RESULTS/verdict"; exit 1
fi
n_first=$(first_layer "$WORK/b" | wc -l)

init_ms=0
if [ "$n_first" -gt 0 ]; then
    t0=$(now_ms)
    git -C "$WORK/b" submodule init >"$WORK/b.init.log" 2>&1
    init_ms=$(( $(now_ms) - t0 ))
fi

t0=$(now_ms)
conc="$WORK/conc-b.txt"; : >"$conc"; rm -f "$WORK/stop-b"
( while [ ! -f "$WORK/stop-b" ]; do
      n=$(count_git_net)
      printf '%s\n' "${n:-0}" >>"$conc"
      sleep 0.2
  done ) &
sampler=$!
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
touch "$WORK/stop-b"; wait "$sampler" 2>/dev/null
msB=$(( $(now_ms) - t0 ))
okB=$(count_done "$WORK/b"); unB=$(count_uninit "$WORK/b")
badB=$(verify_leg "$WORK/b" "$RESULTS/verify-b.tsv")
concB=$(awk '{s+=$1; if($1>m)m=$1; if($1>0)c++} END{printf "mean=%.2f max=%d busy=%d/%d", (NR?s/NR:0), m, c, NR}' "$conc" 2>/dev/null)
if [ "$rcB" -eq 0 ] && [ "$unB" -eq 0 ]; then
    rec manual-parallel PASS "$msB" "jobs=$JOBS,init=${init_ms}ms,submodules=$okB/$n_first,conc[$concB]"
else
    rec manual-parallel FAIL "$msB" "rc=$rcB,uninit=$unB/$n_first,conc[$concB]"
fi
}

# ---------------------------------------------------------------------------
# 腿 C：git 原生 --recursive --jobs（验证「一条命令最简单」方案的代价）
#   上游实现：每层并行 clone，但递归是深度优先、逐子模块串行。
# ---------------------------------------------------------------------------
leg_c() {
log "腿 C：git submodule update --init --recursive --depth 1 --jobs $JOBS"
if ! prep "$WORK/c"; then
    log "❌ 主仓克隆失败：$(head -c 160 "$WORK/c.err" | tr '\n' ' ')"
    rec git-native-recursive FAIL 0 "主仓克隆失败"
    echo "FAIL" >"$RESULTS/verdict"; exit 1
fi
t0=$(now_ms)
git -C "$WORK/c" -c protocol.version=2 submodule update --init --recursive --depth 1 --jobs "$JOBS" \
    >"$WORK/c.log" 2>&1
rcC=$?
msC=$(( $(now_ms) - t0 ))
nC=$(git -C "$WORK/c" submodule status --recursive 2>/dev/null | wc -l)
unC=$(git -C "$WORK/c" submodule status --recursive 2>/dev/null | grep -c '^-' || true)
badC=$(verify_tree "$WORK/c" "$RESULTS/verify-c.tsv")
if [ "$rcC" -eq 0 ] && [ "${unC:-1}" -eq 0 ] && [ "${badC:-1}" -eq 0 ]; then
    rec git-native-recursive PASS "$msC" "jobs=$JOBS,instances=$nC,uninit=0,verify-mismatch=0"
else
    rec git-native-recursive FAIL "$msC" "rc=$rcC,instances=$nC,uninit=${unC:-?},verify-mismatch=${badC:-?},log=$(tail -c 160 "$WORK/c.log" | tr '\n' ' ')"
fi
}

# ---------------------------------------------------------------------------
# 执行顺序：ORDER=a,b（默认）或 b,a —— 用来把「谁先跑谁把缓存焐热」的偏差对调
# ---------------------------------------------------------------------------
ORDER="${ORDER:-a,b}"
log "执行顺序：$ORDER（先跑的腿会预热 git-cdn 的 pack cache，务必对调再跑一轮对照）"
for leg in ${ORDER//,/ }; do
    case "$leg" in
        a) leg_a ;;
        b) leg_b ;;
        c) leg_c ;;
        *) log "⚠️ 未知腿 $leg，忽略" ;;
    esac
done

# ---------------------------------------------------------------------------
# 对照：体积应基本一致（证明两腿拉的是同样内容）
# ---------------------------------------------------------------------------
size_a=$(du -sm "$WORK/a" 2>/dev/null | awk '{print $1}')
size_b=$(du -sm "$WORK/b" 2>/dev/null | awk '{print $1}')
size_c=$(du -sm "$WORK/c" 2>/dev/null | awk '{print $1}')
# A/B 是诊断对照，只在两腿都跑过时输出，避免 ORDER=c 时打出误导性的空值
if [ "$msA" -gt 0 ] && [ "$msB" -gt 0 ]; then
    rec size INFO 0 "git-native=${size_a}MB manual=${size_b}MB"
    ratio=$(awk -v a="$msA" -v b="$msB" 'BEGIN{ if (b > 0) printf "%.2f", a / b; else print "n/a" }')
    rec compare INFO 0 "git-native/manual=${ratio}x（<1 表示 git 原生更快；ORDER=$ORDER，先跑者刷新缓存）"
    if [ "$okA" != "$okB" ]; then
        rec parity FAIL 0 "git-native=$okA manual=$okB 子模块数量不一致"
    fi
    if [ "${badA:-0}" -ne 0 ] || [ "${badB:-0}" -ne 0 ]; then
        rec verify FAIL 0 "子模块 HEAD 与父仓 gitlink 不一致：git-native=$badA manual=$badB（详见 verify-a/b.tsv）"
    else
        rec verify PASS 0 "两腿 $okA/$okB 个子模块 HEAD 均等于父仓 gitlink（内容与 pin 一致）"
    fi
fi
if [ "$msC" -gt 0 ]; then
    rec size-recursive INFO 0 "recursive=${size_c}MB"
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
