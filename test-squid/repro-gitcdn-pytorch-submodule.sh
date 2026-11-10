#!/usr/bin/env bash
# =============================================================================
# repro-gitcdn-pytorch-submodule.sh —— git-cdn「大仓 + 子模块」克隆耗时用例
#
# 场景（模拟真实构建仓的取码姿势）：
#   git clone --depth 1 --recurse-submodules --shallow-submodules <git-cdn>/pytorch/pytorch.git
#   —— 主仓浅取 + 36 个子模块逐个浅取，全部经 git-cdn（github.com 被 insteadOf 重写）
#
# 分段计时，回答「到底慢在哪」：
#   ① main       主仓 depth=1 clone
#   ② submodules `git submodule update --init --recursive --depth 1 --shallow-submodules`
#   ③ total      ①+②
# RUNS>1 时可对比冷/热两轮（git-cdn 对 depth>0 的浅包是否可缓存，用数据说话）。
#
# 子模块默认全量初始化；SUBMODULES 可限定为部分路径（空格/逗号分隔），
# 用于只测某几个大子模块（cutlass / composable_kernel / flash-attention …）。
#
# 判定：主仓或子模块失败 → FAIL（`not our ref` 是 2026-11-04 事故形态）；超时只记 WARN
#      （大仓冷缓存回源超限属容量问题，不是正确性问题，与 repro-gitcdn-latest.sh 同口径）。
#
# 执行方式：test-gitcdn.yaml 的手动 job（pytorch_submodule=1）
#           本地：REPO=pytorch/pytorch RUNS=1 bash repro-gitcdn-pytorch-submodule.sh
#
# 可覆盖：GIT_CDN_BASE / REPO / RUNS / SUBMODULES / SUBMODULE_JOBS
#         / JOBS_LADDER（并发拨测，如 "1 8 32"，每档一轮全新克隆，替代 RUNS）
#         / CLONE_TIMEOUT（主仓，0=按体积估）/ SUBMODULE_TIMEOUT
#         / TRACE_PERF（1 = 打开 GIT_TRACE_PERFORMANCE，把每个 git 子命令的耗时留档）
#         / RESULTS / WORK / GH_TOKEN
#
# TRACE_PERF=1 时：
#   ① 完整 stderr 落盘到 perf-main-run<N>.txt / perf-sub-run<N>.txt（不再只留前 10 行）
#   ② 按子命令归类汇总（index-pack = 网络取数 / checkout = 本地落盘 / fetch = 回源），
#      以 sub_<phase> 行写进 TSV —— 用于判定「慢在取数还是落盘」。
#
# 退出码：0=PASS；1=FAIL；2=SKIP（git-cdn 不可达）
# =============================================================================
set -uo pipefail

GIT_CDN_BASE="${GIT_CDN_BASE:-http://git-cdn-service.git-cdn.svc.cluster.local:8000/}"
REPO="${REPO:-pytorch/pytorch}"
RUNS="${RUNS:-1}"                          # >1 时第 2 轮起为热缓存对照
SUBMODULES="${SUBMODULES:-}"               # 空 = 全量；可给 "third_party/cutlass third_party/flash-attention"
SUBMODULE_JOBS="${SUBMODULE_JOBS:-8}"      # 子模块并发数（36 个并发 8 既不压垮 git-cdn 也不至于太慢）
JOBS_LADDER="${JOBS_LADDER:-}"             # 非空则按此并发档位逐档跑（如 "1 8 32"），忽略 RUNS
SPLIT_PHASE="${SPLIT_PHASE:-1}"            # 1 = 主仓拆成「取数(纯网络)/checkout(纯落盘)」两段计时
TRACE_PERF="${TRACE_PERF:-0}"              # 1 = GIT_TRACE_PERFORMANCE 留档每个 git 子命令耗时
CLONE_TIMEOUT="${CLONE_TIMEOUT:-0}"        # 主仓超时，0 = 按仓库体积估
SUBMODULE_TIMEOUT="${SUBMODULE_TIMEOUT:-3600}"   # 并发 1 档串行 61 个 clone 可能 20min+，留足余量
RESULTS="${RESULTS:-${RESULTS_DIR:-/tmp/test-squid-results}/gitcdn-pytorch}"
WORK="${WORK:-/tmp/gitcdn-pytorch}"
export GIT_TERMINAL_PROMPT=0
# GIT_TRACE_PERFORMANCE 由 git 写到 stderr，经 `git -c` / submodule 子进程继承，
# 所以 `2>file` 就能拿到主仓与每个子模块 clone 的分阶段耗时。
[ "$TRACE_PERF" = 1 ] && export GIT_TRACE_PERFORMANCE=1

mkdir -p "$RESULTS"
rm -rf "$WORK"; mkdir -p "$WORK"

TSV="$RESULTS/pytorch-submodule.tsv"   # run phase ms size_mb submodules verdict note
SUBTSV="$RESULTS/submodules.tsv"       # run path sha size_mb
: >"$TSV"; : >"$SUBTSV"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
now_ms() { date +%s%3N; }

repo_size_mb() {  # GitHub 仓库体积（KB→MB），用于估算超时
    local auth=()
    [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GH_TOKEN}")
    curl -sS --max-time 20 "${auth[@]}" -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${REPO}" 2>/dev/null \
        | jq -r 'if .size then (.size/1024|floor) else 0 end' 2>/dev/null
}

truth_sha() {  # 上游默认分支最新 commit（真值），仅用于 head-lag 留档
    local auth=() body
    [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${GH_TOKEN}")
    body=$(curl -sS --max-time 30 "${auth[@]}" -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/${REPO}/commits?per_page=1" 2>/dev/null)
    printf '%s' "$body" | jq -r 'if type=="array" and length>0 then .[0].sha else empty end' 2>/dev/null
}

timeout_for() {  # 主仓：pytorch 缓存缺新 SHA 时 git-cdn 回源要 18min+，按 1.5MB/s 估
    local mb="$1"
    [ "$CLONE_TIMEOUT" -gt 0 ] 2>/dev/null && { echo "$CLONE_TIMEOUT"; return; }
    local t=$(( ${mb:-0} * 2 / 3 + 300 ))
    [ "$t" -lt 900 ] && t=900
    [ "$t" -gt 5400 ] && t=5400
    echo "$t"
}

classify() {  # classify <errfile> <rc>
    local err="$1" rc="$2"
    grep -qi 'not our ref' "$err" 2>/dev/null && { echo "not-our-ref"; return; }
    grep -qiE 'timed out|timeout' "$err" 2>/dev/null && { echo "timeout"; return; }
    grep -qiE 'early EOF|RPC failed|unexpected disconnect|connection reset' "$err" 2>/dev/null && { echo "transport"; return; }
    grep -qiE 'Could not resolve host|unable to access|Connection refused' "$err" 2>/dev/null && { echo "network"; return; }
    echo "rc=$rc"
}

summarize_perf() {  # summarize_perf <tracefile> → 每行 "phase<TAB>sum_ms<TAB>calls"
    local f="$1"
    [ -s "$f" ] || return 0
    # 本环境 GIT_TRACE_PERFORMANCE 行格式（无 "| " 前缀）：
    #   08:06:14.192038 trace.c:416  performance: 19.959131058 s: git command: /usr/lib/git-core/git remote-http ...
    sed -n 's/.*performance: \([0-9.]*\) s: git command: \(.*\)$/\1\t\2/p' "$f" \
        | awk -F'\t' '
            {
                ms = $1 * 1000
                # 取命令行里第一个「叶子子命令」token 归类，避免 wrapper
                # （clone ⊃ remote-http + index-pack）重复计数，也避免 --no-checkout 误判成 checkout：
                #   net = HTTP 会话（取数）；checkout = 本地落盘；index-pack/unpack-objects = 解包
                n = split($2, a, " ")
                k = ""
                for (i = 1; i <= n && i <= 4; i++) {
                    t = a[i]; sub(/.*\//, "", t)
                    if (t == "remote-http" || t == "remote-https" ||
                        t == "index-pack" || t == "unpack-objects" ||
                        t == "checkout"   || t == "checkout-index") { k = t; break }
                }
                if (k == "remote-http" || k == "remote-https") k = "net"
                # wrapper 行与 net/index-pack 重叠，不可相加，只作对照
                if (k == "") k = "wrapper"
                sum[k] += ms; cnt[k]++
            }
            END { for (k in sum) printf "%s\t%d\t%d\n", k, sum[k], cnt[k] }' \
        | sort -k2,2nr
}

probe_refs() {  # 记录 git-cdn 对 info/refs 的缓存类响应头（每轮一次，作缓存证据）
    local out="$1"
    {
        echo "# $(date -u '+%Y-%m-%dT%H:%M:%SZ') $GIT_CDN_BASE$REPO.git/info/refs?service=git-upload-pack"
        curl -sS -D - -o /dev/null --max-time 30 \
            "${GIT_CDN_BASE}${REPO}.git/info/refs?service=git-upload-pack" 2>/dev/null \
            | tr -d '\r' | grep -iE '^(HTTP/|cache-status|x-cache|age|date|content-length):'
    } >>"$out"
}

# ---------------------------------------------------------------------------
# 前置：git-cdn 可达，否则本集群没有实例，记 SKIP（不判红）
# ---------------------------------------------------------------------------
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$GIT_CDN_BASE" 2>/dev/null) || code="000"
if [ "$code" != "200" ]; then
    log "⚠️ git-cdn 不可达（$GIT_CDN_BASE GET=$code）——记 SKIP"
    printf '0\t-\t0\t-\t-\tSKIP\tgit-cdn-unreachable\n' >>"$TSV"
    exit 2
fi

size_mb=$(repo_size_mb)
tmo=$(timeout_for "$size_mb")
truth=$(truth_sha)
url="${GIT_CDN_BASE}${REPO}.git"
# 子模块 URL 是绝对地址（https://github.com/<owner>/<repo>.git），必须经 insteadOf 重写才走 git-cdn。
# `git -c` 会通过 GIT_CONFIG_PARAMETERS 传给子进程，因此 submodule 递归同样生效。
insteadof="url.${GIT_CDN_BASE}.insteadOf=https://github.com/"

log "被测仓库：$REPO（体积 ${size_mb}MB，主仓超时 ${tmo}s，子模块超时 ${SUBMODULE_TIMEOUT}s，并发 ${SUBMODULE_JOBS}）"
log "git-cdn 基址：$GIT_CDN_BASE；真值 HEAD：${truth:0:9}"
[ -n "$SUBMODULES" ] && log "限定子模块：$SUBMODULES"
[ "$TRACE_PERF" = 1 ] && log "GIT_TRACE_PERFORMANCE=1：逐子命令耗时留档（perf-*.txt）"

FAIL=0; WARN=0
# 轮次计划：JOBS_LADDER 非空 → 每档并发一轮（都从空目录起，排除工作树复用的干扰）；
#           否则按 RUNS 跑冷/热对照
if [ -n "$JOBS_LADDER" ]; then
    plan=(); for j in $JOBS_LADDER; do plan+=("jobs:$j"); done
    log "并发拨测档位：$JOBS_LADDER"
else
    plan=(); for i in $(seq 1 "$RUNS"); do plan+=("run:$i"); done
fi
n_round=0
for item in "${plan[@]}"; do
    run=$((n_round+1)); n_round=$run
    kind="${item%%:*}"; val="${item#*:}"
    if [ "$kind" = jobs ]; then
        SUBMODULE_JOBS="$val"
        tag="jobs$val"
    else
        tag="run$val"; [ "$val" -gt 1 ] && tag="run$val(warm)"
    fi
    d="$WORK/run$run"; mkdir -p "$d"
    probe_refs "$RESULTS/refs-probe-run$run.txt"
    log "===== 第 $run 轮（$tag，子模块并发 $SUBMODULE_JOBS）====="

    # ① 主仓浅取：--no-checkout 只拉对象（纯网络），checkout 单独计时（纯本地落盘）
    #    两者分开才能回答「280s 是网络慢还是写盘慢」
    t0=$(now_ms)
    timeout "$tmo" git -c "$insteadof" clone -q --depth 1 --no-recurse-submodules --no-checkout \
        "$url" "$d/pytorch" 2>"$d/main.err"; rc=$?
    main_ms=$(( $(now_ms) - t0 ))
    if [ "$rc" = 124 ]; then
        log "$REPO —— ⚠️ 主仓 clone 超时（上限 ${tmo}s）"
        printf '%s\tmain\t%s\t-\t-\tWARN\tclone-timeout(limit=%ss)\n' "$tag" "$main_ms" "$tmo" >>"$TSV"
        WARN=$((WARN+1)); continue
    fi
    if [ "$rc" != 0 ]; then
        reason=$(classify "$d/main.err" "$rc")
        log "$REPO —— ❌ 主仓 clone 失败：$reason"
        printf '%s\tmain\t%s\t-\t-\tFAIL\t%s\n' "$tag" "$main_ms" "$reason" >>"$TSV"
        FAIL=$((FAIL+1)); continue
    fi
    fetch_ms=$main_ms
    printf '%s\tmain_fetch\t%s\t-\t-\tPASS\tno-checkout(纯网络)\n' "$tag" "$fetch_ms" >>"$TSV"
    if [ "$TRACE_PERF" = 1 ]; then
        [ -s "$d/main.err" ] && cp "$d/main.err" "$RESULTS/perf-main-run$run.txt"
        summarize_perf "$d/main.err" | while IFS=$'\t' read -r k ms cnt; do
            printf '%s\tmain_%s\t%s\t-\t-\tINFO\tcalls=%s\n' "$tag" "$k" "$ms" "$cnt" >>"$TSV"
            log "主仓阶段 $k：合计 ${ms}ms / ${cnt} 次"
        done
    fi
    if [ "$SPLIT_PHASE" = 1 ]; then
        t_c=$(now_ms)
        timeout "$tmo" git -C "$d/pytorch" checkout -q -f 2>"$d/main-co.err"; rcc=$?
        co_ms=$(( $(now_ms) - t_c ))
        main_ms=$(( fetch_ms + co_ms ))
        if [ "$rcc" != 0 ]; then
            log "$REPO —— ⚠️ 主仓 checkout 失败（rc=$rcc），耗时不可信"
            printf '%s\tmain_checkout\t%s\t-\t-\tWARN\trc=%s\n' "$tag" "$co_ms" "$rcc" >>"$TSV"
            WARN=$((WARN+1))
        else
            printf '%s\tmain_checkout\t%s\t-\t-\tPASS\tlocal(纯落盘)\n' "$tag" "$co_ms" >>"$TSV"
        fi
        log "$REPO —— 主仓拆分：取数 ${fetch_ms}ms / checkout ${co_ms}ms"
        if [ "$TRACE_PERF" = 1 ] && [ -s "$d/main-co.err" ]; then
            cp "$d/main-co.err" "$RESULTS/perf-mainco-run$run.txt"
            summarize_perf "$d/main-co.err" | while IFS=$'\t' read -r k ms cnt; do
                printf '%s\tmainco_%s\t%s\t-\t-\tINFO\tcalls=%s\n' "$tag" "$k" "$ms" "$cnt" >>"$TSV"
            done
        fi
    fi
    main_mb=$(du -sm "$d/pytorch" 2>/dev/null | awk '{print $1}')
    head_sha=$(git -C "$d/pytorch" rev-parse HEAD 2>/dev/null)
    note="head=${head_sha:0:9}"
    [ -n "$truth" ] && [ "$head_sha" != "$truth" ] && note="$note,head-lag"
    log "$REPO —— ✅ 主仓 ${main_ms}ms（${main_mb}MB，${note}）"
    printf '%s\tmain\t%s\t%s\t-\tPASS\t%s\n' "$tag" "$main_ms" "$main_mb" "$note" >>"$TSV"

    # ② 子模块：浅取 + 递归 + 并发
    n_sub=0
    if [ -f "$d/pytorch/.gitmodules" ]; then
        n_sub=$(git config -f "$d/pytorch/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null | wc -l)
    fi
    if [ "$n_sub" = 0 ]; then
        # 该分支没有子模块（或限定的路径不在清单里）：不判红，只留档
        log "子模块 —— ⏭️ 无子模块（.gitmodules 缺失或为空），跳过"
        printf '%s\tsubmodules\t0\t0\t0\tSKIP\tno-gitmodules\n' "$tag" >>"$TSV"
        printf '%s\ttotal\t%s\t%s\t0\tPASS\tmain=%sms,sub=0ms\n' "$tag" "$main_ms" "$main_mb" "$main_ms" >>"$TSV"
        rm -rf "$d"; continue
    fi
    # 注意：--shallow-submodules 是 git clone 的选项，submodule update 不认识（会直接 usage 退出）
    sub_args=(submodule update --init --recursive --depth 1 --jobs "$SUBMODULE_JOBS")
    [ -n "$SUBMODULES" ] && sub_args+=(-- $SUBMODULES)
    t1=$(now_ms)
    # clone 下的 insteadOf 需落到仓库配置里，否则子模块（独立进程、独立 repo）看不到
    git -C "$d/pytorch" config "url.${GIT_CDN_BASE}.insteadOf" "https://github.com/"
    timeout "$SUBMODULE_TIMEOUT" git -C "$d/pytorch" "${sub_args[@]}" 2>"$d/sub.err"; rc=$?
    sub_ms=$(( $(now_ms) - t1 ))
    total_mb=$(du -sm "$d/pytorch" 2>/dev/null | awk '{print $1}')
    sub_mb=$(( ${total_mb:-0} - ${main_mb:-0} ))
    # stderr 留档 + 首行入备注（否则只剩 rc=1 无法定位）
    if [ "$TRACE_PERF" = 1 ]; then
        [ -s "$d/sub.err" ] && cp "$d/sub.err" "$RESULTS/perf-sub-run$run.txt"
    else
        [ -s "$d/sub.err" ] && sed -n '1,10p' "$d/sub.err" >"$RESULTS/submodule-err-run$run.txt"
    fi
    err1=$(grep -om1 -E '(fatal|error): .*' "$d/sub.err" 2>/dev/null | cut -c1-90 | tr '\t' ' ')

    sub_verdict=PASS; sub_note="declared=$n_sub,jobs=$SUBMODULE_JOBS"
    if [ "$rc" = 124 ]; then
        sub_verdict=WARN; sub_note="$sub_note,submodule-timeout(limit=${SUBMODULE_TIMEOUT}s)"; WARN=$((WARN+1))
    elif [ "$rc" != 0 ]; then
        sub_verdict=FAIL; sub_note="$sub_note,$(classify "$d/sub.err" "$rc")${err1:+[$err1]}"; FAIL=$((FAIL+1))
    fi
    done_sub=$(git -C "$d/pytorch" submodule status --recursive 2>/dev/null | awk '$1 !~ /^-/{c++} END{print c+0}')
    sub_note="$sub_note,inited=$done_sub"
    log "子模块 —— ${sub_verdict} ${sub_ms}ms（${sub_mb}MB，已初始化 $done_sub/$n_sub）"
    printf '%s\tsubmodules\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$sub_ms" "$sub_mb" "$done_sub" "$sub_verdict" "$sub_note" >>"$TSV"
    if [ "$TRACE_PERF" = 1 ]; then
        # 各子命令的耗时之和 = 各 clone 内部阶段，可与 sub_ms（墙钟）对照：
        #   index-pack 之和 ≈ 网络取数占比；checkout/other ≈ 本地落盘占比
        summarize_perf "$d/sub.err" | while IFS=$'\t' read -r k ms cnt; do
            printf '%s\tsub_%s\t%s\t-\t-\tINFO\tcalls=%s\n' "$tag" "$k" "$ms" "$cnt" >>"$TSV"
            log "子模块阶段 $k：合计 ${ms}ms / ${cnt} 次（墙钟 ${sub_ms}ms）"
        done
    fi

    # 子模块明细（path / 已 checkout 的 sha / 工作目录体积）
    git -C "$d/pytorch" submodule status --recursive 2>/dev/null | while read -r sha path _; do
        p="$d/pytorch/$path"
        [ -d "$p" ] || continue
        printf '%s\t%s\t%s\t%s\n' "$tag" "$path" "${sha:0:9}" \
            "$(du -sm "$p" 2>/dev/null | awk '{print $1}')" >>"$SUBTSV"
    done

    # ③ 合计 + 内容完整性抽检
    total_ms=$(( main_ms + sub_ms ))
    verdict=PASS
    if ! git -C "$d/pytorch" ls-tree --name-only HEAD >/dev/null 2>&1; then verdict=FAIL; fi
    [ -f "$d/pytorch/setup.py" ] || [ -f "$d/pytorch/CMakeLists.txt" ] || verdict=FAIL
    [ "$verdict" = FAIL ] && FAIL=$((FAIL+1))
    log "合计 $REPO + 子模块 —— ${verdict} ${total_ms}ms（主仓 ${main_ms}ms / 子模块 ${sub_ms}ms，总计 ${total_mb}MB）"
    printf '%s\ttotal\t%s\t%s\t%s\t%s\tmain=%sms,sub=%sms\n' \
        "$tag" "$total_ms" "$total_mb" "$done_sub" "$verdict" "$main_ms" "$sub_ms" >>"$TSV"

    rm -rf "$d"
done

rm -rf "$WORK"
log "===== 汇总：FAIL=$FAIL WARN=$WARN ====="
awk -F'\t' '{printf "  %-12s %-10s %8sms %6sMB %s %s\n", $1, $2, $3, $4, $6, $7}' "$TSV"
[ "$FAIL" -gt 0 ] && { log "❌ 有 $FAIL 处失败（判红）"; exit 1; }
log "✅ 通过（WARN=$WARN 为超时留档项）"
exit 0
