#!/usr/bin/env bash
# =============================================================================
# repro-stale-index.sh —— 复现「源站 max-age 15 天 → squid 长期供旧索引页」
#
# 事故取证（2026-10-29，triton-ascend 3.6.0.post2 构建失败）：
#   10-28 21:50 镜像源重新生成 .../pypi/triton-ascend/ 索引页（8012B，含 post2）
#   10-29 18:32:58 squid(cache-1) 仍回 TCP_MEM_HIT/200 6902B 旧页（无 post2）
#   18:32:58.949 pip 报 No matching distribution found for triton-ascend==3.6.0.post2
#   19:05/19:33 两台副本先后回源拿到新页 → attempt 4 才成功（失败窗口约 1 小时）
#
# 根因：源站索引页带 `Cache-Control: max-age=1296000`（15 天），而 squid 兜底
#   `refresh_pattern . 0 0% 0 refresh-ims` 没有 override-expire，源站 max-age
#   直接生效 → 对象全程判新鲜（elapsed=0 / HIER_NONE），镜像重新生成索引后
#   最长 15 天内不回源验证。与包缺失/网络/源站故障无关。
#
# 三个子命令：
#   mock    —— 机制证据（自带 mock origin，纯标准库）：
#              索引页响应带 15 天 max-age；先经 squid 预热（同 URL），再翻页
#              （源站新增 3.6.0.post2），再经 squid 请求，记录是否仍供旧页。
#              仅留档、不判红——mock 主机是 runner pod IP，域级 deny 规则不适用
#              （grep 结论看 cacheability）。
#              URL 带 run 唯一 query，跨 run 不撞缓存键（幂等，R5）。
#   cacheability —— 主判定：真实域索引页是否被缓存
#              真实 URL 带 run 唯一 query 连打 4 次；任一发由缓存对象作答
#              （HIT / fwd=stale）即判 FAIL——可变索引页被缓存就是事故温床。
#              修复（cache deny hc_repo mutable_meta 覆盖 ^/ascend/repos/.*/$）
#              落地后 4 发全 MISS → PASS。
#   parity  —— 真实索引页新鲜度对照（回归守卫，R15）：
#              经 squid 取索引页 vs 源站直连（cache-buster）取同一页，
#              比对版本清单（href 集合）+ 留档 Cache-Control/Age/Cache-Status。
#              清单不一致 = 18:32:58 事故形态。
#
# 用法：
#   bash test-squid/repro-stale-index.sh mock
#   bash test-squid/repro-stale-index.sh cacheability
#   bash test-squid/repro-stale-index.sh parity
#
# 可覆盖：
#   PX                 squid 地址（默认取 HTTP_PROXY/http_proxy；空=直连，
#                      mock 子命令将记 SKIP——机制复现必须有代理）
#   PORT               mock origin 端口（默认 18093）
#   ORIGIN_HOST        mock origin 主机 IP（默认本 pod IP；本地 docker 验证可设 127.0.0.1）
#   RESULTS            结果目录（默认 /tmp/repro-stale-index）
#   STALE_INDEX_URL    真实索引页 URL（默认 mirrors triton-ascend 索引）
#   STALE_MAX_AGE_S    短 TTL 判定阈值（默认 900s：修复建议 max 10min + 5min 余量）
#   STALE_STRICT       1=经 squid 的 HIT 且 Age 超阈值判红（短 TTL 规则未生效）
#
# 退出码：0=PASS（未供旧页/清单一致）；1=FAIL（供旧索引页/清单不一致）；2=SKIP（取证不足）
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_PID=""
trap '[ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null' EXIT
results="${RESULTS:-${RESULTS_DIR:-/tmp/repro-stale-index}}"
mkdir -p "$results"

PX="${PX:-${HTTP_PROXY:-${http_proxy:-}}}"
PORT="${PORT:-18093}"
URL_PATH="/ascend/repos/pypi/triton-ascend/"
STALE_INDEX_URL="${STALE_INDEX_URL:-https://mirrors.huaweicloud.com/ascend/repos/pypi/triton-ascend/}"
STALE_MAX_AGE_S="${STALE_MAX_AGE_S:-900}"
STALE_STRICT="${STALE_STRICT:-0}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 本机 IP：squid 回源要连到本 pod 的 mock origin（127.0.0.1 是 squid 自身 loopback）
origin_host() {
    local ip
    ip=$(hostname -i 2>/dev/null | awk '{print $1}')
    if [ -z "$ip" ]; then
        ip=$(python3 -c "import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(('8.8.8.8',53));print(s.getsockname()[0])" 2>/dev/null)
    fi
    if [ -z "$ip" ]; then
        ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
    fi
    echo "${ip:-127.0.0.1}"
}

hdr_val() {  # hdr_val <header-name> <hdr-file>
    grep -i "^$1:" "$2" 2>/dev/null | tail -1 | tr -d '\r' | cut -d: -f2- | sed 's/^ *//'
}

squid_trace() {  # 响应头里是否有 squid 专属痕迹（Cache-Status/X-Cache-Lookup/Via）
    grep -qiE '^cache-status:.*squid|^x-cache-lookup:|^x-squid-error:|^via:.*squid' "$1" 2>/dev/null
}

cached_served() {  # 该响应是否由缓存对象作答/存在缓存副本
    # HIT（squid 7: `squid-cache;hit;detail=match`）、fwd=stale（直接供旧副本）、
    # detail=mismatch（Vary 不匹配但有存量对象）都说明该页被缓存了
    grep -qiE '^cache-status:.*(hit|fwd=stale|detail=mismatch)|^x-cache-lookup:.*hit' "$1" 2>/dev/null
}

list_links() {  # <html> → 排序去重的 href 文件名（去 #fragment、取 basename；兼容单/双引号）
    grep -oiE "href=[\"'][^\"']+[\"']" "$1" 2>/dev/null \
        | sed -E "s/href=[\"']([^\"']+)[\"']/\1/" \
        | sed -E 's/#.*$//' \
        | awk -F/ 'NF { print $NF }' \
        | sort -u
}

# =============================================================================
# mock 子命令：机制复现（长 max-age + 源站翻页后仍供旧页）
# =============================================================================
mock_case() {
    if [ -z "$PX" ]; then
        echo "⚠️ 无代理 env（HTTP_PROXY 为空）——机制复现必须经 squid，记 SKIP（本地只能验脚本逻辑）"
        return 2
    fi

    local state="$results/mock-generation" url base ip i code
    local warm_hit=0 warm_miss=0 stale=0 fresh=0 trace=0
    local token="$(date +%s)-$$"

    # mock origin：索引页带 15 天 max-age；Last-Modified/ETag 随 generation 变化，
    # 支持条件请求（If-Modified-Since / If-None-Match → 304），与真实镜像页同构
    cat > "$results/mock-origin.py" <<'PY'
import os
import sys
import time
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

res_dir = sys.argv[1]
port = int(sys.argv[2])
state = os.path.join(res_dir, "mock-generation")

# 真实镜像页（2026-10-30 直连取证）：
#   Content-Length 8012、Last-Modified 2026-10-28 13:50:19Z、
#   Cache-Control: max-age=1296000、Expires=Date+15d、ETag "6ae1fd9b-1f4c"
#   版本分布 9/9/9/8/8（triton_ascend-3.6.0.post2 共 8 条）
# 旧页（复刻 6902B，缺 post2）= 3.2.1/3.2.2/3.2.2.post2（各 9）+ 3.6.0（8）= 35 条
# 新页（复刻 8012B）= 旧页 + 3.6.0.post2（8 条）
ARCHES = (
    "manylinux_2_27_aarch64.manylinux_2_28_aarch64",
    "manylinux_2_27_x86_64.manylinux_2_28_x86_64",
)


def _links(version: str) -> list:
    names = []
    for tag in ("cp310", "cp311", "cp312", "cp313"):
        for arch in ARCHES:
            names.append("triton_ascend-%s-%s-%s-%s.whl" % (version, tag, tag, arch))
    return names


def _old_links() -> list:
    names = []
    for version in ("3.2.1", "3.2.2", "3.2.2.post2"):
        names += _links(version)
        # 3.2.x 系列另有仅 x86_64 的 cp39 包（与真实页一致，各版本 9 条）
        names.append("triton_ascend-%s-cp39-cp39-manylinux_2_27_x86_64."
                     "manylinux_2_28_x86_64.whl" % version)
    names += _links("3.6.0")  # 8 条
    return names


OLD_LINKS = _old_links()                 # 35 条：旧页清单（无 post2）
POST2_LINKS = _links("3.6.0.post2")      # 8 条：镜像重新生成后新增


def generation() -> int:
    try:
        with open(state) as f:
            return int(f.read().strip() or 1)
    except Exception:
        return 1


def page(gen: int) -> bytes:
    links = list(OLD_LINKS)
    if gen >= 2:
        links += POST2_LINKS
    # 与真实镜像页同格式：单引号 href + `<br />`，每行一条（便于贴近 6902B/8012B）
    rows = ["<a href='%s'>%s</a><br />" % (name, name) for name in links]
    return ("\n".join(rows) + "\n").encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, fmt % args))

    def do_GET(self):
        raw = self.path.split("?")[0]
        if raw == "/health":
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if raw != "/ascend/repos/pypi/triton-ascend/":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        gen = generation()
        body = page(gen)
        try:
            lm = formatdate(os.stat(state).st_mtime, usegmt=True)
        except Exception:
            lm = formatdate(time.time(), usegmt=True)
        etag = '"gen-%d"' % gen
        # 事故源站特征头：15 天 max-age（1296000 秒）
        cache_control = "max-age=1296000"
        expires = formatdate(time.time() + 1296000, usegmt=True)
        inm = self.headers.get("If-None-Match")
        ims = self.headers.get("If-Modified-Since")
        if (inm and inm == etag) or (ims and ims == lm):
            self.send_response(304)
            for k, v in (("Cache-Control", cache_control), ("Expires", expires),
                         ("ETag", etag), ("Last-Modified", lm)):
                self.send_header(k, v)
            self.end_headers()
            return
        self.send_response(200)
        for k, v in (("Content-Type", "text/html"), ("Cache-Control", cache_control),
                     ("Expires", expires), ("ETag", etag), ("Last-Modified", lm),
                     ("Content-Length", str(len(body)))):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)


ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY

    echo 1 > "$state"
    python3 "$results/mock-origin.py" "$results" "$PORT" > "$results/origin.log" 2>&1 &
    MOCK_PID=$!

    for i in $(seq 1 20); do
        curl -sS --max-time 2 --noproxy '*' "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
        sleep 1
    done
    if ! curl -sS --max-time 2 --noproxy '*' "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
        echo "❌ mock origin 未就绪（端口 $PORT），日志：$(tail -n 3 "$results/origin.log" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi

    ip="${ORIGIN_HOST:-$(origin_host)}"
    base="http://$ip:$PORT"
    # run 唯一 query：同 run 内预热/翻页后共用同一缓存键，跨 run 不撞（R5）
    url="$base$URL_PATH?run=$token"
    log "mock origin=$base  url=$url  proxy=$PX"

    # ① 预热：同 URL 经 squid 连打（多副本各存一份旧页）
    # 注意：实测 curl 的 -x 仍受 NO_PROXY 影响（NO_PROXY 命中目标即绕过代理），
    # 故显式清空 NO_PROXY，确保流量真的落在 squid 上
    for i in $(seq 1 6); do
        code=$(NO_PROXY='' no_proxy='' curl -sS --max-time 30 -x "$PX" -L -D "$results/warm-$i.hdr" \
               -o "$results/warm-$i.html" -w '%{http_code}' "$url" 2>"$results/warm-$i.err") || code="000"
        printf 'warm-%d\thttp=%s\t%s\n' "$i" "$code" \
               "$(hdr_val 'cache-status' "$results/warm-$i.hdr")" >> "$results/mock-requests.tsv"
        squid_trace "$results/warm-$i.hdr" && trace=$((trace + 1))
        if grep -qiE 'detail=hit|x-cache-lookup:.*hit' "$results/warm-$i.hdr"; then
            warm_hit=$((warm_hit + 1))
        else
            warm_miss=$((warm_miss + 1))
        fi
    done
    if [ "$trace" -eq 0 ]; then
        echo "⚠️ 预热响应无 squid 专属痕迹——流量未经过 squid（或对象不可缓存），记 SKIP"
        return 2
    fi
    if grep -q '3.6.0.post2' "$results"/warm-*.html 2>/dev/null; then
        echo "❌ 预热阶段就拿到 post2（generation 初值或缓存键异常）"
        return 1
    fi
    echo "预热：${warm_hit} 次 HIT / ${warm_miss} 次 MISS（squid 痕迹 ${trace}/6）"
    echo "旧页源站头：Cache-Control=$(hdr_val 'cache-control' "$results/warm-1.hdr")  Last-Modified=$(hdr_val 'last-modified' "$results/warm-1.hdr")"

    # ② 源站翻页：镜像重新生成索引（新增 8 条 3.6.0.post2）
    echo 2 > "$state"
    sleep 1
    cod=$(curl -sS --max-time 30 --noproxy '*' -L -o "$results/origin-after.html" \
          -w '%{http_code}' "$url&b=$(date +%s%N)" 2>"$results/origin-after.err") || cod="000"
    if [ "$cod" != "200" ] || ! grep -q '3.6.0.post2' "$results/origin-after.html"; then
        echo "❌ 翻页后源站直连未拿到 post2（mock 状态异常，取证失败）"
        return 1
    fi
    echo "源站已翻页：直连新页含 post2（$(wc -c < "$results/origin-after.html")B）"

    # ③ 翻页后再经 squid 请求：源站已新、缓存仍判新鲜 → 应继续供旧页
    for i in $(seq 1 6); do
        code=$(NO_PROXY='' no_proxy='' curl -sS --max-time 30 -x "$PX" -L -D "$results/after-$i.hdr" \
               -o "$results/after-$i.html" -w '%{http_code}' "$url" 2>"$results/after-$i.err") || code="000"
        printf 'after-%d\thttp=%s\t%s\n' "$i" "$code" \
               "$(hdr_val 'cache-status' "$results/after-$i.hdr")" >> "$results/mock-requests.tsv"
        if grep -q '3.6.0.post2' "$results/after-$i.html"; then
            fresh=$((fresh + 1))
        else
            stale=$((stale + 1))
            echo "  第 $i 发仍为旧页：Cache-Status=$(hdr_val 'cache-status' "$results/after-$i.hdr")  Age=$(hdr_val 'age' "$results/after-$i.hdr")"
        fi
    done

    echo "翻页后经 squid：旧页 ${stale}/6，新页 ${fresh}/6"
    # 本阶段仅作机制证据，不参与判定：mock origin 主机是 runner pod IP，
    # 而修复规则（cache deny hc_repo mutable_meta）按 dstdomain 命中 mirrors/repo
    # 华为云域，pod IP 永远不匹配 → 该 URL 必然照样缓存旧页。真实判定看
    # cacheability（真实域是否被缓存）+ parity（真实页清单是否与源站一致）。
    if [ "$stale" -gt 0 ]; then
        echo "⚠️ 机制证据：源站已翻页（含 post2），经 squid 仍有 ${stale}/6 供旧页——"
        echo "   复现了 18:32:58 的陷阱形态（可变索引页被按 15 天 max-age 判新鲜）"
        echo "   （本阶段不判红：mock 主机是 pod IP，域级 deny 规则不适用于该 URL）"
        return 0
    fi
    echo "ℹ️ 翻页后经 squid 全部回源到新页（该 mock URL 未被缓存）"
    return 0
}

# =============================================================================
# parity 子命令：真实索引页新鲜度对照（squid vs 源站直连）
# =============================================================================
parity_case() {
    local url="$STALE_INDEX_URL" bound="$STALE_MAX_AGE_S" strict="$STALE_STRICT"
    local pcode ocode origin_url cc max_age age status

    if [ -z "$PX" ]; then
        echo "⚠️ 无代理 env——无法对照 squid 与源站，记 SKIP"
        return 2
    fi
    echo "索引页：$url"

    # ① 经 squid（显式 -x；清空 NO_PROXY 保证不被直连规则绕过）
    pcode=$(NO_PROXY='' no_proxy='' curl -sS --max-time 60 -x "$PX" -L -D "$results/parity-proxy.hdr" \
            -o "$results/parity-proxy.html" -w '%{http_code}' "$url" 2>"$results/parity-proxy.err") || pcode="000"
    if [ "$pcode" != "200" ]; then
        echo "❌ 经 squid 取索引页失败：http=$pcode $(head -c 160 "$results/parity-proxy.err" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi
    if ! squid_trace "$results/parity-proxy.hdr"; then
        echo "⚠️ 响应无 squid 专属痕迹（流量未经过 squid）——记 SKIP，不判结论"
        return 2
    fi

    # ② 源站直连真相：cache-buster query + no-cache 双保险（绕开沿途缓存）
    case "$url" in
        *\?*) origin_url="$url&__squid_index_probe=$(date +%s%N)" ;;
        *)    origin_url="$url?__squid_index_probe=$(date +%s%N)" ;;
    esac
    ocode=$(curl -sS -L --max-time 60 --noproxy '*' \
            -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
            -D "$results/parity-origin.hdr" -o "$results/parity-origin.html" \
            -w '%{http_code}' "$origin_url" 2>"$results/parity-origin.err") || ocode="000"
    if [ "$ocode" != "200" ]; then
        # 部分静态站对未知 query 返回 404/重定向失败：退回裸 URL（数据可信度下降）
        echo "⚠️ 带 cache-buster 的源站请求 http=$ocode，退回裸 URL 取源站页"
        ocode=$(curl -sS -L --max-time 60 --noproxy '*' \
                -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
                -D "$results/parity-origin.hdr" -o "$results/parity-origin.html" \
                -w '%{http_code}' "$url" 2>"$results/parity-origin.err") || ocode="000"
    fi
    if [ "$ocode" != "200" ]; then
        echo "⚠️ 源站直连不可达（http=$ocode）——无法取得真值，记 SKIP（换 runner/改 STALE_INDEX_URL 再跑）"
        head -c 160 "$results/parity-origin.err" 2>/dev/null | sed 's/^/    | /'
        return 2
    fi

    list_links "$results/parity-proxy.html"  > "$results/parity-proxy.links"
    list_links "$results/parity-origin.html" > "$results/parity-origin.links"
    if [ ! -s "$results/parity-origin.links" ]; then
        echo "⚠️ 源站页面无可解析 href（可能不是 PEP 503 索引页）——记 SKIP"
        return 2
    fi

    cc=$(hdr_val 'cache-control' "$results/parity-origin.hdr")
    max_age=$(echo "$cc" | grep -oiE 'max-age=[0-9]+' | head -1 | cut -d= -f2)
    status=$(hdr_val 'cache-status' "$results/parity-proxy.hdr")
    age=$(hdr_val 'age' "$results/parity-proxy.hdr")
    printf 'index-parity\t%s\tsquid: %s Age=%s\torigin: last=%s cc=%s\n' \
        "$url" "${status:-N/A}" "${age:-N/A}" \
        "$(hdr_val 'last-modified' "$results/parity-origin.hdr")" "${cc:-N/A}" \
        >> "$results/stale-index.tsv"

    local missing extra
    missing=$(comm -23 "$results/parity-origin.links" "$results/parity-proxy.links")
    extra=$(comm -13 "$results/parity-origin.links" "$results/parity-proxy.links")

    echo "版本条目：源站 $(wc -l < "$results/parity-origin.links") 条 / 经 squid $(wc -l < "$results/parity-proxy.links") 条"
    echo "源站头：Cache-Control=${cc:-N/A}  Expires=$(hdr_val 'expires' "$results/parity-origin.hdr")"
    echo "squid 头：Cache-Status=${status:-N/A}  Age=${age:-N/A}s  Date=$(hdr_val 'date' "$results/parity-proxy.hdr")"

    if [ -n "$missing" ] || [ -n "$extra" ]; then
        echo "❌ 索引页清单与源站不一致——18:32:58 事故形态（旧页被判新鲜、未回源验证）"
        [ -n "$missing" ] && { echo "   源站独有（经 squid 缺失）$(echo "$missing" | wc -l) 条："; echo "$missing" | head -10 | sed 's/^/     - /'; }
        [ -n "$extra" ]   && { echo "   经 squid 独有（源站已无）$(echo "$extra" | wc -l) 条："; echo "$extra" | head -10 | sed 's/^/     - /'; }
        return 1
    fi

    echo "✅ 清单一致（$(wc -l < "$results/parity-origin.links") 条版本，sha256：proxy=$(sha256sum "$results/parity-proxy.links" | cut -c1-12) origin=$(sha256sum "$results/parity-origin.links" | cut -c1-12)）"

    # ③ 短 TTL 生效性（取证）：HIT 且 Age 已超阈值 = 源站 15 天 max-age 仍直接生效
    if [ -n "$max_age" ] && [ "$max_age" -gt "$bound" ] && [ -n "$age" ] && [ "$age" -gt "$bound" ] \
       && echo "$status" | grep -qiE 'detail=hit|x-cache-lookup:.*hit'; then
        echo "⚠️ 短 TTL 规则疑似未生效：源站 max-age=${max_age}s，经 squid HIT 时 Age=${age}s（>${bound}s 仍未回源验证）"
        if [ "$strict" = "1" ]; then
            echo "❌ STALE_STRICT=1：期望索引页按短 TTL（≤${bound}s）回源验证"
            return 1
        fi
    fi
    return 0
}

# =============================================================================
# cacheability 子命令：真实域索引页「是否被缓存」判定（主判定）
#   可变索引页必须每次回源（gy-006 用 cache deny hc_repo mutable_meta 实现，
#   path ^/ascend/repos/.*/$）。做法：真实域 URL 带 run 唯一 query（缓存键全新，
#   不受历史对象影响），连打 4 次；只要有一发由缓存对象作答（HIT / fwd=stale）
#   就说明这张索引页被缓存了 → 就是 18:32:58 事故的温床 → 判 FAIL。
#   唯一 query 对源站无影响（已实测 200 / 8012B，与裸 URL 同页）。
# =============================================================================
cacheability_case() {
    local i token probe_url code hit=0 miss=0 other=0 trace=0
    local status age

    if [ -z "$PX" ]; then
        echo "⚠️ 无代理 env——无法判定索引页缓存性，记 SKIP"
        return 2
    fi

    token="$(date +%s)-$$"
    case "$STALE_INDEX_URL" in
        *\?*) probe_url="$STALE_INDEX_URL&__idx_probe=$token" ;;
        *)    probe_url="$STALE_INDEX_URL?__idx_probe=$token" ;;
    esac
    echo "缓存性判定：$probe_url"

    for i in $(seq 1 4); do
        # 固定 Accept-Encoding：真实页带 Vary: Accept-Encoding，请求头一致才可能 HIT
        # （否则 Vary 不匹配会让本就该判红的情况看起来像 MISS）
        code=$(NO_PROXY='' no_proxy='' curl -sS --max-time 60 -x "$PX" -H 'Accept-Encoding: gzip' \
               -D "$results/cacheable-$i.hdr" \
               -o "$results/cacheable-$i.html" -w '%{http_code}' "$probe_url" 2>"$results/cacheable-$i.err") || code="000"
        status=$(hdr_val 'cache-status' "$results/cacheable-$i.hdr")
        age=$(hdr_val 'age' "$results/cacheable-$i.hdr")
        printf 'cacheability-%d\thttp=%s\t%s\tAge=%s\n' "$i" "$code" "${status:-N/A}" "${age:-N/A}" \
            >> "$results/cacheability.tsv"
        echo "  第 $i 发：http=$code  Cache-Status=${status:-N/A}  Age=${age:-N/A}"
        squid_trace "$results/cacheable-$i.hdr" && trace=$((trace + 1))
        if [ "$code" != "200" ]; then
            other=$((other + 1))
        elif cached_served "$results/cacheable-$i.hdr"; then
            hit=$((hit + 1))
        elif echo "$status" | grep -qiE 'miss'; then
            miss=$((miss + 1))
        else
            other=$((other + 1))
        fi
    done

    if [ "$trace" -eq 0 ]; then
        echo "⚠️ 4 发都无 squid 专属痕迹——流量未经过 squid，记 SKIP"
        return 2
    fi
    if [ "$hit" -gt 0 ]; then
        echo "❌ 可变索引页被缓存：同 URL 连打 4 发中有 ${hit} 发由缓存对象作答（HIT / fwd=stale）"
        echo "   后果：镜像重新生成索引后，客户端仍拿到旧版本清单 → pip 报 No matching distribution found"
        echo "   修复：cache deny 覆盖 (mirrors|repo).huaweicloud.com/ascend/repos/ 的索引页路径"
        return 1
    fi
    if [ "$miss" -ge 3 ]; then
        echo "✅ 索引页不缓存：4 发全部回源（MISS ${miss}/4，无 HIT），与可变元数据策略一致"
        return 0
    fi
    echo "⚠️ 判定证据不足（MISS ${miss}/4，HIT ${hit}/4，无结论 ${other}/4）——记 SKIP"
    return 2
}

case "${1:-}" in
    mock)         mock_case ;;
    cacheability) cacheability_case ;;
    parity)       parity_case ;;
    *) echo "用法: $0 mock|cacheability|parity（mock=机制证据；cacheability=真实域是否被缓存；parity=真实页清单对照）" >&2; exit 2 ;;
esac
