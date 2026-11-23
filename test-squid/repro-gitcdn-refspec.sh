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
#   ② SHA 回源：从 refs/pull/*/head 取一个 PR-only SHA（mirror 不包含），
#      两路并发 `git fetch --depth 1 <sha>` 都成功；/metrics 可达时记录
#      git_cdn_fetch_sha_total 增量（>1 记 WARN）
#   ③ 失败透传：取一个不存在的 SHA，必须在 180s 内非零退出且 stderr 有 git
#      错误信息（超时 124 = 回源卡死，判红）
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

# ---- 选一个 PR-only SHA（mirror 不包含，验证按 SHA 回源）----------------------
sha=$(printf '%s\n' "$pulls" | awk 'NF {print $1; exit}')
if [ -z "$sha" ]; then
    record sha-pick SKIP "没有 refs/pull/*/head 可取" 0
else
    log "目标 SHA=$sha（refs/pull/*/head，mirror 不含）"

    # ---- 阶段 2：两路并发按 SHA fetch（单飞）--------------------------------
    metric() {
        curl -sS --max-time 10 "${GIT_CDN_BASE%/}/metrics" 2>/dev/null \
            | awk '/^git_cdn_fetch_sha_total/{s+=$2} END{print s+0}'
    }
    before=$(metric)

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
    after=$(metric)

    if [ $rc1 -eq 0 ] && [ $rc2 -eq 0 ]; then
        got1=$(git -C "$d1" rev-parse FETCH_HEAD 2>/dev/null)
        got2=$(git -C "$d2" rev-parse FETCH_HEAD 2>/dev/null)
        if [ "$got1" = "$sha" ] && [ "$got2" = "$sha" ]; then
            record sha-fetch PASS "两路均取到 ${sha:0:9}（${ms}ms）" "$ms"
        else
            record sha-fetch FAIL "FETCH_HEAD 不符：${got1:0:9}/${got2:0:9}" "$ms"
            fail=1
        fi
    else
        record sha-fetch FAIL "rc1=$rc1 rc2=$rc2（见 sha-fetch-*.err）" "$ms"
        fail=1
    fi

    if [ -n "$before" ] && [ -n "$after" ]; then
        delta=$(( after - before ))
        if [ "$delta" -gt 1 ]; then
            record sha-singleflight WARN "git_cdn_fetch_sha_total +$delta（>1，单飞可能未生效）" 0
        else
            record sha-singleflight PASS "git_cdn_fetch_sha_total +$delta" 0
        fi
    else
        record sha-singleflight WARN "/metrics 不可达，未取到 git_cdn_fetch_sha_total" 0
    fi
    rm -rf "$d1" "$d2"

    # ---- 阶段 3：不存在的 SHA 必须快速失败 ----------------------------------
    bad="0000000000000000000000000000000000000001"
    d3=$(mktemp -d) && git -C "$d3" init -q
    t0=$(now_ms)
    GIT_TERMINAL_PROMPT=0 timeout 180 git -C "$d3" fetch --depth 1 "$REMOTE" "$bad" \
        >"$results/sha-bad.out" 2>"$results/sha-bad.err"
    rc=$?
    ms=$(( $(now_ms) - t0 ))
    if [ $rc -eq 124 ]; then
        record sha-error FAIL "坏 SHA 180s 超时未返回（回源卡死未透传）" "$ms"
        fail=1
    elif [ $rc -ne 0 ] && [ -s "$results/sha-bad.err" ]; then
        record sha-error PASS "rc=$rc 快速失败，stderr=$(head -n 1 "$results/sha-bad.err" | cut -c1-80)" "$ms"
    else
        record sha-error FAIL "rc=$rc 但无 git 错误信息（失败未透传）" "$ms"
        fail=1
    fi
    rm -rf "$d3"
fi

if [ "$fail" -ne 0 ]; then
    log "❌ 存在 FAIL 项：$TSV"
    exit 1
fi
log "✅ 全部通过：$TSV"
exit 0
