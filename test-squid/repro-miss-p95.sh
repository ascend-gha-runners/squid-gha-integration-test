#!/usr/bin/env bash
# 复现 SquidMissP95Slow 告警的"假慢"机制（2026-10-09 cn12-001/aiframework 诊断）
#
# 结论先行：squid_Cache_Misses_95 未排除 long-poll 流量。GHA runner 的
# broker.actions.githubusercontent.com/message 端点设计上 hold 连接 ~57s 才回
# （长轮询保活），它在慢请求里占 ~30%，把 MISS p95 直接钉在 hold 时间上——
# 实测 cn12-001 两分片排除 broker 后 p95=853/909ms（完全健康），HIT p95=275ms
# （存储无瓶颈）；aiframework p95=57.44813 两分片同值 = broker hold 特征值。
#
# 本脚本起 mock origin 复刻三类真实流量形态，验证告警误报机制：
#   fast  —— 常规快流量（绝大多数，p95 里的健康分母）
#   blob  —— 10~12s 抖动（复刻 Actions artifact blob 域真实慢，次因）
#   poll  —— 57s hold 后回 200（复刻 broker 长轮询，假慢主因）
#
# 预期：全量 p95 落在 poll 区间（复现告警 >10s），排除 poll 后 p95 <12s
# （证明回源链路健康，告警口径缺陷成立）。
#
# NO_PROXY 对照（第二遍，仅 squid 模式）：所有探测统一带 -x $PX（对齐 runner
# env 注入形态），再真设 NO_PROXY=broker.actions.githubusercontent.com 并用
# --resolve 把该域钉到本 pod IP（mock origin 所在）。分流由 curl 的 NO_PROXY
# 匹配逻辑决定：poll（URL host=broker 域）命中 → 直连旁路不进 squid；
# fast/blob（URL host=pod IP）不命中 → 照常经 squid。与生产 runner 把 broker
# 加进 NO_PROXY 后的行为同构。断言：直连 poll 照常 hold ~57s（流量没消失，
# 只是不经 squid）+ squid 可见口径（np-fast+np-blob）p95 保持健康。
#
# 用法：
#   bash test-squid/repro-miss-p95.sh                 # 直连模式（本地演示）
#   PX=http://squid-cache.squid.svc:3128 bash ...     # squid 模式（runner 上 MISS 语义）
set -euo pipefail

PORT=${PORT:-18091}
HOLD=${HOLD:-57}          # broker hold 秒数（GHA 长轮询特征值）
BLOB_SLOW=${BLOB_SLOW:-11} # blob 域抖动秒数
N_FAST=90                 # 快流量样本数
N_BLOB=5                  # 慢 blob 样本数
N_POLL=7                  # 长轮询样本数（占比 ≥5.5% 才能顶进 p95）
RESULTS=${RESULTS:-/tmp/repro-miss-p95}
T0=$(date +%s)

mkdir -p "$RESULTS"

# ---------- mock origin：三形态端点（纯标准库，内联） ----------
cat > "$RESULTS/mock-origin.py" <<EOF
import time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def do_GET(self):
        if self.path.startswith("/poll"):
            time.sleep($HOLD)          # broker 长轮询：服务端 hold 到有消息/超时
            body, code = b'{"messages":[]}', 200
        elif self.path.startswith("/blob"):
            time.sleep($BLOB_SLOW)     # artifact blob：冷拉抖动 10~12s
            body, code = b'blob-data', 200
        else:
            body, code = b'fast', 200  # 常规流量
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

ThreadingHTTPServer(("0.0.0.0", $PORT), H).serve_forever()
EOF

python3 "$RESULTS/mock-origin.py" > "$RESULTS/origin.log" 2>&1 &
OPID=$!
trap 'kill $OPID 2>/dev/null' EXIT
for i in $(seq 1 10); do
    curl -sS --max-time 2 "http://127.0.0.1:$PORT/fast" >/dev/null 2>&1 && break
    sleep 1
done

# 本机 IP（squid 需回源可达；直连模式用不到）。hostname -i 在部分环境不存在/失败，
# pipefail 下须吞掉非零（origin_host 同款回退）
IP=$( (hostname -i 2>/dev/null || true) | awk '{print $1}')
BASE="http://${IP:-127.0.0.1}:$PORT"

PXARG=()
[ -n "${PX:-}" ] && PXARG=(-x "$PX")
if [ -n "${PX:-}" ]; then
    echo "== squid 模式：经 $PX（MISS 语义对齐生产）origin=$BASE =="
else
    echo "== 直连模式：本地演示 elapsed 分布形态（无 MISS 语义）=="
fi

# ---------- 流量模型：并发打点，记录 elapsed ----------
# 探测顺序：fast 先进（health 轮询 + 主流量），poll 最后一批起跑，总时长 ≈ HOLD+5s
probe() {  # <url> <tag> [curl 额外参数…] → 追加 elapsed ms + 对端 IP 到 TSV
    # 第三列 remote_ip 是"每笔连接的真实对端"直证：经代理=代理 IP，直连=源站 IP
    local url=$1 tag=$2
    shift 2
    local t
    t=$(curl -sS --max-time $((HOLD + 15)) "${PXARG[@]}" "$@" \
        -o /dev/null -w '%{time_total}\t%{remote_ip}' "$url" 2>/dev/null)
    printf '%s\t%s\n' "$tag" "$t" >> "$RESULTS/probes.tsv"
}
# warmup 直连探活（脚手架，失败不致命——正式判据在 pass-1 断言里；
# 正式流量走 $BASE=pod IP —— squid 模式下 127.0.0.1 是 squid 自己的
# loopback，回源连不到本 pod 的 mock origin）
probe "http://127.0.0.1:$PORT/fast" warmup --noproxy '*' || true

# fast ×90（xargs -P10 并发）；URL host 必须用 pod IP（$BASE），
# 经 squid 时 127.0.0.1 会连到 squid 自身 loopback（curl -x 语义）
# 注：xargs bash -c 只继承函数体（declare -f），PXARG 数组须按传入的 PX 重建，
# 否则 squid 模式下 -x 参数静默丢失（直连冒烟测不出）
seq 1 "$N_FAST" | xargs -P 10 -I{} bash -c \
    "$(declare -f probe); PX='${PX:-}'; PXARG=(); [ -n \"\$PX\" ] && PXARG=(-x \"\$PX\"); \
     PORT=$PORT; RESULTS=$RESULTS; HOLD=$HOLD; \
     probe \"$BASE/fast?i={}\" fast"

# blob ×5（模拟 5% 冷拉抖动）
seq 1 "$N_BLOB" | xargs -P 5 -I{} bash -c \
    "$(declare -f probe); PX='${PX:-}'; PXARG=(); [ -n \"\$PX\" ] && PXARG=(-x \"\$PX\"); \
     PORT=$PORT; RESULTS=$RESULTS; HOLD=$HOLD; \
     probe \"$BASE/blob?i={}\" blob"

# poll ×7 并发（broker 长轮询形态）
seq 1 "$N_POLL" | xargs -P "$N_POLL" -I{} bash -c \
    "$(declare -f probe); PX='${PX:-}'; PXARG=(); [ -n \"\$PX\" ] && PXARG=(-x \"\$PX\"); \
     PORT=$PORT; RESULTS=$RESULTS; HOLD=$HOLD; \
     probe \"$BASE/poll?i={}\" poll"

# ---------- p95 三口径（模拟 mtail 滚动窗 MISS p95 计算方式） ----------
# p95 空文件返回 0（防炸：set -e 下空串进 [-ge] 会 "integer expression expected"）
p95() { sort -n "$1" | awk -v q="$2" '{a[NR]=$1} END{if(NR>0) print a[int(NR*q)]; else print 0}'; }
# probes.tsv 三列：tag / elapsed_ms（curl 原始浮点，取整）/ remote_ip（对端直证）
tag_ms() { awk -F'\t' -v t="$1" '$1==t && $2 ~ /^[0-9]+(\.[0-9]+)?$/{print int($2*1000)}' "$RESULTS/probes.tsv"; }
tag_ip() { awk -F'\t' -v t="$1" '$1==t && $3!=""{print $3}' "$RESULTS/probes.tsv" | sort | uniq -c | awk '{printf "%s×%s ", $2, $1}'; }

tag_ms fast  > "$RESULTS/fast.txt"
tag_ms blob  > "$RESULTS/blob.txt"
tag_ms poll  > "$RESULTS/poll.txt"
cat "$RESULTS/fast.txt" "$RESULTS/blob.txt" "$RESULTS/poll.txt" > "$RESULTS/all.txt"
cat "$RESULTS/fast.txt" "$RESULTS/blob.txt" > "$RESULTS/excl-poll.txt"

P95_ALL=$(p95 "$RESULTS/all.txt" 0.95)
P95_EXCL=$(p95 "$RESULTS/excl-poll.txt" 0.95)
P95_POLL=$(p95 "$RESULTS/poll.txt" 0.5)

echo
echo "== 结果（ms）=="
printf '%-28s %s\n' "全量 p95（告警口径）" "$P95_ALL"
printf '%-28s %s\n' "排除 poll 后 p95（真实健康度）" "$P95_EXCL"
printf '%-28s %s\n' "poll 中位（hold 特征值）" "$P95_POLL"
printf '%-28s %s\n' "blob 中位（真慢次因）" "$(p95 "$RESULTS/blob.txt" 0.5)"
echo

# ---------- 判定：复现 = 全量 p95 被 poll 顶进 hold 区间 ----------
FAIL=0
if [ "$P95_ALL" -ge $((HOLD * 1000 * 9 / 10)) ] && [ "$P95_EXCL" -lt 12000 ]; then
    echo "✅ 复现成立：全量 p95=$P95_ALL ms 落在 poll hold 区间，排除后 p95=$P95_EXCL ms 健康"
    echo "   → 告警 squid_Cache_Misses_95 的 >10s 阈值被 long-poll 流量误触发；"
    echo "   → 修复方向：exporter/mtail 按 domain 分组或剔除 broker.actions.githubusercontent.com"
else
    echo "❌ 未复现（all=$P95_ALL excl=$P95_EXCL poll_med=$P95_POLL）——检查 origin.log 与 probes.tsv"
    FAIL=1
fi
echo

# ---------- NO_PROXY 对照：真设 NO_PROXY，分流交给 curl 的匹配逻辑 ----------
# 机理：三批探测统一带 -x $PX（= runner env 注入的 HTTP(S)_PROXY），poll 的
# URL host 换成 broker 域名并真设 NO_PROXY=该域（--noproxy 旗子与 env 同语义，
# 双保险兼容老 curl；--resolve 把该域钉到本 pod IP，直连时可达 mock origin）。
# 于是 curl 自己决定：poll 命中 NO_PROXY → 直连，不进 squid 口径；fast/blob
# （host=pod IP）不命中 → 照常经 squid。若 curl 不认 NO_PROXY（分流失败），
# poll 会被送去 squid 回源真 broker 域 → 探测失败 → 断言立刻抓住。
NPHOST=broker.actions.githubusercontent.com
NPIP=${IP:-127.0.0.1}
NP_FAIL=0
if [ -n "${PX:-}" ]; then
    echo "== NO_PROXY 对照：NO_PROXY=$NPHOST（poll 直连旁路，fast/blob 照常经 squid）=="
    # poll（命中 NO_PROXY）先起占住 ~57s 等待窗口，fast/blob 并行推进
    seq 1 "$N_POLL" | xargs -P "$N_POLL" -I{} bash -c \
        "$(declare -f probe); PX='${PX:-}'; PXARG=(); [ -n \"\$PX\" ] && PXARG=(-x \"\$PX\"); \
         PORT=$PORT; RESULTS=$RESULTS; HOLD=$HOLD; NPHOST=$NPHOST; NPIP=$NPIP; \
         export NO_PROXY=$NPHOST no_proxy=$NPHOST; \
         probe \"http://\$NPHOST:\$PORT/poll?np={}\" np-poll \
               --noproxy \"\$NPHOST\" --resolve \"\$NPHOST:\$PORT:\$NPIP\"" &
    NPPID=$!
    seq 1 "$N_FAST" | xargs -P 10 -I{} bash -c \
        "$(declare -f probe); PX='${PX:-}'; PXARG=(); [ -n \"\$PX\" ] && PXARG=(-x \"\$PX\"); \
         PORT=$PORT; RESULTS=$RESULTS; HOLD=$HOLD; \
         probe \"$BASE/fast?np={}\" np-fast"
    seq 1 "$N_BLOB" | xargs -P 5 -I{} bash -c \
        "$(declare -f probe); PX='${PX:-}'; PXARG=(); [ -n \"\$PX\" ] && PXARG=(-x \"\$PX\"); \
         PORT=$PORT; RESULTS=$RESULTS; HOLD=$HOLD; \
         probe \"$BASE/blob?np={}\" np-blob"
    wait "$NPPID" 2>/dev/null || true

    tag_ms np-fast > "$RESULTS/np-fast.txt"
    tag_ms np-blob > "$RESULTS/np-blob.txt"
    tag_ms np-poll > "$RESULTS/np-poll.txt"
    cat "$RESULTS/np-fast.txt" "$RESULTS/np-blob.txt" > "$RESULTS/np-squid-seen.txt"
    P95_NP_SEEN=$(p95 "$RESULTS/np-squid-seen.txt" 0.95)
    MED_NP_POLL=$(p95 "$RESULTS/np-poll.txt" 0.5)
    # 直证：np-poll 每笔对端 IP 必须等于 pod IP（=curl 真的直连了）；
    # 任何一笔落到别的 IP（=squid 被使用）即分流失败
    NP_BAD_IP=$(awk -F'\t' -v t="np-poll" -v want="$NPIP" \
        '$1==t && $3!="" && $3!=want{c++} END{print c+0}' "$RESULTS/probes.tsv")

    echo
    echo "== NO_PROXY 对照结果（ms）=="
    printf '%-40s %s\n' "对照前：squid 口径全量 p95（被钉住）" "$P95_ALL"
    printf '%-40s %s\n' "对照后：squid 口径 p95（np-fast+blob）" "$P95_NP_SEEN"
    printf '%-40s %s\n' "直连 poll 中位（不经 squid，照常 hold）" "$MED_NP_POLL"
    printf '%-40s %s\n' "np-poll 对端 IP 直证（应只有 pod IP）" "$(tag_ip np-poll)"
    printf '%-40s %s\n' "np-fast/blob 对端 IP（对照：squid）" "$(tag_ip np-fast)$(tag_ip np-blob)"
    printf '%-40s %s\n' "第一遍 poll 对端 IP（对照：squid）" "$(tag_ip poll)"
    echo
    if [ "$MED_NP_POLL" -ge $((HOLD * 1000 * 9 / 10)) ] && [ "$P95_NP_SEEN" -lt 12000 ] \
        && [ "$NP_BAD_IP" -eq 0 ]; then
        echo "✅ NO_PROXY 对照成立：poll 命中 NO_PROXY 直连（对端 $NPIP，0 笔异常）、"
        echo "   照常 hold（$MED_NP_POLL ms）但不进 squid 口径，squid 可见 MISS "
        echo "   p95=$P95_NP_SEEN ms 健康——broker 加进 runner NO_PROXY（或 squid 侧"
        echo "   splice）后 SquidMissP95Slow 误报根除"
    else
        echo "❌ NO_PROXY 对照未达预期（seen_p95=$P95_NP_SEEN poll_med=$MED_NP_POLL 异常对端=$NP_BAD_IP 笔）"
        echo "   → poll 未按 NO_PROXY 直连或直连链路异常，检查 curl 版本与 probes.tsv"
        NP_FAIL=1
    fi
    echo
else
    echo "== NO_PROXY 对照：SKIP（直连模式无 squid 口径，仅 squid 模式有对照意义）=="
    echo
fi
FAIL=$((FAIL | NP_FAIL))

# ---------- timings.tsv（对齐套件口径 phase/seconds/status/group，汇总表统一收录）----------
WALL=$(( $(date +%s) - T0 ))
printf 'phase\tseconds\tstatus\tgroup\n' > "$RESULTS/timings.tsv"
printf 'miss-p95\t%s\t%s\t%s\n' "$WALL" "$FAIL" "${GROUP:-runner}" >> "$RESULTS/timings.tsv"

exit $FAIL
