#!/usr/bin/env bash
# =============================================================================
# repro-gitcdn-refspec.sh —— git-cdn refspec 白名单 / 按 SHA 回源单飞 / 失败透传
#
# 对应上游：
#   https://github.com/opensourceways/git-cache-http-server/pull/30
#     - INCLUDE_REFS 默认只拉 refs/heads/*,refs/tags/*，不再同步 refs/pull/*
#     - 按 SHA 回源单飞（git_cdn_fetch_sha_total / git_cdn_fetch_sha_wait_seconds）
#     - 回源失败透传 git stderr，不再无限等待到 CI 超时
#   https://github.com/opensourceways/git-cache-http-server/pull/32
#     - 移除 lowSpeedLimit/Time 命令行注入，低速保护交回部署 gitconfig
#
# 判定（三个阶段，任一 FAIL → 退出码 1）：
#   ① refspec：目标仓库 refs/heads/* 可读；refs/pull/* 只记录数量（git-cdn 的
#      info/refs 由上游代理，仍会通告 pull refs，这是预期行为，不判红）
#   ② SHA 回源：从 refs/pull/*/head 按 PR 号从大到小取最近的候选 SHA，
#      两路并发 `git fetch --depth 1 <sha>` 都成功；并按
#      git_cdn_fetch_sha_total{result="leader"} 增量断言单飞：
#        两路并发只应有 1 个 leader（+1 = PASS）；
#        +0 说明该 SHA 已在 mirror（没触发回源），自动换下一个候选；
#        ≥2 判红（两路各自回源，单飞失效）。候选全部已缓存时记 SKIP，
#        提示先 purge 缓存（test-squid/purge-gitcdn-cache.sh）再测。
#   ③ 失败透传：两路并发取同一个不存在的 SHA，两路都必须在 180s 内非零退出、
#      stderr 有 git 错误，且不能出现 `curl 56` / `chunked-encoded stream`
#      （错误流未收尾，issue #33）；同时记录 leader/waiter/failed 增量作证据
#
# 冷缓存前置：本脚本不清理后端缓存。要测真正的冷启动，需先在 git-cdn Pod 内
# 删除 /workdir 下对应仓库目录，否则 ① 的 refspec 状态与 ② 的增量都会受既有
# 缓存影响（脚本会按实际结果判定并在 detail 里写明）。
#
# 用法：
#   bash test-squid/repro-gitcdn-refspec.sh
#
# 可覆盖：
#   GIT_CDN_BASE  git-cdn 基址（默认 gy-006 的 git-cdn-gitcode Service）
#   REPO          目标仓库（默认 ascend/pytorch，按 gitcode 路径）
#   RESULTS       结果目录（默认 $RESULTS_DIR/gitcdn-refspec）
#
# 退出码：0=PASS；1=FAIL；2=SKIP（git-cdn 不可达）
# =============================================================================
set -uo pipefail

GIT_CDN_BASE="${GIT_CDN_BASE:-http://git-cdn-service.git-cdn-gitcode.svc.cluster.local:8000/}"
REPO="${REPO:-ascend/pytorch}"
REMOTE="${GIT_CDN_BASE%/}/${REPO}.git"
results="${RESULTS:-${RESULTS_DIR:-/tmp/test-squid-results}/gitcdn-refspec}"
mkdir -p "$results"
TSV="$results/refspec.tsv"
printf 'phase\tstatus\tdetail\tduration_ms\n' >"$TSV"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
record() {  # record <phase> <PASS|FAIL|WARN|SKIP> <detail> <ms>
    printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" | tee -a "$TSV"
}
now_ms() { date +%s%3N; }
fail=0

log "git-cdn=$REMOTE"

# ---- 阶段 0：可达性（不可达 → SKIP，不误红）----------------------------------
# 用 git 自身探测：git-cdn 的 info/refs 对 curl 会回 308，git 会跟随重定向。
if ! GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote "$REMOTE" HEAD \
    >"$results/reach.out" 2>"$results/reach.err"; then
    log "⚠️ git-cdn 不可达（git ls-remote 失败，见 reach.err）——本集群未部署 git-cdn-gitcode，记 SKIP"
    exit 2
fi

# ---- 阶段 1：refspec 白名单 ---------------------------------------------------
t0=$(now_ms)
heads=$(GIT_TERMINAL_PROMPT=0 timeout 120 git ls-remote "$REMOTE" 'refs/heads/*' \
    2>"$results/lsremote-heads.err")
rc=$?
ms=$(( $(now_ms) - t0 ))
if [ $rc -ne 0 ] || [ -z "$heads" ]; then
    record refspec-heads FAIL "rc=$rc 未取到 refs/heads（见 lsremote-heads.err）" "$ms"
    fail=1
else
    record refspec-heads PASS "$(printf '%s\n' "$heads" | wc -l) 个 refs/heads" "$ms"
fi

t0=$(now_ms)
pulls=$(GIT_TERMINAL_PROMPT=0 timeout 120 git ls-remote "$REMOTE" 'refs/pull/*/head' \
    2>"$results/lsremote-pulls.err")
rc=$?
ms=$(( $(now_ms) - t0 ))
if [ $rc -ne 0 ]; then
    record refspec-pulls INFO "ls-remote refs/pull/*/head rc=$rc（仅记录）" "$ms"
else
    # info/refs 由 git-cdn 直接代理上游，pull refs 仍会通告，属预期，不判红
    record refspec-pulls INFO "refs/pull/*/head $(printf '%s\n' "$pulls" | grep -c . ) 条（上游代理通告）" "$ms"
fi

# ---- 选候选 PR-only SHA（mirror 通常不含；按 PR 号取最近的几个）---------------
mapfile -t candidates < <(
    printf '%s\n' "$pulls" |
        awk 'NF==2 {n=$2; sub(/^refs\/pull\//,"",n); sub(/\/head$/,"",n);
                    if (n ~ /^[0-9]+$/) print n, $1}' |
        sort -k1,1nr | awk '!seen[$2]++ {print $2}' | head -n 5
)
if [ "${#candidates[@]}" -eq 0 ]; then
    record sha-pick SKIP "没有 refs/pull/*/head 可取" 0
else
    # ---- 阶段 2：两路并发按 SHA fetch（单飞）--------------------------------
    # git_cdn_fetch_sha_total 带 result 标签（leader/waiter/skipped_present/failed），
    # 只有 leader 代表一次真实回源；单飞判定只看 leader 增量，且必须先保证该 SHA
    # 不在 mirror 里，否则增量恒为 0、用例失去意义。
    metric_result() {  # metric_result <leader|waiter|skipped_present|failed>
        local body n
        # /metrics 偶发连不上（fetch 刚结束时的窗口），最多试 3 次；失败原因留档
        for n in 1 2 3; do
            if body=$(curl -sS --max-time 8 "${GIT_CDN_BASE%/}/metrics" 2>>"$results/metrics.err"); then
                printf '%s\n' "$body" |
                    awk -v r="result=\"$1\"" \
                        '$1 ~ /^git_cdn_fetch_sha_total\{/ && index($0, r) {s+=$2} END{print s+0}'
                return 0
            fi
            [ "$n" -lt 3 ] && sleep 2
        done
        return 1
    }

    decided=0
    for sha in "${candidates[@]}"; do
        log "候选 SHA=$sha（refs/pull/*/head）"
        before=$(metric_result leader) || before=""

        d1=$(mktemp -d) && d2=$(mktemp -d)
        git -C "$d1" init -q && git -C "$d2" init -q
        t0=$(now_ms)
        GIT_TERMINAL_PROMPT=0 timeout 600 git -C "$d1" fetch --depth 1 "$REMOTE" "$sha" \
            >"$results/sha-fetch-1.out" 2>"$results/sha-fetch-1.err" &
        p1=$!
        GIT_TERMINAL_PROMPT=0 timeout 600 git -C "$d2" fetch --depth 1 "$REMOTE" "$sha" \
            >"$results/sha-fetch-2.out" 2>"$results/sha-fetch-2.err" &
        p2=$!
        wait $p1; rc1=$?
        wait $p2; rc2=$?
        ms=$(( $(now_ms) - t0 ))
        after=$(metric_result leader) || after=""

        if [ $rc1 -ne 0 ] || [ $rc2 -ne 0 ]; then
            # `not our ref` = 上游本身不支持按这个 SHA 回源（常见于已关闭/未合并的
            # PR head），不是 git-cdn 的缺陷；换下一个候选，别判红。
            if grep -q 'not our ref' "$results/sha-fetch-1.err" "$results/sha-fetch-2.err" 2>/dev/null; then
                record sha-pick INFO "候选 ${sha:0:9} 上游不可按 SHA 回源（not our ref），换下一个" "$ms"
                rm -rf "$d1" "$d2"
                continue
            fi
            record sha-fetch FAIL "rc1=$rc1 rc2=$rc2（${sha:0:9}，见 sha-fetch-*.err）" "$ms"
            fail=1
            decided=1
            rm -rf "$d1" "$d2"
            break
        fi
        got1=$(git -C "$d1" rev-parse FETCH_HEAD 2>/dev/null)
        got2=$(git -C "$d2" rev-parse FETCH_HEAD 2>/dev/null)
        rm -rf "$d1" "$d2"
        if [ "$got1" != "$sha" ] || [ "$got2" != "$sha" ]; then
            record sha-fetch FAIL "FETCH_HEAD 不符：${got1:0:9}/${got2:0:9}" "$ms"
            fail=1
            decided=1
            break
        fi
        record sha-fetch PASS "两路均取到 ${sha:0:9}（${ms}ms）" "$ms"

        if [ -z "$before" ] || [ -z "$after" ]; then
            record sha-singleflight WARN "/metrics 不可达，未取到 git_cdn_fetch_sha_total{result=\"leader\"}" 0
            decided=1  # fetch 本身已成功，不再换候选
            break
        fi
        delta=$(( after - before ))
        if [ "$delta" -eq 1 ]; then
            record sha-singleflight PASS "回源 leader +1（两路并发合并为一次回源）" 0
            decided=1
            break
        elif [ "$delta" -ge 2 ]; then
            record sha-singleflight FAIL "回源 leader +$delta（>1，两路各自回源，单飞未生效）" 0
            fail=1
            decided=1
            break
        fi
        log "  ${sha:0:9} 已在 mirror（leader +0，未触发回源），换下一个候选"
    done
    if [ "$decided" -eq 0 ]; then
        record sha-singleflight SKIP \
            "候选 SHA 均未触发回源（已在 mirror 或上游不可按 SHA 回源）；先 purge 仓库缓存再测" 0
    fi

    # ---- 阶段 3：坏 SHA 的并发失败路径（leader 失败 → waiter 不能挂死）--------
    # 两路并发打同一个不存在的 SHA。实测 gitcode 对这种 SHA 返回的是
    #   fatal: remote-curl: bad line length character: <CH.
    #   fatal: the remote end hung up unexpectedly
    # 不匹配 is_permanent_fetch_error（只认 not our ref / unadvertised object），
    # 所以每路都会走完整 0.5+1+2+4+8=15.5s 退避后抛 HTTP 500（failed +1），
    # 而不是转 upload-pack 回 "not our ref"。
    # 断言只看客户端：两路都要拿到干净的 git fatal，不能是 curl 56 / chunked
    # stream 未收尾（issue opensourceways/git-cache-http-server#33）。
    bad="0000000000000000000000000000000000000001"
    b_leader=$(metric_result leader) || b_leader=""
    b_failed=$(metric_result failed) || b_failed=""
    b_waiter=$(metric_result waiter) || b_waiter=""

    d3=$(mktemp -d) && d4=$(mktemp -d)
    git -C "$d3" init -q && git -C "$d4" init -q
    bad_dirs=("$d3" "$d4")
    t0=$(now_ms)
    for i in 1 2; do
        (
            s=$(now_ms)
            GIT_TERMINAL_PROMPT=0 timeout 180 git -C "${bad_dirs[$(( i - 1 ))]}" fetch --depth 1 "$REMOTE" "$bad" \
                >"$results/sha-bad-$i.out" 2>"$results/sha-bad-$i.err"
            echo "$? $(( $(now_ms) - s ))" >"$results/sha-bad-$i.stat"
        ) &
    done
    wait
    total=$(( $(now_ms) - t0 ))
    a_leader=$(metric_result leader) || a_leader=""
    a_failed=$(metric_result failed) || a_failed=""
    a_waiter=$(metric_result waiter) || a_waiter=""

    check_bad() {  # check_bad <第几路> <rc> <耗时ms> <stderr 文件>
        local n=$1 rc=$2 rms=$3 err=$4
        if [ "$rc" -eq 124 ]; then
            record sha-error FAIL "第 $n 路 180s 超时未返回（回源卡死未透传）" "$rms"
            fail=1
        elif [ "$rc" -eq 0 ]; then
            record sha-error FAIL "第 $n 路 rc=0（坏 SHA 竟然成功）" "$rms"
            fail=1
        elif [ ! -s "$err" ]; then
            record sha-error FAIL "第 $n 路 rc=$rc 但无 git 错误信息（失败未透传）" "$rms"
            fail=1
        elif grep -qiE 'chunked-encoded stream|curl 56' "$err"; then
            record sha-error FAIL \
                "第 $n 路 rc=$rc 错误流未正常收尾（$(head -n 1 "$err" | cut -c1-70)）" "$rms"
            fail=1
        else
            record sha-error PASS "第 $n 路 rc=$rc，$(head -n 1 "$err" | cut -c1-70)" "$rms"
        fi
    }
    for i in 1 2; do
        read -r bad_rc bad_ms <"$results/sha-bad-$i.stat"
        check_bad "$i" "$bad_rc" "$bad_ms" "$results/sha-bad-$i.err"
    done

    # 失败路径的单飞只留证据不判红：同 worker 内 waiter 复用 leader 的 Future
    # （leader +1 / waiter +1）；跨 worker 时按 SHA flock 串行、各自退避
    # （leader +2）。两种都属实现现状，成本差异写进 detail 供人判断。
    if [ -n "$b_leader" ] && [ -n "$a_leader" ]; then
        record sha-error-singleflight INFO \
            "leader +$(( a_leader - b_leader )) / waiter +$(( a_waiter - b_waiter )) / failed +$(( a_failed - b_failed ))（两路总墙钟 ${total}ms）" 0
    fi
    rm -rf "$d3" "$d4"
fi

if [ "$fail" -ne 0 ]; then
    log "❌ 存在 FAIL 项：$TSV"
    exit 1
fi
log "✅ 全部通过：$TSV"
exit 0
