#!/usr/bin/env bash
# =============================================================================
# repro-ghproxy-clone-compare.sh —— git-cdn vs gh-proxy 直连 clone 对照
#
# 背景：git-cdn 的回源上游就是 gh-proxy（pod 内 GITSERVER_UPSTREAM =
#   https://gh-proxy.test.osinfra.cn/https://github.com/），所以「客户端不经
#   git-cdn、自己拿 gh-proxy 克隆」是判断 git-cdn 到底有没有收益的最直接对照。
#
# 被测形态与 CI 一致（默认 pytorch/pytorch）：
#   ① 主仓 git clone --depth 1
#   ② 全量子模块 git submodule update --init --recursive --depth 1 --jobs 8
#      （.gitmodules 里是绝对 github.com 地址，靠 insteadOf 重写到各自的基址）
#   两条腿在同 pod 上先后来一遍，记录主仓 / 子模块 / 总计耗时与 HEAD。
#
#   proxy  git clone --depth 1 https://gh-proxy.test.osinfra.cn/https://github.com/<repo>.git
#   cdn    git clone --depth 1 http://git-cdn-service.git-cdn.svc.cluster.local:8000/<repo>.git
#
# 判定：
#   - 两边 HEAD 或子模块个数不一致 → FAIL（内容正确性）
#   - cdn 克隆失败 → FAIL；proxy 克隆失败 → WARN（基线不可用，仅记录）
#   - cdn 总耗时 / proxy 总耗时 > RATIO_WARN（默认 2.0）→ WARN（缓存没体现收益）
#
# 口径说明：
#   * 两条路径落点不同：gh-proxy 在集群外，runner 的 HTTP(S)_PROXY 指向 squid，
#     流量会被 MITM 且可能命中 squid 缓存；git-cdn 是 .svc.cluster.local 直连。
#     所以结论是「CI 客户端的真实体验差」，不是纯链路带宽差。
#   * 总耗时包含主仓 + 子模块两部分（note 里给出拆分）。
#
# 可覆盖：GIT_CDN_BASE / GHPROXY_BASE / REPOS / ROUNDS / DEPTH / SUBMODULES
#         / SUB_JOBS / CLONE_TIMEOUT / SUB_TIMEOUT / RATIO_WARN / RESULTS / WORK
# 退出码：0=PASS；1=FAIL；2=SKIP（git-cdn 与 gh-proxy 都不可达）
# =============================================================================
set -uo pipefail

GIT_CDN_BASE="${GIT_CDN_BASE:-http://git-cdn-service.git-cdn.svc.cluster.local:8000/}"
GHPROXY_BASE="${GHPROXY_BASE:-https://gh-proxy.test.osinfra.cn/https://github.com/}"
CDN_BASE="${GIT_CDN_BASE%/}"
PROXY_BASE="${GHPROXY_BASE%/}"

# 默认仓：pytorch（主仓 + 61 个递归子模块实例，CI 里最痛的那条路径）
DEFAULT_REPOS="pytorch/pytorch"
REPOS="${REPOS:-$DEFAULT_REPOS}"
REPOS="${REPOS//,/ }"
REPOS=$(printf '%s\n' "$REPOS" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
ROUNDS="${ROUNDS:-1}"                     # 轮数；2 = 追加一轮冷/热对照
DEPTH="${DEPTH:-1}"                       # 0 = 全量克隆
SUBMODULES="${SUBMODULES:-1}"             # 1 = 全量子模块；0 = 只测主仓
SUB_JOBS="${SUB_JOBS:-8}"                 # 子模块并发数
CLONE_TIMEOUT="${CLONE_TIMEOUT:-1800}"    # 单次主仓克隆上限秒
SUB_TIMEOUT="${SUB_TIMEOUT:-3600}"        # 单腿子模块总上限秒
RATIO_WARN="${RATIO_WARN:-2.0}"           # cdn/proxy 超过该倍数记 WARN
RESULTS="${RESULTS:-${RESULTS_DIR:-/tmp/test-squid-results}/ghproxy-compare}"
WORK="${WORK:-/tmp/ghproxy-compare}"
mkdir -p "$RESULTS"
rm -rf "$WORK"; mkdir -p "$WORK"

export GIT_TERMINAL_PROMPT=0
TSV="$RESULTS/ghproxy-compare.tsv"   # repo round mode ms size_mb head sub verdict note
: >"$TSV"
FAIL=0; WARN=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }
now_ms() { date +%s%3N; }
rec() {  # rec <repo> <round> <mode> <ms> <size_mb> <head> <sub> <verdict> <note>
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >>"$TSV"
}

# ---------------------------------------------------------------------------
# 0. 可达性：两边都不可达才 SKIP（单边不可达留给逐仓用例判定）
# ---------------------------------------------------------------------------
first_repo="${REPOS%% *}"
probe() { timeout 60 git ls-remote --heads "$1" >/dev/null 2>&1; }
cdn_ok=0; proxy_ok=0
probe "$CDN_BASE/$first_repo.git" && cdn_ok=1
probe "$PROXY_BASE/$first_repo.git" && proxy_ok=1
if [ "$cdn_ok" = 0 ] && [ "$proxy_ok" = 0 ]; then
    log "⚠️ git-cdn 与 gh-proxy 都不可达，SKIP"
    rec - - - 0 - - - SKIP "cdn=$CDN_BASE proxy=$PROXY_BASE 均不可达"
    echo "SKIP" >"$RESULTS/verdict"
    exit 2
fi
log "可达性：git-cdn=$cdn_ok gh-proxy=$proxy_ok；仓库：$REPOS；轮数=$ROUNDS depth=$DEPTH 子模块=$SUBMODULES"

# ---------------------------------------------------------------------------
# 1. 逐仓逐轮：同一条腿内先主仓再子模块，两条腿顺序按轮次交替
# ---------------------------------------------------------------------------
for repo in $REPOS; do
    slug="${repo//\//_}"
    for r in $(seq 1 "$ROUNDS"); do
        if [ $((r % 2)) -eq 1 ]; then order="proxy cdn"; else order="cdn proxy"; fi

        # 每条腿的结果：<mode>_ms 总耗时 / <mode>_main 主仓 / <mode>_sub 子模块
        for m in proxy cdn; do
            eval "${m}_ms=''"; eval "${m}_main=''"; eval "${m}_sub=''"
            eval "${m}_head=''"; eval "${m}_nsub=''"; eval "${m}_size=''"; eval "${m}_rc=1"
        done

        for mode in $order; do
            case "$mode" in
                proxy) base="$PROXY_BASE" ;;
                cdn)   base="$CDN_BASE" ;;
            esac
            url="$base/$repo.git"
            dir="$WORK/$slug/r$r/$mode"
            rm -rf "$dir"; mkdir -p "$(dirname "$dir")"

            args=(clone --quiet)
            [ "$DEPTH" != "0" ] && args+=(--depth "$DEPTH")

            log "[$repo r$r] $mode 主仓克隆：$url"
            t0=$(now_ms)
            timeout "$CLONE_TIMEOUT" git -c protocol.version=2 "${args[@]}" \
                "$url" "$dir" >"$WORK/$slug.r$r.$mode.log" 2>&1
            rc=$?
            ms_main=$(( $(now_ms) - t0 ))
            ms_sub=0; nsub=0

            if [ "$rc" = 0 ] && [ "$SUBMODULES" = 1 ]; then
                # 子模块 URL 是绝对 github.com 地址：非 github 基址必须写 insteadOf，
                # 否则子模块会绕过 git-cdn / gh-proxy 直接打 github.com（口径就废了）
                case "$base" in
                    https://github.com*) ;;
                    *) git -C "$dir" config "url.${base}/.insteadOf" "https://github.com/" ;;
                esac
                log "[$repo r$r] $mode 子模块（--recursive --depth $DEPTH --jobs $SUB_JOBS）"
                t1=$(now_ms)
                timeout "$SUB_TIMEOUT" git -C "$dir" submodule update \
                    --init --recursive --depth 1 --jobs "$SUB_JOBS" \
                    >>"$WORK/$slug.r$r.$mode.log" 2>&1
                rc_sub=$?
                ms_sub=$(( $(now_ms) - t1 ))
                nsub=$(git -C "$dir" submodule status --recursive 2>/dev/null | wc -l)
                [ "$rc_sub" != 0 ] && rc=$rc_sub
            fi

            ms=$(( ms_main + ms_sub ))
            head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
            size=$(du -sm "$dir" 2>/dev/null | cut -f1 || echo 0)

            eval "${mode}_ms='$ms'"; eval "${mode}_main='$ms_main'"; eval "${mode}_sub='$ms_sub'"
            eval "${mode}_head='$head'"; eval "${mode}_nsub='$nsub'"
            eval "${mode}_size='${size:-0}'"; eval "${mode}_rc=$rc"

            if [ "$rc" = 0 ]; then
                rec "$repo" "$r" "$mode" "$ms" "${size:-0}" "${head:0:12}" "$nsub" PASS \
                    "main=${ms_main}ms sub=${ms_sub}ms url=$url"
            elif [ "$mode" = proxy ]; then
                # 基线失败不判红：只说明这一轮没法比较
                rec "$repo" "$r" "$mode" "$ms" "${size:-0}" - "$nsub" WARN \
                    "基线克隆失败 rc=$rc：$(tail -c 200 "$WORK/$slug.r$r.$mode.log" | tr '\n' ' ')"
                WARN=$((WARN + 1))
            else
                rec "$repo" "$r" "$mode" "$ms" "${size:-0}" - "$nsub" FAIL \
                    "克隆失败 rc=$rc：$(tail -c 200 "$WORK/$slug.r$r.$mode.log" | tr '\n' ' ')"
                FAIL=$((FAIL + 1))
            fi
        done

        # --- 比对：内容一致性（HEAD + 子模块个数）与相对耗时 ---
        if [ "$proxy_rc" = 0 ] && [ "$cdn_rc" = 0 ]; then
            if [ -n "$cdn_head" ] && [ "$cdn_head" = "$proxy_head" ] && [ "$cdn_nsub" = "$proxy_nsub" ]; then
                ratio=$(awk -v a="$cdn_ms" -v b="$proxy_ms" 'BEGIN { if (b > 0) printf "%.2f", a / b; else print "0" }')
                over=$(awk -v x="$ratio" -v t="$RATIO_WARN" 'BEGIN { print (x > t) ? 1 : 0 }')
                note=$(printf 'cdn: main=%sms sub=%sms total=%sms/%sMB; proxy: main=%sms sub=%sms total=%sms/%sMB; submodules=%s ratio=%sx' \
                    "$cdn_main" "$cdn_sub" "$cdn_ms" "$cdn_size" \
                    "$proxy_main" "$proxy_sub" "$proxy_ms" "$proxy_size" \
                    "$cdn_nsub" "$ratio")
                if [ "$over" = 1 ]; then
                    rec "$repo" "$r" compare "$cdn_ms" "$cdn_size" "${cdn_head:0:12}" "$cdn_nsub" WARN \
                        "$note（cdn 慢于 gh-proxy ${RATIO_WARN} 倍以上，缓存未体现收益）"
                    WARN=$((WARN + 1))
                else
                    rec "$repo" "$r" compare "$cdn_ms" "$cdn_size" "${cdn_head:0:12}" "$cdn_nsub" PASS "$note"
                fi
            else
                rec "$repo" "$r" compare "$cdn_ms" "$cdn_size" "${cdn_head:0:12}" "$cdn_nsub" FAIL \
                    "内容不一致：cdn HEAD=${cdn_head:0:12}/sub=$cdn_nsub proxy HEAD=${proxy_head:0:12}/sub=$proxy_nsub"
                FAIL=$((FAIL + 1))
            fi
        fi
    done
done

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
log "===== 汇总：FAIL=$FAIL WARN=$WARN ====="
awk -F'\t' '{printf "  %-24s r%-2s %-8s %9sms %6sMB %-12s sub=%-4s %-5s %s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9}' "$TSV"
echo "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)" >"$RESULTS/verdict"
[ "$FAIL" -eq 0 ]
