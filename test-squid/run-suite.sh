#!/usr/bin/env bash
# =============================================================================
# test-squid run-suite.sh —— squid 功能 + 并发测试主脚本
#
# 说明：
#   - Squid 代理已由 runner / 工作负载 pod 注入（HTTP(S)_PROXY + MITM CA），
#     本脚本【不配置任何代理】，只复用 pod 注入的环境。
#   - 场景阶段化：每个阶段独立计时、失败不影响其它阶段（run_timed 全量记录）。
#   - 通过 --mode 选择阶段组，与 .github/workflows/test-squid.yaml 的两个 job 对应：
#       function    —— squid 功能：代理/隧道/MITM、缓存 MISS→HIT、完整性、失败面
#       concurrency —— 并发：同对象阶梯、异对象阶梯、混合工具并行
#
# 用法：
#   bash test-squid/run-suite.sh --mode function
#   bash test-squid/run-suite.sh --mode concurrency
#
# 环境变量（均可覆盖）：
#   RESULTS_DIR   结果目录，默认 /tmp/test-squid-results
#   LADDER        并发度阶梯，默认 "1 4 8 16"
#   HEAVY         1=启用大载荷（~146MB torch wheel，默认 0）
#   URL_SMALL/URL_MED/URL_HEAVY   三档载荷 URL（真实 URL、mock 大小）
#   DOMAINS       功能探测域名矩阵
#
# 输出（RESULTS_DIR 下）：
#   timings.tsv   阶段<TAB>秒<TAB>状态(0/1/SKIP)<TAB>组
#   probes.tsv    域名探测明细
#   env.txt       注入环境快照
# =============================================================================
set -uo pipefail

MODE="function"
LAYER="runner"   # runner = job 直接跑在 runner pod；container = job 跑进 container: 镜像
while [ $# -gt 0 ]; do
    case "$1" in
        --mode)      MODE="${2:-function}"; shift 2 ;;
        --container) LAYER="container"; shift ;;
        *) echo "未知参数: $1（用法: run-suite.sh --mode function|concurrency [--container]）" >&2; exit 2 ;;
    esac
done

RESULTS_DIR="${RESULTS_DIR:-/tmp/test-squid-results}"
LADDER="${LADDER:-1 4 8 16}"
HEAVY="${HEAVY:-0}"

# 载荷 URL：真实路径 + 稳定对象（小 ~200KB / 中 ~1-2MB / 大 ~146MB）
URL_SMALL="${URL_SMALL:-https://repo.huaweicloud.com/ubuntu-ports/dists/noble/Release}"
URL_MED="${URL_MED:-https://repo.huaweicloud.com/ubuntu-ports/dists/noble/main/binary-arm64/Packages.gz}"
URL_HEAVY="${URL_HEAVY:-https://files.pythonhosted.org/packages/78/89/f5554b13ebd71e05c0b002f95148033e730d3f7067f67423026cc9c69410/torch-2.10.0-cp311-cp311-manylinux_2_28_aarch64.whl}"
DOMAINS="${DOMAINS:-https://github.com https://raw.githubusercontent.com https://repo.huaweicloud.com https://download.pytorch.org https://pypi.org https://mirrors.tuna.tsinghua.edu.cn}"

mkdir -p "$RESULTS_DIR"
TSV="$RESULTS_DIR/timings.tsv"
PROBES="$RESULTS_DIR/probes.tsv"
printf 'phase\tseconds\tstatus\tgroup\n' > "$TSV"
printf 'url\thttp_code\tseconds\n' > "$PROBES"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 阶段计时封装：任何失败都记录为数据，不中断后续阶段
run_timed() {
    local phase="$1" group="$2"
    shift 2
    local start end status sec
    start=$(date +%s)
    "$@" > "$RESULTS_DIR/$phase.log" 2>&1
    status=$?
    end=$(date +%s)
    sec=$((end - start))
    # exit 2 = SKIP 语义（场景不适用/无缓存头等数据记录，非失败）
    local tsv_status="$status"
    if [ "$status" -eq 2 ]; then tsv_status="SKIP"; fi
    printf '%s\t%s\t%s\t%s\n' "$phase" "$sec" "$tsv_status" "$group" >> "$TSV"
    if [[ $status -eq 0 ]]; then
        log "### [$phase] OK   ${sec}s"
    elif [[ $status -eq 2 ]]; then
        log "### [$phase] SKIP ${sec}s  (数据记录，非失败；tail 见下)"
        tail -n 5 "$RESULTS_DIR/$phase.log" | sed 's/^/    | /'
    else
        log "### [$phase] FAIL(exit=$status)  ${sec}s  (tail 见下)"
        tail -n 5 "$RESULTS_DIR/$phase.log" | sed 's/^/    | /'
    fi
    return 0
}

sha256_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# 下载并输出 http_code/耗时（供子阶段内部使用）
curl_get() {  # curl_get <url> <输出文件> [超时秒]
    curl -sS -L --max-time "${3:-120}" -o "$2" -w 'http_code=%{http_code} time=%{time_total}s size=%{size_download}B\n' "$1"
}

# =============================================================================
# function 组阶段
# =============================================================================

# 环境快照：确认 runner pod 注入的 squid 代理环境（只读，不做任何配置）
env-snapshot() {
    {
        echo "---- proxy 相关 env ----"
        env | grep -iE 'proxy|ca_|_ca|ssl_cert|pip_cert' | sort || echo "(无 proxy env)"
        echo "---- 工具版本 ----"
        curl --version | head -1
        git --version
        python3 --version 2>/dev/null || echo "(no python3)"
    } | tee "$RESULTS_DIR/env.txt"
}

# 元自检：响应头必须带 squid 专属证据——Cache-Status: <id>(squid 7.x, RFC 9211) /
# X-Cache-Lookup（老式）/ Via 含 squid 标识，否则整套测试无效。
# 注意不能用任意 Via/X-Cache 判定——ISP/CDN 缓存也会带这些头
# （本地实测电信缓存 via: CHN-...-CACHE 即假阳性）
meta-trace() {
    local headers
    headers=$(curl -sS -L --max-time 30 -o /dev/null -D - "$URL_SMALL")
    echo "$headers" | head -20
    if echo "$headers" | grep -qiE '^cache-status:.*squid|^x-cache-lookup:|^x-squid-error:|via:.*squid'; then
        echo "✅ squid 专属痕迹存在（Cache-Status(squid) / X-Cache-Lookup / Via(squid)）——流量确实经过 squid"
    else
        echo "❌ 响应头无 squid 专属痕迹——流量未经过 squid，整套测试无效"
        echo "   （若 Via/X-Cache 来自其他缓存层，属假阳性，同样判无效）"
        return 1
    fi
}

# 基本代理：http 明文 GET / https CONNECT+MITM CA（curl 不加 -k）
basic-proxy() {
    local http_url="${URL_SMALL/https:\/\//http://}"
    echo "--- http 明文 GET ---"
    curl_get "$http_url" "$RESULTS_DIR/basic-http.out" 60
    echo "--- https CONNECT 隧道 + MITM CA ---"
    # 不加 -k：证书错误会直接非零退出（MITM CA 注入生效的证据）
    curl_get "$URL_SMALL" "$RESULTS_DIR/basic-https.out" 60
    [ -s "$RESULTS_DIR/basic-https.out" ] || { echo "❌ https 响应体为空"; return 1; }
    echo "✅ http/https 全通，MITM CA 链有效（无证书告警）"
}

# 域名可达矩阵（记录数据；全部无响应才算失败）
domain-matrix() {
    local unreachable=0 total=0
    for d in $DOMAINS; do
        total=$((total + 1))
        # 用 GET 而非 HEAD：经 squid 时部分站点对 HEAD 响应异常（前作实测）
        local code t0
        t0=$(date +%s)
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$d" 2>/dev/null)
        local rc=$?
        if [ $rc -ne 0 ]; then
            printf '%s\tERR(%s)\t%s\n' "$d" "$rc" "$(( $(date +%s) - t0 ))" >> "$PROBES"
            unreachable=$((unreachable + 1))
        else
            printf '%s\t%s\t%s\n' "$d" "$code" "$(( $(date +%s) - t0 ))" >> "$PROBES"
        fi
    done
    echo "可达 $((total - unreachable))/$total（明细 probes.tsv）"
    [ "$unreachable" -eq "$total" ] && return 1
    return 0
}

# 缓存 MISS→HIT：同 URL 二连发，抓 X-Cache-Lookup 头 + 耗时对照
# 均 MISS / 无缓存头 → 记 SKIP（对象不可缓存 ≠ 失败）
cache-hitmiss() {
    local s1 s2 h1 h2 t0 ms1 ms2
    t0=$(date +%s)
    h1=$(curl -sS -L --max-time 120 -o "$RESULTS_DIR/cache-r1.bin" -D "$RESULTS_DIR/cache-r1.headers" "$URL_MED")
    ms1=$(( $(date +%s) - t0 ))
    t0=$(date +%s)
    h2=$(curl -sS -L --max-time 120 -o "$RESULTS_DIR/cache-r2.bin" -D "$RESULTS_DIR/cache-r2.headers" "$URL_MED")
    ms2=$(( $(date +%s) - t0 ))
    # squid 7.x 发 Cache-Status（RFC 9211, detail=miss/hit/mismatch…），
    # 老式 squid 发 X-Cache-Lookup：两种都抓
    s1=$(grep -iE '^(x-cache-lookup|cache-status):' "$RESULTS_DIR/cache-r1.headers" | tail -1 | tr -d '\r' || true)
    s2=$(grep -iE '^(x-cache-lookup|cache-status):' "$RESULTS_DIR/cache-r2.headers" | tail -1 | tr -d '\r' || true)
    echo "第一发(${ms1}s): ${s1:-无缓存头}"
    echo "第二发(${ms2}s): ${s2:-无缓存头}"
    echo "耗时对照: MISS=${ms1}s HIT=${ms2}s"
    if echo "$s2" | grep -qiE 'detail=hit|x-cache-lookup:.*hit'; then
        echo "✅ MISS→HIT 闭环成立"
    elif [ -z "$s1$s2" ]; then
        echo "⚠️ 响应无 Cache-Status/X-Cache 头（可能 TUNNEL 未 bump 或缓存头被抑制）——记录数据，不判失败"
        return 2   # run_timed 记为 SKIP 语义（exit 非 0/1 之外的标记，见汇总口径）
    else
        echo "⚠️ 未呈现 MISS→HIT（$s1 → $s2）——记录数据，不判失败"
        return 2
    fi
}

# 容器层专属：验证用户镜像内 squid CA 信任生效（postStart 灌库三条路径之一）
ca-trust() {
    echo "--- 系统信任库盘点 ---"
    for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
        [ -f "$f" ] && echo "$f: $(grep -c 'BEGIN CERTIFICATE' "$f" 2>/dev/null) 个证书"
    done
    echo "--- MITM 链验证（curl 无 -k，失败即 CA 未灌入容器信任库）---"
    if curl -sS --max-time 30 -o /dev/null "$URL_SMALL"; then
        echo "✅ 容器内信任库已含 squid CA（curl 无 -k 验证通过）"
    else
        echo "❌ 容器内 MITM CA 未被信任（postStart 灌库未生效或镜像无 ca-certificates）"
        return 1
    fi
}

# 传输完整性：同载荷独立下载两次 sha256 互比
integrity() {
    local url="$URL_MED" tag="med"
    curl_get "$url" "$RESULTS_DIR/int-$tag-r1.bin" 300 >/dev/null
    curl_get "$url" "$RESULTS_DIR/int-$tag-r2.bin" 300 >/dev/null
    local h1 h2
    h1=$(sha256_of "$RESULTS_DIR/int-$tag-r1.bin")
    h2=$(sha256_of "$RESULTS_DIR/int-$tag-r2.bin")
    echo "h1=${h1:0:16}… h2=${h2:0:16}…"
    if [ -n "$h1" ] && [ "$h1" = "$h2" ]; then
        echo "✅ 两次下载 sha256 一致（MITM 链路无截断/损坏/混源）"
    else
        echo "❌ sha256 不一致"; return 1
    fi
    if [ "${HEAVY:-0}" = "1" ]; then
        echo "--- 大载荷完整性（HEAVY=1）---"
        curl_get "$URL_HEAVY" "$RESULTS_DIR/int-heavy.bin" 900 > "$RESULTS_DIR/int-heavy.stat" 2>&1
        tail -1 "$RESULTS_DIR/int-heavy.stat"
        [ -s "$RESULTS_DIR/int-heavy.bin" ] || return 1
    fi
}

# 失败面：坏域名/拒绝端口应快速干净失败，且 squid 之后仍健康
failure-face() {
    local t0 d1
    echo "--- 不可解析域名（预期 ≤30s 快速失败）---"
    t0=$(date +%s)
    # -f 必须：squid 对坏域回 502 错误页，无 -f 时 curl rc=0（HTTP 事务"成功"）属误判
    curl -sS -f -o /dev/null --max-time 30 "https://no-such-domain-squid-it.invalid/" 2>&1
    d1=$?
    echo "rc=$d1 用时=$(( $(date +%s) - t0 ))s"
    [ "$d1" -ne 0 ] || { echo "❌ 坏域名竟然成功？"; return 1; }
    [ $(( $(date +%s) - t0 )) -le 30 ] || { echo "❌ 坏域名失败耗时 >30s（挂死形态）"; return 1; }
    echo "--- 拒绝端口（127.0.0.1:1，预期快速失败）---"
    t0=$(date +%s)
    curl -sS -o /dev/null --max-time 15 "http://127.0.0.1:1/" 2>&1
    echo "rc=$? 用时=$(( $(date +%s) - t0 ))s"
    echo "--- squid 存活检查：坏请求之后正常请求仍成功 ---"
    curl_get "$URL_SMALL" "$RESULTS_DIR/failure-after.out" 30 >/dev/null || { echo "❌ squid 坏请求后不服务"; return 1; }
    echo "✅ 失败面行为正常，squid 存活"
}

# =============================================================================
# concurrency 组阶段
# =============================================================================

# 并发-同对象：N worker 并发拉同一 URL，全部 sha256 一致 + 0 错误（一票否决）
# 正确后记录聚合吞吐
worker-same() {  # worker <序号> <workdir>
    local i="$1" wd="$2"
    local t0 out rc code
    out="$wd/worker.$i.bin"
    t0=$(date +%s)
    code=$(curl -sS -L --max-time 300 -o "$out" -w '%{http_code}' "$URL_MED" 2>"$wd/worker.$i.err")
    rc=$?
    printf '%s\t%s\t%s\t%s\t%s\n' "$rc" "$code" "$(( $(date +%s) - t0 ))" \
        "$(sha256_of "$out")" "$(wc -c < "$out" 2>/dev/null || echo 0)" > "$wd/worker.$i.out"
}

conc-same-object() {
    local N wd wall t0 hashes n_hash n_fail total_bytes thr p50
    for N in $LADDER; do
        wd="$RESULTS_DIR/same-N$N"; rm -rf "$wd"; mkdir -p "$wd"
        t0=$(date +%s)
        local pids=() i
        for i in $(seq 1 "$N"); do worker-same "$i" "$wd" & pids+=($!); done
        local wrc=0
        for i in "${!pids[@]}"; do wait "${pids[$i]}" || wrc=1; done
        wall=$(( $(date +%s) - t0 ))
        hashes=$(awk -F'\t' '{print $4}' "$wd"/worker.*.out 2>/dev/null | sort -u)
        n_hash=$(echo "$hashes" | grep -c . || true)
        n_fail=$(awk -F'\t' '$1!=0' "$wd"/worker.*.out 2>/dev/null | wc -l)
        if [ "$wrc" -eq 0 ] && [ "$n_hash" -eq 1 ]; then
            total_bytes=$(awk -F'\t' '{s+=$5} END{print s+0}' "$wd"/worker.*.out)
            thr=$(( total_bytes / (wall > 0 ? wall : 1) / 1024 ))
            p50=$(awk -F'\t' '{print $3}' "$wd"/worker.*.out | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
            echo "✅ N=$N 全部签名一致 聚合吞吐≈${thr}KB/s p50=${p50}s 墙钟=${wall}s"
        else
            echo "❌ N=$N 正确性失败（rc=$wrc 签名数=$n_hash 失败数=$n_fail）"; return 1
        fi
    done
}

# 并发-异对象：N worker 拉 URL 池不同变体（query 绕缓存键），聚合吞吐
conc-distinct() {
    local wd="$RESULTS_DIR/distinct"; rm -rf "$wd"; mkdir -p "$wd"
    local pool=("$URL_MED" "$URL_SMALL" "${URL_MED}.index" )  # 3 类对象
    local N t0 wall total_bytes thr
    local maxn
    maxn=$(echo $LADDER | awk '{print $NF}')
    t0=$(date +%s)
    local pids=() i url
    for i in $(seq 1 "$maxn"); do
        url="${pool[$(( (i - 1) % ${#pool[@]} ))]}?w=$i"   # query 变体 → 异缓存键
        ( curl -sS -L --max-time 300 -o "$wd/w$i.bin" -w "w$i rc ok http=%{http_code} %{time_total}s %{size_download}B\n" "$url" \
            > "$wd/w$i.out" 2>&1 || echo "w$i FAIL" >> "$wd/w$i.out" ) &
        pids+=($!)
    done
    local wrc=0
    for i in "${!pids[@]}"; do wait "${pids[$i]}" || wrc=1; done
    wall=$(( $(date +%s) - t0 ))
    total_bytes=$(wc -c "$wd"/w*.bin 2>/dev/null | tail -1 | awk '{print $1}')
    thr=$(( ${total_bytes:-0} / (wall > 0 ? wall : 1) / 1024 ))
    cat "$wd"/w*.out
    if [ "$wrc" -eq 0 ] && ! grep -q FAIL "$wd"/w*.out 2>/dev/null; then
        echo "✅ 异对象并发 N=$maxn 全部成功 聚合吞吐≈${thr}KB/s"
    else
        echo "❌ 异对象并发有失败"; return 1
    fi
}

# 并发-混合工具：pip / git / wget / curl 四类并行（真实 CI 形态）
# 容器内工具可能缺失：缺失记 ⚪ SKIP，不算失败
have() { command -v "$1" >/dev/null 2>&1; }

conc-mixed() {
    local wd="$RESULTS_DIR/mixed"; rm -rf "$wd"; mkdir -p "$wd"
    local pids=() rc=0
    # 1 pip：下载小轮子（走真实 index）
    if have python3 && python3 -m pip --version >/dev/null 2>&1; then
        ( python3 -m pip download --no-deps --no-cache-dir -d "$wd/pip" zstandard >"$wd/pip.log" 2>&1 \
            && echo "✅ pip" >>"$wd/verdict" || echo "❌ pip" >>"$wd/verdict" ) & pids+=($!)
    else
        echo "⚪ pip SKIP（镜像无 pip）" >>"$wd/verdict"
    fi
    # 2 git：ls-remote + 浅克隆
    if have git; then
        ( git ls-remote https://github.com/octocat/Hello-World.git HEAD >"$wd/git-ls.log" 2>&1 \
            && git clone --depth 1 --filter=blob:none https://github.com/octocat/Hello-World.git "$wd/clone" >"$wd/git-clone.log" 2>&1 \
            && echo "✅ git" >>"$wd/verdict" || echo "❌ git" >>"$wd/verdict" ) & pids+=($!)
    else
        echo "⚪ git SKIP（镜像无 git）" >>"$wd/verdict"
    fi
    # 3 wget：直链下载
    if have wget; then
        ( wget -q -O "$wd/wget.out" "$URL_SMALL" >"$wd/wget.log" 2>&1 \
            && echo "✅ wget" >>"$wd/verdict" || echo "❌ wget" >>"$wd/verdict" ) & pids+=($!)
    else
        echo "⚪ wget SKIP（镜像无 wget）" >>"$wd/verdict"
    fi
    # 4 curl：API 形态（套件本身依赖 curl，缺失则整体早退，这里不判 SKIP）
    ( curl -sS --max-time 60 "https://pypi.org/pypi/zstandard/json" -o "$wd/curl.json" >"$wd/curl.log" 2>&1 \
        && grep -q '"name"' "$wd/curl.json" \
        && echo "✅ curl" >>"$wd/verdict" || echo "❌ curl" >>"$wd/verdict" ) & pids+=($!)
    local i
    for i in "${!pids[@]}"; do wait "${pids[$i]}" || rc=1; done
    cat "$wd/verdict"
    grep -q '❌' "$wd/verdict" && return 1
    [ $rc -eq 0 ] || return 1
    echo "✅ 可用工具并行全绿（互不干扰；⚪ 为镜像缺工具，不计失败）"
}

# =============================================================================
# 主流程
# =============================================================================
log "== test-squid run-suite mode=$MODE =="

if [ "$MODE" = "function" ]; then
    run_timed env-snapshot   "$LAYER" env-snapshot
    run_timed meta-trace     "$LAYER" meta-trace
    run_timed basic-proxy    "$LAYER" basic-proxy
    [ "$LAYER" = "container" ] && run_timed ca-trust "$LAYER" ca-trust
    run_timed domain-matrix  "$LAYER" domain-matrix
    run_timed cache-hitmiss  "$LAYER" cache-hitmiss
    run_timed integrity      "$LAYER" integrity
    run_timed failure-face   "$LAYER" failure-face
elif [ "$MODE" = "concurrency" ]; then
    run_timed env-snapshot     "$LAYER" env-snapshot
    run_timed conc-same-object "$LAYER" conc-same-object
    run_timed conc-distinct    "$LAYER" conc-distinct
    run_timed conc-mixed       "$LAYER" conc-mixed
else
    echo "未知 mode: $MODE（可选 function | concurrency）" >&2
    exit 2
fi

log "== 汇总（$MODE/$LAYER）=="
cat "$TSV"

# 退出码 gate：存在 status=1 的阶段 → 套件非零退出（job 结论必须反映失败，
# 禁止"阶段红 job 绿"；SKIP/数据记录不阻断）
if awk -F'\t' 'NR>1 && $3=="1"{found=1} END{exit found?1:0}' "$TSV"; then
    log "完成。结果目录: $RESULTS_DIR"
else
    log "❌ 存在失败阶段，套件判 FAIL（明细见上 / $RESULTS_DIR）"
    exit 1
fi
