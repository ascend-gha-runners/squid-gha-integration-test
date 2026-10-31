#!/usr/bin/env bash
# =============================================================================
# repro-pip-metadata.sh —— PEP 658 metadata 不缓存（编码变体毒化守卫）
#
# 事故（2026-10-31 pip hash 校验失败）：
#   download-r2.pytorch.org 等 CDN 按 Accept-Encoding 实际压缩，但响应不带 Vary；
#   squid 存储副本无 Vary 键 → 首个请求者的编码定型并共享给所有客户端
#   （配置里的 reply_header_replace Vary Accept-Encoding 只改回给客户端的响应头，
#     不影响存储副本与缓存键计算）；pip 的 metadata 请求只收 identity 且不解码
#   （decode_content=False），拿到 gzip 变体后对压缩体算 sha256 必挂。
#
# metadata 特性：KB 级（2-6KB）、内容寻址（文件名含版本+平台）、pip 每次验 hash
#   → 缓存收益趋近零，禁缓存后 MISS 回源代价可忽略。
#
# 命中面：wheel 与 sdist 的 metadata 后缀对所有主机生效（download-r2.pytorch.org、
#   files.pythonhosted.org、repo.huaweicloud.com 等）；.whl/.tar.gz/.zip 本体不以
#   .metadata 结尾，不受影响。
#
# 修复（配置侧，规则见 META.md R22）：
#   acl pip_metadata urlpath_regex -i \.(whl|tar\.gz|zip)\.metadata$
#   cache deny pip_metadata
#   collapsed_forwarding_access deny pip_metadata
#
# 三个子命令：
#   mock —— 自带 mock origin（复刻「CDN 压缩但不发 Vary」形态），主判定：
#           ① 三种 metadata 后缀（.whl.metadata / .tar.gz.metadata / .zip.metadata，
#              run 唯一路径）经 squid 连打，gzip 预热 + identity 请求都不得由缓存
#              对象作答（deny 生效）；
#           ② identity 响应体 sha256 == 源站直连 identity，且不是 gzip 魔数
#              （事故形态：identity 客户端收到 gzip 压缩体）；
#           ③ 同 host 的 .whl/.tar.gz/.zip 本体二连发必须 HIT——负样本守卫：
#              证明本脚本的“HIT 检测”确实能看见缓存，且 deny 没有误伤大对象长缓存。
#   real —— 真实域 metadata（默认 torch wheel 的 PEP 658 metadata）：
#           经 squid 连打 3 发不得 HIT；identity 响应体与源站直连 sha256 一致。
#   pip  —— 真实 pip 客户端（PEP 658 metadata 解析 + hash 校验）：
#           不得出现 hash mismatch（事故的客户端侧签名）。
#
# 用法：
#   bash test-squid/repro-pip-metadata.sh mock
#   bash test-squid/repro-pip-metadata.sh real
#   bash test-squid/repro-pip-metadata.sh pip
#
# 可覆盖：
#   PX                 squid 地址（默认取 HTTP_PROXY/http_proxy；空=直连 → SKIP）
#   PORT               mock origin 端口（默认 18094）
#   ORIGIN_HOST        mock origin 主机 IP（默认本 pod IP；本地 docker 验证可设 127.0.0.1）
#   RESULTS            结果目录（默认 /tmp/repro-pip-metadata）
#   PIP_METADATA_URL   真实 metadata URL（默认 torch wheel + .metadata）
#   PIP_INDEX_URL      pip 子命令的索引（默认为事故源 download.pytorch.org/whl/cpu）
#   PIP_PKG            pip 子命令的目标包（默认 torch==2.10.0）
#
# 退出码：0=PASS；1=FAIL；2=SKIP（无代理 / 无 squid 痕迹 / 源站不可达）
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_PID=""
trap '[ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null' EXIT
results="${RESULTS:-${RESULTS_DIR:-/tmp/repro-pip-metadata}}"
mkdir -p "$results"

PX="${PX:-${HTTP_PROXY:-${http_proxy:-}}}"
PORT="${PORT:-18094}"
# 事故源 URL 的稳定载体：套件里已用于大载荷的 torch wheel（PEP 658 metadata 为
# 同名 URL + .metadata，KB 级）
PIP_METADATA_URL="${PIP_METADATA_URL:-https://files.pythonhosted.org/packages/78/89/f5554b13ebd71e05c0b002f95148033e730d3f7067f67423026cc9c69410/torch-2.10.0-cp311-cp311-manylinux_2_28_aarch64.whl.metadata}"
PIP_INDEX_URL="${PIP_INDEX_URL:-https://download.pytorch.org/whl/cpu}"
PIP_PKG="${PIP_PKG:-torch==2.10.0}"

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

cached_served() {  # 该响应是否由缓存对象作答/存在缓存副本（含 Vary mismatch）
    grep -qiE '^cache-status:.*(hit|fwd=stale|detail=mismatch)|^x-cache-lookup:.*hit' "$1" 2>/dev/null
}

no_cache_marked() {  # squid 判定「不可缓存」的标记（cache deny 命中即 no-cache）
    grep -qiE '^cache-status:.*(no-cache|miss)|^x-cache-lookup:.*miss' "$1" 2>/dev/null
}

file_sha256() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

file_size() {  # 文件不存在时安全返回 0（避免 wc 的重定向报错污染日志）
    if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi
}

is_gzip_magic() {  # 0 = 前两字节是 gzip 魔数 1f8b
    python3 -c 'import sys
try:
    d=open(sys.argv[1],"rb").read(2)
except Exception:
    sys.exit(1)
sys.exit(0 if d==b"\x1f\x8b" else 1)' "$1" 2>/dev/null
}

# =============================================================================
# mock 子命令：机制 + 判定（deny 生效 / identity 不被毒化 / .whl 仍可缓存）
# =============================================================================
mock_case() {
    if [ -z "$PX" ]; then
        echo "⚠️ 无代理 env（HTTP_PROXY 为空）——mock 判定必须经 squid，记 SKIP（本地只能验脚本逻辑）"
        return 2
    fi

    local token="$(date +%s)-$$"
    local state="$results/mock-state"
    local base ip i code st enc body_sha origin_sha
    local gzip_hit=0 gzip_nocache=0 id_hit=0 id_nocache=0 trace=0 art_hit=0

    # mock origin：metadata 按 Accept-Encoding 实际压缩、但不发 Vary（事故源形态）；
    # 路径以 (whl|tar.gz|zip).metadata 结尾，deny 规则对 host 无约束，pod IP 也命中。
    cat > "$results/mock-origin.py" <<'PY'
import gzip
import os
import sys
import time
from email.utils import formatdate
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

res_dir = sys.argv[1]
port = int(sys.argv[2])
prefix = sys.argv[3]          # 形如 /mock-<run-token>

# KB 级 PEP 658 metadata（内容寻址：文件名含版本+平台，pip 每次验 hash）
META_BODY = (b'{"metadata_version":"2.4","name":"demo","version":"1.0.0",'
             b'"summary":"PEP 658 metadata encoding probe (no Vary)",'
             b'"description":"' + b'x' * 2048 + b'"}')

# 本体负样本（.whl/.tar.gz/.zip）：必须仍被长 TTL 缓存（证明 deny 没有误伤）
# 用确定性 LCG 造 64KB 近似随机字节（压缩后仍有量级，避免小对象被当噪声）
_seed = 1
_buf = bytearray()
for _ in range(65536):
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff
    _buf.append((_seed >> 16) & 0xff)
RAW = bytes(_buf)
ARTIFACTS = {
    "demo-1.0.0-py3-none-any.whl": RAW,
    "demo-1.0.0.tar.gz": gzip.compress(RAW, mtime=0),
    "demo-1.0.0.zip": RAW,
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, fmt % args))

    def _common(self, etag, length):
        self.send_header("Cache-Control", "public, max-age=86400")
        self.send_header("ETag", etag)
        self.send_header("Last-Modified", formatdate(time.time(), usegmt=True))
        self.send_header("Content-Length", str(length))

    def do_HEAD(self):
        self.do_GET(head=True)

    def do_GET(self, head=False):
        path = self.path.split("?")[0]
        if path == "/health":
            body = b'{"status":"ok"}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if not head:
                self.wfile.write(body)
            return

        if path.startswith(prefix + "/") and path.endswith(".metadata"):
            # 关键：按 Accept-Encoding 压缩，但不发 Vary（CDN 实况）
            ae = (self.headers.get("Accept-Encoding") or "").lower()
            if "gzip" in ae:
                payload, enc = gzip.compress(META_BODY, mtime=0), "gzip"
            else:
                payload, enc = META_BODY, "identity"
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            if enc == "gzip":
                self.send_header("Content-Encoding", "gzip")
            self.send_header("X-Origin-Encoding", enc)
            self._common('"meta-%s-%d"' % (enc, len(payload)), len(payload))
            self.end_headers()
            if not head:
                self.wfile.write(payload)
            return

        name = path.rsplit("/", 1)[-1]
        if path.startswith(prefix + "/") and name in ARTIFACTS:
            body = ARTIFACTS[name]
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("X-Origin-Encoding", "identity")
            self._common('"artifact-%s-%d"' % (name, len(body)), len(body))
            self.end_headers()
            if not head:
                self.wfile.write(body)
            return

        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()


ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
PY

    echo 1 > "$state"
    python3 "$results/mock-origin.py" "$results" "$PORT" "/mock-$token" > "$results/origin.log" 2>&1 &
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
    log "mock origin=$base  proxy=$PX"

    # wheel + sdist 两种 metadata 后缀（.whl/.tar.gz/.zip）+ 三种本体（负样本）
    local shapes=(
        "demo-1.0.0-py3-none-any.whl.metadata|whl-metadata"
        "demo-1.0.0.tar.gz.metadata|sdist-tgz-metadata"
        "demo-1.0.0.zip.metadata|sdist-zip-metadata"
    )
    local artifacts=(
        "demo-1.0.0-py3-none-any.whl|whl"
        "demo-1.0.0.tar.gz|sdist-tgz"
        "demo-1.0.0.zip|sdist-zip"
    )
    local entry name label url bad_identity=0

    for entry in "${shapes[@]}"; do
        name="${entry%%|*}"; label="${entry##*|}"
        url="$base/mock-$token/$name"

        # ① 源站直连 identity 真值（--noproxy '*' + 显式 identity）
        code=$(curl -sS --max-time 10 --noproxy '*' -H 'Accept-Encoding: identity' \
               -D "$results/mock-origin-$label.hdr" -o "$results/mock-origin-$label.bin" \
               -w '%{http_code}' "$url" 2>"$results/mock-origin-$label.err") || code="000"
        if [ "$code" != "200" ]; then
            echo "❌ mock 直连 identity 取证失败[$label]：http=$code $(head -c 160 "$results/mock-origin-$label.err" 2>/dev/null | tr '\n' ' ')"
            return 1
        fi
        origin_sha=$(file_sha256 "$results/mock-origin-$label.bin")
        echo "源站 identity[$label]：sha256=${origin_sha:0:12} bytes=$(file_size "$results/mock-origin-$label.bin")"

        # ② gzip 预热 ×2（模拟首个请求者定型；修复前第二发会 HIT 并被共享给所有人）
        for i in 1 2; do
            code=$(NO_PROXY='' no_proxy='' curl -sS --max-time 20 -x "$PX" -H 'Accept-Encoding: gzip' \
                   -D "$results/mock-gzip-$label-$i.hdr" -o "$results/mock-gzip-$label-$i.bin" \
                   -w '%{http_code}' "$url" 2>"$results/mock-gzip-$label-$i.err") || code="000"
            st=$(hdr_val 'cache-status' "$results/mock-gzip-$label-$i.hdr")
            enc=$(hdr_val 'x-origin-encoding' "$results/mock-gzip-$label-$i.hdr")
            printf 'mock-gzip-%s-%s\thttp=%s\t%s\torigin-enc=%s\tbytes=%s\n' "$label" "$i" "$code" "${st:-N/A}" \
                "${enc:-N/A}" "$(file_size "$results/mock-gzip-$label-$i.bin")" >> "$results/pip-metadata.tsv"
            echo "  [$label] gzip 预热 $i：http=$code  Cache-Status=${st:-N/A}  origin-enc=${enc:-N/A}"
            squid_trace "$results/mock-gzip-$label-$i.hdr" && trace=$((trace + 1))
            if [ "$code" = "200" ] && cached_served "$results/mock-gzip-$label-$i.hdr"; then
                gzip_hit=$((gzip_hit + 1))
            elif [ "$code" = "200" ] && no_cache_marked "$results/mock-gzip-$label-$i.hdr"; then
                gzip_nocache=$((gzip_nocache + 1))
            fi
        done

        # ③ identity 请求 ×2（pip 形态）：不得收到 gzip 变体，sha 必须等于源站 identity
        for i in 1 2; do
            code=$(NO_PROXY='' no_proxy='' curl -sS --max-time 20 -x "$PX" -H 'Accept-Encoding: identity' \
                   -D "$results/mock-id-$label-$i.hdr" -o "$results/mock-id-$label-$i.bin" \
                   -w '%{http_code}' "$url" 2>"$results/mock-id-$label-$i.err") || code="000"
            st=$(hdr_val 'cache-status' "$results/mock-id-$label-$i.hdr")
            enc=$(hdr_val 'x-origin-encoding' "$results/mock-id-$label-$i.hdr")
            body_sha=$(file_sha256 "$results/mock-id-$label-$i.bin")
            printf 'mock-identity-%s-%s\thttp=%s\t%s\torigin-enc=%s\tsha256=%s\n' "$label" "$i" "$code" \
                "${st:-N/A}" "${enc:-N/A}" "${body_sha:0:12}" >> "$results/pip-metadata.tsv"
            echo "  [$label] identity $i：http=$code  Cache-Status=${st:-N/A}  origin-enc=${enc:-N/A}  sha=${body_sha:0:12}"
            squid_trace "$results/mock-id-$label-$i.hdr" && trace=$((trace + 1))
            if [ "$code" = "200" ] && cached_served "$results/mock-id-$label-$i.hdr"; then
                id_hit=$((id_hit + 1))
            elif [ "$code" = "200" ] && no_cache_marked "$results/mock-id-$label-$i.hdr"; then
                id_nocache=$((id_nocache + 1))
            fi
            if [ "$code" = "200" ]; then
                if [ "$(hdr_val 'content-encoding' "$results/mock-id-$label-$i.hdr")" = "gzip" ] \
                   || is_gzip_magic "$results/mock-id-$label-$i.bin"; then
                    echo "  ❌ [$label] identity $i 收到 gzip 压缩体（origin-enc=${enc:-N/A}）——hash 校验必挂形态"
                    bad_identity=$((bad_identity + 1))
                elif [ "$body_sha" != "$origin_sha" ]; then
                    echo "  ❌ [$label] identity $i 响应体与源站不一致（proxy=${body_sha:0:12} origin=${origin_sha:0:12}）"
                    bad_identity=$((bad_identity + 1))
                fi
            fi
        done
    done

    # ④ 本体负样本（.whl/.tar.gz/.zip）：二连发第二发必须 HIT（证明 deny 未误伤）
    for entry in "${artifacts[@]}"; do
        name="${entry%%|*}"; label="${entry##*|}"
        url="$base/mock-$token/$name"
        for i in 1 2; do
            code=$(NO_PROXY='' no_proxy='' curl -sS --max-time 20 -x "$PX" -H 'Accept-Encoding: identity' \
                   -D "$results/mock-artifact-$label-$i.hdr" -o "$results/mock-artifact-$label-$i.bin" \
                   -w '%{http_code}' "$url" 2>"$results/mock-artifact-$label-$i.err") || code="000"
            st=$(hdr_val 'cache-status' "$results/mock-artifact-$label-$i.hdr")
            printf 'mock-artifact-%s-%s\thttp=%s\t%s\tbytes=%s\n' "$label" "$i" "$code" "${st:-N/A}" \
                "$(file_size "$results/mock-artifact-$label-$i.bin")" >> "$results/pip-metadata.tsv"
            echo "  [$label] 本体负样本 $i：http=$code  Cache-Status=${st:-N/A}"
            squid_trace "$results/mock-artifact-$label-$i.hdr" && trace=$((trace + 1))
            if [ "$i" = "2" ] && [ "$code" = "200" ] && cached_served "$results/mock-artifact-$label-$i.hdr"; then
                art_hit=$((art_hit + 1))
            fi
        done
    done

    if [ "$trace" -eq 0 ]; then
        echo "⚠️ 全部响应无 squid 专属痕迹——流量未经过 squid，记 SKIP"
        return 2
    fi

    echo "统计：metadata gzip HIT=${gzip_hit}/6  identity HIT=${id_hit}/6  本体第二发 HIT=${art_hit}/3  内容异常=${bad_identity}"
    printf 'mock-summary\tgzip_hit=%s\tid_hit=%s\tartifact_hit=%s\tbad_identity=%s\n' \
        "$gzip_hit" "$id_hit" "$art_hit" "$bad_identity" >> "$results/pip-metadata.tsv"

    # 判定 ①：deny 生效（三种后缀的 metadata 都不得由缓存作答）
    if [ "$gzip_hit" -gt 0 ] || [ "$id_hit" -gt 0 ]; then
        echo "❌ metadata 被缓存（gzip HIT=${gzip_hit}，identity HIT=${id_hit}）"
        echo "   后果：首个请求者的编码定型被共享，identity 客户端可能拿到 gzip 压缩体 → sha256 必挂"
        echo "   修复：cache deny pip_metadata（acl pip_metadata urlpath_regex -i \\.(whl|tar\\.gz|zip)\\.metadata$）"
        return 1
    fi
    # 判定 ②：identity 完整性（事故的核心客户端面）
    if [ "$bad_identity" -gt 0 ]; then
        echo "❌ identity 内容异常 ${bad_identity} 处——收到 gzip 变体或与源站不一致，hash 校验必挂"
        return 1
    fi
    # 判定 ③：负样本守卫（.whl/.tar.gz/.zip 本体必须仍能 HIT）
    if [ "$art_hit" -ne 3 ]; then
        echo "❌ 本体第二发命中缓存 ${art_hit}/3——缓存能力不可用或 deny 误伤，metadata 的\"未缓存\"结论不可信"
        return 1
    fi
    echo "✅ 三种 metadata 后缀全部不缓存（gzip ${gzip_nocache}/6、identity ${id_nocache}/6 全部回源），identity 内容与源站一致，本体仍可 HIT"
    return 0
}

# =============================================================================
# real 子命令：真实域 metadata 不缓存 + identity 内容完整性
# =============================================================================
real_case() {
    local url="$PIP_METADATA_URL" i code st origin_sha p_sha hit=0 nocache=0 trace=0 other=0

    if [ -z "$PX" ]; then
        echo "⚠️ 无代理 env——无法判定真实域 metadata 缓存性，记 SKIP"
        return 2
    fi
    echo "metadata URL：$url"

    origin_sha=""
    code=$(curl -sS --max-time 30 --noproxy '*' -H 'Accept-Encoding: identity' \
           -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
           -D "$results/real-origin.hdr" -o "$results/real-origin.bin" \
           -w '%{http_code}' "$url" 2>"$results/real-origin.err") || code="000"
    if [ "$code" = "404" ]; then
        echo "⚠️ 源站无此 metadata（http=404）——换 PIP_METADATA_URL 再跑，记 SKIP"
        return 2
    fi
    if [ "$code" != "200" ]; then
        echo "⚠️ 源站直连不可达（http=$code）——无法取得真值，记 SKIP"
        head -c 160 "$results/real-origin.err" 2>/dev/null | sed 's/^/    | /'
        return 2
    fi
    origin_sha=$(file_sha256 "$results/real-origin.bin")
    echo "源站 identity：sha256=${origin_sha:0:12} bytes=$(wc -c < "$results/real-origin.bin")  cc=$(hdr_val 'cache-control' "$results/real-origin.hdr")"

    for i in 1 2 3; do
        code=$(NO_PROXY='' no_proxy='' curl -sS --max-time 30 -x "$PX" -H 'Accept-Encoding: identity' \
               -D "$results/real-proxy-$i.hdr" -o "$results/real-proxy-$i.bin" \
               -w '%{http_code}' "$url" 2>"$results/real-proxy-$i.err") || code="000"
        st=$(hdr_val 'cache-status' "$results/real-proxy-$i.hdr")
        p_sha=$(file_sha256 "$results/real-proxy-$i.bin")
        printf 'real-metadata-%d\thttp=%s\t%s\tsha256=%s\tbytes=%s\n' "$i" "$code" "${st:-N/A}" \
            "${p_sha:0:12}" "$(wc -c < "$results/real-proxy-$i.bin" 2>/dev/null || echo 0)" \
            >> "$results/pip-metadata.tsv"
        echo "  第 $i 发：http=$code  Cache-Status=${st:-N/A}  sha=${p_sha:0:12}"
        squid_trace "$results/real-proxy-$i.hdr" && trace=$((trace + 1))
        if [ "$code" != "200" ]; then
            other=$((other + 1))
        elif cached_served "$results/real-proxy-$i.hdr"; then
            hit=$((hit + 1))
        elif no_cache_marked "$results/real-proxy-$i.hdr"; then
            nocache=$((nocache + 1))
        else
            other=$((other + 1))
        fi
    done

    if [ "$trace" -eq 0 ]; then
        echo "⚠️ 响应无 squid 专属痕迹（流量未经过 squid）——记 SKIP"
        return 2
    fi
    if [ "$other" -ge 2 ]; then
        echo "⚠️ 经 squid 取 metadata 失败/无结论 ${other}/3 发——记 SKIP（换 runner 或 PIP_METADATA_URL 再跑）"
        head -c 160 "$results/real-proxy-1.err" 2>/dev/null | sed 's/^/    | /'
        return 2
    fi
    if [ "$hit" -gt 0 ]; then
        echo "❌ 真实域 .whl.metadata 被缓存：3 发中 ${hit} 发由缓存对象作答"
        echo "   修复：cache deny pip_metadata（host 无关，download-r2/files.pythonhosted/repo.huaweicloud 全生效）"
        return 1
    fi
    for i in 1 2 3; do
        if [ "$(hdr_val 'content-encoding' "$results/real-proxy-$i.hdr")" = "gzip" ] \
           || is_gzip_magic "$results/real-proxy-$i.bin"; then
            echo "❌ 真实域 identity 请求收到 gzip 压缩体（第 $i 发）——hash 校验必挂"
            return 1
        fi
        if [ "$(file_sha256 "$results/real-proxy-$i.bin")" != "$origin_sha" ]; then
            echo "❌ 真实域 identity 响应体与源站不一致（第 $i 发：proxy=$(file_sha256 "$results/real-proxy-$i.bin" | cut -c1-12) origin=${origin_sha:0:12}）"
            return 1
        fi
    done
    echo "✅ 真实域 metadata 全部回源（${nocache}/3 no-cache/miss），identity 内容与源站一致"
    return 0
}

# =============================================================================
# pip 子命令：真实 pip 客户端解析（PEP 658 metadata + hash 校验）
# =============================================================================
pip_case() {
    local tmp="$results/pip-tmp" ver major minor logf="$results/pip.log"
    if [ -z "$PX" ]; then
        echo "⚠️ 无代理 env——pip 通道必须经 squid，记 SKIP"
        return 2
    fi
    if ! python3 -m pip --version >/dev/null 2>&1; then
        echo "⚠️ 无 pip（python3 -m pip 不可用）——记 SKIP"
        return 2
    fi
    ver=$(python3 -m pip --version 2>/dev/null | awk '{print $2}')
    major=${ver%%.*}
    minor=$(echo "$ver" | cut -d. -f2)
    if [ "${major:-0}" -lt 22 ] || { [ "${major:-0}" -eq 22 ] && [ "${minor:-0}" -lt 2 ]; }; then
        echo "⚠️ pip $ver 不支持 --dry-run（<22.2），无法用 PEP 658 metadata 驱动解析——记 SKIP"
        return 2
    fi

    rm -rf "$tmp"; mkdir -p "$tmp"
    log "pip $ver：index=$PIP_INDEX_URL  pkg=$PIP_PKG"
    # --dry-run --no-deps：只解析不下载整包，pip 会走 PEP 658 metadata 并校验其 hash
    # （事故形态下这里报 THashMismatchError / 哈希不匹配）
    NO_PROXY='' no_proxy='' python3 -m pip install --dry-run --no-deps --ignore-installed \
        --no-cache-dir --disable-pip-version-check --only-binary=:all: \
        --index-url "$PIP_INDEX_URL" -v "$PIP_PKG" > "$logf" 2>&1
    local rc=$?
    local meta_count
    meta_count=$(grep -ciE '\.whl\.metadata|dist-info-metadata' "$logf" 2>/dev/null || true)
    printf 'pip-resolve\texit=%s\tpip=%s\tmetadata_refs=%s\tpkg=%s\n' \
        "$rc" "$ver" "${meta_count:-0}" "$PIP_PKG" >> "$results/pip-metadata.tsv"
    echo "pip exit=$rc  metadata 引用行=${meta_count:-0}（日志 $logf）"

    if [ "$rc" -eq 0 ]; then
        if [ "${meta_count:-0}" -eq 0 ]; then
            echo "⚠️ pip 解析成功，但日志未出现 PEP 658 metadata 引用（该 index 可能未提供 metadata）——PASS 但覆盖度不足"
        else
            echo "✅ pip 解析成功：PEP 658 metadata 请求 ${meta_count} 条引用，未出现 hash 校验失败"
        fi
        return 0
    fi

    # 失败归因：hash 相关 = 事故签名（FAIL）；其余（索引/网络/版本不存在）= SKIP
    if grep -qiE 'hash|sha256|THashMismatch|do not match' "$logf"; then
        echo "❌ pip 报 hash 校验失败——19:xx 事故形态（metadata 编码被毒化或内容不一致）"
        grep -iE 'hash|sha256|THashMismatch|do not match' "$logf" | head -5 | sed 's/^/    | /'
        return 1
    fi
    echo "⚠️ pip 解析失败但非 hash 原因（索引/网络/版本/平台问题）——记 SKIP，不判红（R17）"
    tail -n 5 "$logf" | sed 's/^/    | /'
    return 2
}

case "${1:-}" in
    mock) mock_case ;;
    real) real_case ;;
    pip)  pip_case ;;
    *) echo "用法: $0 mock|real|pip（mock=机制+判定；real=真实域；pip=真实客户端）" >&2; exit 2 ;;
esac
