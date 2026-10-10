#!/usr/bin/env bash
# =============================================================================
# test-production-runners.sh —— 生产集群 runner 批量 squid 注入验证
#
# 背景：
#   除 gy-006（测试集群）外，其余 runner set 都在生产集群上。集群侧的
#   squid 注入（caNamespaces / env / CA 卷 / postStart）由平台侧维护，
#   本脚本【不改任何集群资源、不需要 kubeconfig】——只通过 gh CLI 逐个
#   触发 test-squid workflow（-f runner='["<标签>"]'），盯完结果出汇总表。
#   验证口径与 cn12-001 相同：meta-trace 门禁 + A/B 上游对照 + 全套场景。
#
# 用法：
#   ./test-squid/test-production-runners.sh                    # 全部生产 runner 顺序测
#   ./test-squid/test-production-runners.sh --only cpu-2-hk001 # 只测指定标签
#   ./test-squid/test-production-runners.sh --list             # 只列标签不触发
#   ./test-squid/test-production-runners.sh --no-watch         # 只触发不等结果
#   ./test-squid/test-production-runners.sh --heavy 1          # 透传给 workflow
#
# 退出码：任一 runner 的 run conclusion != success → 1；全部绿 → 0
# =============================================================================
set -uo pipefail

REPO="${REPO:-ascend-gha-runners/squid-gha-integration-test}"
WF="test-squid.yaml"
WATCH_TIMEOUT="${WATCH_TIMEOUT:-5400}"   # 单个 run 最长等待秒数（生产集群容器层慢，90min 兜底）
POLL_INTERVAL=30

# ---------------------------------------------------------------------------
# 生产 runner 注册表。
#   每个 runner 有 3 个可选标签（arch / 站点 / 全局唯一名），统一用全局
#   唯一名做单标签触发（避免多标签 AND 语义踩坑）。
#   标签 | 集群 | 注入状态备注（集群侧变更由平台侧维护，此处仅留档）
# ---------------------------------------------------------------------------
RUNNERS=(
    "linux-amd64-cpu-2-gy001|gy-001|新增（2026-10-10 上产线）"
    "linux-amd64-cpu-2-aiframe|aiframework|caNamespaces 已有"
    "linux-amd64-cpu-2-gy003|gy-003|caNamespaces 已有，仅注入"
    "linux-amd64-cpu-2-hk001|hk-001|新增 postStart（原无 lifecycle）；CM 在 ascend-gha-runners-hk-001 ns"
    "linux-amd64-cpu-2-mind-third|mind-third-ci|caNamespaces + ascend-gha-runners"
    "linux-amd64-cpu-4-gy004|gy-004|caNamespaces 已有，仅注入"
    "linux-amd64-cpu-8-gy005|gy-005|保留 karpenter 注解；caNamespaces + ascend-gha-runners"
    "linux-amd64-cpu-4-cn12-001|cn12-001|已注入（workflow pod 实测 env/CA 卷齐全）"
)

ONLY=""; NO_WATCH=0; LIST_ONLY=0; HEAVY=""; LADDER=""
while [ $# -gt 0 ]; do
    case "$1" in
        --only)     ONLY="${2:?}"; shift 2 ;;
        --no-watch) NO_WATCH=1; shift ;;
        --list)     LIST_ONLY=1; shift ;;
        --heavy)    HEAVY="${2:?}"; shift 2 ;;
        --ladder)   LADDER="${2:?}"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

if [ "$LIST_ONLY" = 1 ]; then
    echo "生产 runner 注册表（标签 | 集群 | 注入状态）："
    printf '  %s\n' "${RUNNERS[@]}" | awk -F'|' '{printf "  %-28s %-14s %s\n", $1, $2, $3}'
    exit 0
fi

command -v gh >/dev/null || { echo "❌ 需要 gh CLI"; exit 2; }

# ---------------------------------------------------------------------------
# 触发一个 runner 的 test-squid，返回新 run id
# 判定口径：createdAt >= 本轮触发时刻（cutoff）且未被此前触发认领。
# 不用「前后差集」：gh 的 run 登记有秒级延迟，上一轮触发的 run 可能迟到
# 混进下一轮的差集窗口（2026-10-09 实测 7 连发时 cn12-001 的 id 被拼脏）。
# ---------------------------------------------------------------------------
CLAIMED=" "   # 已认领 run id（空格分隔，跨 trigger_one 累积）

trigger_one() {  # trigger_one <标签> → stdout: run_id
    local label="$1" cutoff id i
    cutoff=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local extra=()
    [ -n "$HEAVY" ]  && extra+=(-f heavy="$HEAVY")
    [ -n "$LADDER" ] && extra+=(-f ladder="$LADDER")
    if ! gh workflow run "$WF" --repo "$REPO" --ref main \
            -f runner="[\"$label\"]" ${extra+"${extra[@]}"}; then
        echo "TRIGGER_FAIL"
        return 1
    fi
    # 轮询等 GitHub 登记新 run（最多 60s）
    for i in $(seq 1 12); do
        sleep 5
        id=$(gh run list --repo "$REPO" --workflow "$WF" --limit 10 \
                --json databaseId,createdAt \
                --jq "[.[] | select(.createdAt >= \"$cutoff\") \
                        | select((.databaseId|tostring) as \$d \
                                  | (\"$CLAIMED\" | split(\" \")) | index(\$d) | not)] \
                      | sort_by(.createdAt) | first | .databaseId // empty" 2>/dev/null)
        [ -n "$id" ] && { CLAIMED="$CLAIMED$id "; echo "$id"; return 0; }
    done
    echo "TRIGGER_FAIL"
    return 1
}

# ---------------------------------------------------------------------------
# 等一个 run 完成，stdout: conclusion
# ---------------------------------------------------------------------------
watch_one() {  # watch_one <run_id>
    local id="$1" waited=0 st
    while [ $waited -lt "$WATCH_TIMEOUT" ]; do
        st=$(gh run view "$id" --repo "$REPO" --json status,conclusion \
                 -q '.status+" "+.conclusion' 2>/dev/null) || { sleep $POLL_INTERVAL; waited=$((waited+POLL_INTERVAL)); continue; }
        case "$st" in
            completed*) echo "${st#completed }"; return 0 ;;
        esac
        sleep $POLL_INTERVAL
        waited=$((waited+POLL_INTERVAL))
    done
    echo "WATCH_TIMEOUT"
}

# ---------------------------------------------------------------------------
# 主流程：两阶段并行。
#   阶段 1 逐个触发（gh 调用本身很快）；阶段 2 并行盯所有 run——
#   七个标签是七个不同集群，互不抢资源，并行总耗时 = 最慢的那个，
#   串行只会把各集群耗时相加（约 1-2 小时）。
# ---------------------------------------------------------------------------
declare -a LABELS=() IDS=() URLS=()
FAIL_TRIGGER=0

for entry in "${RUNNERS[@]}"; do
    label="${entry%%|*}"
    [ -n "$ONLY" ] && [ "$label" != "$ONLY" ] && continue
    LABELS+=("$label")
done

[ ${#LABELS[@]} -eq 0 ] && { echo "没有匹配的 runner（--only $ONLY）"; exit 2; }

# 阶段 1：全部触发
echo "== 阶段 1：触发 ${#LABELS[@]} 个 run =="
for label in "${LABELS[@]}"; do
    run_id=$(trigger_one "$label")
    if [ "$run_id" = "TRIGGER_FAIL" ]; then
        echo "❌ $label  触发失败"
        IDS+=("TRIGGER_FAIL"); URLS+=("")
        FAIL_TRIGGER=$((FAIL_TRIGGER+1))
    else
        echo "⏳ $label  run=$run_id"
        IDS+=("$run_id"); URLS+=("https://github.com/$REPO/actions/runs/$run_id")
    fi
done

if [ "$NO_WATCH" = 1 ]; then
    echo ""
    echo "== 已触发（--no-watch 不盯结果）=="
    for i in "${!LABELS[@]}"; do
        printf '%s\t%s\t%s\n' "${LABELS[$i]}" "${IDS[$i]}" "${URLS[$i]}"
    done
    [ "$FAIL_TRIGGER" -eq 0 ] || exit 1
    exit 0
fi

# 阶段 2：并行盯（每个 run 一个后台子进程，结论落临时文件）
echo ""
echo "== 阶段 2：并行盯 ${#LABELS[@]} 个 run（超时 ${WATCH_TIMEOUT}s）=="
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
for i in "${!LABELS[@]}"; do
    label="${LABELS[$i]}"; id="${IDS[$i]}"
    (
        if [ "$id" = "TRIGGER_FAIL" ]; then
            echo "TRIGGER_FAIL" > "$TMPD/r$i"
        else
            watch_one "$id" > "$TMPD/r$i"
        fi
    ) &
done
wait

# 汇总（按标签顺序输出）
FAIL_COUNT=$FAIL_TRIGGER
echo ""
echo "== 汇总 =="
for i in "${!LABELS[@]}"; do
    label="${LABELS[$i]}"; url="${URLS[$i]}"
    c=$(cat "$TMPD/r$i" 2>/dev/null || echo "NO_RESULT")
    if [ "$c" = "success" ]; then
        echo "✅ $label  全绿  $url"
    elif [ "$c" = "TRIGGER_FAIL" ]; then
        echo "❌ $label  触发失败"
    else
        jobs_summary=$(gh run view "${IDS[$i]}" --repo "$REPO" --json jobs \
            -q '[.jobs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped") | .name+"("+.conclusion+")"] | join(", ")' 2>/dev/null)
        echo "❌ $label  conclusion=$c  非绿 job: ${jobs_summary:-?}  $url"
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
done
echo ""
echo "FAIL_COUNT=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
