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
WATCH_TIMEOUT="${WATCH_TIMEOUT:-2400}"   # 单个 run 最长等待秒数（tools 阶段慢集群可到 ~20min）
POLL_INTERVAL=30

# ---------------------------------------------------------------------------
# 生产 runner 注册表（单标签 JSON 数组，多标签是 AND 语义）
#   标签 | 集群 | 注入状态备注（集群侧变更由平台侧维护，此处仅留档）
# ---------------------------------------------------------------------------
RUNNERS=(
    "cpu-2-aiframe|aiframework|caNamespaces 已有"
    "cpu-2-gy003|gy-003|caNamespaces 已有，仅注入"
    "cpu-2-hk001|hk-001|新增 postStart（原无 lifecycle）；CM 在 ascend-gha-runners-hk-001 ns"
    "cpu-2-mind-third|mind-third-ci|caNamespaces + ascend-gha-runners"
    "cpu-4-gy004|gy-004|caNamespaces 已有，仅注入"
    "cpu-8-gy005|gy-005|保留 karpenter 注解；caNamespaces + ascend-gha-runners"
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
# 触发一个 runner 的 test-squid，返回新 run id（用触发前后 run 集合差集防撞车）
# ---------------------------------------------------------------------------
trigger_one() {  # trigger_one <标签> → stdout: run_id
    local label="$1" before after id
    before=$(gh run list --repo "$REPO" --workflow "$WF" --limit 30 \
                 --json databaseId --jq '.[].databaseId' 2>/dev/null | sort | tr '\n' ',')
    local extra=()
    [ -n "$HEAVY" ]  && extra+=(-f heavy="$HEAVY")
    [ -n "$LADDER" ] && extra+=(-f ladder="$LADDER")
    if ! gh workflow run "$WF" --repo "$REPO" --ref main \
            -f runner="[\"$label\"]" ${extra+"${extra[@]}"}; then
        echo "TRIGGER_FAIL"
        return 1
    fi
    sleep 10   # 等 GitHub 登记新 run
    after=$(gh run list --repo "$REPO" --workflow "$WF" --limit 30 \
                --json databaseId --jq '.[].databaseId' 2>/dev/null | sort)
    id=$(comm -13 <(echo "$before" | tr ',' '\n' | sort) <(echo "$after") | head -1)
    [ -n "$id" ] && { echo "$id"; return 0; }
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
# 主流程：顺序测每个 runner（生产 runner 多为单实例，并行触发只会排队）
# ---------------------------------------------------------------------------
declare -a RESULT_LINES=()
FAIL_COUNT=0

for entry in "${RUNNERS[@]}"; do
    label="${entry%%|*}"
    [ -n "$ONLY" ] && [ "$label" != "$ONLY" ] && continue

    echo ""
    echo "==================================================================="
    echo "== $label"
    echo "==================================================================="
    run_id=$(trigger_one "$label")
    if [ "$run_id" = "TRIGGER_FAIL" ]; then
        RESULT_LINES+=("❌ $label  触发失败")
        FAIL_COUNT=$((FAIL_COUNT+1))
        continue
    fi
    local_url="https://github.com/$REPO/actions/runs/$run_id"
    echo "run: $local_url"

    if [ "$NO_WATCH" = 1 ]; then
        RESULT_LINES+=("⏳ $label  已触发（未盯）  $local_url")
        continue
    fi

    conclusion=$(watch_one "$run_id")
    jobs_summary=$(gh run view "$run_id" --repo "$REPO" --json jobs \
        -q '[.jobs[] | select(.conclusion != "success" and .conclusion != "skipped") | .name+"("+.conclusion+")"] | join(", ")' 2>/dev/null)
    if [ "$conclusion" = "success" ]; then
        RESULT_LINES+=("✅ $label  全绿  $local_url")
    else
        RESULT_LINES+=("❌ $label  conclusion=$conclusion  非绿 job: ${jobs_summary:-?}  $local_url")
        FAIL_COUNT=$((FAIL_COUNT+1))
    fi
done

echo ""
echo "==================================================================="
echo "== 汇总（FAIL_COUNT=$FAIL_COUNT）"
echo "==================================================================="
printf '%s\n' "${RESULT_LINES[@]}"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
