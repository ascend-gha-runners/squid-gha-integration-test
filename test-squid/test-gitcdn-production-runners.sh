#!/usr/bin/env bash
# =============================================================================
# test-gitcdn-production-runners.sh —— 生产 runner 批量跑 git-cdn / gitcode-cdn
#
# 与 test-production-runners.sh 的区别：那个跑 test-squid.yaml（squid 注入验证），
# 本脚本跑两个独立 workflow：
#   - test-gitcdn.yaml        git-cdn 未同步 SHA 回源（R23）
#   - test-gitcode-clone.yaml gitcode → 缓存后端 clone 性能
#
# 同样只调 gh CLI：不改任何集群资源、不需要 kubeconfig。
#
# 前置（决定绿/红，不是脚本能修的）：
#   - test-gitcode-clone 要求 runner 的 job pod 模板 postStart 已注入
#     url.<backend>.insteadOf = https://gitcode.com/ ；未注入的 runner 会在
#     重写断言处判红（属前置缺失，不是 git-cdn 服务故障）。
#   - test-gitcdn 显式打 http://git-cdn-service.git-cdn.svc.cluster.local:8000，
#     目标集群没有本地 git-cdn 实例时脚本记 SKIP（不判红）。
#
# 用法：
#   ./test-squid/test-gitcdn-production-runners.sh               # 全部生产 runner × 两个 workflow
#   ./test-squid/test-gitcdn-production-runners.sh --list        # 只列注册表
#   ./test-squid/test-gitcdn-production-runners.sh --only linux-amd64-cpu-2-hk001
#   ./test-squid/test-gitcdn-production-runners.sh --exclude aiframe,gy-00
#   ./test-squid/test-gitcdn-production-runners.sh --workflow gitcdn    # gitcdn|gitcode|both（默认 both）
#   ./test-squid/test-gitcdn-production-runners.sh --no-watch    # 只触发不盯结果
#   ./test-squid/test-gitcdn-production-runners.sh --container-image quay.io/ascend/cann:9.0.0-a3-ubuntu22.04-py3.12
#   ./test-squid/test-gitcdn-production-runners.sh --iterations 3 --repo https://gitcode.com/cann/catlass.git
#
# 退出码：任一 run conclusion != success → 1；全部 success → 0。
# =============================================================================
set -uo pipefail

REPO="${REPO:-ascend-gha-runners/squid-gha-integration-test}"
REF="${REF:-main}"
WATCH_TIMEOUT="${WATCH_TIMEOUT:-3600}"   # 单个 run 最长等待秒数（gitcode clone job 默认超时 40min）
POLL_INTERVAL=30

# 跨集群拉cn-north-12 CANN 镜像可能 30min+，默认用 quay 就近源
CONTAINER_IMAGE="${CONTAINER_IMAGE:-quay.io/ascend/cann:9.0.0-a3-ubuntu22.04-py3.12}"
ITERATIONS=""; REPO_URL=""; GITCODE_BACKEND=""; TIMEOUT_MIN=""

# ---------------------------------------------------------------------------
# 生产 runner 注册表（与 test-production-runners.sh 同一份；标签 | 集群 | 备注）
# 统一用全局唯一名做单标签触发，避免多标签 AND 语义。
# ---------------------------------------------------------------------------
RUNNERS=(
    "linux-amd64-cpu-2-gy001|gy-001|gitcode 后端 git-cdn-gitcode（无独立实例，ExternalName 别名指向 git-cache）"
    "linux-aarch64-a3-2-aiframe|aiframework|aarch64；无 gitcode 重写"
    "linux-amd64-cpu-2-gy003|gy-003|无 gitcode 重写"
    "linux-amd64-cpu-2-hk001|hk-001|无 gitcode 重写；容器镜像跨集群拉取慢"
    "linux-aarch64-a2-1-wlcb001|wlcb-001|aarch64 A2；gitcode 走 git-cdn-gitcode 别名（Liqo 卸载）"
    "linux-amd64-cpu-2-mind-third|mind-third-ci|无 gitcode 重写"
    "linux-amd64-cpu-4-gy004|gy-004|无 gitcode 重写"
    "linux-amd64-cpu-8-gy005|gy-005|无 gitcode 重写"
    "linux-amd64-cpu-4-cn12-001|cn12-001|无 gitcode 重写"
    "linux-aarch64-a5-2-sh001|sh-001|aarch64 A5；有 git-cdn-local（git-cdn 组可跑）"
    "linux-amd64-a5-2-sh002|sh-002|amd64 A5；有 git-cdn-local（git-cdn 组可跑）"
)

ONLY=""; EXCLUDE=""; NO_WATCH=0; LIST_ONLY=0; WORKFLOW="both"
while [ $# -gt 0 ]; do
    case "$1" in
        --only)            ONLY="${2:?}"; shift 2 ;;
        --exclude)         EXCLUDE="${2:?}"; shift 2 ;;
        --workflow)        WORKFLOW="${2:?}"; shift 2 ;;
        --no-watch)        NO_WATCH=1; shift ;;
        --list)            LIST_ONLY=1; shift ;;
        --container-image) CONTAINER_IMAGE="${2:?}"; shift 2 ;;
        --iterations)      ITERATIONS="${2:?}"; shift 2 ;;
        --repo)            REPO_URL="${2:?}"; shift 2 ;;
        --gitcode-backend) GITCODE_BACKEND="${2:?}"; shift 2 ;;
        --timeout-minutes) TIMEOUT_MIN="${2:?}"; shift 2 ;;
        --ref)             REF="${2:?}"; shift 2 ;;
        *) echo "未知参数: $1" >&2; exit 2 ;;
    esac
done

case "$WORKFLOW" in
    gitcdn)  WFS=(test-gitcdn.yaml) ;;
    gitcode) WFS=(test-gitcode-clone.yaml) ;;
    both)    WFS=(test-gitcdn.yaml test-gitcode-clone.yaml) ;;
    *) echo "❌ --workflow 只支持 gitcdn | gitcode | both" >&2; exit 2 ;;
esac

if [ -n "$GITCODE_BACKEND" ]; then
    case "$GITCODE_BACKEND" in
        smart-git-proxy|git-cdn-gitcode) ;;
        *) echo "❌ 不支持的 gitcode 后端: $GITCODE_BACKEND（可选 smart-git-proxy | git-cdn-gitcode）" >&2; exit 2 ;;
    esac
fi

if [ "$LIST_ONLY" = 1 ]; then
    echo "生产 runner 注册表（标签 | 集群 | 备注）："
    printf '%s\n' "${RUNNERS[@]}" | awk -F'|' '{printf "  %-30s %-14s %s\n", $1, $2, $3}'
    exit 0
fi

command -v gh >/dev/null || { echo "❌ 需要 gh CLI"; exit 2; }

# ---------------------------------------------------------------------------
# 选中要跑的 runner 标签
# ---------------------------------------------------------------------------
declare -a LABELS=()
for entry in "${RUNNERS[@]}"; do
    label="${entry%%|*}"
    [ -n "$ONLY" ] && [ "$label" != "$ONLY" ] && continue
    if [ -n "$EXCLUDE" ]; then
        skip=0
        IFS=',' read -ra _ex <<< "$EXCLUDE"
        for e in "${_ex[@]}"; do
            [ -n "$e" ] && [[ "$label" == *"$e"* ]] && skip=1
        done
        [ "$skip" = 1 ] && continue
    fi
    LABELS+=("$label")
done
[ ${#LABELS[@]} -eq 0 ] && { echo "没有匹配的 runner（--only $ONLY --exclude $EXCLUDE）"; exit 2; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
RUNS_FILE="$TMPD/runs.tsv"; : > "$RUNS_FILE"

# ---------------------------------------------------------------------------
# 触发一个 run，返回 run id。
# 判定口径同 test-production-runners.sh：createdAt >= cutoff 且未被本轮认领，
# 避免 gh 的秒级登记延迟把上一轮 run 混进来。
# ---------------------------------------------------------------------------
trigger_one() {  # trigger_one <workflow> <label> → run id / TRIGGER_FAIL
    local wf="$1" label="$2" cutoff id i
    local claimed_file="$TMPD/claimed-$wf"; touch "$claimed_file"
    local extra=()
    if [ "$wf" = "test-gitcode-clone.yaml" ]; then
        extra+=(-f container_image="$CONTAINER_IMAGE")
        [ -n "$ITERATIONS" ]      && extra+=(-f iterations="$ITERATIONS")
        [ -n "$REPO_URL" ]        && extra+=(-f repo="$REPO_URL")
        [ -n "$GITCODE_BACKEND" ] && extra+=(-f gitcode_backend="$GITCODE_BACKEND")
        [ -n "$TIMEOUT_MIN" ]     && extra+=(-f timeout_minutes="$TIMEOUT_MIN")
    fi
    cutoff=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if ! gh workflow run "$wf" --repo "$REPO" --ref "$REF" \
            -f runner="[\"$label\"]" ${extra+"${extra[@]}"} >/dev/null 2>&1; then
        echo "TRIGGER_FAIL"; return 1
    fi
    local claimed
    for i in $(seq 1 15); do
        sleep 4
        claimed=$(tr '\n' ' ' < "$claimed_file")
        id=$(gh run list --repo "$REPO" --workflow "$wf" --limit 30 \
                --json databaseId,createdAt \
                --jq "[.[] | select(.createdAt >= \"$cutoff\")
                        | select((.databaseId|tostring) as \$d
                                  | (\"$claimed\" | split(\" \")) | index(\$d) | not)]
                      | sort_by(.createdAt) | first | .databaseId // empty" 2>/dev/null)
        if [ -n "$id" ]; then echo "$id" >> "$claimed_file"; echo "$id"; return 0; fi
    done
    echo "TRIGGER_FAIL"; return 1
}

# ---------------------------------------------------------------------------
# 等一个 run 完成，输出 conclusion
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
# 阶段 1：逐个触发（gh 调用本身很快）
# ---------------------------------------------------------------------------
echo "== 阶段 1：触发 ${#LABELS[@]} 个 runner × ${#WFS[@]} 个 workflow =="
[ " ${WFS[*]} " == *" test-gitcode-clone.yaml "* ] && echo "   container_image=$CONTAINER_IMAGE"
for label in "${LABELS[@]}"; do
    for wf in "${WFS[@]}"; do
        id=$(trigger_one "$wf" "$label")
        printf '%s\t%s\t%s\n' "$wf" "$label" "$id" | tee -a "$RUNS_FILE"
    done
done

if [ "$NO_WATCH" = 1 ]; then
    echo ""
    echo "== 已触发（--no-watch 不盯结果）=="
    awk -F'\t' '$3!="TRIGGER_FAIL"{printf "%s\t%s\thttps://github.com/%s/actions/runs/%s\n", $2, $1, "'"$REPO"'", $3}' "$RUNS_FILE"
    grep -q 'TRIGGER_FAIL' "$RUNS_FILE" && exit 1
    exit 0
fi

# ---------------------------------------------------------------------------
# 阶段 2：并行盯（每个 run 一个后台子进程，结论落临时文件）
# ---------------------------------------------------------------------------
echo ""
echo "== 阶段 2：并行盯 ${#WFS[@]}×${#LABELS[@]} 个 run（超时 ${WATCH_TIMEOUT}s）=="
i=0
while IFS=$'\t' read -r wf label id; do
    i=$((i+1))
    if [ "$id" = "TRIGGER_FAIL" ]; then
        echo "TRIGGER_FAIL" > "$TMPD/r$i"
    else
        ( watch_one "$id" > "$TMPD/r$i" ) &
    fi
done < "$RUNS_FILE"
wait

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
FAIL=0
i=0
echo ""
echo "== 汇总 =="
while IFS=$'\t' read -r wf label id; do
    i=$((i+1))
    url="https://github.com/$REPO/actions/runs/$id"
    if [ "$id" = "TRIGGER_FAIL" ]; then
        echo "❌ $label  $wf  触发失败"; FAIL=$((FAIL+1)); continue
    fi
    c=$(cat "$TMPD/r$i" 2>/dev/null || echo NO_RESULT)
    if [ "$c" = "success" ]; then
        echo "✅ $label  $wf  $url"
    else
        bad=$(gh run view "$id" --repo "$REPO" --json jobs \
                -q '[.jobs[] | select(.conclusion != null and .conclusion != "success" and .conclusion != "skipped") | .name+"("+.conclusion+")"] | join(", ")' 2>/dev/null)
        echo "❌ $label  $wf  conclusion=$c  非绿 job: ${bad:-?}  $url"
        FAIL=$((FAIL+1))
    fi
done < "$RUNS_FILE"
echo ""
echo "FAIL_COUNT=$FAIL"
[ "$FAIL" -eq 0 ]
