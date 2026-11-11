#!/usr/bin/env bash
# =============================================================================
# repro-ghproxy-clone-compare.sh —— git-cdn vs gh-proxy 直连 clone 对照
#
# 背景：git-cdn 的回源上游就是 gh-proxy（pod 内 GITSERVER_UPSTREAM =
#   https://gh-proxy.test.osinfra.cn/https://github.com/），所以「客户端不经
#   git-cdn、自己拿 gh-proxy 克隆」是判断 git-cdn 到底有没有收益的最直接对照。
#
# 每个仓库每轮做两次同样的克隆（顺序按轮次交替，抵消「谁先跑谁先暖」的偏差）：
#   proxy  git clone --depth 1 https://gh-proxy.test.osinfra.cn/https://github.com/<repo>.git
#   cdn    git clone --depth 1 http://git-cdn-service.git-cdn.svc.cluster.local:8000/<repo>.git
#
# 记录：耗时(ms) / .git 体积(MB) / HEAD SHA / 结论 / 备注
#
# 判定：
#   - 两边 HEAD 必须一致（内容正确性）→ 不一致 FAIL
#   - cdn 克隆失败 → FAIL；proxy 克隆失败 → WARN（基线不可用，仅记录）
#   - cdn 耗时 / proxy 耗时 > RATIO_WARN（默认 2.0）→ WARN（缓存没体现收益）
#
# 口径说明：
#   * 两条路径落点不同：gh-proxy 在集群外，runner 的 HTTP(S)_PROXY 指向 squid，
#     流量会被 MITM 且可能命中 squid 缓存；git-cdn 是 .svc.cluster.local 直连。
#     所以结论是「CI 客户端的真实体验差」，不是纯链路带宽差。
#   * 默认都带 --depth 1（CI checkout 常见形态）；DEPTH=0 改全量克隆。
#   * 小仓库耗时只有几百毫秒，抖动可能盖过收益，比值只记 WARN 不判红。
#
# 可覆盖：GIT_CDN_BASE / GHPROXY_BASE / REPOS / ROUNDS / DEPTH / CLONE_TIMEOUT
#         / RATIO_WARN / RESULTS / WORK
# 退出码：0=PASS；1=FAIL；2=SKIP（git-cdn 与 gh-proxy 都不可达）
# =============================================================================
set -uo pipefail

GIT_CDN_BASE="${GIT_CDN_BASE:-http://git-cdn-service.git-cdn.svc.cluster.local:8000/}"
GHPROXY_BASE="${GHPROXY_BASE:-https://gh-proxy.test.osinfra.cn/https://github.com/}"
CDN_BASE="${GIT_CDN_BASE%/}"
PROXY_BASE="${GHPROXY_BASE%/}"

# 默认仓：CI 主体仓 + 中等体积依赖仓（几秒级，适合日常回归）
DEFAULT_REPOS="vllm-project/vllm-ascend triton-lang/triton"
REPOS="${REPOS:-$DEFAULT_REPOS}"
REPOS="${REPOS//,/ }"
REPOS=$(printf '%s\n' "$REPOS" | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//')
ROUNDS="${ROUNDS:-1}"                     # 轮数；2 = 追加一轮冷/热对照
DEPTH="${DEPTH:-1}"                       # 0 = 全量克隆
CLONE_TIMEOUT="${CLONE_TIMEOUT:-600}"     # 单次克隆上限秒
RATIO_WARN="${RATIO_WARN:-2.0}"           # cdn/proxy 超过该倍数记 WARN
RESULTS="${RESULTS:-${RESULTS_DIR:-/tmp/test-squid-results}/ghproxy-compare}"
WORK="${WORK:-/tmp/ghproxy-compare}"
mkdir -p "$RESULTS"
rm -rf "$WORK"; mkdir -p "$WORK"

export GIT_TERMINAL_PROMPT=0
TSV="$RESULTS/ghproxy-compare.tsv"   # repo round mode ms size_mb head verdict note
: >"$TSV"
FAIL=0; WARN=0

log() { echo "[$(date '+%H:%M:%S')] $*"; }
now_ms() { date +%s%3N; }
rec() {  # rec <repo> <round> <mode> <ms> <size_mb> <head> <verdict> <note>
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >>"$TSV"
}

# ---------------------------------------------------------------------------
# 0. 可达性：两边都不可达才 SKIP（单边不可达留给逐仓用例判定）
# ---------------------------------------------------------------------------
probe() { timeout 30 git ls-remote --heads "$1" >/dev/null 2>&1; }
cdn_ok=0; proxy_ok=0
probe "$CDN_BASE/${REPOS%% *}.git" && cdn_ok=1
probe "$PROXY_BASE/${REPOS%% *}.git" && proxy_ok=1
if [ "$cdn_ok" = 0 ] && [ "$proxy_ok" = 0 ]; then
    log "⚠️ git-cdn 与 gh-proxy 都不可达，SKIP"
    rec - - - 0 - - SKIP "cdn=$CDN_BASE proxy=$PROXY_BASE 均不可达"
    echo "SKIP" >"$RESULTS/verdict"
    exit 2
fi
log "可达性：git-cdn=$cdn_ok gh-proxy=$proxy_ok；仓库：$REPOS；轮数=$ROUNDS depth=$DEPTH"

# ---------------------------------------------------------------------------
# 1. 逐仓逐轮：proxy / cdn 各克隆一次，再比对 HEAD 与耗时
# ---------------------------------------------------------------------------
for repo in $REPOS; do
    for r in $(seq 1 "$ROUNDS"); do
        # 交替顺序：奇数轮先 proxy，偶数轮先 cdn
        if [ $((r % 2)) -eq 1 ]; then order="proxy cdn"; else order="cdn proxy"; fi

        ms_proxy=""; head_proxy=""; size_proxy=""; rc_proxy=1
        ms_cdn="";   head_cdn="";   size_cdn="";   rc_cdn=1

        for mode in $order; do
            case "$mode" in
                proxy) url="$PROXY_BASE/$repo.git" ;;
                cdn)   url="$CDN_BASE/$repo.git" ;;
            esac
            dir="$WORK/${repo//\//_}/r$r/$mode"
            rm -rf "$dir"; mkdir -p "$(dirname "$dir")"

            args=(clone --quiet)
            [ "$DEPTH" != "0" ] && args+=(--depth "$DEPTH")

            t0=$(now_ms)
            timeout "$CLONE_TIMEOUT" git -c protocol.version=2 "${args[@]}" \
                "$url" "$dir" >"$WORK/${repo//\//_}.r$r.$mode.log" 2>&1
            rc=$?
            ms=$(( $(now_ms) - t0 ))
            head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
            size=$(du -sm "$dir/.git" 2>/dev/null | cut -f1 || echo 0)

            case "$mode" in
                proxy) ms_proxy="$ms"; head_proxy="$head"; size_proxy="$size"; rc_proxy=$rc ;;
                cdn)   ms_cdn="$ms";   head_cdn="$head";   size_cdn="$size";   rc_cdn=$rc ;;
            esac

            if [ "$rc" = 0 ]; then
                rec "$repo" "$r" "$mode" "$ms" "${size:-0}" "${head:0:12}" PASS "url=$url"
            elif [ "$mode" = proxy ]; then
                # 基线失败不判红：只说明这一轮没法比较
                rec "$repo" "$r" "$mode" "$ms" "${size:-0}" - WARN \
                    "基线克隆失败 rc=$rc：$(head -c 100 "$WORK/${repo//\//_}.r$r.$mode.log" | tr '\n' ' ')"
                WARN=$((WARN + 1))
            else
                rec "$repo" "$r" "$mode" "$ms" "${size:-0}" - FAIL \
                    "克隆失败 rc=$rc：$(head -c 100 "$WORK/${repo//\//_}.r$r.$mode.log" | tr '\n' ' ')"
                FAIL=$((FAIL + 1))
            fi
        done

        # --- 比对：内容一致性 + 相对耗时 ---
        if [ "$rc_cdn" = 0 ] && [ "$rc_proxy" = 0 ]; then
            if [ -n "$head_cdn" ] && [ "$head_cdn" = "$head_proxy" ]; then
                ratio=$(awk -v a="$ms_cdn" -v b="$ms_proxy" 'BEGIN { if (b > 0) printf "%.2f", a / b; else print "0" }')
                over=$(awk -v x="$ratio" -v t="$RATIO_WARN" 'BEGIN { print (x > t) ? 1 : 0 }')
                note="cdn=${ms_cdn}ms/${size_cdn}MB proxy=${ms_proxy}ms/${size_proxy}MB ratio=${ratio}x"
                if [ "$over" = 1 ]; then
                    rec "$repo" "$r" compare "$ms_cdn" "$size_cdn" "${head_cdn:0:12}" WARN \
                        "$note（cdn 慢于 gh-proxy ${RATIO_WARN} 倍以上，缓存未体现收益）"
                    WARN=$((WARN + 1))
                else
                    rec "$repo" "$r" compare "$ms_cdn" "$size_cdn" "${head_cdn:0:12}" PASS "$note"
                fi
            else
                rec "$repo" "$r" compare "$ms_cdn" "$size_cdn" "${head_cdn:0:12}" FAIL \
                    "HEAD 不一致：cdn=${head_cdn:0:12} proxy=${head_proxy:0:12}（内容正确性问题）"
                FAIL=$((FAIL + 1))
            fi
        fi
    done
done

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
log "===== 汇总：FAIL=$FAIL WARN=$WARN ====="
awk -F'\t' '{printf "  %-32s r%-2s %-8s %8sms %6sMB %-12s %-5s %s\n", $1,$2,$3,$4,$5,$6,$7,$8}' "$TSV"
echo "$([ "$FAIL" -eq 0 ] && echo PASS || echo FAIL)" >"$RESULTS/verdict"
[ "$FAIL" -eq 0 ]
