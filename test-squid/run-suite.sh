#!/usr/bin/env bash
# =============================================================================
# test-squid run-suite.sh —— squid 功能 + 并发测试主脚本
#
# 说明：
#   - Squid 代理已由 runner / 工作负载 pod 注入（HTTP(S)_PROXY + MITM CA），
#     本脚本【不配置任何代理】，只复用 pod 注入的环境。
#   - 场景阶段化：每个阶段独立计时、失败不影响其它阶段（run_timed 全量记录）。
#   - 通过 --mode 选择阶段组，与 .github/workflows/test-squid.yaml 的各 job 对应：
#       function    —— squid 功能：代理/隧道/MITM、缓存 MISS→HIT、完整性、失败面
#       concurrency —— 并发：同对象阶梯、异对象阶梯、混合工具并行
#       cabundle    —— no_proxy 直连 × CA 注入矩阵（独立脚本 no-proxy-ca-test.sh）
#       pkg         —— dnf/yum 包管理链路（openEuler 基底容器；RHEL 系 CA 注入路径）
#       stale-index —— 索引页陈旧复现（源站 15 天 max-age → squid 长期供旧页，
#                      2026-10-29 triton-ascend post2 构建失败回归守卫）
#       pip-metadata —— PEP 658 metadata 不缓存（编码变体毒化守卫，
#                      2026-10-31 pip hash 校验事故，META R22）
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
#   CATLASS_COMMIT/IB_GIT_PROXY/IB_VLLM_REF   imagebuild 组参数（见下文定义处）
#   OBS_CANN_URL/OBS_CANN_REFERER/OBS_COV_JSON/OBS_COV_TGZ/OBS_ELF_URL/OBS_NEG_URL
#                                             OBS 静态资产通道（见下文定义处）
#   TORCH_INDEX_URL/HF_MIRROR_ENDPOINT/MS_DATASET  tools 组特殊通道参数（见定义处）
#
# 输出（RESULTS_DIR 下）：
#   timings.tsv   阶段<TAB>秒<TAB>状态(0/1/SKIP)<TAB>组
#   probes.tsv    域名探测明细
#   env.txt       注入环境快照
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# 宿主机架构：go/git-lfs/shfmt 的工具链 bootstrap 二进制按此选择
# （a3 等 aarch64 runner 上下载 amd64 会 Exec format error，run 38359549887 实证）
case "$(uname -m)" in
    x86_64)        PKG_ARCH="amd64" ;;
    aarch64|arm64) PKG_ARCH="arm64" ;;
    *)             PKG_ARCH="amd64" ;;
esac

# 载荷 URL：真实路径 + 稳定对象（小 ~200KB / 中 ~1-2MB / 大 ~146MB）
URL_SMALL="${URL_SMALL:-https://repo.huaweicloud.com/ubuntu-ports/dists/noble/Release}"
URL_MED="${URL_MED:-https://repo.huaweicloud.com/ubuntu-ports/dists/noble/main/binary-arm64/Packages.gz}"
URL_HEAVY="${URL_HEAVY:-https://files.pythonhosted.org/packages/78/89/f5554b13ebd71e05c0b002f95148033e730d3f7067f67423026cc9c69410/torch-2.10.0-cp311-cp311-manylinux_2_28_aarch64.whl}"

# imagebuild 组：vllm-ascend Dockerfile.310p 外网流量面复刻参数
#   CATLASS_COMMIT  catlass 子模块 .gitmodules 固定 commit（checkout submodules:recursive 形态）
#   IB_GIT_PROXY    镜像内 gitconfig insteadOf 前缀（GIT_PROXY build-arg）；置空 = 直连（本地冒烟）
#   IB_VLLM_REF     vllm tag（Dockerfile VLLM_TAG）；不存在时自动改用最新 tag，避免上游发版打失效 mock
CATLASS_COMMIT="${CATLASS_COMMIT:-41bf90da655bba3c66d0acd7e00abe33960ecfd6}"
IB_GIT_PROXY="${IB_GIT_PROXY:-https://gh-proxy.test.osinfra.cn/}"
IB_VLLM_REF="${IB_VLLM_REF:-v0.11.0}"

# 上游仓库真实 CI 面（2026-10-20，按 sgl-project / vllm-project / volcengine /
# fla-org / hiyouga / alibaba 等仓库 workflow 实测增补）：
#   TORCH_INDEX_URL     torch 官方索引（规则11：pytorch 官方源不重写，经 squid 直通）
#   HF_MIRROR_ENDPOINT  sglang NPU CI 显式 HF_ENDPOINT（真实 CI 现状复刻，见 META R12 注记）
#   MS_DATASET          vllm-ascend / sglang 数据集通道样例（modelscope --dataset）
TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cpu}"
HF_MIRROR_ENDPOINT="${HF_MIRROR_ENDPOINT:-https://hf-mirror.com}"
MS_DATASET="${MS_DATASET:-vllm-ascend/gsm8k-lite}"

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
    # 阶段自身的 stdout 落 <phase>.phase.log：多个 tool-* 阶段内部也往
    # $RESULTS_DIR/<同名>.log 写命令输出，若此处复用同名文件，内层重定向会
    # 截断外层的 fd、真实报错被 NUL 覆盖（wlcb-001 run 41178106355 实证）。
    local plog="$RESULTS_DIR/$phase.phase.log"
    start=$(date +%s)
    "$@" > "$plog" 2>&1
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
        tail -n 5 "$plog" | sed 's/^/    | /'
    else
        log "### [$phase] FAIL(exit=$status)  ${sec}s  (tail 见下)"
        tail -n 5 "$plog" | sed 's/^/    | /'
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

# git 硬超时兜底（2026-10-30 事故）：容器层 github.com 被 insteadOf 重写到集群内
# git-cdn，而 git-cdn 自身回源 github 经常连不上（TCP 握手即丢），它按
# `aiohttp.ClientTimeout(total=None)` + 10 次退避重试一直挂着，git 客户端本身
# 又没有超时 —— 一条静默上游连接就能让整个 job 挂到小时级（40995187145 的
# tool-git 卡 4h、41016156204 的 checkout 卡 6min 都是这条链）。
# 这里统一包 timeout，超时按失败计：宁可判红也不挂死。
#   GIT_LS_TIMEOUT（默认 60s）  —— ls-remote / fetch 这类元数据操作
#   GIT_OP_TIMEOUT（默认 180s）  —— clone
#   GIT_BIG_TIMEOUT（默认 300s） —— git lfs pull 这类大对象下载
git_to() {  # git_to <秒> <git 命令...>
    local sec="$1"; shift
    if have timeout; then timeout -k 10 "$sec" "$@"; else "$@"; fi
}
GIT_LS_TIMEOUT="${GIT_LS_TIMEOUT:-60}"
GIT_OP_TIMEOUT="${GIT_OP_TIMEOUT:-180}"
GIT_BIG_TIMEOUT="${GIT_BIG_TIMEOUT:-300}"

# busybox wget 经 HTTP 代理访问 https 不发 CONNECT（把 https URL 当绝对 URI 直接
# 丢给代理，squid 侧 abort），上游长期未修 → 任何用它下 https 的用例都必失败，
# 且与 squid/CA/no_proxy 无关，统一记 ⚪ SKIP 而不是红。
# 判定：可执行文件解析后落在 busybox，或 --version 输出含 BusyBox
# （Alpine 默认镜像 /usr/bin/wget -> /bin/busybox）。
wget_is_busybox() {
    have wget || return 1
    local p
    p=$(readlink -f "$(command -v wget)" 2>/dev/null || command -v wget)
    case "$p" in *busybox*) return 0;; esac
    wget --version 2>&1 | head -3 | grep -qi 'busybox'
}

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
    # 2 git：ls-remote + 浅克隆（容器内 insteadOf 重写 gh-proxy 需认证时，
    #   属环境路由问题非 squid 层问题 → 降级 SKIP）
    if have git; then
        ( git_to "$GIT_LS_TIMEOUT" git ls-remote https://github.com/octocat/Hello-World.git HEAD >"$wd/git-ls.log" 2>&1 \
            && git_to "$GIT_OP_TIMEOUT" git clone --depth 1 --filter=blob:none https://github.com/octocat/Hello-World.git "$wd/clone" >"$wd/git-clone.log" 2>&1 \
            && echo "✅ git" >>"$wd/verdict" \
            || { grep -q "could not read Username" "$wd/git-ls.log" "$wd/git-clone.log" 2>/dev/null \
                && echo "⚪ git SKIP（insteadOf 重写 gh-proxy 需认证，环境路由问题非 squid 层）" >>"$wd/verdict" \
                || echo "❌ git" >>"$wd/verdict"; } ) & pids+=($!)
    else
        echo "⚪ git SKIP（镜像无 git）" >>"$wd/verdict"
    fi
    # 3 wget：直链下载（busybox wget 经代理访 https 必失败且与 squid 无关 → SKIP）
    if ! have wget; then
        echo "⚪ wget SKIP（镜像无 wget）" >>"$wd/verdict"
    elif wget_is_busybox; then
        echo "⚪ wget SKIP（busybox wget 不发 CONNECT，经代理访 https 必失败；上游未修）" >>"$wd/verdict"
    else
        ( wget -q -O "$wd/wget.out" "$URL_SMALL" >"$wd/wget.log" 2>&1 \
            && echo "✅ wget" >>"$wd/verdict" || echo "❌ wget" >>"$wd/verdict" ) & pids+=($!)
    fi
    # 4 curl：与 wget 并发拉同一对象 URL_SMALL（~200KB，稳定小载荷）。
    #   不用 pypi JSON API：pypi host 上 /simple、/packages 是重写域而
    #   /pypi/*/json 不是，语义易混淆，且 1.17MB 在慢出口上 flaky、覆盖与
    #   pip worker 冗余。同对象并发（curl+wget）额外覆盖 R8 工具间同键并发，
    #   结束后 sha256 互校（下方统一做）。
    ( curl -sS --max-time 120 "$URL_SMALL" -o "$wd/curl.out" >"$wd/curl.log" 2>&1 \
        && [ -s "$wd/curl.out" ] \
        && echo "✅ curl" >>"$wd/verdict" || echo "❌ curl" >>"$wd/verdict" ) & pids+=($!)
    local i
    for i in "${!pids[@]}"; do wait "${pids[$i]}" || rc=1; done
    # curl/wget 同对象 sha256 互校（两工具都成功才有意义）
    if [ -s "$wd/curl.out" ] && [ -s "$wd/wget.out" ] \
        && [ "$(sha256_of "$wd/curl.out")" != "$(sha256_of "$wd/wget.out")" ]; then
        echo "❌ curl/wget 同对象 sha256 不一致" >>"$wd/verdict"
        rc=1
    fi
    cat "$wd/verdict"
    grep -q '❌' "$wd/verdict" && return 1
    [ $rc -eq 0 ] || return 1
    echo "✅ 可用工具并行全绿（互不干扰；⚪ 为镜像缺工具，不计失败）"
}

# =============================================================================
# vllm 组阶段（mock vLLM 通信：HF hub 模型下载形态 + OpenAI 兼容 API 形态）
# 自带 mock origin（mock-vllm-origin.py），流量强制经 squid（显式 -x）
# =============================================================================

# 显式代理地址：注入 env 里的 squid（-x 不受 NO_PROXY 影响，127.0.0.1 也走 squid）
PX=""
case "${HTTP_PROXY:-}${http_proxy:-}" in
    "") ;;
    *)  PX="${HTTP_PROXY:-${http_proxy:-}}" ;;
esac

origin_host() {
    # 多级回退取本机 IP：hostname 命令在部分镜像/沙箱中不存在
    local ip
    ip=$(hostname -i 2>/dev/null | awk '{print $1}')
    if [ -z "$ip" ]; then
        # UDP connect 不发包，仅查路由源地址
        ip=$(python3 -c "import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.connect(('8.8.8.8',53));print(s.getsockname()[0])" 2>/dev/null)
    fi
    if [ -z "$ip" ]; then
        ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
    fi
    echo "${ip:-127.0.0.1}"
}

start_origin() {  # <port> <dir> <tag> → 打印 PID
    python3 "$SCRIPT_DIR/mock-vllm-origin.py" --port "$1" --dir "$2" --tag "$3" \
        > "$RESULTS_DIR/origin-$1.log" 2>&1 &
    echo $!
}

px_curl() {  # px_curl <curl 参数…>（无代理 env 时去掉 -x，本地冒烟直连）
    if [ -n "$PX" ]; then
        curl -sS --max-time 60 -x "$PX" "$@"
    else
        curl -sS --max-time 60 "$@"
    fi
}

obs_curl() {  # OBS 静态对象：Range 可快，HEAVY 全量 16MB 级给足 600s
    if [ -n "$PX" ]; then
        curl -sS --max-time 600 -x "$PX" "$@"
    else
        curl -sS --max-time 600 "$@"
    fi
}

wait_origin() {  # <port> 本机直连探活 /health —— 对齐 vllm-ascend e2e/conftest.py:337
                 # （requests.get http://127.0.0.1:8000/health 轮询到 200）。
                 # 探活是脚手架不是被测流量：直连才不会被 squid 的陈旧缓存条目
                 # 假阳性（gy-005/gy003 事故形态），10s 不通视为失败
    local url="http://127.0.0.1:$1/health" i
    for i in $(seq 1 10); do
        curl -sS --max-time 5 "$url" 2>/dev/null | grep -q '"ok"' && return 0
        sleep 1
    done
    return 1
}

# vLLM 模型拉取模拟：ModelScope（首选）/ HF（回退）双通道 —— 元数据小文件 +
# 多 worker 大文件（全量 + Range 断点续传混跑），二轮复拉验证缓存命中
vllm-model-pull() {
    local port=18081
    local mock_dir="/tmp/test-squid-mock/model"
    rm -rf "$mock_dir"
    local run_tag="m-${GITHUB_RUN_ID:-local}-$(date +%s)"
    local pid
    pid=$(start_origin "$port" "$mock_dir" "$run_tag")
    if ! wait_origin "$port"; then
        kill "$pid" 2>/dev/null
        echo "❌ mock origin 起不来（$(cat "$RESULTS_DIR/origin-$port.log" 2>/dev/null | tail -3)）"; return 1
    fi
    local base="http://$(origin_host):$port"
    local manifest="$mock_dir/manifest.json"

    if [ -z "$PX" ]; then
        echo "⚠️ 无代理 env（本地冒烟）：直连 origin 仅验证 mock 逻辑，缓存/代理行为不判"
    fi

    echo "--- 冷启动拉取（vllm-ascend 双通道：ModelScope API + HF resolve，权重并行）---"
    local t0 wall_a
    t0=$(date +%s)
    # 元数据（顺序，ModelScope 通道——vllm-ascend CI 首选 modelscope download）
    local f rc=0 ms_base hf_base
    # Revision / resolve rev 带 run 唯一段（真实 ModelScope repo?Revision=… /
    # HF resolve/{rev}/ 本就是内容寻址）→ 缓存键跨 run 不撞，且同 tag 内容可复现
    ms_base="$base/api/v1/models/qwen/mock-vllm/repo?Revision=$run_tag&FilePath="
    hf_base="$base/qwen/mock-vllm/resolve/$run_tag/"
    for f in config.json tokenizer.json; do
        px_curl -L -o "$RESULTS_DIR/vllm-$f" "$ms_base$f" || rc=1
    done
    # 权重：w1/w2 全量（ModelScope 通道）+ w3/w4 Range 半拉（HF 通道，断点续传形态）
    local pids=() i half seg
    for i in 1 2; do
        f="model-0000$i-of-00002.safetensors"
        ( px_curl -L -o "$RESULTS_DIR/vllm-w$i.bin" "$ms_base$f" || echo FAIL > "$RESULTS_DIR/vllm-w$i.rc" ) & pids+=($!)
    done
    for i in 3 4; do
        f="model-00001-of-00002.safetensors"
        half=$(( $(stat -c%s "$mock_dir/$f") / 2 ))
        seg=$([ "$i" -eq 3 ] && echo "0-$((half - 1))" || echo "$half-")
        ( px_curl -L -r "$seg" -o "$RESULTS_DIR/vllm-w$i.bin" "$hf_base$f" || echo FAIL > "$RESULTS_DIR/vllm-w$i.rc" ) & pids+=($!)
    done
    for i in "${!pids[@]}"; do wait "${pids[$i]}" || rc=1; done
    wall_a=$(( $(date +%s) - t0 ))

    # 完整性：全量 worker sha256 对 manifest；Range worker 校验 206 长度
    local n_bad=0 w h expect
    for i in 1 2; do
        f="model-0000$i-of-00002.safetensors"
        expect=$(python3 -c "import json;print(json.load(open('$manifest'))['$f'])")
        [ -f "$RESULTS_DIR/vllm-w$i.rc" ] && { echo "❌ w$i 下载失败"; n_bad=$((n_bad+1)); continue; }
        h=$(sha256_of "$RESULTS_DIR/vllm-w$i.bin")
        [ "$h" = "$expect" ] || { echo "❌ w$i sha256 不匹配"; n_bad=$((n_bad+1)); }
    done
    for i in 3 4; do
        [ -f "$RESULTS_DIR/vllm-w$i.rc" ] && { echo "❌ w$i Range 拉取失败"; n_bad=$((n_bad+1)); }
    done
    [ "$rc" -eq 0 ] || { echo "❌ 存在 worker 非零退出"; kill "$pid" 2>/dev/null; return 1; }
    [ "$n_bad" -eq 0 ] || { kill "$pid" 2>/dev/null; return 1; }
    echo "✅ 冷拉取 4 worker 全部正确 墙钟=${wall_a}s"

    echo "--- 热复拉（同对象重下，验证 squid 缓存命中）---"
    local hdr wall_b
    t0=$(date +%s)
    # 复拉冷拉阶段的同一个 URL（同 cache key 才可能 HIT）。旧实现用冷拉从未
    # 拉过的 /models/… 路径——同 run 内必 MISS，观测到的"命中"全是跨 run 污染
    hdr=$(px_curl -L -D - -o "$RESULTS_DIR/vllm-hot.bin" \
        "$ms_base/model-00001-of-00002.safetensors" | tr -d '\r')
    wall_b=$(( $(date +%s) - t0 ))
    expect=$(python3 -c "import json;print(json.load(open('$manifest'))['model-00001-of-00002.safetensors'])")
    h=$(sha256_of "$RESULTS_DIR/vllm-hot.bin")
    [ "$h" = "$expect" ] || { echo "❌ 热复拉 sha256 不匹配"; kill "$pid" 2>/dev/null; return 1; }
    local cs
    cs=$(echo "$hdr" | grep -i '^cache-status:' | tail -1)
    echo "热复拉: ${cs:-无缓存头} 用时=${wall_b}s（冷=$wall_a s）"
    if echo "$cs" | grep -q 'hit'; then
        echo "✅ 二轮命中 squid 缓存"
    else
        echo "⚠️ 二轮未呈现命中（记录数据，不判失败）"
    fi
    kill "$pid" 2>/dev/null
    echo "✅ vLLM 模型拉取模拟通过（mock origin 已停）"
}

# vLLM API 通信模拟：OpenAI 兼容端点，同 pod 127.0.0.1 直连 —— 形态对齐真实
# vllm-ascend CI（e2e/conftest.py RemoteOpenAIServer + engine_func_test_robot 各
# test_*：server/client 同 pod，API 流量全部 localhost 直连、从不过代理）。
# 早期版本强行走 squid（pod IP + -x）测的是真实 CI 不存在的拓扑，且是无缓存头
# POST/GET 撞 squid 陈旧缓存事故的根源——已按对照表纠正（见 CASES.md vllm 组）
vllm-api-stream() {
    local port=18082
    local mock_dir="/tmp/test-squid-mock/api"
    rm -rf "$mock_dir"
    local pid
    pid=$(start_origin "$port" "$mock_dir" "a-$(date +%s)")
    if ! wait_origin "$port"; then
        kill "$pid" 2>/dev/null
        echo "❌ mock origin 起不来"; return 1
    fi
    # 同 pod 直连（对齐 conftest.py:337 http://127.0.0.1:8000/health 的 localhost 形态）
    local base="http://127.0.0.1:$port"

    echo "--- GET /v1/models（localhost 直连，原生 requests 形态）---"
    curl -sS --max-time 60 "$base/v1/models" | grep -q '"mock-vllm-model"' || { echo "❌ /v1/models 异常"; kill "$pid" 2>/dev/null; return 1; }

    echo "--- 8 并发流式 POST /v1/chat/completions（SSE 完整性：8 chunk + [DONE]；规模对齐 structured_output 32req/8worker）---"
    local wd="$RESULTS_DIR/vllm-api"; rm -rf "$wd"; mkdir -p "$wd"
    local pids=() i
    for i in $(seq 1 8); do
        ( curl -sS --max-time 60 -N -X POST -H 'Content-Type: application/json' \
            -d '{"model":"mock-vllm-model","stream":true,"max_tokens":8,"messages":[{"role":"user","content":"hi"}]}' \
            "$base/v1/chat/completions" > "$wd/s$i.out" 2>&1 \
          && [ "$(grep -c '^data: {' "$wd/s$i.out")" -eq 8 ] \
          && grep -q 'data: \[DONE\]' "$wd/s$i.out" \
          && echo "✅ s$i" >> "$wd/verdict" || echo "❌ s$i" >> "$wd/verdict" ) & pids+=($!)
    done
    local rc=0 j
    for j in "${!pids[@]}"; do wait "${pids[$j]}" || rc=1; done
    cat "$wd/verdict"

    # X-Request-ID 语义三断言（对齐 engine_func_test_robot/test_request_id.py 的
    # 2×2×2 矩阵：透传回显 endswith + 重复 ID → 400）
    echo "--- 非流式 POST 带 X-Request-Id（响应 id = chatcmpl-{ID} 回显）---"
    curl -sS --max-time 60 -X POST -H 'Content-Type: application/json' \
        -H 'X-Request-Id: squid-it-req-42' \
        -d '{"model":"mock-vllm-model","stream":false,"temperature":0.7,"max_tokens":8,"messages":[{"role":"user","content":"hi"}]}' \
        "$base/v1/chat/completions" > "$wd/nostream.json"
    grep -Eq '"id": *"chatcmpl-squid-it-req-42"' "$wd/nostream.json" \
        || { echo "❌ 非流式响应 id 未回显 X-Request-Id"; kill "$pid" 2>/dev/null; return 1; }
    grep -q '"finish_reason"' "$wd/nostream.json" || { echo "❌ 非流式异常"; kill "$pid" 2>/dev/null; return 1; }
    echo "✅ 非流式 id 回显"

    echo "--- 流式 POST 带 X-Request-Id（chunk id 透传 + [DONE]）---"
    curl -sS --max-time 60 -N -X POST -H 'Content-Type: application/json' \
        -H 'X-Request-Id: stream-rid-7' \
        -d '{"model":"mock-vllm-model","stream":true,"max_tokens":4,"messages":[{"role":"user","content":"hi"}]}' \
        "$base/v1/chat/completions" > "$wd/rid-stream.out"
    grep -Eq '"id": *"chatcmpl-stream-rid-7"' "$wd/rid-stream.out" \
        && grep -q 'data: \[DONE\]' "$wd/rid-stream.out" \
        || { echo "❌ 流式 chunk id 未透传或流不完整"; kill "$pid" 2>/dev/null; return 1; }
    echo "✅ 流式 id 透传"

    echo "--- 重复 X-Request-Id 三连发（重复提交 → 400，vLLM DuplicateRequestError；allow_400：200/400 均合法）---"
    local dup_pids=() k code
    for k in 1 2 3; do
        ( curl -sS --max-time 60 -o "$wd/dup$k.json" -w '%{http_code}' -X POST \
            -H 'Content-Type: application/json' -H 'X-Request-Id: dup-rid-9' \
            -d '{"model":"mock-vllm-model","stream":false,"max_tokens":4,"messages":[{"role":"user","content":"hi"}]}' \
            "$base/v1/chat/completions" > "$wd/dup$k.code" ) & dup_pids+=($!)
    done
    for k in "${!dup_pids[@]}"; do wait "${dup_pids[$k]}" || rc=1; done
    for k in 1 2 3; do
        code=$(cat "$wd/dup$k.code" 2>/dev/null)
        case "$code" in
            200|400) echo "✅ dup$k → $code（合法）" ;;
            *) echo "❌ dup$k → ${code:-无}（期望 200 或 400）"; rc=1 ;;
        esac
    done

    if grep -q '❌' "$wd/verdict"; then kill "$pid" 2>/dev/null; return 1; fi
    [ "$rc" -eq 0 ] || { kill "$pid" 2>/dev/null; return 1; }
    kill "$pid" 2>/dev/null
    echo "✅ vLLM API 通信模拟通过（8 并发流式直连无断流 + X-Request-ID 语义全量）"
}

# =============================================================================
# parity 组（tool-17 全量移植：13 条重写规则内容签名 + 负样本 + 回归守卫）
# runner 不挂 squid-config CM → helper 断言层（tool-17 [A] 层）不可用，
# 只做内容签名层（[B] 层）——R13 环境边界，留档。
# 唯一显式镜像 URL 是负样本（R14：证明判定方法有效，tool-17 NEG-demo 传承）。
# =============================================================================

P_PASS=0; P_FAIL=0

ck_get() {  # name url want_code [magic_hex] [grep_pat] —— GET+range，状态码/魔数/签名三重判
    local name=$1 url=$2 want=${3:-200} magic=${4:-} pat=${5:-}
    local body="$RESULTS_DIR/parity-body" code
    code=$(curl -sS -L --max-time 90 -r 0-65535 -o "$body" -w '%{http_code}' "$url" 2>>"$RESULTS_DIR/parity.log")
    case "$code" in
        "$want"|206) : ;;
        *) echo "✗ $name [$url] GET=$code 期望=$want ← 镜像路径不同构或失效"; P_FAIL=$((P_FAIL+1)); return 1 ;;
    esac
    if [ -n "$magic" ]; then
        local got; got=$(od -An -tx1 -N4 "$body" | tr -d ' \n'); got=${got:0:${#magic}}
        [ "$got" = "$magic" ] || { echo "✗ $name 魔数=$got 期望=$magic（内容形态不对）"; P_FAIL=$((P_FAIL+1)); return 1; }
    fi
    if [ -n "$pat" ] && ! grep -qE "$pat" "$body"; then
        echo "✗ $name 缺签名 /$pat/（同构性破坏）"; P_FAIL=$((P_FAIL+1)); return 1
    fi
    echo "✓ $name GET=$code 签名OK"; P_PASS=$((P_PASS+1))
}

ck_head() {  # 大文件只 HEAD（conda repodata 等百 MB 级）
    local name=$1 url=$2 want=${3:-200} code
    code=$(curl -sSI -L --max-time 60 -o /dev/null -w '%{http_code}' "$url" 2>>"$RESULTS_DIR/parity.log")
    if [ "$code" = "$want" ]; then
        echo "✓ $name HEAD=$code"; P_PASS=$((P_PASS+1))
    else
        echo "✗ $name HEAD=$code 期望=$want ← 不同构或失效"; P_FAIL=$((P_FAIL+1))
    fi
}

ck_json() {  # name url [must_key] —— 200/206 + 真 JSON 可解析
    # 事故形态（2026-09-20 gy-002）：?mode=json 被重写到镜像目录页 → 拿到 HTML
    # → pre-commit _infer_go_version 抛 JSONDecodeError。只 grep 引号关键字会漏，
    # 这里做 json.load 真解析；不带 range（include=all 响应可达数百 KB，截断会崩）。
    local name=$1 url=$2 key=${3:-}
    local body="$RESULTS_DIR/parity-body" code
    code=$(curl -sS -L --max-time 90 -o "$body" -w '%{http_code}' "$url" 2>>"$RESULTS_DIR/parity.log")
    case "$code" in
        200|206) : ;;
        *) echo "✗ $name [$url] GET=$code（JSON 通道异常）"; P_FAIL=$((P_FAIL+1)); return 1 ;;
    esac
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if (not sys.argv[2]) or (sys.argv[2] in json.dumps(d)) else 1)' "$body" "$key" 2>/dev/null \
            || { echo "✗ $name JSON 解析失败或缺少 /$key/（重写落点拿到 HTML 目录页？）"; P_FAIL=$((P_FAIL+1)); return 1; }
    else
        grep -q '"version"' "$body" \
            || { echo "✗ $name 缺 /\"version\"/ 签名（python3 缺失，降级 grep 判定）"; P_FAIL=$((P_FAIL+1)); return 1; }
    fi
    echo "✓ $name GET=$code JSON 可解析"; P_PASS=$((P_PASS+1))
}

ck_page() {  # name url —— 下载页守卫：必须 200 + HTML（防 /dl/ 被误改写成 /dl/go*）
    local name=$1 url=$2 body="$RESULTS_DIR/parity-body" code magic
    code=$(curl -sS -L --max-time 60 -o "$body" -w '%{http_code}' "$url" 2>>"$RESULTS_DIR/parity.log")
    magic=$(od -An -tx1 -N4 "$body" 2>/dev/null | tr -d ' \n')
    if [ "$code" != "200" ]; then
        echo "✗ $name [$url] GET=$code 期望=200 ← 下载页被误改写（规则3 应只匹配 /dl/go*）"; P_FAIL=$((P_FAIL+1)); return 1
    fi
    case "$magic" in
        1f8b08*) echo "✗ $name 返回 gzip 二进制而非 HTML ← /dl/ 被误改写"; P_FAIL=$((P_FAIL+1)); return 1 ;;
    esac
    grep -qi '<html' "$body" || { echo "✗ $name 非 HTML 形态（magic=$magic）← /dl/ 被误改写"; P_FAIL=$((P_FAIL+1)); return 1; }
    echo "✓ $name GET=$code HTML 形态（下载页未被误改写）"; P_PASS=$((P_PASS+1))
}

neg_expect_404() {  # 负样本：故意错误映射，期望 404/403
    local name=$1 url=$2 code
    code=$(curl -sS -L --max-time 60 -o /dev/null -w '%{http_code}' "$url" 2>>"$RESULTS_DIR/parity.log")
    case "$code" in
        404|403) echo "✓ NEG-$name → $code（不同构必失效，判定方法有效）"; P_PASS=$((P_PASS+1)) ;;
        *) echo "! NEG-$name → $code（期望 404/403，镜像路径策略可能变化，降级警告不判失败）" ;;
    esac
}

ck_get_inv() {  # name url want_code grep_pat —— direct 策略位：镜像特征必须【缺席】
    local name=$1 url=$2 want=${3:-200} pat=${4:-}
    local body="$RESULTS_DIR/parity-body" code
    code=$(curl -sS -L --max-time 90 -r 0-65535 -o "$body" -w '%{http_code}' "$url" 2>>"$RESULTS_DIR/parity.log")
    case "$code" in
        "$want"|206) : ;;
        *) echo "✗ $name [$url] GET=$code（直连链路异常）"; P_FAIL=$((P_FAIL+1)); return 1 ;;
    esac
    if [ -n "$pat" ] && grep -qE "$pat" "$body"; then
        echo "✗ $name 命中镜像签名 /$pat/（direct 策略下不应重写却重写了，策略漂移）"; P_FAIL=$((P_FAIL+1)); return 1
    fi
    echo "✓ $name GET=$code 无镜像签名（direct 直连策略符合预期）"; P_PASS=$((P_PASS+1))
}

rewrite-parity() {
    # 策略自探测（R12 范围注记）：CN 出口集群配置镜像重写；HK 等海外出口
    # 集群策略为 origin 直连（不重写）。crates config.json 的 api/v1/crates
    # 是唯一无歧义的镜像特征（origin config.json 上不存在），以它判定策略。
    local policy_code REWRITE_POLICY=rewrite
    policy_code=$(curl -sS -L --max-time 60 -o "$RESULTS_DIR/parity-policy.json" -w '%{http_code}' \
        "https://index.crates.io/config.json" 2>>"$RESULTS_DIR/parity.log")
    grep -q 'api/v1/crates' "$RESULTS_DIR/parity-policy.json" 2>/dev/null || REWRITE_POLICY=direct
    echo "--- 重写策略探测：$REWRITE_POLICY（config.json GET=$policy_code）---"

    echo "--- 规则1/12 pypi → repo.huaweicloud.com/repository/pypi（索引+对象域）---"
    ck_get pypi-simple https://pypi.org/simple/flask/ 200 '' '\.\./\.\./packages/|files\.pythonhosted\.org'
    # 动态取真实 wheel 路径（经 squid 的 simple 页 = 镜像页）
    local simple_html whl_href
    simple_html=$(curl -sS -L --max-time 60 https://pypi.org/simple/flask/ 2>>"$RESULTS_DIR/parity.log")
    # href 两种形态：镜像页相对路径（../../packages/…）或官方页绝对 URL（files.pythonhosted…）
    whl_href=$(printf '%s' "$simple_html" | grep -o 'href="[^"]*\.whl' | head -1 | sed 's/^href="//')
    case "$whl_href" in
        http*)
            ck_get pypi-packages "$whl_href" 200 ;;                       # 规则12：官方对象域
        ../*)
            ck_get pypi-packages "https://pypi.org/${whl_href#\.\./\.\./}" 200 ;;  # 镜像相对路径 → 源站 URL
        *)
            echo "✗ pypi-packages 未知 href 形态: $whl_href"; P_FAIL=$((P_FAIL+1)) ;;
    esac

    echo "--- 规则3/13 github → gh-proxy 前缀式（archive/releases/raw）---"
    ck_get gh-archive https://github.com/mvdan/sh/archive/refs/tags/v3.10.0.tar.gz 200 1f8b08
    ck_get gh-release https://github.com/mvdan/sh/releases/download/v3.10.0/shfmt_v3.10.0_linux_amd64 200 7f454c46
    ck_get gh-raw https://raw.githubusercontent.com/mvdan/sh/master/README.md 200

    echo "--- 规则5 go：goproxy.cn 同构 / tarball→dl.google.com / ?mode=json→golang.google.cn（R15 守卫）---"
    ck_get goproxy-list https://proxy.golang.org/github.com/google/uuid/@v/list 200 '' '^v'
    ck_get go-tarball https://go.dev/dl/go1.26.1.linux-amd64.tar.gz 200 1f8b08
    ck_get go-json "https://go.dev/dl/?mode=json" 200 '' '"version"'   # tool-18 事故回归位

    echo "--- 规则5b go 下载通道细分（2026-10-20 redirect 更新后新增守卫）---"
    # 规则1：?mode=json → golang.google.cn（保留完整 query）；判定升级为真 JSON 解析
    ck_json go-json-query "https://go.dev/dl/?mode=json&include=all" '"version"'
    # 规则2：golang.google.cn 入口原样放行（防自我改写循环）
    ck_json go-json-cn "https://golang.google.cn/dl/?mode=json" '"version"'
    # 规则3：go* 二进制 → dl.google.com；第二入口（golang.google.cn/dl/go*）零覆盖补齐
    ck_get go-tarball-cn https://golang.google.cn/dl/go1.26.1.linux-amd64.tar.gz 200 1f8b08
    # 规则3 边界守卫：/dl/ 下载页不得命中 /dl/go*（${url##*/} 为空会拼出 dl.google.com/go/）
    ck_page go-dl-page https://go.dev/dl/

    echo "--- 规则6 apt → repo.huaweicloud.com（host 交换，路径同构）---"
    ck_get ubuntu-release http://archive.ubuntu.com/ubuntu/dists/noble/Release 200 '' 'Origin: Ubuntu'
    ck_get ports-release http://ports.ubuntu.com/ubuntu-ports/dists/noble/Release 200 '' 'Origin: Ubuntu'

    echo "--- 规则7 npm → registry.npmmirror.com（host 交换）---"
    ck_get npm-doc https://registry.npmjs.org/left-pad 200 '' '"versions"'
    ck_get npm-tgz https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz 200 1f8b08

    echo "--- 规则8 cargo → rsproxy（sparse index + api/v1/crates 守卫 + 对象兜底）---"
    ck_get crates-index https://index.crates.io/se/rd/serde 200 '' '"vers"'
    # R15 守卫位：rewrite 策略下镜像特征必须在，direct 策略下镜像特征必须不在
    if [ "$REWRITE_POLICY" = direct ]; then
        ck_get_inv crates-config-guard https://index.crates.io/config.json 200 'api/v1/crates'
    else
        ck_get crates-config-guard https://index.crates.io/config.json 200 '' 'api/v1/crates'
    fi
    ck_get crates-static https://static.crates.io/crates/serde/serde-1.0.210.crate 200 1f8b08

    echo "--- 规则9 conda → nju（/cloud/ 前缀重映射 + pkgs|miniconda）---"
    ck_head conda-cloud https://conda.anaconda.org/conda-forge/linux-64/repodata.json 200
    ck_head conda-pkgs https://repo.anaconda.com/pkgs/main/linux-64/repodata.json 200
    ck_head miniconda https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh 200

    echo "--- 规则10 openEuler yum host 交换 ---"
    ck_get openeuler-repomd https://repo.openeuler.org/openEuler-24.03-LTS/OS/x86_64/repodata/repomd.xml 200 '' '<repomd'

    echo "--- 规则10a rustup → huaweicloud（manifest 签名 + bootstrap 固定映射）---"
    ck_get rustup-manifest https://static.rust-lang.org/dist/channel-rust-stable.toml 200 '' 'manifest-version'
    ck_head rustup-init https://sh.rustup.rs 200

    echo "--- 负样本对照（R14）：故意去掉 nju 的 /cloud/ 前缀 → 期望 404/403 ---"
    neg_expect_404 conda-nocloud https://mirror.nju.edu.cn/anaconda/conda-forge/linux-64/repodata.json

    echo "RESULT: pass=$P_PASS fail=$P_FAIL policy=$REWRITE_POLICY"
    [ "$P_FAIL" -eq 0 ] && echo "✅ 重写同构校验通过（$P_PASS 条，策略=$REWRITE_POLICY）"
}



# pip 真实下载 + 安装 + import 验证（pypi 经 squid）
tool-pip() {
    ensure_pip || { echo "❌ pip 不可用且 bootstrap 失败"; return 1; }
    local dl="$RESULTS_DIR/pip-dl"; rm -rf "$dl"; mkdir -p "$dl"
    python3 -m pip download --no-deps --timeout 60 -d "$dl" 'requests==2.32.3' \
        > "$RESULTS_DIR/tool-pip.log" 2>&1 || { echo "❌ pip download 失败（tail: $(tail -2 "$RESULTS_DIR/tool-pip.log" | tr '\n' ' ')）"; return 1; }
    local whl
    whl=$(ls "$dl"/requests-*.whl 2>/dev/null | head -1)
    [ -n "$whl" ] || { echo "❌ 未产出 wheel"; return 1; }
    echo "wheel: $(basename "$whl") $(sha256_of "$whl" | cut -c1-12)…"
    # 不用 --no-deps：极简镜像缺 requests 依赖（urllib3 等），import 必挂；
    # 依赖解析本身也是真实 pip→squid 流量（run 36655296843 实测）
    pip_install --force-reinstall "$whl" >> "$RESULTS_DIR/tool-pip.log" 2>&1 \
        || { echo "❌ pip install 失败"; return 1; }
    python3 -c "import requests; print('requests', requests.__version__)" \
        || { echo "❌ import 验证失败"; return 1; }
    echo "✅ pip 真实下载→安装→import 全链路经 squid 通过"
}

# huggingface 整体排除（R12/R16 留档）：helper 无 hf 重写规则，前版 tool-hf 写死
# HF_ENDPOINT=hf-mirror.com 属显式镜像违例，已删除。3xx 跟随能力由 vllm 组覆盖。

# 工具链缺失守卫（R16）：无该工具 → SKIP 记数据；工具在而失败 → FAIL
need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "⚠️ 无 $1（runner 工具链缺失），SKIP（R16：数据记录）"; return 1; }
}

# pip 安装带 PEP 668 回退（ubuntu-24.04/CANN py3.12 的 externally-managed 环境）
pip_install() {
    python3 -m pip install --quiet --timeout 60 "$@" 2>/dev/null \
        || python3 -m pip install --quiet --timeout 60 --break-system-packages "$@"
}

# 极简 runner 镜像可能无 pip：ensurepip 优先，失败则 apt 装 python3-pip（本身是真实 apt 重写链路）。
# 注意：极简镜像包列表可能为空，必须先 apt-get update（run 36571660908 实测：跳过 update
# 导致 install "Unable to locate package" 失败）；runner 非 root，sudo 可选。
ensure_pip() {
    python3 -m pip --version >/dev/null 2>&1 && return 0
    python3 -m ensurepip --default-pip >/dev/null 2>&1 && return 0
    local SUDO=""; command -v sudo >/dev/null 2>&1 && SUDO=sudo
    $SUDO apt-get update -qq >/dev/null 2>&1
    $SUDO apt-get install -y -qq python3-pip >/dev/null 2>&1
    python3 -m pip --version >/dev/null 2>&1
}

# 清理含只读文件（go modcache 等设置 444）的目录
rmrf() { chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"; }

# tool-02 apt：官方源零换源 update+install（重写规则6）；容器层 root 无 sudo → sudo 可选
tool-apt() {
    need apt-get || return 2
    local SUDO=""; command -v sudo >/dev/null 2>&1 && SUDO=sudo
    $SUDO apt-get update -qq > "$RESULTS_DIR/tool-apt.log" 2>&1 \
        && $SUDO apt-get install -y -qq jq >> "$RESULTS_DIR/tool-apt.log" 2>&1 \
        || { echo "❌ apt update/install 失败（tail: $(tail -2 "$RESULTS_DIR/tool-apt.log" | tr '\n' ' ')）"; return 1; }
    jq --version || { echo "❌ jq 不可用"; return 1; }
    echo "✅ apt 官方源零换源经 squid 通过"
}

# tool-16 dnf/yum：openEuler 24.03 基底的包管理真实链路（规则10 host 交换域）。
# GHA/CANN 均 ubuntu 无 dnf → need 守卫记 SKIP（R16 数据记录），
# 容器层由 openEuler 镜像 job 真实执行（RHEL 系 CA 注入路径的唯一覆盖）。
# 只启用 OS/everything/EPOL/update 四个 repo：镜像默认还开了 debuginfo/source/
# update-source（元数据 100MB+ 且与安装无关，全量 makecache 单次 ~5min），
# 截断只是缩小同步面，URL/源配置保持镜像默认（零换源）。
PKG_REPOS="${PKG_REPOS:-OS,everything,EPOL,update}"

pkg-dnf() {
    need dnf || return 2
    local log="$RESULTS_DIR/pkg-dnf.log"
    echo "dnf: $(dnf --version 2>/dev/null | head -1)（repo=$PKG_REPOS）"
    dnf -y --disablerepo='*' --enablerepo="$PKG_REPOS" makecache >> "$log" 2>&1 \
        || { echo "❌ dnf makecache 失败（tail: $(tail -2 "$log" | tr '\n' ' ')）"; return 1; }
    dnf -y --disablerepo='*' --enablerepo="$PKG_REPOS" install tree >> "$log" 2>&1 \
        || { echo "❌ dnf install tree 失败（tail: $(tail -2 "$log" | tr '\n' ' ')）"; return 1; }
    tree --version >/dev/null 2>&1 || { echo "❌ tree 未落盘/不可执行"; return 1; }
    echo "✅ dnf 元数据同步 + install 经 squid 通过（$(tree --version | head -1)）"
}

pkg-yum() {
    need yum || return 2
    local log="$RESULTS_DIR/pkg-yum.log"
    echo "yum: $(yum --version 2>/dev/null | head -1)（repo=$PKG_REPOS）"
    yum -y --disablerepo='*' --enablerepo="$PKG_REPOS" install jq >> "$log" 2>&1 \
        || { echo "❌ yum install jq 失败（tail: $(tail -2 "$log" | tr '\n' ' ')）"; return 1; }
    jq --version >/dev/null 2>&1 || { echo "❌ jq 未落盘/不可执行"; return 1; }
    echo "✅ yum 安装经 squid 通过（$(jq --version)）"
}

# tool-09 npm：默认 registry 安装（规则7 host 交换）
tool-npm() {
    need npm || return 2
    local d="$RESULTS_DIR/npm-proj"; rm -rf "$d"; mkdir -p "$d"
    (cd "$d" && npm install express --no-audit --no-fund --loglevel=warn > "$RESULTS_DIR/tool-npm.log" 2>&1 \
        && node -e "require('express'); console.log('express ok')") \
        || { echo "❌ npm install/require 失败（tail: $(tail -2 "$RESULTS_DIR/tool-npm.log" | tr '\n' ' ')）"; return 1; }
    echo "✅ npm 默认 registry 经 squid 通过"
}

# tool-15 pnpm：npm bootstrap pnpm 后安装（规则7）
tool-pnpm() {
    need npm || return 2
    local d="$RESULTS_DIR/pnpm-proj"; rm -rf "$d"; mkdir -p "$d"
    npm install -g pnpm --loglevel=warn > "$RESULTS_DIR/tool-pnpm.log" 2>&1 \
        && (cd "$d" && pnpm add left-pad@1.3.0 --loglevel=warn >> "$RESULTS_DIR/tool-pnpm.log" 2>&1 \
            && node -e "require('./node_modules/left-pad'); console.log('pnpm ok')") \
        || { echo "❌ pnpm 链路失败（tail: $(tail -2 "$RESULTS_DIR/tool-pnpm.log" | tr '\n' ' ')）"; return 1; }
    echo "✅ pnpm 安装链经 squid 通过"
}

# tool-12 uv：pip bootstrap + uv venv 安装（默认官方 index）。
# 不用 --system：runner 层非 root 写 /usr/local/lib 被拒（run 36655296843 实测）；
# uv venv 是标准用法，两层通用且天然绕开 PEP 668。
tool-uv() {
    ensure_pip || { echo "❌ pip 不可用且 bootstrap 失败"; return 1; }
    pip_install uv > "$RESULTS_DIR/tool-uv.log" 2>&1
    local d="$RESULTS_DIR/uv-venv"; rmrf "$d"
    uv venv "$d" >> "$RESULTS_DIR/tool-uv.log" 2>&1 \
        && uv pip install --python "$d/bin/python" --quiet pyyaml >> "$RESULTS_DIR/tool-uv.log" 2>&1 \
        && "$d/bin/python" -c "import yaml; print('yaml ok')" \
        || { echo "❌ uv venv/pip install/import 失败（tail: $(tail -2 "$RESULTS_DIR/tool-uv.log" | tr '\n' ' ')）"; return 1; }
    echo "✅ uv 官方 index 经 squid 通过（uv venv）"
}

# tool-04 goproxy：go 缺失则官方 tarball bootstrap（规则5 tarball），go mod download（规则5 goproxy）
tool-goproxy() {
    if ! command -v go >/dev/null 2>&1; then
        echo "runner 无 go → 官方 tarball bootstrap（同时验证规则5 tarball 重写 + squid 大文件下载）"
        # squid 大文件冷下载实测 ~96KB/s（66.8MB 需 ~720s），600s 会超时（run 36571660908），
        # 放宽到 1200s；若 squid 已缓存则秒回
        curl -sSL --max-time 1200 -o /tmp/go.tgz "https://go.dev/dl/go1.26.1.linux-${PKG_ARCH}.tar.gz" \
            || { echo "❌ go tarball 下载失败（exit=$?，>20min 未完成）"; return 1; }
        mkdir -p "$RESULTS_DIR/goroot" && tar -C "$RESULTS_DIR/goroot" -xzf /tmp/go.tgz
        export PATH="$RESULTS_DIR/goroot/go/bin:$PATH"
    fi
    local d="$RESULTS_DIR/go-proj"; rmrf "$d"; mkdir -p "$d"
    export GOMODCACHE="$d/gomodcache" GOPATH="$d/gopath"
    (cd "$d" && go mod init t >/dev/null 2>&1 && go mod download github.com/google/uuid@v1.6.0) \
        > "$RESULTS_DIR/tool-goproxy.log" 2>&1 \
        || { echo "❌ go mod download 失败（tail: $(tail -2 "$RESULTS_DIR/tool-goproxy.log" | tr '\n' ' ')）"; return 1; }
    [ -d "$d/gomodcache/github.com/google/uuid@v1.6.0" ] || { echo "❌ 模块未落缓存"; return 1; }
    echo "✅ goproxy 默认 GOPROXY 经 squid 通过（go $(go version | awk '{print $3}')）"
}

# tool-06 wget：官方 github release 下载（规则3），ELF 魔数校验
tool-wget() {
    need wget || return 2
    # busybox wget 不发 CONNECT，https 必失败（上游未修）→ 记 SKIP，不判红
    wget_is_busybox && { echo "⚠️ busybox wget 经代理访 https 必失败（上游未修），SKIP"; return 2; }
    wget -q --timeout=90 -O "$RESULTS_DIR/shfmt" \
        https://github.com/mvdan/sh/releases/download/v3.10.0/shfmt_v3.10.0_linux_${PKG_ARCH} \
        || { echo "❌ wget release 失败"; return 1; }
    [ "$(od -An -tx1 -N4 "$RESULTS_DIR/shfmt" | tr -d ' \n')" = "7f454c46" ] \
        || { echo "❌ 下载内容非 ELF（重写路径不同构?）"; return 1; }
    echo "✅ wget 官方 release 经 squid 通过（ELF 完整）"
}

# tool-14 git-lfs：官方 release bootstrap（规则3）+ lfs 可用性
tool-gitlfs() {
    if command -v git-lfs >/dev/null 2>&1; then
        git lfs version && { echo "✅ git-lfs 现成可用（$(git lfs version)）"; return 0; }
    fi
    echo "runner 无 git-lfs → 官方 release bootstrap（验证规则3 工具链自举；极简镜像无 wget 用 curl）"
    local d="$RESULTS_DIR/gitlfs"; rm -rf "$d"; mkdir -p "$d"
    curl -sSL --max-time 300 -o "$d/lfs.tar.gz" \
        https://github.com/git-lfs/git-lfs/releases/download/v3.7.0/git-lfs-linux-${PKG_ARCH}-v3.7.0.tar.gz \
        || { echo "❌ git-lfs release 下载失败"; return 1; }
    tar -C "$d" -xzf "$d/lfs.tar.gz"
    "$d"/git-lfs-3.7.0/git-lfs version || { echo "❌ git-lfs 二进制不可用"; return 1; }
    echo "✅ git-lfs 官方 bootstrap 经 squid 通过"
}

# ---- HEAVY=1 才跑（编译/工具链级耗时）----

# tool-19 rustup：官方 bootstrap（规则10a）+ cargo serde 构建（规则8）
tool-rustup() {
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --profile minimal --default-toolchain stable > "$RESULTS_DIR/tool-rustup.log" 2>&1 \
        || { echo "❌ rustup bootstrap 失败（tail: $(tail -2 "$RESULTS_DIR/tool-rustup.log" | tr '\n' ' ')）"; return 1; }
    export PATH="$HOME/.cargo/bin:$PATH"
    local d="$RESULTS_DIR/rust-proj"; rm -rf "$d"; mkdir -p "$d"
    (cd "$d" && cargo new t --bin >/dev/null 2>&1 && cd t \
        && cargo add serde --features derive >/dev/null 2>&1 && cargo build --quiet) \
        >> "$RESULTS_DIR/tool-rustup.log" 2>&1 \
        || { echo "❌ cargo add/build 失败（tail: $(tail -2 "$RESULTS_DIR/tool-rustup.log" | tr '\n' ' ')）"; return 1; }
    [ -x "$d/t/target/debug/t" ] || { echo "❌ 产物缺失"; return 1; }
    echo "✅ rustup+cargo 官方链经 squid 通过"
}

# tool-11 conda：官方 miniconda installer + conda-forge create（规则9）
tool-conda() {
    # busybox wget 无法经代理下 https → 环境不可用，记 SKIP（非 squid 层问题）
    wget_is_busybox && { echo "⚠️ busybox wget 经代理访 https 必失败（上游未修），SKIP"; return 2; }
    local d="$RESULTS_DIR/conda"; rm -rf "$d"; mkdir -p "$d"
    wget -q --timeout=300 -O "$d/miniconda.sh" \
        https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh \
        || { echo "❌ miniconda 下载失败"; return 1; }
    bash "$d/miniconda.sh" -b -p "$d/root" >> "$RESULTS_DIR/tool-conda.log" 2>&1 \
        || { echo "❌ miniconda 安装失败"; return 1; }
    "$d/root/bin/conda" create -y -q -n t -c conda-forge 'numpy<2' >> "$RESULTS_DIR/tool-conda.log" 2>&1 \
        || { echo "❌ conda create 失败（tail: $(tail -2 "$RESULTS_DIR/tool-conda.log" | tr '\n' ' ')）"; return 1; }
    "$d/root/envs/t/bin/python" -c "import numpy; print('numpy', numpy.__version__)" \
        || { echo "❌ numpy import 失败"; return 1; }
    echo "✅ conda 官方链经 squid 通过"
}

# tool-07 cmake FetchContent：git clone 官方 googletest（不经重写直连）+ cmake 构建
tool-cmake() {
    need cmake || return 2
    local d="$RESULTS_DIR/cmake-proj"; rm -rf "$d"; mkdir -p "$d"
    git_to "$GIT_OP_TIMEOUT" git clone --depth 1 --quiet https://github.com/google/googletest.git "$d/googletest" \
        > "$RESULTS_DIR/tool-cmake.log" 2>&1 || { echo "❌ googletest clone 失败"; return 1; }
    cat > "$d/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(t CXX)
add_subdirectory(googletest EXCLUDE_FROM_ALL)
add_executable(t main.cc)
target_link_libraries(t gtest)
EOF
    echo '#include <gtest/gtest.h>
int main(){testing::InitGoogleTest(nullptr,nullptr);return 0;}' > "$d/main.cc"
    (cd "$d" && cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null \
        && cmake --build build -j2 --quiet) >> "$RESULTS_DIR/tool-cmake.log" 2>&1 \
        || { echo "❌ cmake 构建失败（tail: $(tail -2 "$RESULTS_DIR/tool-cmake.log" | tr '\n' ' ')）"; return 1; }
    echo "✅ cmake+googletest 官方 git 直连经 squid 通过"
}

# tool-08 bazel：bazelisk（官方 github release，规则3）+ http_archive 构建
tool-bazel() {
    # busybox wget 无法经代理下 https → 环境不可用，记 SKIP（非 squid 层问题）
    wget_is_busybox && { echo "⚠️ busybox wget 经代理访 https 必失败（上游未修），SKIP"; return 2; }
    local d="$RESULTS_DIR/bazel-proj"; rm -rf "$d"; mkdir -p "$d"
    wget -q --timeout=120 -O "$d/bazelisk" \
        https://github.com/bazelbuild/bazelisk/releases/download/v1.25.0/bazelisk-linux-amd64 \
        || { echo "❌ bazelisk 下载失败"; return 1; }
    chmod +x "$d/bazelisk"
    cat > "$d/MODULE.bazel" <<'EOF'
module(name = "t")
bazel_dep(name = "rules_cc", version = "0.0.17")
EOF
    printf 'cc_binary(name = "t", srcs = ["t.cc"])\n' > "$d/BUILD"
    echo 'int main(){return 0;}' > "$d/t.cc"
    (cd "$d" && "$d/bazelisk" build //:t --nosystem_rc --nohome_rc) \
        > "$RESULTS_DIR/tool-bazel.log" 2>&1 \
        || { echo "❌ bazel build 失败（tail: $(tail -2 "$RESULTS_DIR/tool-bazel.log" | tr '\n' ' ')）"; return 1; }
    echo "✅ bazelisk+bazel_dep 官方链经 squid 通过"
}

# tool-18 pre-commit：pip bootstrap + gitleaks hook 官方 repo（自举编译，最重）
tool-precommit() {
    ensure_pip || { echo "❌ pip 不可用且 bootstrap 失败"; return 1; }
    pip_install pre-commit > "$RESULTS_DIR/tool-precommit.log" 2>&1
    local d="$RESULTS_DIR/precommit-proj"; rm -rf "$d"; mkdir -p "$d"
    cat > "$d/.pre-commit-config.yaml" <<'EOF'
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.27.2
    hooks:
      - id: gitleaks
EOF
    (cd "$d" && git init -q && git add -A \
        && pre-commit run gitleaks --all-files) >> "$RESULTS_DIR/tool-precommit.log" 2>&1 \
        || { echo "❌ pre-commit run 失败（tail: $(tail -2 "$RESULTS_DIR/tool-precommit.log" | tr '\n' ' ')）"; return 1; }
    echo "✅ pre-commit+gitleaks 官方 hook 链经 squid 通过"
}

# modelscope 真实 CLI 下载（vllm-ascend / sglang CI 首选通道，天然 302→CDN）
# 模型 + 数据集双通道：sglang/vllm-ascend workflow 里两者是不同 API 面
# （--model 走 models/...，--dataset 走 datasets/...），都要经 squid。
tool-modelscope() {
    ensure_pip || { echo "❌ pip 不可用且 bootstrap 失败"; return 1; }
    pip_install 'modelscope<1.38' > "$RESULTS_DIR/tool-modelscope.log" 2>&1
    local dir="$RESULTS_DIR/ms-model"; rm -rf "$dir"
    modelscope download --model Qwen/Qwen2.5-0.5B config.json generation_config.json \
        --local_dir "$dir" >> "$RESULTS_DIR/tool-modelscope.log" 2>&1 \
        || { echo "❌ modelscope download（model）失败（tail: $(tail -2 "$RESULTS_DIR/tool-modelscope.log" | tr '\n' ' ')）"; return 1; }
    [ -s "$dir/config.json" ] || { echo "❌ config.json 缺失/为空"; return 1; }
    grep -q 'qwen' "$dir/config.json" || { echo "❌ config.json 内容异常"; return 1; }
    local ds="$RESULTS_DIR/ms-dataset"; rm -rf "$ds"
    modelscope download --dataset "$MS_DATASET" --local_dir "$ds" >> "$RESULTS_DIR/tool-modelscope.log" 2>&1 \
        || { echo "❌ modelscope download（dataset $MS_DATASET）失败（tail: $(tail -2 "$RESULTS_DIR/tool-modelscope.log" | tr '\n' ' ')）"; return 1; }
    local jsonl
    jsonl=$(find "$ds" -type f -name '*.jsonl' -size +0 2>/dev/null | head -1)
    [ -n "$jsonl" ] || { echo "❌ dataset $MS_DATASET 未产出非空 jsonl"; return 1; }
    head -1 "$jsonl" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null \
        || { echo "❌ dataset jsonl 首行非法：$(basename "$jsonl")"; return 1; }
    echo "✅ modelscope CLI 真实下载经 squid 通过（model + dataset $MS_DATASET）"
}

# torch 官方索引（download.pytorch.org）——sglang / ROLL / LLaMA-Factory / fla /
# sgl-kernel-npu 的真实装法：pip/uv --index-url https://download.pytorch.org/whl/{cpu,xpu}。
# 规则11 明确 pytorch 官方源不重写 → 该流量经 squid 直通（不依赖 helper），
# 日常只做索引可达 + 版本解析；HEAVY=1 才真下 wheel（~200MB，冷拉可能很慢）。
tool-torch() {
    ensure_pip || { echo "❌ pip 不可用且 bootstrap 失败"; return 1; }
    local log="$RESULTS_DIR/tool-torch.log"
    if python3 -m pip index versions torch --index-url "$TORCH_INDEX_URL" > "$log" 2>&1 \
        && grep -q 'Available versions' "$log"; then
        echo "torch 索引可达（$TORCH_INDEX_URL）：$(sed -n 's/^Available versions: *//p' "$log" | head -1 | cut -d, -f1)"
    else
        # 老 pip 无 index 子命令：直接读索引页（HTML 列表）
        local body="$RESULTS_DIR/torch-index.html" code
        code=$(curl -sS -L --max-time 60 -o "$body" -w '%{http_code}' "$TORCH_INDEX_URL/torch/" 2>>"$log")
        [ "$code" = "200" ] && grep -q 'torch-' "$body" \
            || { echo "❌ torch 索引不可用（pip index 与索引页均失败，HTTP $code）"; return 1; }
        echo "torch 索引页可达（HTTP $code；pip index 不可用已回退）"
    fi
    if [ "$HEAVY" = "1" ]; then
        local d="$RESULTS_DIR/torch-wheel"; rm -rf "$d"; mkdir -p "$d"
        echo "HEAVY=1 → 真实下载 torch CPU wheel（官方索引，冷拉 ~200MB 可能较慢）"
        timeout 3600 python3 -m pip download --no-deps --timeout 300 -d "$d" torch \
            --index-url "$TORCH_INDEX_URL" >> "$log" 2>&1 \
            || { echo "❌ torch wheel 下载失败/超时（tail: $(tail -2 "$log" | tr '\n' ' ')）"; return 1; }
        local whl
        whl=$(ls "$d"/torch-*.whl 2>/dev/null | head -1)
        [ -n "$whl" ] || { echo "❌ 未产出 torch wheel"; return 1; }
        [ "$(od -An -tx1 -N4 "$whl" | tr -d ' \n')" = "504b0304" ] \
            || { echo "❌ 下载内容非 ZIP/wheel（魔数不符）"; return 1; }
        echo "✅ torch wheel 完整（$(basename "$whl") $(du -h "$whl" | cut -f1)）"
    fi
    echo "✅ torch 官方索引经 squid 通过"
}

# hf CLI（huggingface_hub）——sglang / Ascend-sglang / sglang-omni 的 NPU CI 显式
# 设置 HF_ENDPOINT=https://hf-mirror.com 后 `hf download` / snapshot_download。
# 该维度是「真实 CI 现状复刻」，不参与 no-mirror（R12）判定；镜像 URL 原样保留。
# HF_HUB_DISABLE_XET=1：hf-mirror 不支持 Xet 传输，真实 CI 同样走 HTTP 回落。
tool-hf() {
    ensure_pip || { echo "❌ pip 不可用且 bootstrap 失败"; return 1; }
    pip_install -U 'huggingface_hub[cli]' > "$RESULTS_DIR/tool-hf.log" 2>&1 \
        || { echo "❌ huggingface_hub[cli] 安装失败（tail: $(tail -2 "$RESULTS_DIR/tool-hf.log" | tr '\n' ' ')）"; return 1; }
    local cmd=""
    command -v hf >/dev/null 2>&1 && cmd=hf
    [ -z "$cmd" ] && command -v huggingface-cli >/dev/null 2>&1 && cmd=huggingface-cli
    [ -n "$cmd" ] || { echo "❌ hf / huggingface-cli 均不在 PATH"; return 1; }
    local dir="$RESULTS_DIR/hf-model"; rm -rf "$dir"
    HF_ENDPOINT="$HF_MIRROR_ENDPOINT" HF_HUB_DISABLE_XET=1 \
        "$cmd" download Qwen/Qwen2.5-0.5B config.json generation_config.json \
        --local-dir "$dir" >> "$RESULTS_DIR/tool-hf.log" 2>&1 \
        || { echo "❌ hf download 失败（tail: $(tail -2 "$RESULTS_DIR/tool-hf.log" | tr '\n' ' ')）"; return 1; }
    [ -s "$dir/config.json" ] || { echo "❌ hf 未落盘 config.json"; return 1; }
    grep -qi 'qwen' "$dir/config.json" || { echo "❌ hf 下载内容异常"; return 1; }
    echo "✅ hf CLI + $HF_MIRROR_ENDPOINT（真实 CI 复刻）经 squid 通过"
}

# git 真实 clone —— no-mirror 直连 github.com（runner 层）/ insteadOf 重写 gh-proxy（容器层）
tool-git() {
    local dir="$RESULTS_DIR/git-clone"; rm -rf "$dir"
    git_to "$GIT_LS_TIMEOUT" git ls-remote https://github.com/octocat/Hello-World.git HEAD > "$RESULTS_DIR/tool-git.log" 2>&1 \
        || { echo "❌ ls-remote 失败（超时阈值 ${GIT_LS_TIMEOUT}s）"; return 1; }
    git_to "$GIT_OP_TIMEOUT" git clone --depth 1 --quiet https://github.com/octocat/Hello-World.git "$dir" >> "$RESULTS_DIR/tool-git.log" 2>&1 \
        || { echo "❌ clone 失败（超时阈值 ${GIT_OP_TIMEOUT}s）"; return 1; }
    local nrewritten
    nrewritten=$(git config --global --get-regexp '^url\..*\.insteadof' 2>/dev/null | wc -l)
    if [ "$nrewritten" -gt 0 ]; then
        echo "环境含 $nrewritten 条 insteadOf 重写 → 实际走 gh-proxy（环境正道形态）"
    else
        echo "无 insteadOf → github.com 直连（no-mirror 形态）"
    fi
    [ -f "$dir/README" ] || { echo "❌ 仓库内容缺失"; return 1; }
    echo "✅ git 真实 clone 经 squid 通过（$(ls "$dir" | wc -l) 个文件）"
}

# =============================================================================
# upstream 组 —— 上游通道健康（R17，源自 cn12-001 runbook 诊断）
#   背景：cn12-001 单 pod 6h 内 17 次 TIMEDOUT，53% 集中在 GitHub Actions
#   构件通道（出口固有抖动），gh-proxy test 实例 4 次且 p50 3.2s（可修）。
#   判定原则（A/B 对照）：同通道走 squid 与直连各 5 次，squid 成功率 ≥ 直连
#   且延迟不劣 → PASS；squid 比直连差 → FAIL（代理必须证明自己没让链路变差）。
#   可达=2xx–4xx，5xx（squid 错误页）不算应答。
#   范围收窄（2026-10-13）：Actions 构件通道两域（blob/results-receiver）已入
#   NO_PROXY（PR 1926/1930）——生产流量直连不过 squid；A/B 的"squid 腿"靠 env
#   代理，NO_PROXY 命中后同样是直连，相对判定退化为两条直连腿的抖动互搏
#   （gy-001/gy-004 同 commit 一红一绿实证）。按"不测不过 squid 的流量"原则
#   移出套件（actions-channels 已删），本组只测真走 squid 的通道。
# =============================================================================

# A/B 探测：同 URL 走 squid（默认 env）与直连（剥代理 env + --noproxy）各 N 次。
# 成功判据：2xx–4xx（未认证 4xx 属预期，说明出口+TLS+上游全通）；
# 5xx 不算——经代理时 5xx 主要是 squid 生成的错误页（上游不可达），与超时同属失败。
# probe_ab <域名> <URL> <每路探测次数>  →  stdout: "squid_ok squid_p50 direct_ok direct_p50"
# （TSV 头由调用方初始化，本函数只追加；squid 路响应体落 ab-body 供内容抽查）
probe_ab() {
    local host="$1" url="$2" n="${3:-5}"
    local mid=$(( (n + 1) / 2 ))
    local path ok times=() i out code t
    for path in squid direct; do
        ok=0; times=()
        for i in $(seq 1 "$n"); do
            if [ "$path" = squid ]; then
                out=$(curl -sS -o "$RESULTS_DIR/ab-body" -m 15 -w '%{http_code} %{time_total}' "$url" 2>>"$RESULTS_DIR/upstream-channels.log")
            else
                # 直连：剥代理 env + --noproxy '*' 双保险（绕开 squid，同出口对比）
                out=$(env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
                      curl -sS --noproxy '*' -o /dev/null -m 15 -w '%{http_code} %{time_total}' "$url" \
                      2>>"$RESULTS_DIR/upstream-channels.log")
            fi
            if [ -n "$out" ]; then code=${out%% *} t=${out##* }; else code=ERR; t=15; fi
            printf '%s\t%s\t%s\t%s\t%s\n' "$host" "$path" "$code" "$t" "$(date '+%H:%M:%S')" >> "$RESULTS_DIR/upstream-probes.tsv"
            case "$code" in 2*|3*|4*) ok=$((ok+1)); times+=("$t") ;; esac
        done
        if [ ${#times[@]} -gt 0 ]; then
            eval "p50_$path=\$(printf '%s\n' \"\${times[@]}\" | sort -n | sed -n ${mid}p)"
        else
            eval "p50_$path=15"
        fi
        eval "ok_$path=$ok"
    done
    echo "$ok_squid ${p50_squid:-15} $ok_direct ${p50_direct:-15}"
}

# A/B 判定：squid 成功率 ≥ 直连 且 p50 不劣于直连（×1.5 噪声容差）→ PASS，否则 FAIL
ab_verdict() {   # ab_verdict <host> <s_ok> <s_p50> <d_ok> <d_p50>
    local host="$1" s_ok="$2" s_p50="$3" d_ok="$4" d_p50="$5"
    if [ "$s_ok" -lt "$d_ok" ]; then
        echo "❌ $host：squid 成功 $s_ok/5 < 直连 $d_ok/5 —— 代理引入失败（R17 A/B）"; return 1
    fi
    awk -v s="$s_p50" -v d="$d_p50" 'BEGIN{exit !(s <= d*1.5 + 0.1)}' || {
        echo "❌ $host：squid p50=${s_p50}s 显著劣于直连 p50=${d_p50}s（>1.5×，R17 A/B）"; return 1
    }
    if [ "$d_ok" -eq 0 ]; then
        echo "✅ $host：squid $s_ok/5 p50=${s_p50}s；直连 0/5（出口策略封直连，squid 是唯一通路）"
    else
        echo "✅ $host：squid $s_ok/5 p50=${s_p50}s 不劣于直连 $d_ok/5 p50=${d_p50}s（R17 A/B）"
    fi
    return 0
}

# gh-proxy 健康度：A/B 对照（诊断实测 test 实例 p50 3.2s 已不健康；
# 同时保留 5s 绝对预算——直连也慢说明是 host 本身的问题，不是 squid 的）
GHPROXY_URL="${GHPROXY_URL:-https://gh-proxy.test.osinfra.cn}"
ghproxy-health() {
    # URL 形态对齐 CANN gitconfig insteadOf：<host>/https://github.com/...
    local url="$GHPROXY_URL/https://raw.githubusercontent.com/octocat/Hello-World/master/README"
    : > "$RESULTS_DIR/ghproxy.log"
    # probe_ab / slow-upstream 的落盘文件（TSV 头在此初始化，调用方只追加）
    : > "$RESULTS_DIR/upstream-channels.log"
    printf 'host\tpath\tcode\tseconds\tat\n' > "$RESULTS_DIR/upstream-probes.tsv"
    local r fail=0
    r=$(probe_ab "gh-proxy" "$url" 5)
    # 内容抽查：squid 路最后一次拉取物必须非空
    [ -s "$RESULTS_DIR/ab-body" ] || { echo "❌ gh-proxy 拉取内容为空——host: $GHPROXY_URL"; return 1; }
    ab_verdict "gh-proxy" $r || fail=1
    # 绝对预算兜底：A/B 相对判定可能双双都慢（同走坏 host），绝对线防漏
    local s_p50=$(echo "$r" | awk '{print $2}')
    awk -v t="$s_p50" 'BEGIN{exit !(t<=5.0)}' || {
        echo "❌ gh-proxy p50=${s_p50}s 超绝对预算 5s——host 本身不健康: $GHPROXY_URL（R17：test 实例形态）"; fail=1
    }
    return $fail
}

# 静默上游：TCP 可建立但永不响应 → 留档 squid read_timeout 实际形态（R17：数据不判结论）
slow-upstream() {
    local port=$((18080 + RANDOM % 2000))
    python3 -c "
import socket,time,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('127.0.0.1',$port)); s.listen(1)
c,_=s.accept(); time.sleep(90)
" > "$RESULTS_DIR/slow-upstream.log" 2>&1 &
    local pid=$!
    sleep 1
    # 显式 -x + 清空 noproxy：127.0.0.1 必须走 squid 才能测到 squid 的 read_timeout
    local out rc=0
    out=$(curl -sS --noproxy '' -x "$PX" -m 60 -o /dev/null -w '%{http_code} %{time_total}' "http://127.0.0.1:$port/" 2>&1) || rc=$?
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
    printf 'silent-upstream\t%s\t%s\n' "$out" "rc=$rc" >> "$RESULTS_DIR/upstream-probes.tsv"
    case "$out" in
        *4*)  echo "⚠️ squid ${out##* }s 内返回 $out（read_timeout 已调短，fail-fast 生效）" ;;
        *)    echo "⚠️ 60s 内 squid 未裁决（客户端中止 rc=$rc）→ read_timeout 仍为长超时（cn12-001 30min 未调形态），仅留档" ;;
    esac
    return 0   # R17：CI 时限内无法观测完整 read_timeout，只做数据留档
}

# =============================================================================
# imagebuild 组 —— 镜像构建外网流量面复刻（vllm-ascend Image Build and Push）
#   背景：Dockerfile.310p 构建的出网面 = ① checkout@v7 submodules:recursive 按
#   .gitmodules 拉 gitcode.com/cann/catlass；② COMPILE_CUSTOM_KERNELS=1 时
#   csrc cmake 拉 gitcode.com/cann-src-third-party 5 个 release 压缩包（REQ_URL，
#   protobuf 在 protobuf.cmake / ascend_protobuf.cmake 重复出现已去重）；
#   ③ Dockerfile L92 经 GIT_PROXY insteadOf clone github.com/vllm-project/vllm。
#   集群内 cache-service（pypi/yum/rustup/crates）已入 NO_PROXY 直连不过 squid，
#   按"不测不过 squid 的流量"原则不在本组（与 upstream 组同口径）。
# =============================================================================

IB_TARBALLS=(
    "abseil-cpp|https://gitcode.com/cann-src-third-party/abseil-cpp/releases/download/20230802.1/abseil-cpp-20230802.1.tar.gz"
    "protobuf|https://gitcode.com/cann-src-third-party/protobuf/releases/download/v25.1/protobuf-25.1.tar.gz"
    "googletest|https://gitcode.com/cann-src-third-party/googletest/releases/download/v1.14.0/googletest-1.14.0.tar.gz"
    "json|https://gitcode.com/cann-src-third-party/json/releases/download/v3.11.3/include.zip"
    "makeself|https://gitcode.com/cann-src-third-party/makeself/releases/download/release-2.5.0-patch1.0/makeself-release-2.5.0-patch1.tar.gz"
)

# ① catlass 子模块：actions/checkout@v7 submodules:recursive 形态 = git fetch
#    固定 commit → 内容落盘（对应构建机 COPY 进镜像的动作）
ib-catlass() {
    local dir="$RESULTS_DIR/catlass" mode="pinned"
    rm -rf "$dir"; mkdir -p "$dir"
    echo "--- gitcode.com/cann/catlass @ $CATLASS_COMMIT（checkout submodules:recursive 形态）---"
    (
        cd "$dir" && git init -q . && git remote add origin https://gitcode.com/cann/catlass.git &&
        git_to "$GIT_OP_TIMEOUT" git fetch -q --depth 1 origin "$CATLASS_COMMIT" && git checkout -q FETCH_HEAD
    ) 2>"$RESULTS_DIR/catlass.err" || mode="default"
    if [ "$mode" = "default" ]; then
        # 部分托管端不放开任意 commit fetch（allowAnySHA1InWant）→ 回退默认分支
        # depth1：仅数据点（mock 形态降级），不判失败——代理链路是否通由内容落盘判
        echo "⚠️ pinned commit fetch 被拒（$(head -c 160 "$RESULTS_DIR/catlass.err" | tr '\n' ' ')），回退默认分支 depth1"
        (
            cd "$dir" && git_to "$GIT_OP_TIMEOUT" git fetch -q --depth 1 origin && git checkout -q FETCH_HEAD
        ) 2>>"$RESULTS_DIR/catlass.err" || { echo "❌ catlass fetch 失败（含默认分支回退）"; return 1; }
    fi
    local n
    n=$(find "$dir" -type f -not -path '*/.git/*' | wc -l)
    [ "$n" -gt 10 ] || { echo "❌ catlass 工作区仅 $n 个文件，子模块内容未落盘"; return 1; }
    echo "✅ catlass 内容落盘（$mode）：$n 个文件，HEAD $(git -C "$dir" rev-parse --short HEAD)"
}

# ② cmake 第三方压缩包：csrc/cmake/third_party 各 .cmake 的 REQ_URL。
#    两遍拉取（同对象复拉）：sha256 一致性判缓存内容完整性；Cache-Status 留档
#    （静态 release 资产可缓存性取决于 squid refresh_pattern，HIT/MISS 不判结论）
ib-tarballs() {
    local item name url f1 f2 h1 h2 out c1 c2 t1 t2 xc bad=0
    echo "--- gitcode.com/cann-src-third-party release 压缩包（cmake REQ_URL 两遍拉取）---"
    for item in "${IB_TARBALLS[@]}"; do
        name="${item%%|*}"; url="${item#*|}"
        f1="$RESULTS_DIR/tb-$name.r1"; f2="$RESULTS_DIR/tb-$name.r2"
        rm -f "$f1" "$f2" "$RESULTS_DIR/tb-$name.hdr"
        # 第一遍：冷拉（cmake 首次构建形态），-D 收响应头看 Cache-Status
        out=$(px_curl -D "$RESULTS_DIR/tb-$name.hdr" -L -o "$f1" -w '%{http_code} %{time_total}' "$url")
        c1=${out%% *}; t1=${out##* }
        printf '%s\t%s\t%s\n' "$url" "$c1" "$t1" >> "$PROBES"
        # 第二遍：同对象复拉（缓存命中形态 + 完整性比对）
        out=$(px_curl -L -o "$f2" -w '%{http_code} %{time_total}' "$url")
        c2=${out%% *}; t2=${out##* }
        printf '%s\t%s\t%s\n' "$url" "$c2" "$t2" >> "$PROBES"
        h1=$(sha256_of "$f1"); h2=$(sha256_of "$f2")
        xc=$(grep -ai '^x-cache:' "$RESULTS_DIR/tb-$name.hdr" 2>/dev/null | head -1 | tr -d '\r' | cut -d' ' -f2-)
        if [[ "$c1" != 2* || "$c2" != 2* ]]; then
            echo "❌ $name：拉取失败（r1=$c1 r2=$c2）$url"; bad=$((bad+1)); continue
        fi
        if [ -s "$f1" ] && [ "$h1" = "$h2" ]; then
            printf 'tb-tarball\t%s\t%s\tr1=%ss r2=%ss\n' "$name" "${xc:-N/A}" "$t1" "$t2" >> "$RESULTS_DIR/imagebuild-cache.tsv"
            echo "✅ $name：${t1}s/${t2}s，sha256 两遍一致，X-Cache: ${xc:-N/A}"
        else
            echo "❌ $name：两遍 sha256 不一致或内容为空（r1=$h1 r2=$h2）——缓存内容完整性存疑"
            bad=$((bad+1))
        fi
    done
    [ "$bad" -eq 0 ] || return 1
    echo "⚠️ Cache-Status 仅留档（imagebuild-cache.tsv / probes.tsv），HIT/MISS 不判结论"
    return 0
}

# ③ vllm clone：Dockerfile.310p L92 形态 = gitconfig url.insteadOf 把 github.com
#    重写到 GIT_PROXY 后 clone --depth 1 -b <VLLM_TAG>（大 pack 吞吐通道）
ib-vllm-gitproxy() {
    local dir="$RESULTS_DIR/vllm-clone" ref="$IB_VLLM_REF"
    rm -rf "$dir"
    # insteadOf 形态与 Dockerfile L86 一致；IB_GIT_PROXY 为空 → 不加配置（直连，本地冒烟逃生门）
    local g=()
    [ -n "$IB_GIT_PROXY" ] && g=(-c "url.${IB_GIT_PROXY}https://github.com/.insteadOf=https://github.com/")
    echo "--- github.com/vllm-project/vllm --depth 1 -b $ref（insteadOf → ${IB_GIT_PROXY:-直连}）---"
    # tag 预检：Dockerfile 用固定 VLLM_TAG；上游发版后旧 tag 不存在则改用最新 tag
    if ! git "${g[@]}" ls-remote --exit-code --tags https://github.com/vllm-project/vllm "refs/tags/$ref" >/dev/null 2>&1; then
        ref=$(git "${g[@]}" ls-remote --tags https://github.com/vllm-project/vllm \
              | awk -F'/' '{print $NF}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
        [ -n "$ref" ] || { echo "❌ vllm tag 预检失败（$IB_VLLM_REF 不存在且取不到最新 tag）"; return 1; }
        echo "⚠️ 指定 tag $IB_VLLM_REF 不存在，改用最新 tag $ref"
    fi
    if timeout 600 git "${g[@]}" clone -q --depth 1 -b "$ref" \
        https://github.com/vllm-project/vllm "$dir" 2>"$RESULTS_DIR/vllm-clone.err"; then
        local n
        n=$(find "$dir" -type f -not -path '*/.git/*' | wc -l)
        [ "$n" -gt 100 ] || { echo "❌ vllm 工作区仅 $n 个文件，clone 不完整"; return 1; }
        echo "✅ vllm@$ref clone 完成：$n 个文件（大 pack 吞吐经 ${IB_GIT_PROXY:-直连}）"
    else
        echo "❌ vllm clone 失败：$(head -c 200 "$RESULTS_DIR/vllm-clone.err" | tr '\n' ' ')"
        return 1
    fi
}

# ④ OBS 静态资产：CANN 安装包 + CI 覆盖率工件 + 代码扫描二进制（R18 镜像构建外网面）
#    OBS 域名不在重写规则内（META 规则11 官方源直通），流量经 squid MITM 打到 origin：
#    验 ① Range/HEAD 语义不被 MITM 破坏 ② 静态对象内容形态正确 ③ 负样本确实失败
OBS_CANN_URL="${OBS_CANN_URL:-https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%209.1.0/Ascend-cann-toolkit_9.1.0_linux-ARCH.run}"
OBS_CANN_REFERER="${OBS_CANN_REFERER:-https://www.hiascend.com/}"
OBS_COV_JSON="${OBS_COV_JSON:-https://sglang-npu.obs.cn-southwest-2.myhuaweicloud.com/coverage/test_case_map.json}"
OBS_COV_TGZ="${OBS_COV_TGZ:-https://sglang-npu.obs.cn-southwest-2.myhuaweicloud.com/coverage/outputs.tar.gz}"
OBS_ELF_URL="${OBS_ELF_URL:-https://pytorch-package.obs.cn-north-4.myhuaweicloud.com/pta-codecheck/gitleaks}"
OBS_NEG_URL="${OBS_NEG_URL:-https://sglang-npu.obs.cn-southwest-2.myhuaweicloud.com/coverage/__squid_negative_sample__.json}"

ib-ascend-obs() {
    local bad=0 arch url out code t hdr magic b0 cl rc bin
    case "$PKG_ARCH" in amd64) arch="x86_64" ;; arm64) arch="aarch64" ;; *) arch="x86_64" ;; esac
    echo "--- myhuaweicloud OBS 静态资产（CANN .run / 覆盖率工件 / 代码扫描二进制）---"

    # ① CANN toolkit .run：vllm-ascend / CANN 镜像构建必装，脚本带 Referer 防盗链。
    #    Range 前 32 字节取 bash 魔数；HEAD 的 Content-Length 证明大对象元数据完整
    url="${OBS_CANN_URL/ARCH/$arch}"
    hdr="$RESULTS_DIR/obs-cann.hdr"; rm -f "$hdr" "$RESULTS_DIR/obs-cann.head"
    out=$(obs_curl -D "$hdr" --max-filesize 1048576 -H "Referer: $OBS_CANN_REFERER" \
          -r 0-31 -o "$RESULTS_DIR/obs-cann.head" -w '%{http_code} %{time_total}' "$url")
    code=${out%% *}; t=${out##* }
    printf '%s\t%s\t%s\n' "$url" "$code" "$t" >> "$PROBES"
    if [ "$code" = "404" ] && [ "$arch" != "x86_64" ]; then
        echo "⚠️ CANN $arch 安装包 URL 未命中（404，命名可能变更），跳过该架构子项"
    elif [ "$code" != "206" ]; then
        echo "❌ CANN .run Range 异常：http=$code（期望 206——MITM 下 Range 语义被破坏或防盗链拒绝）$url"
        bad=$((bad+1))
    elif [ "$(head -c 2 "$RESULTS_DIR/obs-cann.head" 2>/dev/null)" != "#!" ]; then
        echo "❌ CANN .run 前 32 字节不是 #!（内容错乱/错误页）：$(head -c 40 "$RESULTS_DIR/obs-cann.head" | tr -d '\0' | tr '\n' ' ')"
        bad=$((bad+1))
    else
        cl=$(obs_curl -sSI --max-time 60 -H "Referer: $OBS_CANN_REFERER" "$url" \
             | grep -ai '^content-length:' | tail -1 | tr -dc '0-9')
        printf 'obs-cann\t%s\t%s\tRange32=206 len=%s\n' "$url" "$t" "${cl:-N/A}" >> "$RESULTS_DIR/imagebuild-cache.tsv"
        if [ -n "$cl" ] && [ "$cl" -gt 100000000 ]; then
            echo "✅ CANN .run：Range 32B 魔数 #!，Content-Length $cl 字节（${t}s，经 ${PX:-直连}）"
        else
            echo "❌ CANN .run Content-Length 异常（${cl:-取不到}，期望 >100MB——大对象元数据被截断）"
            bad=$((bad+1))
        fi
    fi

    # ② CI 覆盖率索引 JSON（sglang-npu / vllm-ascend 工件通道，~20–25MB）：
    #    Range 首字节判 JSON 形态；X-Cache-Lookup/X-Cache/Via 只留档不判 HIT
    hdr="$RESULTS_DIR/obs-json.hdr"; rm -f "$hdr" "$RESULTS_DIR/obs-json.b0"
    out=$(obs_curl -D "$hdr" --max-filesize 1048576 -r 0-0 -o "$RESULTS_DIR/obs-json.b0" \
          -w '%{http_code} %{time_total}' "$OBS_COV_JSON")
    code=${out%% *}; t=${out##* }
    printf '%s\t%s\t%s\n' "$OBS_COV_JSON" "$code" "$t" >> "$PROBES"
    b0=$(cat "$RESULTS_DIR/obs-json.b0" 2>/dev/null)
    local xc
    xc=$(grep -aiE '^(x-cache-lookup|x-cache|via):' "$hdr" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | cut -c1-200)
    if [[ "$code" = 2* ]] && { [ "$b0" = "{" ] || [ "$b0" = "[" ]; }; then
        printf 'obs-json\t%s\t%s\tfirst_byte=%s %s\n' "$OBS_COV_JSON" "$t" "$b0" "${xc:-无缓存头}" >> "$RESULTS_DIR/imagebuild-cache.tsv"
        echo "✅ 覆盖率 JSON 首字节 $b0（${t}s；缓存头留档：${xc:-无}）"
    else
        echo "❌ 覆盖率 JSON 形态异常：http=$code 首字节=[$b0]"
        bad=$((bad+1))
    fi

    # ③ 覆盖率打包工件 tar.gz：gzip 魔数；HEAVY=1 两遍全量 sha256（~16MB，
    #    同对象复拉 → 缓存内容完整性，判定口径对齐 ib-tarballs）
    out=$(obs_curl --max-filesize 1048576 -r 0-2 -o "$RESULTS_DIR/obs-tgz.b0" \
          -w '%{http_code} %{time_total}' "$OBS_COV_TGZ")
    code=${out%% *}; t=${out##* }
    printf '%s\t%s\t%s\n' "$OBS_COV_TGZ" "$code" "$t" >> "$PROBES"
    magic=$(od -An -tx1 -N3 "$RESULTS_DIR/obs-tgz.b0" 2>/dev/null | tr -d ' \n')
    if [[ "$code" = 2* ]] && [ "$magic" = "1f8b08" ]; then
        echo "✅ 覆盖率 tar.gz gzip 魔数 1f8b08（${t}s）"
    else
        echo "❌ 覆盖率 tar.gz 魔数异常：http=$code magic=${magic:-空}"
        bad=$((bad+1))
    fi
    if [ "$HEAVY" = "1" ]; then
        local f1="$RESULTS_DIR/obs-tgz.r1" f2="$RESULTS_DIR/obs-tgz.r2" c1 c2 h1 h2
        rm -f "$f1" "$f2"
        c1=$(obs_curl -o "$f1" -w '%{http_code}' "$OBS_COV_TGZ")
        c2=$(obs_curl -o "$f2" -w '%{http_code}' "$OBS_COV_TGZ")
        h1=$(sha256_of "$f1"); h2=$(sha256_of "$f2")
        if [[ "$c1" = 2* && "$c2" = 2* ]] && [ -s "$f1" ] && [ "$h1" = "$h2" ]; then
            printf 'obs-tgz\t%s\t%s\tr1/r2 sha256 一致\n' "$OBS_COV_TGZ" "$h1" >> "$RESULTS_DIR/imagebuild-cache.tsv"
            echo "✅ 覆盖率 tar.gz 两遍全量 sha256 一致（$h1）"
        else
            echo "❌ 覆盖率 tar.gz 两遍全量不一致（r1=$c1 r2=$c2 $h1 vs $h2）——缓存内容完整性存疑"
            bad=$((bad+1))
        fi
    else
        echo "⚠️ 覆盖率 tar.gz 全量 sha256 未做（HEAVY=0，仅验魔数）"
    fi

    # ④ gitleaks 单文件二进制：真实 CI 形态是 wget --no-check-certificate 拉取后直接执行
    if [ "$arch" != "x86_64" ]; then
        echo "⚠️ gitleaks 仅发布 x86_64 产物，$arch 跳过"
    else
        bin="$RESULTS_DIR/gitleaks"; rm -f "$bin"
        if have wget && ! wget_is_busybox; then
            wget -q --no-check-certificate --timeout=120 -O "$bin" "$OBS_ELF_URL" 2>"$RESULTS_DIR/obs-elf.err"
            rc=$?
        else
            obs_curl -o "$bin" "$OBS_ELF_URL" 2>"$RESULTS_DIR/obs-elf.err"
            rc=$?
        fi
        magic=$(od -An -tx1 -N4 "$bin" 2>/dev/null | tr -d ' \n')
        if [ "$rc" -ne 0 ]; then
            echo "❌ gitleaks 下载失败（rc=$rc）：$(head -c 160 "$RESULTS_DIR/obs-elf.err" | tr '\n' ' ')"
            bad=$((bad+1))
        elif [ "$magic" != "7f454c46" ]; then
            echo "❌ gitleaks 不是 ELF（magic=${magic:-空}，可能是 OBS 错误页）"
            bad=$((bad+1))
        else
            chmod +x "$bin"
            out=$("$bin" version 2>&1 | head -1)
            if [ -n "$out" ]; then
                echo "✅ gitleaks ELF 可执行：$out（$(wc -c < "$bin") 字节）"
            else
                echo "❌ gitleaks ELF 完整但无法执行（架构/依赖不匹配）"
                bad=$((bad+1))
            fi
        fi
    fi

    # ⑤ 负样本（R3/F6）：不存在的 key 必须 403/404，证明上面的 2xx 判定不是恒真
    out=$(obs_curl --max-filesize 1048576 -o /dev/null -w '%{http_code} %{time_total}' "$OBS_NEG_URL")
    code=${out%% *}; t=${out##* }
    printf '%s\t%s\t%s\n' "$OBS_NEG_URL" "$code" "$t" >> "$PROBES"
    if [ "$code" = "403" ] || [ "$code" = "404" ]; then
        echo "✅ 负样本：不存在 key 返回 $code（判定方法有效）"
    else
        echo "❌ 负样本：不存在 key 返回 $code（期望 403/404——2xx 判定可能恒真）"
        bad=$((bad+1))
    fi

    [ "$bad" -eq 0 ] || return 1
    echo "⚠️ X-Cache-Lookup/X-Cache/Via 仅留档（imagebuild-cache.tsv），OBS 静态对象 HIT/MISS 不判结论"
    return 0
}

# =============================================================================
# gitcode 组阶段（smart git proxy 缓存验证，R21）
#   前提：pod postStart 往 /root/.gitconfig 追加
#     [url "http://smart-git-proxy-service.smart-git-proxy.svc.cluster.local:8080/gitcode.com/"]
#         insteadOf = https://gitcode.com/
#   该 service 属 .svc.cluster.local（在 NO_PROXY 内）→ 直连绕开 squid，
#   缓存由 smart git proxy 自己负责。本组只回答三个问题：
#     ① 重写是否生效（git ls-remote --get-url 展开后是否指向 proxy）
#     ② 拉取是否真的走 proxy（GIT_TRACE_CURL 里的 Host/请求行）
#     ③ 重复拉取是否命中缓存（二遍耗时 / 缓存响应头）
#   注意：本组流量【不应】经过 squid，故不跑 meta-trace。
# =============================================================================
GITCODE_REPO="${GITCODE_REPO:-https://gitcode.com/cann/catlass.git}"
# 缓存后端基址。两种注入形态：
#   gy-005  smart-git-proxy：http://smart-git-proxy-service.smart-git-proxy.svc.cluster.local:8080/gitcode.com/
#   gy-006  等生产集群 git-cdn-gitcode：http://git-cdn-service.git-cdn-gitcode.svc.cluster.local:8000/
# 重写后 URL 只差"是否带 /gitcode.com 前缀段"，故本组统一从展开结果反推基址，
# 不硬编码前缀段（GITCODE_PROXY 只作为期望值断言）。
GITCODE_PROXY="${GITCODE_PROXY:-http://smart-git-proxy-service.smart-git-proxy.svc.cluster.local:8080}"
GITCODE_STRICT="${GITCODE_STRICT:-0}"   # 1=重写缺失/无缓存收益时判红（定向验证用）
GITCODE_DIRECT="${GITCODE_DIRECT:-0}"   # 1=跳过 insteadOf 断言，直接打 GITCODE_PROXY（验后端服务本身）
# clone 形态，决定能否进后端 pack 缓存：
#   full    = --single-branch（不带 depth）→ git-cdn/smart-git-proxy 的 can_be_cached() 才放行
#   shallow = --depth 1 → git-cdn 默认 PACK_CACHE_DEPTH=false，带 depth 的请求直接不缓存，
#             只能验"能拉下来"，不能验"二次命中"，故该形态下缓存断言记 SKIP 而非红。
GITCODE_CLONE_MODE="${GITCODE_CLONE_MODE:-full}"
# LFS 验证目标仓库。空=沿用 GITCODE_REPO，克隆后按 .gitattributes 是否含 filter=lfs 自动判定；
# 目标仓库不含 LFS 时记 SKIP，可指向真实 LFS 仓库（如模型/权重仓库）再验。
GITCODE_LFS_REPO="${GITCODE_LFS_REPO:-}"

_gitcode_repo_path() { printf '%s' "${GITCODE_REPO#*gitcode.com}"; }   # /cann/catlass.git
_gitcode_proxied_url() { git ls-remote --get-url "$GITCODE_REPO" 2>/dev/null; }
_gitcode_norm() { printf '%s' "${1%/}"; }
# 本次实际访问的起点：direct 用 GITCODE_PROXY；否则从 insteadOf 展开结果剥掉仓库路径
_gitcode_base() {
    local u path origin
    if [ "$GITCODE_DIRECT" = "1" ]; then _gitcode_norm "$GITCODE_PROXY"; return 0; fi
    u=$(_gitcode_proxied_url); path=$(_gitcode_repo_path)
    case "$u" in
        *"$path")
            u=$(_gitcode_norm "${u%"$path"}")
            # 展开后仍指向 gitcode.com 本体 = 未重写，不能拿它当缓存后端去探测
            origin=$(_gitcode_norm "${GITCODE_REPO%"$path"}")
            [ "$u" = "$origin" ] && return 1
            printf '%s' "$u"
            ;;
        *) return 1 ;;
    esac
}

gitcode-config() {
    echo "--- 全局 insteadOf 重写 ---"
    git config --global --get-regexp '^url\..*\.insteadof$' || echo "(无 insteadOf 配置)"
    local u base
    u=$(_gitcode_proxied_url)
    echo "URL 展开: $GITCODE_REPO → ${u:-<空>}"
    if [ "$GITCODE_DIRECT" = "1" ]; then
        echo "ℹ️ GITCODE_DIRECT=1：跳过 insteadOf 断言，直连 $(_gitcode_base)（验缓存后端服务本身）"
        return 0
    fi
    base=$(_gitcode_base) || base=""
    echo "重写起点: ${base:-<未解析>}（期望 $(_gitcode_norm "$GITCODE_PROXY")）"
    if [ "$base" = "$(_gitcode_norm "$GITCODE_PROXY")" ]; then
        echo "✅ gitcode.com 已重写到缓存后端 $base"
        return 0
    fi
    echo "⚠️ 未重写到 $(_gitcode_norm "$GITCODE_PROXY")（postStart 未生效 / 该 runner 未注入）"
    echo "   已知后端基址: smart-git-proxy(gitcode.com/) | git-cdn-gitcode"
    [ -n "$base" ] && echo "   本次实际: $base —— 若不是所选后端，用 -f gitcode_backend=<后端> 重跑"
    if [ "$GITCODE_STRICT" = "1" ]; then echo "❌ GITCODE_STRICT=1，判失败"; return 1; fi
    return 2
}

gitcode-refs-probe() {
    local base path url i hdrs out code t
    path=$(_gitcode_repo_path)                 # /cann/catlass.git
    base=$(_gitcode_base) || { echo "⚠️ 无法解析缓存后端基址（见 gitcode-config）"; return 2; }
    url="${base}${path}/info/refs?service=git-upload-pack"
    echo "探测端点: $url"
    for i in 1 2; do
        hdrs="$RESULTS_DIR/gitcode-refs-$i.headers"
        # UA 必须是 git：git-cdn 的 redirect_browsers() 把不含 "git" 的客户端
        # （curl/wget 等）308 跳回上游，只有 UA 含 git 才走缓存逻辑。
        if ! out=$(curl -sS -A 'git/2.43.0' -o "$RESULTS_DIR/gitcode-refs-$i.bin" -D "$hdrs" \
                       -w '%{http_code} %{time_total}' --max-time 30 "$url" 2>/dev/null); then
            echo "⚠️ smart git proxy 不可达（$url）"
            [ "$GITCODE_STRICT" = "1" ] && return 1
            return 2
        fi
        code=${out%% *}; t=${out##* }
        printf '%s\t%s\t%s\n' "$url" "$code" "$t" >> "$PROBES"
        echo "第 ${i} 次: http=$code time=${t}s"
        grep -iE '^(cache-status|x-cache|x-cache-status|age|via|server):' "$hdrs" 2>/dev/null \
            | tr -d '\r' | sed 's/^/    | /' || true
    done
    [ "$code" = "200" ] || { echo "❌ info/refs 非 200（$code）"; return 1; }
    if grep -q 'git-upload-pack' "$RESULTS_DIR/gitcode-refs-2.bin"; then
        echo "✅ refs 广告正常（smart HTTP，含 git-upload-pack）"
    elif [ -s "$RESULTS_DIR/gitcode-refs-2.bin" ]; then
        echo "✅ refs 响应非空（dumb HTTP 形态，无 service 广告）"
    else
        echo "❌ refs 响应为空，端点不是 git 服务"
        return 1
    fi
}

gitcode-clone-hitmiss() {
    local base url d1 d2 s e t1 t2 host hit="" args
    base=$(_gitcode_base) || { echo "⚠️ 无法解析缓存后端基址，跳过 clone（见 gitcode-config）"; return 2; }
    url="${base}$(_gitcode_repo_path)"
    host="${base#*://}"; host="${host%%/*}"
    case "$GITCODE_CLONE_MODE" in
        full)    args=("--single-branch") ;;              # 不带 depth → 可进 pack 缓存
        shallow) args=("--depth" "1" "--single-branch") ;; # 带 depth → 后端默认不缓存
        *) echo "❌ 未知 GITCODE_CLONE_MODE=$GITCODE_CLONE_MODE（可选 full|shallow）"; return 1 ;;
    esac
    echo "clone 目标: $url（对端 $host，形态 $GITCODE_CLONE_MODE）"
    d1="$RESULTS_DIR/gitcode-clone-1"; d2="$RESULTS_DIR/gitcode-clone-2"
    rm -rf "$d1" "$d2"

    s=$(date +%s%3N)
    if ! GIT_TERMINAL_PROMPT=0 GIT_TRACE_CURL=1 \
            git clone "${args[@]}" -q "$url" "$d1" \
            2>"$RESULTS_DIR/gitcode-clone-1.trace"; then
        echo "❌ 第 1 次 clone 失败（重写后不可拉取）"
        tail -n 8 "$RESULTS_DIR/gitcode-clone-1.trace" | sed 's/^/    | /'
        return 1
    fi
    e=$(date +%s%3N); t1=$((e-s))

    s=$(date +%s%3N)
    if ! GIT_TERMINAL_PROMPT=0 GIT_TRACE_CURL=1 \
            git clone "${args[@]}" -q "$url" "$d2" \
            2>"$RESULTS_DIR/gitcode-clone-2.trace"; then
        echo "❌ 第 2 次 clone 失败"
        tail -n 8 "$RESULTS_DIR/gitcode-clone-2.trace" | sed 's/^/    | /'
        return 1
    fi
    e=$(date +%s%3N); t2=$((e-s))

    echo "耗时: 第1次 ${t1}ms / 第2次 ${t2}ms"
    if grep -q "$host" "$RESULTS_DIR/gitcode-clone-1.trace"; then
        echo "✅ clone 实际经过缓存后端（trace 含 $host）"
    else
        echo "❌ clone 未经过缓存后端（trace 无 $host）——insteadOf 未生效"
        return 1
    fi

    # 带 depth 的请求在 git-cdn 后端不进 pack 缓存（can_be_cached() 要求 no-depth），
    # 此时"二次无收益"是设计行为而非故障，记 SKIP，避免假红。
    if [ "$GITCODE_CLONE_MODE" = "shallow" ]; then
        rm -rf "$d1" "$d2"
        echo "⚠️ shallow 形态（--depth 1）：后端默认 PACK_CACHE_DEPTH=false，pack 缓存不适用，缓存断言记 SKIP"
        echo "ℹ️ 要验缓存收益请用 GITCODE_CLONE_MODE=full（默认）或后端开启 PACK_CACHE_DEPTH"
        return 2
    fi

    grep -qiE '^< (cache-status:.*hit|x-cache: *hit|x-cache-status: *hit|age: *[1-9])' \
        "$RESULTS_DIR/gitcode-clone-2.trace" && hit="header"

    # trace 只留请求行/主机/缓存头证据：原始 GIT_TRACE_CURL 单文件 40MB+，
    # 上传 artifact 又慢又没价值（证据行已足够定位是否走后端/是否命中）。
    for f in "$RESULTS_DIR/gitcode-clone-1.trace" "$RESULTS_DIR/gitcode-clone-2.trace"; do
        [ -f "$f" ] && grep -aE '^< (cache-status|x-cache|age|HTTP)|^> (Host|GET|POST)' "$f" > "$f.small" && mv "$f.small" "$f"
    done

    rm -rf "$d1" "$d2"
    if [ -n "$hit" ]; then
        echo "✅ 第 2 次响应头带缓存命中标记 → 后端已缓存该仓库"
        return 0
    fi
    if [ "$t1" -gt 0 ] && [ "$t2" -le $((t1 * 70 / 100)) ]; then
        echo "✅ 第 2 次耗时下降 $((100 - t2 * 100 / t1))% → 命中后端 pack 缓存"
        return 0
    fi
    if [ "$t1" -le 5000 ] && [ "$t2" -le 5000 ]; then
        echo "✅ 两遍均 ≤5s（缓存已预热，无冷缓存对照）"
        return 0
    fi
    # 口径：本组硬判据是「insteadOf 生效、clone 真的走后端」（上方 trace 断言）。
    # 耗时不建硬判据——冷集群首跑必然无收益（第一遍才写缓存），且 git-cdn 的
    # pack 缓存对 --single-branch/协议差异有边界，判红只会制造假红。
    echo "⚠️ 第 2 次未见缓存收益（t1=${t1}ms t2=${t2}ms）——冷缓存首跑或后端未缓存，仅留档"
    return 2
}

# LFS 验证：git-cdn 会拦 info/lfs/objects/batch 并把 objects href 改写指向自己
# （git_cdn.py:260/322 + lfs_cache_manager.py），故这里验三件事：
#   ① git lfs 可用、HEAD 确有 LFS 跟踪文件（否则 SKIP，不判红）
#   ② 两次独立 clone 各拉同一个 LFS 对象，均成功且字节数一致（有界，不拉全仓）
#   ③ LFS batch endpoint 指向缓存后端主机（batch 被拦截）
#   ④ 【决定性】对象实际下载域必须也是缓存后端——gitcode 的 download href 常指向
#      lfs-cdn.gitcode.com，二者不是同一地址；只验 ③ 会把"绕过缓存"误判成命中
gitcode-lfs() {
    local base repo path url host d1 d2 ep t1 t2 s e n obj sz1 sz2 oid obj_url ohost obj_via_cache
    base=$(_gitcode_base) || { echo "⚠️ 无法解析缓存后端基址，跳过 LFS（见 gitcode-config）"; return 2; }
    repo="${GITCODE_LFS_REPO:-$GITCODE_REPO}"
    path="${repo#*gitcode.com}"
    url="${base}${path}"
    host="${base#*://}"; host="${host%%/*}"
    echo "LFS 目标: $url（对端 $host）"

    if ! command -v git-lfs >/dev/null 2>&1; then
        echo "⚠️ 容器内无 git-lfs，尝试安装"
        if ! (apt-get install -y -q git-lfs >/dev/null 2>&1 || apt-get update -q >/dev/null 2>&1 && apt-get install -y -q git-lfs >/dev/null 2>&1); then
            echo "⚠️ git-lfs 安装失败，LFS 用例记 SKIP"
            return 2
        fi
    fi
    git lfs version 2>/dev/null | sed 's/^/    | /' || true

    d1="$RESULTS_DIR/gitcode-lfs-1"; d2="$RESULTS_DIR/gitcode-lfs-2"
    rm -rf "$d1" "$d2"
    export GIT_LFS_SKIP_SMUDGE=1
    # LFS 仓库（如 Ascend/pytorch，LFS 体量 GB 级）历史与对象都大：clone 用
    # --depth 1 只取 HEAD 的指针，真正的对象下载由下面的 git lfs pull 有界执行。
    if ! GIT_TERMINAL_PROMPT=0 git_to "$GIT_OP_TIMEOUT" git clone --depth 1 --single-branch -q "$url" "$d1" 2>"$RESULTS_DIR/gitcode-lfs-1.trace"; then
        echo "❌ LFS 用例 clone 失败"
        tail -n 8 "$RESULTS_DIR/gitcode-lfs-1.trace" | sed 's/^/    | /'
        return 1
    fi
    # 用 ls-files 判定"HEAD 是否真有 LFS 跟踪文件"（.gitattributes 可能散在
    # 子目录、也可能只存在于历史），比只 grep 根 .gitattributes 准确。
    n=$(cd "$d1" && git lfs ls-files 2>/dev/null | wc -l)
    obj=$(cd "$d1" && git lfs ls-files -n 2>/dev/null | head -1)
    if [ -z "$obj" ]; then
        echo "⚠️ $repo 在 HEAD 没有 LFS 跟踪文件（git lfs ls-files 为空）→ SKIP"
        rm -rf "$d1"
        return 2
    fi
    echo "✅ HEAD 含 LFS 文件 $n 个；取首个对象做有界验证: $obj"

    ep=$(cd "$d1" && git lfs env 2>/dev/null | sed -n 's/^Endpoint=\(.*\) (.*/\1/p' | head -1)
    echo "LFS endpoint: ${ep:-<未解析>}"
    if [ -n "$ep" ] && [ "${ep#*://}" != "${ep}" ]; then
        case "${ep#*://}" in
            "$host"*) echo "✅ LFS endpoint 指向缓存后端 $host（batch 已被拦截改写）" ;;
            *) echo "❌ LFS endpoint 未指向缓存后端（${ep}）——batch 未改写，LFS 流量绕去上游"
               [ "$GITCODE_STRICT" = "1" ] && return 1 ;;
        esac
    else
        echo "⚠️ 无法解析 LFS endpoint，仅留档"
    fi

    # 只拉这一个对象（不拉全仓 GB 级 LFS），两次独立 clone 各拉一次；
    # GIT_CURL_VERBOSE 是为了取对象实际下载域（见下方断言）。
    s=$(date +%s%3N)
    if ! (cd "$d1" && GIT_TERMINAL_PROMPT=0 GIT_CURL_VERBOSE=1 git_to "$GIT_BIG_TIMEOUT" git lfs pull --include="$obj" >"$RESULTS_DIR/gitcode-lfs-pull-1.log" 2>&1); then
        echo "❌ 第 1 次 git lfs pull 失败"
        tail -n 8 "$RESULTS_DIR/gitcode-lfs-pull-1.log" | sed 's/^/    | /'
        return 1
    fi
    e=$(date +%s%3N); t1=$((e-s))
    if head -c 64 "$d1/$obj" 2>/dev/null | grep -q 'version https://git-lfs'; then
        echo "❌ $obj 仍是 LFS pointer，对象未真正下载"
        return 1
    fi
    sz1=$(stat -c%s "$d1/$obj" 2>/dev/null || echo 0)

    # 关键取证：batch 的 endpoint 与对象下载用的是两个地址（actions.download.href），
    # gitcode 的 href 若指向 lfs-cdn.gitcode.com（独立存储域），git-cdn 的
    # hook_lfs_batch（href.replace(upstream, base_url)）就匹配不到 → 对象直连
    # 上游存储，绕开缓存后端，此时"耗时下降"与缓存无关。
    oid=$(cd "$d1" && git show HEAD:"$obj" 2>/dev/null | sed -n 's/^oid sha256://p' | head -1)
    # 对象 URL 的 oid 是分段路径（objects/ae/6b/2603...），不是连续串，
    # 所以按 "objects/<2>/<2>/<hex>" 形态匹配，不能拿整串 oid 去 grep。
    obj_url=$(grep -aoE 'https?://[^ ]*/(lfs-objects|info/lfs/objects)/[0-9a-f]{2}/[0-9a-f]{2}/[0-9a-f]+' \
                  "$RESULTS_DIR/gitcode-lfs-pull-1.log" 2>/dev/null | head -1)
    if [ -n "$obj_url" ]; then
        ohost="${obj_url#*://}"; ohost="${ohost%%/*}"
        echo "对象下载 URL: $obj_url"
        if [ "$ohost" = "$host" ]; then
            echo "✅ LFS 对象下载经过缓存后端 $host"
            obj_via_cache=1
        else
            # 已知缺口（2026-10-23 取证）：gitcode 的 batch href 指向
            # lfs-cdn.gitcode.com，git-cdn 的 hook_lfs_batch 只改写 upstream
            # 前缀匹配的 href，改不到这个独立存储域 → 对象直连上游存储。
            # 记 ⚠️ 不阻断（rollout 验证关注重写本身），缺口单独修。
            echo "⚠️ LFS 对象下载绕过缓存后端（实际下载域 $ohost，期望 $host）——batch 已改写但 href 未改写，git-cdn LFS 缓存不生效（已知缺口）"
            obj_via_cache=0
        fi
    else
        echo "⚠️ 未能从 pull 日志解析对象下载 URL（oid=${oid:-<未取到>}），仅留档"
    fi

    if ! GIT_TERMINAL_PROMPT=0 git_to "$GIT_OP_TIMEOUT" git clone --depth 1 --single-branch -q "$url" "$d2" 2>"$RESULTS_DIR/gitcode-lfs-2.trace"; then
        echo "❌ 第 2 次 LFS clone 失败"
        return 1
    fi
    s=$(date +%s%3N)
    if ! (cd "$d2" && GIT_TERMINAL_PROMPT=0 git_to "$GIT_BIG_TIMEOUT" git lfs pull --include="$obj" >"$RESULTS_DIR/gitcode-lfs-pull-2.log" 2>&1); then
        echo "❌ 第 2 次 git lfs pull 失败"
        tail -n 8 "$RESULTS_DIR/gitcode-lfs-pull-2.log" | sed 's/^/    | /'
        return 1
    fi
    e=$(date +%s%3N); t2=$((e-s))
    sz2=$(stat -c%s "$d2/$obj" 2>/dev/null || echo 0)

    rm -rf "$d1" "$d2"
    echo "LFS 对象 $obj 大小: ${sz1}B / ${sz2}B；pull 耗时: 第1次 ${t1}ms / 第2次 ${t2}ms"
    [ "$sz1" -gt 0 ] && [ "$sz1" = "$sz2" ] || { echo "❌ 两次下载的对象大小不一致（${sz1} vs ${sz2}）"; return 1; }
    echo "✅ 两次独立 clone 的 LFS 对象下载均成功且大小一致（${sz1}B）"
    if [ "${obj_via_cache:-0}" != 1 ]; then
        echo "⚠️ 对象未经缓存后端，耗时差（${t1}ms → ${t2}ms）只反映上游/网络，不作为缓存命中证据"
    elif [ "$t1" -gt 0 ] && [ "$t2" -le $((t1 * 70 / 100)) ]; then
        echo "✅ 第 2 次 LFS pull 耗时下降 $((100 - t2 * 100 / t1))% → LFS 对象命中缓存"
    else
        echo "⚠️ 第 2 次 LFS pull 未见明显耗时下降（${t1}ms → ${t2}ms），仅留档"
    fi
    return 0
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
    run_timed cache-hitmiss  "$LAYER" cache-hitmiss
    run_timed integrity      "$LAYER" integrity
    run_timed failure-face   "$LAYER" failure-face
elif [ "$MODE" = "concurrency" ]; then
    run_timed env-snapshot     "$LAYER" env-snapshot
    run_timed conc-same-object "$LAYER" conc-same-object
    run_timed conc-distinct    "$LAYER" conc-distinct
    run_timed conc-mixed       "$LAYER" conc-mixed
elif [ "$MODE" = "vllm" ]; then
    run_timed env-snapshot       "$LAYER" env-snapshot
    run_timed meta-trace         "$LAYER" meta-trace
    run_timed vllm-model-pull    "$LAYER" vllm-model-pull
    run_timed vllm-api-stream    "$LAYER" vllm-api-stream
elif [ "$MODE" = "parity" ]; then
    run_timed env-snapshot   "$LAYER" env-snapshot
    run_timed meta-trace     "$LAYER" meta-trace
    run_timed rewrite-parity "$LAYER" rewrite-parity
elif [ "$MODE" = "upstream" ]; then
    # R17：上游通道健康（runner 层 only——gh-proxy 是 runner 环境关心的事；
    # Actions 构件通道已入 NO_PROXY 直连，不测不过 squid 的流量）
    run_timed env-snapshot      "$LAYER" env-snapshot
    run_timed meta-trace        "$LAYER" meta-trace
    run_timed ghproxy-health    "$LAYER" ghproxy-health
    run_timed slow-upstream     "$LAYER" slow-upstream
elif [ "$MODE" = "imagebuild" ]; then
    # 镜像构建外网流量面复刻（runner/容器两层；vllm-ascend Image Build and Push 的
    # gitcode.com + GIT_PROXY github 通道——cache-service 集群内直连不测）
    run_timed env-snapshot      "$LAYER" env-snapshot
    run_timed meta-trace        "$LAYER" meta-trace
    run_timed ib-catlass        "$LAYER" ib-catlass
    run_timed ib-tarballs       "$LAYER" ib-tarballs
    run_timed ib-vllm-gitproxy  "$LAYER" ib-vllm-gitproxy
    run_timed ib-ascend-obs     "$LAYER" ib-ascend-obs
elif [ "$MODE" = "cabundle" ]; then
    # no_proxy 直连 × CA 注入变量组矩阵（runner/容器两层）：
    # CA 形态取证 + no_proxy 生效性 + 排他/union/追加三语义工具的直连/MITM 双路径
    run_timed env-snapshot      "$LAYER" env-snapshot
    run_timed meta-trace        "$LAYER" meta-trace
    run_timed cabundle-matrix   "$LAYER" bash "$SCRIPT_DIR/no-proxy-ca-test.sh"
elif [ "$MODE" = "tools" ]; then
    # pip --user 装的 CLI（uv/modelscope 等）落 ~/.local/bin，极简镜像 PATH 默认不含
    export PATH="$HOME/.local/bin:$PATH"
    run_timed env-snapshot      "$LAYER" env-snapshot
    run_timed meta-trace        "$LAYER" meta-trace
    run_timed tool-pip          "$LAYER" tool-pip
    run_timed tool-apt          "$LAYER" tool-apt
    run_timed tool-npm          "$LAYER" tool-npm
    run_timed tool-pnpm         "$LAYER" tool-pnpm
    run_timed tool-uv           "$LAYER" tool-uv
    run_timed tool-torch        "$LAYER" tool-torch
    run_timed tool-goproxy      "$LAYER" tool-goproxy
    run_timed tool-wget         "$LAYER" tool-wget
    run_timed tool-gitlfs       "$LAYER" tool-gitlfs
    run_timed tool-modelscope   "$LAYER" tool-modelscope
    run_timed tool-hf           "$LAYER" tool-hf
    run_timed tool-git          "$LAYER" tool-git
    if [ "${HEAVY:-0}" = "1" ]; then
        run_timed tool-rustup    "$LAYER" tool-rustup
        run_timed tool-conda     "$LAYER" tool-conda
        run_timed tool-cmake     "$LAYER" tool-cmake
        run_timed tool-bazel     "$LAYER" tool-bazel
        run_timed tool-precommit "$LAYER" tool-precommit
    fi
elif [ "$MODE" = "pkg" ]; then
    # dnf/yum 包管理链路（openEuler 24.03 容器层；RHEL 系 CA 信任路径：
    # 注入脚本走 /etc/pki/ca-trust/source/anchors + update-ca-trust）
    run_timed env-snapshot      "$LAYER" env-snapshot
    run_timed meta-trace        "$LAYER" meta-trace
    [ "$LAYER" = "container" ] && run_timed ca-trust "$LAYER" ca-trust
    run_timed pkg-dnf           "$LAYER" pkg-dnf
    run_timed pkg-yum           "$LAYER" pkg-yum
elif [ "$MODE" = "gitcode" ]; then
    # R21：gitcode.com → smart git proxy 的 insteadOf 重写 + 缓存命中验证
    # （流量走 .svc.cluster.local 直连，不经过 squid，故不跑 meta-trace）
    run_timed env-snapshot          "$LAYER" env-snapshot
    run_timed gitcode-config        "$LAYER" gitcode-config
    run_timed gitcode-refs-probe    "$LAYER" gitcode-refs-probe
    run_timed gitcode-clone-hitmiss "$LAYER" gitcode-clone-hitmiss
    run_timed gitcode-lfs           "$LAYER" gitcode-lfs
elif [ "$MODE" = "stale-index" ]; then
    # R15 回归守卫（2026-10-29 取证）：源站索引页带 Cache-Control: max-age=1296000
    # （15 天），squid 兜底 refresh_pattern 无 override-expire → 镜像重新生成索引
    # 后仍长期供旧页，pip 报 No matching distribution（18:32:58 事故形态）。
    # 阶段：mock 机制证据（不判红）+ 真实域索引页是否被缓存（主判定）
    # + 真实索引页 squid×源站直连清单对照（test-squid/repro-stale-index.sh；runner 层 only）
    run_timed env-snapshot            "$LAYER" env-snapshot
    run_timed meta-trace              "$LAYER" meta-trace
    run_timed stale-index-mechanism   "$LAYER" env RESULTS="$RESULTS_DIR/stale-index" bash "$SCRIPT_DIR/repro-stale-index.sh" mock
    run_timed stale-index-cacheability "$LAYER" env RESULTS="$RESULTS_DIR/stale-index" bash "$SCRIPT_DIR/repro-stale-index.sh" cacheability
    run_timed stale-index-origin-parity "$LAYER" env RESULTS="$RESULTS_DIR/stale-index" bash "$SCRIPT_DIR/repro-stale-index.sh" parity
elif [ "$MODE" = "pip-metadata" ]; then
    # R22 回归守卫（2026-10-31 取证）：CDN 按 Accept-Encoding 压缩但不发 Vary，
    # squid 存储副本无 Vary 键 → 首个请求者编码定型共享（reply_header_replace 只改
    # 客户端响应头，不影响存储副本与缓存键）；pip metadata 只收 identity 且不解码，
    # 拿到 gzip 变体后 sha256 必挂。修复为 cache deny (whl|tar.gz|zip).metadata。
    # 阶段：mock 机制+判定（deny 生效 / identity 不被毒化 / .whl 仍可 HIT）
    # + 真实域 metadata 不缓存与内容完整 + 真实 pip 解析（runner 层 only）
    run_timed env-snapshot        "$LAYER" env-snapshot
    run_timed meta-trace          "$LAYER" meta-trace
    run_timed pip-metadata-mock   "$LAYER" env RESULTS="$RESULTS_DIR/pip-metadata" bash "$SCRIPT_DIR/repro-pip-metadata.sh" mock
    run_timed pip-metadata-real   "$LAYER" env RESULTS="$RESULTS_DIR/pip-metadata" bash "$SCRIPT_DIR/repro-pip-metadata.sh" real
    run_timed pip-metadata-client "$LAYER" env RESULTS="$RESULTS_DIR/pip-metadata" bash "$SCRIPT_DIR/repro-pip-metadata.sh" pip
else
    echo "未知 mode: $MODE（可选 function | concurrency | vllm | parity | upstream | imagebuild | cabundle | tools | pkg | gitcode | stale-index | pip-metadata）" >&2
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
