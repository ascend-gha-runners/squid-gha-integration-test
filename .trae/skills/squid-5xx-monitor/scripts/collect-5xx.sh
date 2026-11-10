#!/usr/bin/env bash
# squid 5xx 跨集群只读采集：只查中心 Prometheus，不碰任何集群资源。
#
# 用法：
#   bash collect-5xx.sh                          # 默认 10m 快照 + 24h 排行
#   bash collect-5xx.sh --window 1h --trend 7d   # 自定义窗口
#   PROM_URL=http://x:9090 bash collect-5xx.sh   # 换 Prometheus
#
# 输出为 markdown，可直接贴进 SQUID-5XX-MONITORING.md。
set -uo pipefail

PROM_URL="${PROM_URL:-http://113.44.182.82:9090}"
WINDOW="10m"
TREND="24h"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --window) WINDOW="$2"; shift 2 ;;
    --trend)  TREND="$2";  shift 2 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

command -v curl >/dev/null || { echo "需要 curl" >&2; exit 1; }
command -v python3 >/dev/null || { echo "需要 python3" >&2; exit 1; }

# 5xx 选择器：保留 MISS_5xx（旧桶）与 5xx（#2556 新桶）两种写法，排除自身抓取/空 host/隧道
SEL='squid_requests_total{job="mtail", cluster=~".+", result=~"MISS_5xx|5xx", host!~"squid-cache:.*|-|.*:443"}'

query() {
  # $1 = PromQL；输出 markdown 表格行（无结果时说明为空）
  local expr="$1"
  curl -sf -m 60 -G "${PROM_URL}/api/v1/query" --data-urlencode "query=${expr}" \
  | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception as e:
    print(f"> 查询解析失败: {e}"); sys.exit(0)
res = d.get("data", {}).get("result", [])
if not res:
    print("> 当前窗口无数据（5xx 为 0 或指标缺失）"); sys.exit(0)
rows = []
for r in res:
    m = r["metric"]
    rows.append((m.get("cluster", "-"), m.get("host", "-"), float(r["value"][1])))
rows.sort(key=lambda x: -x[2])
print("| cluster | host | inc |")
print("|---|---|---|")
for c, h, v in rows:
    print(f"| {c} | {h} | {v:.1f} |")
'
}

echo "# squid 5xx 巡检采集"
echo
echo "- Prometheus: \`${PROM_URL}\`"
echo "- 快照窗口: \`${WINDOW}\`；趋势窗口: \`${TREND}\`"
echo "- 采集时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo

echo "## 1. 快照（topk 20，按集群×域名）"
echo
query "topk(20, sum by (cluster, host) (increase(${SEL}[${WINDOW}])))"
echo

echo "## 2. 趋势排行（按域名）"
echo
query "topk(20, sum by (host) (increase(${SEL}[${TREND}])))"
echo

echo "## 3. 集群汇总（按集群）"
echo
query "topk(20, sum by (cluster) (increase(${SEL}[${TREND}])))"
echo

echo "## 4. 下一步"
echo
echo "1. 对每个非零域名执行 SKILL.md 第 4 步，进集群读 access.log 定 TAG/status 归属。"
echo "2. 按「一个域名一个 issue」查重后建 issue 或追加评论。"
