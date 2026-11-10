#!/usr/bin/env bash
# =============================================================================
# gitcode-clone-bench.sh —— 只测 gitcode clone 的耗时与吞吐（R22）
#
# 前提：pod 模板的 postStart 已把 https://gitcode.com/ 重写到缓存后端
#       （/root/.gitconfig 里的 url.<backend>.insteadOf），否则本脚本判失败。
#
# 输入（env）：
#   GITCODE_REPO     目标仓库，默认 https://gitcode.com/cann/catlass.git
#   GITCODE_PROXY    期望的缓存后端基址（仅用于断言，空=不断言）
#   CLONE_MODE       full=--single-branch（不带 depth，可进后端 pack 缓存）
#                    shallow=--depth 1（多数后端默认不缓存，只测拉取速度）
#   ITERATIONS       克隆次数，默认 5；第 1 次为冷启动，其余为热路径
#   BASELINE         1=额外克隆一次上游 gitcode.com 作对照（GIT_CONFIG_GLOBAL=/dev/null 跳过 insteadOf）
#   LADDER           并发阶梯（空格分隔，如 "1 4 8"）；空=只测串行。
#                    每个并发度下同时启动 N 个 clone（各自独立目录），记录实际耗时（wall-clock）与逐次耗时
#   GITHUB_CLONE     1=额外测 github.com 的 clone：走 pod 模板 postStart 注入的
#                    gitconfig 重写（github.com → git-cdn 的 github 实例），
#                    与 gitcode 是两套独立缓存后端
#   GITHUB_REPO      github 对照仓库，默认本测试仓库
#   GITHUB_ITERATIONS github 对照的克隆次数，默认 3
#   REWRITE_STRICT   1=重写未生效即判失败（默认 1）
#   REF              指定 commit/branch：clone 后 checkout 到该版本（默认空=默认分支）
#   LFS_VERIFY       1=clone 后 git lfs pull，并逐文件校验 sha256 == pointer 里的 oid
#   LFS_SKIP_SMUDGE  1=clone 只取 pointer（GIT_LFS_SKIP_SMUDGE=1），把 LFS 下载挪到
#                    显式 git lfs pull，用于观察 MISS→HIT（默认 0=贴近真实 CI 行为）
#   LFS_INCLUDE      LFS 只拉指定路径（git lfs pull -I），空=全部
#   RESULTS_DIR      结果目录，默认 /tmp/gitcode-bench
#
# 输出：
#   clone.tsv        每次克隆：iter / mode / exit / ms / bytes / MBps / url
#   github.tsv       github 对照：iter / mode / exit / ms / bytes / MBps / url
#   concurrency.tsv  并发明细：level / idx / exit / ms / bytes / MBps
#   conc-levels.tsv  并发阶梯汇总：level / ok / fail / wall / median / min / max / MBps
#   lfs.tsv          LFS 校验：iter / path / oid / actual / bytes / expect_size / match / pull_ms / age
#   summary.md       汇总：冷/热耗时、加速比、中位数、吞吐、github 对照、并发表、LFS 校验
#
# 退出码：有克隆失败 → 1；重写断言失败 → 1；否则 0（性能数据不判红）
# =============================================================================
set -uo pipefail

REPO="${GITCODE_REPO:-https://gitcode.com/cann/catlass.git}"
BACKEND="${GITCODE_PROXY:-}"
MODE="${CLONE_MODE:-full}"
ITER="${ITERATIONS:-5}"
BASELINE="${BASELINE:-0}"
LADDER="${LADDER:-}"
GH_ON="${GITHUB_CLONE:-1}"
GH_REPO="${GITHUB_REPO:-https://github.com/ascend-gha-runners/squid-gha-integration-test.git}"
GH_ITER="${GITHUB_ITERATIONS:-3}"
STRICT="${REWRITE_STRICT:-1}"
REF="${REF:-}"
LFS_VERIFY="${LFS_VERIFY:-0}"
LFS_SKIP_SMUDGE="${LFS_SKIP_SMUDGE:-0}"
LFS_INCLUDE="${LFS_INCLUDE:-}"
OUT="${RESULTS_DIR:-/tmp/gitcode-bench}"

mkdir -p "$OUT"
CSV="$OUT/clone.tsv"
GH_CSV="$OUT/github.tsv"
LFS_CSV="$OUT/lfs.tsv"
SUMMARY="$OUT/summary.md"
printf 'iter\tmode\texit\tms\tbytes\tMBps\turl\n' > "$CSV"
printf 'iter\tpath\toid\tactual\tbytes\texpect_size\tmatch\tpull_ms\tage\n' > "$LFS_CSV"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
norm() { printf '%s' "${1%/}"; }

origin=$(printf '%s' "$REPO" | sed -E 's#^(https?://[^/]+).*#\1#')   # https://gitcode.com
path=$(printf '%s' "$REPO" | sed -E 's#^https?://[^/]+##')           # /cann/catlass.git

# --- ① 断言 insteadOf 生效，并从展开结果反推后端基址 -------------------------
expanded=$(git ls-remote --get-url "$REPO" 2>/dev/null)
log "URL 展开: $REPO -> ${expanded:-<空>}"
base=""
case "$expanded" in
    *"$path") base=$(norm "${expanded%"$path"}") ;;
esac
if [ -z "$base" ] || [ "$base" = "$origin" ]; then
    log "❌ insteadOf 未生效（展开结果不是缓存后端）。该 runner 未注入重写？"
    [ "$STRICT" = 1 ] && exit 1
    base="$origin"
fi
if [ -n "$BACKEND" ] && [ "$base" != "$(norm "$BACKEND")" ]; then
    log "⚠️ 实际后端 $base 与期望 $(norm "$BACKEND") 不一致"
    [ "$STRICT" = 1 ] && { log "❌ REWRITE_STRICT=1，判失败"; exit 1; }
fi
url="${base}${path}"
host="${url#*://}"; host="${host%%/*}"
log "clone 目标: $url（对端 $host，形态 $MODE，次数 $ITER）"

case "$MODE" in
    full)    args=(--single-branch) ;;
    shallow) args=(--depth 1 --single-branch) ;;
    *) log "❌ 未知 CLONE_MODE=$MODE（可选 full|shallow）"; exit 1 ;;
esac

# run_clone <tag> <mode> <url> <dir> [csv]：计时并落一行 CSV
run_clone() {
    local tag="$1" mode="$2" u="$3" d="$4" csv="${5:-$CSV}"
    local s e rc ms bytes mbps
    rm -rf "$d"
    s=$(date +%s%3N)
    if GIT_TERMINAL_PROMPT=0 git clone "${args[@]}" -q "$u" "$d" \
            >/dev/null 2>"$OUT/clone-$tag.err"; then
        rc=0
    else
        rc=$?
    fi
    e=$(date +%s%3N); ms=$((e - s))
    bytes=$(du -sb "$d" 2>/dev/null | cut -f1); bytes=${bytes:-0}
    mbps=$(awk -v b="$bytes" -v ms="$ms" 'BEGIN{ if (ms > 0) printf "%.2f", (b/1048576)/(ms/1000); else print "0.00" }')
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$tag" "$mode" "$rc" "$ms" "$bytes" "$mbps" "$u" >> "$csv"
    log "iter $tag ($mode): exit=$rc ${ms}ms $((bytes/1048576))MB ${mbps}MB/s"
    [ -f "$OUT/clone-$tag.err" ] && [ -s "$OUT/clone-$tag.err" ] && tail -n 3 "$OUT/clone-$tag.err" | sed 's/^/    | /'
    return "$rc"
}

# ensure_lfs：容器镜像通常不带 git-lfs，先 apt 安装，失败再走官方 release 自举
ensure_lfs() {
    command -v git-lfs >/dev/null 2>&1 && { log "git-lfs 可用（$(git lfs version)）"; return 0; }
    log "容器内无 git-lfs，尝试 apt-get 安装"
    if apt-get install -y -q git-lfs >/dev/null 2>&1 \
            || { apt-get update -q >/dev/null 2>&1 && apt-get install -y -q git-lfs >/dev/null 2>&1; }; then
        command -v git-lfs >/dev/null 2>&1 \
            && { log "git-lfs 安装完成（$(git lfs version)）"; return 0; }
    fi
    local arch d
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
    esac
    log "⚠️ apt 安装失败，改用官方 release bootstrap（linux-$arch）"
    d=$(mktemp -d)
    curl -fsSL "https://github.com/git-lfs/git-lfs/releases/download/v3.7.0/git-lfs-linux-${arch}-v3.7.0.tar.gz" \
        | tar xz -C "$d" || { log "❌ git-lfs 下载失败"; return 1; }
    export PATH="$d/git-lfs-3.7.0:$PATH"
    git lfs version || { log "❌ git-lfs 二进制不可用"; return 1; }
    log "git-lfs bootstrap 完成"
}

# lfs_verify <dir> <tag>：git lfs pull 后逐文件校验 sha256 == pointer oid
# 判据三条：① 文件已实体化（不是 pointer 原文）；② sha256 与 oid 一致；
#           ③ 文件大小与 pointer 的 size 一致。任一不符即判失败。
lfs_verify() {
    local d="$1" tag="$2" sha="${3:-}"
    local id="$tag:${sha:-?}"
    local s e ms age bad=0 cnt=0
    local -a inc=()
    [ -n "$LFS_INCLUDE" ] && inc=(-I "$LFS_INCLUDE")
    s=$(date +%s%3N)
    if ! GIT_TERMINAL_PROMPT=0 GIT_CURL_VERBOSE=1 git -C "$d" lfs pull "${inc[@]}" \
            >/dev/null 2>"$OUT/lfs-$tag.err"; then
        log "❌ lfs pull 失败（iter $id）"
        tail -n 5 "$OUT/lfs-$tag.err" 2>/dev/null | sed 's/^/    | /'
        printf '%s\t-\t-\t-\t-\t-\tFAIL\t-\t-\n' "$id" >> "$LFS_CSV"
        return 1
    fi
    e=$(date +%s%3N); ms=$((e - s))
    # Age 响应头最大值：>0 说明该对象来自缓存（仅留证，不作判据）
    age=$(grep -aioE '^< age: [0-9]+' "$OUT/lfs-$tag.err" 2>/dev/null \
          | awk '{print $3}' | sort -n | tail -1); age=${age:--}

    while read -r p; do
        [ -n "$p" ] || continue
        # LFS_INCLUDE 非空时只校验被拉取的那部分（其余文件保持 pointer 形态）
        if [ -n "$LFS_INCLUDE" ]; then
            case "$p" in $LFS_INCLUDE) ;; *) continue ;; esac
        fi
        cnt=$((cnt + 1))
        local ptr oid size actual bytes match
        ptr=$(git -C "$d" show "HEAD:$p" 2>/dev/null)
        oid=$(printf '%s\n' "$ptr" | sed -n 's/^oid sha256://p' | head -1)
        size=$(printf '%s\n' "$ptr" | sed -n 's/^size //p' | head -1)
        if [ ! -f "$d/$p" ]; then
            actual="-"; bytes=0; match="MISSING"
        else
            actual=$(sha256sum "$d/$p" | awk '{print $1}')
            bytes=$(stat -c %s "$d/$p" 2>/dev/null || echo 0)
            match=ok
            [ "$actual" = "$oid" ] || match="SHA-MISMATCH"
            [ "${size:-$bytes}" = "$bytes" ] || match="SIZE-MISMATCH"
        fi
        [ "$match" = ok ] || bad=$((bad + 1))
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$p" "${oid:0:12}" "${actual:0:12}" "$bytes" "${size:--}" "$match" "$ms" "$age" >> "$LFS_CSV"
        log "lfs $p: oid=${oid:0:12} actual=${actual:0:12} ${bytes}B match=$match ${ms}ms age=$age"
    done < <(git -C "$d" lfs ls-files -n 2>/dev/null)

    if [ "$cnt" = 0 ]; then
        log "⚠️ iter $tag 该 commit 没有 LFS 文件（ls-files 为空）"
    fi
    [ "$bad" -eq 0 ]
}

# --- ② 基线（可选）：跳过全局 insteadOf，直接打上游 --------------------------
if [ "$BASELINE" = 1 ]; then
    uexp=$(GIT_CONFIG_GLOBAL=/dev/null git ls-remote --get-url "$REPO" 2>/dev/null)
    ubase=""
    case "$uexp" in
        *"$path") ubase=$(norm "${uexp%"$path"}") ;;
    esac
    if [ "$ubase" = "$origin" ]; then
        log "baseline: 直连上游 $origin（已跳过 insteadOf）"
        run_clone baseline baseline "$REPO" "$OUT/clone-baseline" || true
        rm -rf "$OUT/clone-baseline"
    else
        log "⚠️ 无法构建上游基线（GIT_CONFIG_GLOBAL=/dev/null 展开为 ${uexp:-<空>}），跳过"
    fi
fi

# --- ③ 主循环：同一仓库重复 clone ------------------------------------------
fails=0
if [ "$LFS_VERIFY" = 1 ]; then
    ensure_lfs || { log "❌ git-lfs 不可用，LFS 校验无法进行"; exit 1; }
    # 只取 pointer，把 LFS 下载留给显式 pull（便于观察 MISS→HIT）
    if [ "$LFS_SKIP_SMUDGE" = 1 ]; then
        export GIT_LFS_SKIP_SMUDGE=1
        log "LFS_SKIP_SMUDGE=1：clone 只写 pointer，下载在 git lfs pull 阶段"
    fi
fi
for i in $(seq 1 "$ITER"); do
    if ! run_clone "$i" "$MODE" "$url" "$OUT/clone-$i"; then
        fails=$((fails + 1))
        rm -rf "$OUT/clone-$i"
        continue
    fi
    d="$OUT/clone-$i"
    if [ -n "$REF" ]; then
        if git -C "$d" checkout -q "$REF" 2>"$OUT/checkout-$i.err"; then
            log "iter $i: checkout $REF（$(git -C "$d" rev-parse --short HEAD)）"
        else
            log "❌ iter $i: checkout $REF 失败（$MODE 形态可能取不到该 commit）"
            tail -n 3 "$OUT/checkout-$i.err" 2>/dev/null | sed 's/^/    | /'
            fails=$((fails + 1))
            rm -rf "$d"
            continue
        fi
    fi
    if [ "$LFS_VERIFY" = 1 ]; then
        lfs_verify "$d" "$i" "$(git -C "$d" rev-parse --short=12 HEAD)" || fails=$((fails + 1))
    fi
    rm -rf "$d"
done

# --- ③'' github 对照（可选）：走 pod 模板 postStart 注入的 gitconfig 重写
#     （github.com → git-cdn 的 github 实例），只记录耗时，不做缓存命中断言 --
gh_expanded=""
if [ "$GH_ON" = 1 ]; then
    printf 'iter\tmode\texit\tms\tbytes\tMBps\turl\n' > "$GH_CSV"
    gh_expanded=$(git ls-remote --get-url "$GH_REPO" 2>/dev/null)
    log "github URL 展开: $GH_REPO -> ${gh_expanded:-<空>}"
    for i in $(seq 1 "$GH_ITER"); do
        run_clone "gh-$i" github "$GH_REPO" "$OUT/gh-$i" "$GH_CSV" || fails=$((fails + 1))
        rm -rf "$OUT/gh-$i"
    done
fi

# --- ③' 并发阶梯（可选）：同时 clone N 份，测实际耗时（wall-clock）与逐次耗时 ---------
CONC_CSV="$OUT/concurrency.tsv"
CONC_TBL="$OUT/conc-levels.tsv"
if [ -n "$LADDER" ]; then
    printf 'level\tidx\texit\tms\tbytes\tMBps\n' > "$CONC_CSV"
    printf 'level\tok\tfail\twall_ms\tmedian_ms\tmin_ms\tmax_ms\tMBps\n' > "$CONC_TBL"
fi

# run_conc <level> <idx>：后台执行，结果写 c<idx>.res（idx/exit/ms/bytes）
run_conc() {
    local lvl="$1" idx="$2" d="$OUT/conc-$1/c$2"
    local s e rc ms bytes
    rm -rf "$d"
    s=$(date +%s%3N)
    if GIT_TERMINAL_PROMPT=0 git clone "${args[@]}" -q "$url" "$d" \
            >/dev/null 2>"$OUT/conc-$lvl/c$idx.err"; then
        rc=0
    else
        rc=$?
    fi
    e=$(date +%s%3N); ms=$((e - s))
    bytes=$(du -sb "$d" 2>/dev/null | cut -f1); bytes=${bytes:-0}
    printf '%s\t%s\t%s\t%s\n' "$idx" "$rc" "$ms" "$bytes" > "$OUT/conc-$lvl/c$idx.res"
    return "$rc"
}

for lvl in $LADDER; do
    case "$lvl" in
        ''|*[!0-9]*|0) log "⚠️ 跳过非法并发度 '$lvl'"; continue ;;
    esac
    lvl_dir="$OUT/conc-$lvl"
    mkdir -p "$lvl_dir"
    log "并发度 $lvl: 同时启动 $lvl 个 clone"
    ws=$(date +%s%3N)
    pids=""
    for i in $(seq 1 "$lvl"); do
        run_conc "$lvl" "$i" &
        pids="$pids $!"
    done
    for p in $pids; do wait "$p" || true; done
    we=$(date +%s%3N); wall=$((we - ws))

    # 汇总本并发度：ok/fail、实际耗时、逐次耗时中位数/极值、整体吞吐
    agg=$(awk -F'\t' -v wall="$wall" '
    { n++; rc[n] = $2; ms[n] = $3; by[n] = $4; if ($2 == 0) ok++; else fail++; tot += $4 }
    END {
        if (n == 0) { printf "0\t0\t%d\t0\t0\t0\t0.00\n", wall; exit }
        for (i = 1; i <= n; i++)
            for (j = i + 1; j <= n; j++)
                if (ms[j] < ms[i]) { t = ms[i]; ms[i] = ms[j]; ms[j] = t }
        med = (n % 2 ? ms[(n+1)/2] : (ms[n/2] + ms[n/2+1]) / 2)
        mbps = (wall > 0) ? sprintf("%.2f", (tot/1048576)/(wall/1000)) : "0.00"
        printf "%d\t%d\t%d\t%d\t%d\t%d\t%s\n", ok+0, fail+0, wall, med, ms[1], ms[n], mbps
    }' "$lvl_dir"/*.res)
    printf '%s\t%s\n' "$lvl" "$agg" >> "$CONC_TBL"

    # 逐次明细落表（含单次吞吐）
    awk -F'\t' -v lvl="$lvl" '
    { mbps = ($3 > 0) ? sprintf("%.2f", ($4/1048576)/($3/1000)) : "0.00"
      printf "%s\t%s\t%s\t%s\t%s\t%s\n", lvl, $1, $2, $3, $4, mbps }' \
        "$lvl_dir"/*.res >> "$CONC_CSV"

    lfail=$(printf '%s' "$agg" | cut -f2)
    log "并发度 $lvl: ok=$(printf '%s' "$agg" | cut -f1) fail=$lfail wall=${wall}ms median=$(printf '%s' "$agg" | cut -f4)ms"
    if [ "${lfail:-0}" -gt 0 ]; then
        fails=$((fails + lfail))
        log "❌ 并发度 $lvl 有 $lfail 次失败（明细见 $lvl_dir/c*.err）"
        grep -l . "$lvl_dir"/c*.err 2>/dev/null | while read -r f; do
            log "    | $f"; tail -n 3 "$f" | sed 's/^/    | /'
        done
    fi
    rm -rf "$lvl_dir"/c*
done

# --- ④ 汇总：冷启动 vs 热路径（中位数），顺手出 markdown ----------------------
awk -F'\t' -v repo="$REPO" -v origin="$origin" -v backend="$base" -v mode="$MODE" -v iter="$ITER" '
NR == 1 { next }
$1 == "baseline" { bl = $4; next }
{
    n++; ms[n] = $4; mb[n] = $6
    it[n] = $1; ex[n] = $3; by[n] = $5
    if (n == 1) cold = $4
    else { w++; warm[w] = $4 }
}
END {
    # 热路径中位数：冒泡排序（n 很小）
    for (i = 1; i <= w; i++)
        for (j = i + 1; j <= w; j++)
            if (warm[j] < warm[i]) { t = warm[i]; warm[i] = warm[j]; warm[j] = t }
    med = (w > 0) ? (w % 2 ? warm[(w+1)/2] : (warm[w/2] + warm[w/2+1]) / 2) : 0

    print "## clone 性能"
    print ""
    printf "- 仓库: `%s`\n", repo
    printf "- 后端: `%s`\n", backend
    printf "- 形态: `%s`，次数: %s（第 1 次冷启动）\n", mode, iter
    if (bl != "") printf "- 上游基线（直连 %s）: %d ms\n", origin, bl
    print ""
    print "| 指标 | 耗时 |"
    print "|---|---|"
    printf "| 冷启动（第 1 次） | %d ms |\n", cold
    printf "| 热路径中位数（第 2..%d 次） | %d ms |\n", n, med
    if (cold > 0 && med > 0)
        printf "| 加速比 | %.2fx（%d ms → %d ms） |\n", cold/med, cold, med
    if (bl != "" && bl > 0 && med > 0)
        printf "| 相对上游 | %.2fx（上游 %d ms → 缓存 %d ms） |\n", bl/med, bl, med
    print ""
    print "| 次数 | exit | 耗时 | 大小 | 吞吐 |"
    print "|---|---|---|---|---|"
    for (i = 1; i <= n; i++)
        printf "| %s | %s | %d ms | %d MB | %s MB/s |\n", it[i], ex[i], ms[i], by[i]/1048576, mb[i]
    if (med > 0 && cold > 0 && med <= cold * 0.7)
        print "\n结论：热路径中位数 ≤ 冷启动 70%，缓存收益明显。"
    else
        print "\n结论：未见明显缓存收益（冷缓存首跑 / 后端不缓存该形态时属正常，仅留档）。"
}' "$CSV" > "$SUMMARY"

if [ -s "$GH_CSV" ] && [ "$(awk 'END{print NR-1}' "$GH_CSV")" -gt 0 ]; then
    gh_stat=$(awk -F'\t' '
    NR > 1 { c++; ms[c] = $4; if ($3 != 0) f++ }
    END {
        if (c == 0) { print "0\t0\t0\t0"; exit }
        cold = ms[1]; n = 0
        for (i = 2; i <= c; i++) w[++n] = ms[i]
        for (i = 1; i <= n; i++)
            for (j = i + 1; j <= n; j++)
                if (w[j] < w[i]) { t = w[i]; w[i] = w[j]; w[j] = t }
        med = (n == 0) ? 0 : ((n % 2) ? w[int((n+1)/2)] : (w[n/2] + w[n/2+1]) / 2)
        printf "%d\t%d\t%d\t%d\n", cold, med, c, f+0
    }' "$GH_CSV")
    gh_cold=$(printf '%s' "$gh_stat" | cut -f1)
    gh_med=$(printf '%s' "$gh_stat" | cut -f2)
    gh_cnt=$(printf '%s' "$gh_stat" | cut -f3)
    gh_fail=$(printf '%s' "$gh_stat" | cut -f4)
    {
        printf '%s\n' ""
        printf '## github clone（github 缓存后端 git-cdn）\n'
        printf '%s\n' ""
        printf -- '- 仓库: `%s`\n' "$GH_REPO"
        printf -- '- URL 展开: `%s`\n' "${gh_expanded:-<空>}"
        printf -- '- 冷启动: %s ms；热路径中位数: %s ms（共 %s 次%s）\n' \
            "$gh_cold" "$gh_med" "$gh_cnt" "$([ "$gh_fail" -gt 0 ] && printf '，失败 %s 次' "$gh_fail")"
        printf '%s\n' ""
        printf '%s\n' "| 次数 | exit | 耗时 | 大小 | 吞吐 |"
        printf '%s\n' "|---|---|---|---|---|"
        awk -F'\t' 'NR>1{printf "| %s | %s | %s ms | %d MB | %s MB/s |\n", $1, $3, $4, $5/1048576, $6}' "$GH_CSV"
    } >> "$SUMMARY"
fi

if [ -s "$CONC_TBL" ] && [ "$(wc -l < "$CONC_TBL")" -gt 1 ]; then
    {
        printf '%s\n' ""
        printf '## gitcode clone 并发\n'
        printf '%s\n' ""
        printf '%s\n' "同一仓库同时 clone N 份（各自独立目录），实际耗时为整组起止时间。"
        printf '%s\n' ""
        printf '%s\n' "| 并发度 | 成功 | 失败 | 实际耗时 | 单次中位数 | 最小 | 最大 | 聚合吞吐 |"
        printf '%s\n' "|---|---|---|---|---|---|---|---|"
        awk -F'\t' 'NR>1{printf "| %s | %s | %s | %s ms | %s ms | %s ms | %s ms | %s MB/s |\n", $1,$2,$3,$4,$5,$6,$7,$8}' "$CONC_TBL"
    } >> "$SUMMARY"
fi

if [ -s "$LFS_CSV" ] && [ "$(awk 'END{print NR-1}' "$LFS_CSV")" -gt 0 ]; then
    lfs_bad=$(awk -F'\t' 'NR>1 && $7 != "ok"' "$LFS_CSV" | wc -l)
    {
        printf '\n## LFS 下载校验\n\n'
        printf -- '- 判据：下载文件的 sha256 必须等于 pointer 里的 oid，大小必须等于 pointer 的 size\n'
        printf -- '- Age 为该次拉取响应里最大的 Age 值（>0 说明来自 squid 缓存，仅留证不判红）\n\n'
        printf '| 版本 | 文件 | pointer oid | 实测 sha256 | 字节 | 期望 size | 判定 | pull 耗时 | Age |\n'
        printf '|---|---|---|---|---|---|---|---|---|\n'
        awk -F'\t' 'NR>1{printf "| %s | %s | %s | %s | %s | %s | %s | %s ms | %s |\n",$1,$2,$3,$4,$5,$6,$7,$8,$9}' "$LFS_CSV"
        if [ "$lfs_bad" -gt 0 ]; then
            printf '\n❌ 有 %s 个文件校验失败\n' "$lfs_bad"
        else
            printf '\n✅ 全部文件 sha256 与 pointer oid 一致\n'
        fi
    } >> "$SUMMARY"
fi

cat "$SUMMARY"
log "== 汇总（$CSV）=="
printf '%s\n' "iter	mode	exit	ms	bytes	MBps" >&2
awk -F'\t' 'NR>1{printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1,$2,$3,$4,$5,$6}' "$CSV" >&2

if [ "$fails" -gt 0 ]; then
    log "❌ 有 $fails 次 clone 失败（明细见 $OUT/clone-*.err）"
    exit 1
fi
log "完成。结果目录: $OUT"
