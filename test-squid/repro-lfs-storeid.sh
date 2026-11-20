#!/usr/bin/env bash
# =============================================================================
# repro-lfs-storeid.sh —— GitCode LFS / Release CDN 的 store_id 去 query 作缓存键
#                          （ascend-ci-deployment PR #2272 / issue #2260 回归守卫）
#
# 被测配置（chart ≥ 0.1.32，squid.storeId.enabled=true）：
#   acl lfsdom dstdomain .lfs-cdn.gitcode.com .file-cdn.gitcode.com
#   store_id_program /bin/sh /etc/squid/store-id-helper.sh
#   store_id_access allow lfsdom / deny all
#   refresh_pattern -i lfs-cdn\.gitcode\.com/lfs-objects/ 10080 100% 525600 \
#                   ignore-reload override-expire override-lastmod
#
# 为什么要测：这两个 CDN 的下载 URL 路径稳定，但 query 里的 auth_key 每次都变
# （LFS 每次 batch 换一个，Release 资产每次 302 换一个）；默认缓存键是完整 URL
# → 永远 MISS，500MiB 对象每次都要重下。store_id 只把 query 从「缓存键」里去掉，
# 回源请求仍带原 auth_key（鉴权不变）。
#
# 两个域各测一遍（同一条判定链）：
#   A. lfs-cdn.gitcode.com  —— 两次 POST batch（同 oid）拿同路径、不同 auth_key
#   B. file-cdn.gitcode.com —— 同一 release 资产两次 302，拿同路径、不同 auth_key
#
# 每个域的判定：
#   ① 两发都 200，响应体 sha256 一致（LFS 还要求 == pointer 的 oid）→ 鉴权/内容没坏
#   ②【决定性】第二发（从未请求过的签名）响应带缓存命中标记（Cache-Status:
#     ...;hit / X-Cache-Lookup: HIT）→ 跨签名复用同一个缓存对象；出现 fwd=miss 即红
#   ③ 两发响应至少一发有 squid 痕迹 → 证明流量确实过代理，否则用例无效
#   说明：squid 7.x 把 TCP_REFRESH_UNMODIFIED（304 再验证）也标成 hit，客户端只看
#   响应头无法硬区分「真 TCP_HIT」与「304」；override-lastmod 的收益（省掉回源
#   RTT）需 squid access.log 的 TCP_HIT/HIER_NONE 佐证，本用例只留档 Age/耗时。
#
# 另加一致性判定（同名/同路径换内容会不会被旧副本污染）：
#   LFS 路径必须是内容地址（含 oid）→ 同名必然同字节；
#   file-cdn 同名资产在不同 release 下必须落在不同路径（untagger_<uuid>）；
#   再用伪造 auth_key 打已缓存路径，记录 HIT 是否会跳过签名校验。
# 有 gitcode token（repository secret CQ_GITCODE_TOKEN）时再做「同名替换」实证：
#   建临时仓库 → 建临时 release → 上传 probe.bin（内容 A）→ 经 squid 预热并确认
#   HIT → 删附件后同名重传（内容 B）→ 再取 302：
#     · 路径变了（新 untagger_<uuid>）→ 换内容必换缓存键，安全；
#     · 路径没变 → 经 squid 取 vs 直连取对照：squid 供 A、直连是 B 即实证污染
#       （refresh_pattern min=10080 分钟，最长 7 天不回源）；
#     · 无论结论如何，结束时删 release（自建仓库一并删）。
# 另加负样本：非 CDN 域（默认 pypi.org 索引页）同 URL 二发应 HIT、换 query 必须
# MISS，证明 store_id_access 的域限定没被放大。
#
# 前提不成立一律记 SKIP（退出码 2，workflow 不判红）：无代理 / CDN 域在 NO_PROXY /
# 仓库无 LFS / batch 需鉴权 / 最小对象超上限 / 资产 URL 失效。
#
# 用法：
#   bash test-squid/repro-lfs-storeid.sh
#
# 可覆盖：
#   LFS_STOREID_REPO       LFS 仓库（默认 https://gitcode.com/ccijunk/lfs-test.git）
#   LFS_STOREID_MAX_MB     参与测试的最大 LFS 对象体积（默认 96；该仓有 64MiB / 500MiB）
#   LFS_STOREID_OID        直接指定 oid（跳过浅克隆发现，需同时给 SIZE）
#   LFS_STOREID_SIZE       直接指定 size（字节）
#   LFS_STOREID_ASSET_URL  Release 资产页 URL（默认 gitcode-oauth 的 install.sh，
#                          两次访问 302 到 file-cdn 且签名不同）
#   LFS_STOREID_ASSET_URL_ALT 同名资产的另一个 release（默认 v0.0.2，用于证明
#                          「换内容必换路径」）
#   LFS_STOREID_NEG_URL    负样本 URL（空=用 pypi.org/simple/six/）
#   LFS_STOREID_GITCODE_TOKEN  gitcode token（有写权限才跑同名替换实验；空=跳过）
#   LFS_STOREID_CONSISTENCY_REPO  替换实验用仓库（空=token 用户名下 squid-storeid-consistency，自动创建）
#   LFS_STOREID_API_BASE   GitCode API 基址（默认 https://api.gitcode.com/api/v5）
#   LFS_STOREID_GET_TIMEOUT 单次下载超时秒数（默认 900）
#   RESULTS_DIR            结果目录（默认 /tmp/test-squid-results）
#
# 输出：timings.tsv（phase/seconds/status/group）、probes.tsv、lfs-storeid.tsv
# 退出码：0=PASS；1=FAIL；2=SKIP（前提不成立）
# =============================================================================
set -uo pipefail

REPO="${LFS_STOREID_REPO:-https://gitcode.com/ccijunk/lfs-test.git}"
MAX_MB="${LFS_STOREID_MAX_MB:-96}"
OID="${LFS_STOREID_OID:-}"
SIZE="${LFS_STOREID_SIZE:-}"
ASSET_URL="${LFS_STOREID_ASSET_URL:-https://gitcode.com/zhoucungen/gitcode-oauth/releases/download/v0.0.1/install.sh}"
ASSET_ALT="${LFS_STOREID_ASSET_URL_ALT:-https://gitcode.com/zhoucungen/gitcode-oauth/releases/download/v0.0.2/install.sh}"
NEG_URL="${LFS_STOREID_NEG_URL:-https://pypi.org/simple/six/}"
GC_TOKEN="${LFS_STOREID_GITCODE_TOKEN:-}"
GC_API="${LFS_STOREID_API_BASE:-https://api.gitcode.com/api/v5}"
CONS_REPO="${LFS_STOREID_CONSISTENCY_REPO:-}"
GET_TIMEOUT="${LFS_STOREID_GET_TIMEOUT:-900}"
results="${RESULTS_DIR:-/tmp/test-squid-results}"
RUN_ID="${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}"

mkdir -p "$results"
TSV="$results/timings.tsv"
PROBES="$results/probes.tsv"
DETAIL="$results/lfs-storeid.tsv"
[ -f "$TSV" ] || printf 'phase\tseconds\tstatus\tgroup\n' > "$TSV"
[ -f "$PROBES" ] || printf 'url\thttp_code\tseconds\n' > "$PROBES"
printf 'case\tside\turl\thttp\tcache_status\tage\tbytes\tsha256_prefix\tseconds\tnote\n' > "$DETAIL"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

step() { printf '%s\t%s\t%s\t%s\n' "$1" "$3" "$2" "${4:-lfs-storeid}" >> "$TSV"; }

hdr_val() {
    awk -v h="$1" 'tolower($1)==h":"{sub(/^[^:]*:[ \t]*/,""); sub(/\r$/,""); print; exit}' "$2" 2>/dev/null
}

squid_trace() {
    grep -qiE '^(cache-status|x-cache-lookup):.*(squid|hit|fwd=)' "$1" 2>/dev/null
}

host_in_noproxy() {
    local host=$1 list item
    list=$(printf '%s' "${NO_PROXY:-${no_proxy:-}}" | tr ' ' ',')
    local IFS=','
    for item in $list; do
        item=$(printf '%s' "$item" | sed 's/^[.]*//' | tr -d ' ')
        [ -z "$item" ] && continue
        [ "$item" = "*" ] && return 0
        case "$host" in "$item"|*".$item") return 0 ;; esac
    done
    return 1
}

url_host() { local h="${1#*://}"; printf '%s' "${h%%/*}"; }
url_path() { local p="${1#*://}"; p="${p#*/}"; printf '/%s' "${p%%\?*}"; }
strip_q()  { printf '%s' "${1%%\?*}"; }

curl_one() {  # <url> <out-prefix> —— 输出 "code bytes time_total"
    curl -sS --max-time "$GET_TIMEOUT" -o "$2.bin" -D "$2.hdr" \
        -w '%{http_code} %{size_download} %{time_total}' "$1" 2>"$2.err"
}

# 抓一次重定向的 Location（不跟随）
resolve_location() {
    curl -sS --max-time 60 -o /dev/null -D - "$1" 2>/dev/null \
        | awk 'tolower($1)=="location:"{sub(/^[^:]*:[ \t]*/,""); sub(/\r$/,""); print; exit}'
}

# ---- GitCode API v5（Gitee 兼容）：凭据形态先探测（token 头 / Bearer 头 / access_token 参数）
# GC_MODE 由 phase_replace 探测后写入；query 形态会把 token 拼进 URL，故 curl 的
# stderr 一律重定向到文件、不回显（日志里只有 HTTP 码与错误码，不含凭据）。
gc_call() {  # <method> <api-path> [json-body] —— 响应体写 $results/gc.json，回显 HTTP 码
    local m=$1 p=$2 body=${3:-} url="$GC_API$p" auth=()
    case "$GC_MODE" in
        token)  auth=(-H "Authorization: token $GC_TOKEN") ;;
        bearer) auth=(-H "Authorization: Bearer $GC_TOKEN") ;;
        query)  case "$url" in *\?*) url="$url&access_token=$GC_TOKEN" ;; *) url="$url?access_token=$GC_TOKEN" ;; esac ;;
    esac
    if [ -n "$body" ]; then
        curl -sS -m 60 -X "$m" "${auth[@]}" -H 'Content-Type: application/json' -d "$body" \
            -o "$results/gc.json" -w '%{http_code}' "$url" 2>"$results/gc.err"
    else
        curl -sS -m 60 -X "$m" "${auth[@]}" \
            -o "$results/gc.json" -w '%{http_code}' "$url" 2>"$results/gc.err"
    fi
}

gc_upload() {  # <api-path> <file> —— multipart 上传，回显 HTTP 码
    local p=$1 url="$GC_API$1" auth=()
    case "$GC_MODE" in
        token)  auth=(-H "Authorization: token $GC_TOKEN") ;;
        bearer) auth=(-H "Authorization: Bearer $GC_TOKEN") ;;
        query)  case "$url" in *\?*) url="$url&access_token=$GC_TOKEN" ;; *) url="$url?access_token=$GC_TOKEN" ;; esac ;;
    esac
    curl -sS -m 180 -X POST "${auth[@]}" -F "file=@$2" \
        -o "$results/gc.json" -w '%{http_code}' "$url" 2>"$results/gc.err"
}

gc_field() {  # <json keys...> —— 从 $results/gc.json 取嵌套字段
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2:]:
    d = d.get(k) if isinstance(d, dict) else None
    if d is None:
        break
print("" if d is None else d)
' "$results/gc.json" "$@" 2>/dev/null
}

# -----------------------------------------------------------------------------
# 同名替换实验：同一个 release 里把同名附件换成新内容，看缓存键/缓存副本是否跟着变
#   ① 建临时仓库（或复用 LFS_STOREID_CONSISTENCY_REPO）+ 临时 release
#   ② 上传 probe.bin（内容 A）→ 经 squid 两发预热（第二发应 HIT）
#   ③ 删附件后同名重传（内容 B）→ 再取 302，比较路径；路径没变则代理/直连对照
# 返回 0=PASS（换内容必换键，或缓存未供旧副本）/ 1=FAIL（实证供旧副本）/ 2=SKIP
# -----------------------------------------------------------------------------
phase_replace() {
    local code login slug rname created_repo=0 tag rid page shaA shaB aidA aidB mode
    local locA locA2 locB warm_rc cb bb tb sb pc sp delc dc sd
    GC_TOKEN=$(printf '%s' "$GC_TOKEN" | tr -d ' \t\r\n')
    if [ -z "$GC_TOKEN" ]; then
        echo "⚠️ 无 LFS_STOREID_GITCODE_TOKEN（repository secret CQ_GITCODE_TOKEN）——跳过同名替换实验"
        return 2
    fi
    # GitCode 的凭据形态与 Gitee 不完全一致：三种都试，取第一个能拿到用户信息的
    for mode in token bearer query; do
        GC_MODE=$mode
        code=$(gc_call GET /user); login=$(gc_field login)
        [ "$code" = "200" ] && [ -n "$login" ] && break
        login=""
    done
    if [ -z "$login" ]; then
        echo "⚠️ token 不被 GitCode 接受（token/Bearer/access_token 三形态均失败，最后 HTTP $code）：$(head -c 160 "$results/gc.json" | tr -d '\n')"
        return 2
    fi
    echo "ℹ️ 凭据形态 $GC_MODE 可用（用户 $login）"
    if [ -n "$CONS_REPO" ]; then
        slug="${CONS_REPO#*gitcode.com/}"; slug="${slug%.git}"; slug="${slug#/}"
    else
        slug="$login/squid-storeid-consistency"
    fi
    rname="${slug##*/}"
    code=$(gc_call GET "/repos/$slug")
    if [ "$code" = "404" ]; then
        code=$(gc_call POST /user/repos "$(printf '{"name":"%s","private":false,"auto_init":true,"description":"store_id consistency probe (auto-created by squid-gha test)"}' "$rname")")
        [ "$code" = "201" ] && created_repo=1
        echo "临时仓库 $slug：创建 HTTP $code"
    fi
    if [ "$code" != "200" ] && [ "$code" != "201" ]; then
        echo "⚠️ 无法访问/创建 $slug（HTTP $code）：$(head -c 160 "$results/gc.json" | tr -d '\n')"
        echo "   token 需对目标仓库有写权限（或允许在用户名下建仓），记 SKIP"
        return 2
    fi
    tag="storeid-probe-$RUN_ID"
    code=$(gc_call POST "/repos/$slug/releases" "$(printf '{"tag_name":"%s","name":"%s","body":"store_id 一致性探针（自动创建，结束即删）"}' "$tag" "$tag")")
    rid=$(gc_field id)
    if [ -z "$rid" ]; then
        echo "⚠️ 建 release 失败（HTTP $code）：$(head -c 200 "$results/gc.json" | tr -d '\n')——记 SKIP"
        return 2
    fi
    page="https://gitcode.com/$slug/releases/download/$tag/probe.bin"
    mkdir -p "$results/repA" "$results/repB"
    { printf 'A %s\n' "$RUN_ID"; head -c 2048 /dev/urandom | base64; } > "$results/repA/probe.bin"
    { printf 'B %s\n' "$RUN_ID"; head -c 2048 /dev/urandom | base64; } > "$results/repB/probe.bin"
    shaA=$(sha256sum "$results/repA/probe.bin" | cut -d' ' -f1)
    shaB=$(sha256sum "$results/repB/probe.bin" | cut -d' ' -f1)

    code=$(gc_upload "/repos/$slug/releases/$rid/attach_files" "$results/repA/probe.bin")
    aidA=$(gc_field id)
    locA=$(resolve_location "$page")
    echo "上传 A：HTTP $code 附件id=${aidA:-无} 302=${locA:0:120}"
    if [ -z "$aidA" ] || [ -z "$locA" ]; then
        echo "⚠️ 附件上传或 302 解析失败——同名替换实验记 SKIP"
        gc_call DELETE "/repos/$slug/releases/$rid" >/dev/null
        [ "$created_repo" = 1 ] && gc_call DELETE "/repos/$slug" >/dev/null
        return 2
    fi

    # ② 预热「旧路径」：确认这一版内容确实进了 squid 缓存
    locA2=$(resolve_location "$page")
    fetch_pair replwarm "$locA" "${locA2:-$locA}" "$shaA"; warm_rc=$?
    [ "$warm_rc" = 0 ] || echo "⚠️ 预热未拿到 HIT（rc=$warm_rc），旧副本存在性无法确认，后续污染判定降级为对照"

    # ③ 同名替换：删旧附件 → 同名重传新内容 → 重新解析 302
    code=$(gc_call DELETE "/repos/$slug/releases/$rid/attach_files/$aidA"); delc=$code
    code=$(gc_upload "/repos/$slug/releases/$rid/attach_files" "$results/repB/probe.bin")
    aidB=$(gc_field id)
    echo "替换：删 A HTTP $delc；同名重传 B HTTP $code 附件id=${aidB:-无}"
    locB=$(resolve_location "$page")
    if [ -z "$locB" ]; then
        echo "⚠️ 替换后取不到 302——记 SKIP"
        gc_call DELETE "/repos/$slug/releases/$rid" >/dev/null
        [ "$created_repo" = 1 ] && gc_call DELETE "/repos/$slug" >/dev/null
        return 2
    fi

    local rc=2
    if [ "$(strip_q "$locB")" != "$(strip_q "$locA")" ]; then
        echo "✅ 换内容后 302 路径变了（$(strip_q "$locA" | sed 's#.*/releases/##') → $(strip_q "$locB" | sed 's#.*/releases/##')）"
        echo "   → untagger uuid 随上传变化，缓存键跟着变，同名替换不会命中旧副本"
        read -r cb bb tb < <(curl_one "$locB" "$results/replB")
        sb=$(sha256sum "$results/replB.bin" 2>/dev/null | cut -d' ' -f1)
        printf 'replace\tnew-path\t%s\t%s\t%s\t-\t%s\t%s\t%s\t%s\n' "${locB:0:150}" "$cb" \
            "$(hdr_val cache-status "$results/replB.hdr")" "${bb:-}" "${sb:0:12}" "${tb:-}" \
            "换内容必换路径" >> "$DETAIL"
        if [ "$cb" = "200" ] && [ "$sb" = "$shaB" ]; then
            echo "✅ 新路径经 squid 拿到新内容（sha=${sb:0:12}）"
            rc=0
        else
            echo "❌ 新路径经 squid 未拿到新内容（http=$cb 期望 ${shaB:0:12} 实际 ${sb:0:12}）"
            rc=1
        fi
    else
        echo "⚠️ 换内容后 302 路径完全相同（同 untagger uuid）——直接实测 squid 会不会供旧副本"
        pc=$(curl -sS -m 300 -o "$results/replB-proxy.bin" -D "$results/replB-proxy.hdr" \
            -w '%{http_code}' "$locB" 2>/dev/null)
        sp=$(sha256sum "$results/replB-proxy.bin" 2>/dev/null | cut -d' ' -f1)
        dst=$(hdr_val cache-status "$results/replB-proxy.hdr")
        dc=$(curl -sS --noproxy '*' -m 300 -o "$results/replB-direct.bin" -w '%{http_code}' "$locB" 2>/dev/null)
        sd=$(sha256sum "$results/replB-direct.bin" 2>/dev/null | cut -d' ' -f1)
        printf 'replace\tsame-path\t%s\t%s/%s\t%s\t-\t-\t%s/%s\t-\tA=%s B=%s\n' "${locB:0:150}" \
            "$pc" "$dc" "${dst:-}" "${sp:0:12}" "${sd:0:12}" "${shaA:0:12}" "${shaB:0:12}" >> "$DETAIL"
        echo "   经代理: http=$pc sha=${sp:0:12} ${dst:-<无缓存头>}"
        echo "   直连对照: http=$dc sha=${sd:0:12}"
        if [ "$sd" != "$shaB" ]; then
            echo "⚠️ 直连也没拿到新内容——上传/预签名未生效，判定记 SKIP"
        elif [ "$sp" = "$shaA" ]; then
            echo "❌ 同名换内容后 squid 仍供旧副本（代理 ${sp:0:12}=旧A，直连 ${sd:0:12}=新B）"
            echo "   → store_id 去 query + refresh_pattern min=10080 分钟导致长期供旧，一致性缺陷"
            rc=1
        elif [ "$sp" = "$shaB" ]; then
            echo "✅ 同路径但 squid 拿到的是新内容（${sp:0:12}），未出现旧副本"
            rc=0
        else
            echo "⚠️ 两次内容都不符合预期（proxy=$sp direct=$sd B=$shaB）——记 SKIP"
        fi
    fi
    # 清理：删 release（连带附件），自建仓库一并删
    code=$(gc_call DELETE "/repos/$slug/releases/$rid"); echo "清理：删 release HTTP $code"
    if [ "$created_repo" = 1 ]; then
        code=$(gc_call DELETE "/repos/$slug"); echo "清理：删临时仓库 $slug HTTP $code"
    fi
    return "$rc"
}

# -----------------------------------------------------------------------------
# 对一对「同路径、不同签名」的 URL 做完整判定
#   fetch_pair <case-label> <url1> <url2> [expect-sha256]
# 返回 0=PASS / 1=FAIL / 2=SKIP
# -----------------------------------------------------------------------------
fetch_pair() {
    local label=$1 u1=$2 u2=$3 expect=${4:-}
    local pre="$results/$label" c1 b1 t1 c2 b2 t2 s1 s2 st1 st2 xc2 ag2
    read -r c1 b1 t1 < <(curl_one "$u1" "${pre}-1")
    read -r c2 b2 t2 < <(curl_one "$u2" "${pre}-2")
    s1=$(sha256sum "${pre}-1.bin" 2>/dev/null | cut -d' ' -f1)
    s2=$(sha256sum "${pre}-2.bin" 2>/dev/null | cut -d' ' -f1)
    st1=$(hdr_val cache-status "${pre}-1.hdr")
    st2=$(hdr_val cache-status "${pre}-2.hdr")
    ag2=$(hdr_val age "${pre}-2.hdr")

    local i u c st ag b s t side
    for i in 1 2; do
        if [ "$i" = 1 ]; then
            u=$u1; c=$c1; st=$st1; ag=""; b=$b1; s=$s1; t=$t1; side="get1"
        else
            u=$u2; c=$c2; st=$st2; ag=${ag2:-}; b=$b2; s=$s2; t=$t2; side="get2"
            [ "$u1" = "$u2" ] && side="get2(同URL)"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t\n' "$label" "$side" "${u:0:150}" "$c" \
            "${st:-}" "${ag:-}" "${b:-}" "${s:0:12}" "${t:-}" >> "$DETAIL"
        printf '%s\t%s\t%s\n' "${u:0:160}" "$c" "${t:-}" >> "$PROBES"
    done
    echo "[$label] 第1发: http=$c1 ${b1}B ${t1}s sha=${s1:0:12} ${st1:-<无缓存头>}"
    echo "[$label] 第2发: http=$c2 ${b2}B ${t2}s sha=${s2:0:12} ${st2:-<无缓存头>}${ag2:+ Age=$ag2}"

    if [ "$c1" != "200" ] || [ "$c2" != "200" ]; then
        echo "[$label] ❌ 未拿到 200（第1发=$c1 第2发=$c2）"
        tail -n 3 "${pre}-1.err" "${pre}-2.err" 2>/dev/null | sed 's/^/    | /'
        return 1
    fi
    if [ -z "$s1" ] || [ "$s1" != "$s2" ]; then
        echo "[$label] ❌ 两发内容不一致（$s1 vs $s2）"
        return 1
    fi
    if [ -n "$expect" ] && [ "$s1" != "$expect" ]; then
        echo "[$label] ❌ 内容 sha256 与期望不符（期望 $expect，实际 $s1）"
        return 1
    fi
    if ! squid_trace "${pre}-1.hdr" && ! squid_trace "${pre}-2.hdr"; then
        echo "[$label] ❌ 两发都没有 squid 痕迹——流量没经过代理，用例无效"
        return 1
    fi
    if grep -qiE '^cache-control:.*(no-store|private)' "${pre}-1.hdr"; then
        echo "[$label] ⚠️ 响应带 no-store/private，源站不允许缓存，本域判据不成立"
        return 2
    fi
    if echo "$st2 $(hdr_val x-cache-lookup "${pre}-2.hdr")" | grep -qiE 'hit'; then
        if echo "$st1" | grep -qiE 'hit'; then
            echo "[$label] ✅ 第2发命中缓存（第1发已是命中：该对象此前被预热，仍证明新签名复用了既有缓存对象）"
        else
            echo "[$label] ✅ 第2发命中缓存（第1发 MISS）→ 不同 auth_key 复用同一缓存对象，store_id 生效"
        fi
        return 0
    fi
    echo "[$label] ❌ 第2发未命中缓存（Cache-Status=${st2:-无}）——不同 auth_key 仍各拉一份，store_id 未生效"
    return 1
}

# --- ① 环境前置 -------------------------------------------------------------
t0=$(date +%s)
proxy="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
repo_host=$(url_host "$REPO")
echo "LFS 仓库: $REPO"
echo "Release 资产页: $ASSET_URL"
echo "代理: ${proxy:-<空>}"
echo "NO_PROXY: ${NO_PROXY:-${no_proxy:-<空>}}"
if [ -z "$proxy" ]; then
    echo "⚠️ 无代理环境变量——runner 未注入 squid，本用例前提不成立"
    step env SKIP 0; exit 2
fi
if host_in_noproxy "$repo_host"; then
    echo "ℹ️ 仓库域在 NO_PROXY（batch/302 直连），被测的是 CDN 域的对象下载，稍后单独判定"
fi
step env 0 0

# --- ② 发现一个体积可控的 LFS 对象 -----------------------------------------
t0=$(date +%s)
if [ -z "$OID" ] || [ -z "$SIZE" ]; then
    wd="$results/lfs-storeid-work"
    rm -rf "$wd"
    if ! GIT_LFS_SKIP_SMUDGE=1 GIT_TERMINAL_PROMPT=0 timeout 300 \
         git -c filter.lfs.smudge= -c filter.lfs.required=false \
             clone --depth 1 --single-branch -q "$REPO" "$wd" 2>"$results/lfs-storeid-clone.log"; then
        echo "⚠️ 浅克隆失败（仓库不可达或需鉴权），无法发现 LFS 对象"
        tail -n 5 "$results/lfs-storeid-clone.log" | sed 's/^/    | /'
        step discover SKIP $(( $(date +%s) - t0 )); exit 2
    fi
    found=""
    while IFS= read -r f; do
        p="$wd/$f"
        head -c 200 "$p" 2>/dev/null | grep -q '^version https://git-lfs' || continue
        o=$(sed -n 's/^oid sha256://p' "$p" | head -1)
        s=$(sed -n 's/^size //p' "$p" | head -1)
        [ -n "$o" ] && [ -n "$s" ] && found="${found}${s}\t${o}\t${f}\n"
    done < <(git -C "$wd" ls-files)
    pick=$(printf "$found" | sort -n | head -1)
    OID=$(printf '%s' "$pick" | cut -f2)
    SIZE=$(printf '%s' "$pick" | cut -f1)
    echo "选定对象: $(printf '%s' "$pick" | cut -f3)  oid=$OID  size=${SIZE}B"
    rm -rf "$wd"
    if [ -z "$OID" ] || [ -z "$SIZE" ]; then
        echo "⚠️ $REPO 的 HEAD 没有 LFS 对象，用例不适用"
        step discover SKIP $(( $(date +%s) - t0 )); exit 2
    fi
fi
if [ "$SIZE" -gt $(( MAX_MB * 1024 * 1024 )) ]; then
    echo "⚠️ 最小对象 ${SIZE}B 超过上限 ${MAX_MB}MiB——换 LFS_STOREID_REPO 或调大 LFS_STOREID_MAX_MB"
    step discover SKIP $(( $(date +%s) - t0 )); exit 2
fi
step discover 0 $(( $(date +%s) - t0 ))

# --- ③ LFS：两次 batch → 同路径、不同 auth_key -----------------------------
t0=$(date +%s)
batch_url="${REPO%/}/info/lfs/objects/batch"
body=$(printf '{"operation":"download","transfers":["basic"],"objects":[{"oid":"%s","size":%s}]}' "$OID" "$SIZE")
get_href() {
    python3 - "$1" <<'PY' 2>/dev/null || grep -o '"href":"[^"]*"' "$1" | head -1 | cut -d'"' -f4
import json,sys
d=json.load(open(sys.argv[1]))
o=d["objects"][0]
print((o.get("actions") or {}).get("download",{}).get("href",""))
PY
}
href1=""; href2=""
for i in 1 2; do
    code=$(curl -sS --max-time 60 -o "$results/batch-$i.json" -w '%{http_code}' \
        -X POST "$batch_url" \
        -H 'Accept: application/vnd.git-lfs+json' \
        -H 'Content-Type: application/vnd.git-lfs+json' \
        -d "$body" 2>"$results/batch-$i.err")
    echo "batch#$i: http=$code $(head -c 160 "$results/batch-$i.json" | tr -d '\n')"
    [ "$code" = "200" ] || { echo "⚠️ batch 接口不可匿名访问（http=$code），LFS 域用例前提不成立"
        step discover-batch SKIP $(( $(date +%s) - t0 )); href1=""; break; }
    if [ "$i" = 1 ]; then href1=$(get_href "$results/batch-$i.json"); else href2=$(get_href "$results/batch-$i.json"); fi
    sleep 2   # auth_key 含秒级时间戳，拉开两批确保签名不同
done
lfs_rc=2
if [ -n "$href1" ] && [ -n "$href2" ]; then
    echo "LFS URL#1: $href1"
    echo "LFS URL#2: $href2"
    lfs_host=$(url_host "$href1")
    if [ "$(strip_q "$href1")" != "$(strip_q "$href2")" ]; then
        echo "❌ 两批 LFS URL 路径不同，store_id 前提不成立"
        step lfs-batch 1 $(( $(date +%s) - t0 )); exit 1
    elif [ "$href1" = "$href2" ]; then
        echo "⚠️ 两批 auth_key 相同（签名未轮换），无法证明跨签名复用"
        step lfs-batch SKIP $(( $(date +%s) - t0 )); lfs_rc=2
    elif host_in_noproxy "$lfs_host"; then
        echo "⚠️ $lfs_host 在 NO_PROXY 内——LFS 对象下载直连，store_id 无从验证"
        step lfs-batch SKIP $(( $(date +%s) - t0 )); lfs_rc=2
    else
        echo "✅ LFS 同路径、不同签名（CDN 域 ${lfs_host}）"
        step lfs-batch 0 $(( $(date +%s) - t0 ))
        t0=$(date +%s)
        fetch_pair lfs "$href1" "$href2" "$OID"; lfs_rc=$?
        step lfs-reuse "$([ $lfs_rc = 2 ] && echo SKIP || echo $lfs_rc)" $(( $(date +%s) - t0 ))
    fi
fi

# --- ④ Release 资产：两次 302 → file-cdn 同路径、不同 auth_key --------------
t0=$(date +%s)
asset_rc=2
if [ -z "$ASSET_URL" ]; then
    echo "⚠️ 未配置 Release 资产 URL，跳过 file-cdn 域"
    step asset-resolve SKIP 0
else
    loc1=$(resolve_location "$ASSET_URL")
    sleep 2
    loc2=$(resolve_location "$ASSET_URL")
    echo "资产 302#1: ${loc1:0:140}"
    echo "资产 302#2: ${loc2:0:140}"
    if [ -z "$loc1" ] || [ -z "$loc2" ]; then
        echo "⚠️ 资产页没有 302（$ASSET_URL 可能已失效/不再是附件），file-cdn 域记 SKIP"
        step asset-resolve SKIP $(( $(date +%s) - t0 ))
    elif [ "$(url_host "$loc1")" != "file-cdn.gitcode.com" ]; then
        echo "⚠️ 资产跳转落到 $(url_host "$loc1")，不是 file-cdn.gitcode.com，本域记 SKIP"
        step asset-resolve SKIP $(( $(date +%s) - t0 ))
    elif [ "$(strip_q "$loc1")" != "$(strip_q "$loc2")" ]; then
        echo "❌ 两次 302 路径不同（附件可能被替换），无法验证同路径复用"
        step asset-resolve 1 $(( $(date +%s) - t0 )); asset_rc=1
    elif host_in_noproxy "$(url_host "$loc1")"; then
        echo "⚠️ file-cdn.gitcode.com 在 NO_PROXY 内——资产下载直连，store_id 无从验证"
        step asset-resolve SKIP $(( $(date +%s) - t0 ))
    else
        echo "✅ Release 资产同路径、不同签名（file-cdn.gitcode.com）"
        step asset-resolve 0 $(( $(date +%s) - t0 ))
        if [ "$loc1" = "$loc2" ]; then
            echo "ℹ️ 两次 302 的签名相同，只能验证普通缓存，无法验证跨签名复用"
        fi
        t0=$(date +%s)
        fetch_pair filecdn "$loc1" "$loc2"; asset_rc=$?
        # 单轮 detail=mismatch 可能是变体竞态（首轮响应刚到、缓存副本尚未定型）；
        # 换一对全新签名再验一轮，两轮都 MISS 才判红。
        if [ "$asset_rc" = 1 ]; then
            echo "ℹ️ file-cdn 首轮未命中，换新签名重试一轮（排除瞬时变体/存储竞态）"
            sleep 2
            loc3=$(resolve_location "$ASSET_URL"); sleep 2
            loc4=$(resolve_location "$ASSET_URL")
            if [ -n "$loc3" ] && [ "$(strip_q "$loc3")" = "$(strip_q "$loc1")" ]; then
                fetch_pair filecdn-retry "$loc3" "${loc4:-$loc3}"; asset_rc=$?
            fi
        fi
        step filecdn-reuse "$([ $asset_rc = 2 ] && echo SKIP || echo $asset_rc)" $(( $(date +%s) - t0 ))
    fi
fi

# --- ⑤ 一致性：同名/同路径换内容会不会被旧副本污染 --------------------------
# store_id 把 query 从缓存键里去掉，所以必须证明「路径唯一决定内容」，否则上游
# 替换同名文件后 squid 会继续供旧副本（refresh_pattern min=10080 分钟，最长 7 天）。
t0=$(date +%s)
cons_rc=2
cons_notes=""
# A. LFS：路径就是内容地址（/lfs-objects/aa/91/<oid 剩余部分>），同名必然同内容
if [ -n "${href1:-}" ]; then
    norm=$(strip_q "$href1" | tr -d '/')
    if printf '%s' "$norm" | grep -q "$OID"; then
        cons_notes="${cons_notes}LFS 路径含 oid（内容寻址，同名不可能换内容）；"
        echo "✅ LFS 路径是内容地址（含 oid）→ 同路径必然同字节，无陈旧风险"
        [ "$cons_rc" = 1 ] || cons_rc=0
    else
        cons_notes="${cons_notes}LFS 路径不含 oid（同名换内容风险）；"
        echo "❌ LFS 路径不含 oid——同路径可能对应不同内容，store_id 会把新对象挡在缓存外"
        cons_rc=1
    fi
fi
# B. file-cdn：路径里的 untagger_<uuid> 是否随 release/上传变化（换了就不是同一个键）
if [ -n "${loc1:-}" ] && [ -n "$ASSET_ALT" ]; then
    loc_alt=$(resolve_location "$ASSET_ALT")
    if [ -z "$loc_alt" ]; then
        cons_notes="${cons_notes}file-cdn 对照资产不可达；"
        echo "⚠️ 对照资产页无 302（$ASSET_ALT），路径版本化判定记 SKIP"
    elif [ "$(url_host "$loc_alt")" != "file-cdn.gitcode.com" ]; then
        cons_notes="${cons_notes}file-cdn 对照资产未落到 file-cdn；"
        echo "⚠️ 对照资产跳到 $(url_host "$loc_alt")，路径版本化判定记 SKIP"
    else
        d1=$(strip_q "$loc1"); d1="${d1%/*}"
        d2=$(strip_q "$loc_alt"); d2="${d2%/*}"
        if [ "$d1" != "$d2" ]; then
            cons_notes="${cons_notes}file-cdn 路径带上传 uuid（跨 release 不复用键）；"
            echo "✅ file-cdn 同文件名在不同 release 下路径不同（$d1 vs $d2）→ 换内容必换缓存键"
            [ "$cons_rc" = 1 ] || cons_rc=0
        else
            cons_notes="${cons_notes}file-cdn 同名跨 release 共用路径（替换风险）；"
            echo "⚠️ 同文件名跨 release 落在同一路径——同名替换内容可能被旧副本污染，需按上传替换实验复核"
            [ "$cons_rc" = 1 ] || cons_rc=0
        fi
    fi
fi
# C. 缓存命中是否会跳过签名校验：用伪造 auth_key 打已缓存的 LFS 路径
if [ -n "${href1:-}" ]; then
    bogus="$(strip_q "$href1")?auth_key=bogus-probe"
    bc=$(curl -sS --max-time 120 -o /dev/null -D "$results/authbypass.hdr" -w '%{http_code}' "$bogus" 2>/dev/null)
    bst=$(hdr_val cache-status "$results/authbypass.hdr")
    echo "伪造 auth_key 请求: http=$bc ${bst:-<无缓存头>}"
    case "$bc" in
        200)
            echo "ℹ️ 已缓存路径即使 auth_key 非法也返回 200 ${bst:+（$bst）}——HIT 不再回源校验签名；公开对象无影响，私有仓需评估"
            cons_notes="${cons_notes}缓存命中会跳过签名校验（公开对象无影响）；" ;;
        *)
            cons_notes="${cons_notes}非法签名被拒（$bc），签名仍生效；" ;;
    esac
fi
if [ -z "$cons_notes" ]; then
    echo "⚠️ 一致性阶段没有可判定项"
    step consistency SKIP $(( $(date +%s) - t0 ))
else
    echo "ℹ️ 一致性结论: $cons_notes"
    printf 'consistency\t-\t%s\t-\t%s\t-\t-\t-\t%s\n' "$cons_notes" >> "$DETAIL"
    step consistency "$([ $cons_rc = 2 ] && echo SKIP || echo $cons_rc)" $(( $(date +%s) - t0 ))
fi

# --- ⑥ 负样本：非 CDN 域不同 query 不得复用 ---------------------------------
t0=$(date +%s)
neg_rc=2
if [ -z "$NEG_URL" ]; then
    echo "⚠️ 未配置 LFS_STOREID_NEG_URL，跳过域隔离负样本"
    step negative SKIP 0
else
    sep='?'; case "$NEG_URL" in *\?*) sep='&' ;; esac
    u1="${NEG_URL}${sep}storeid_probe=$RUN_ID"
    u2="${NEG_URL}${sep}storeid_probe=${RUN_ID}b"
    n1=$(curl -sS --max-time 120 -o /dev/null -D "$results/neg-1.hdr" -w '%{http_code}' "$u1" 2>/dev/null)
    n2=$(curl -sS --max-time 120 -o /dev/null -D "$results/neg-2.hdr" -w '%{http_code}' "$u1" 2>/dev/null)
    n3=$(curl -sS --max-time 120 -o /dev/null -D "$results/neg-3.hdr" -w '%{http_code}' "$u2" 2>/dev/null)
    h2=$(hdr_val cache-status "$results/neg-2.hdr")
    h3=$(hdr_val cache-status "$results/neg-3.hdr")
    echo "负样本 ${NEG_URL}: 首发=$n1 同URL二发=$n2(${h2:-无}) 换query=$n3(${h3:-无})"
    if [ "$n1" != "200" ] || [ "$n2" != "200" ]; then
        echo "⚠️ 负样本 URL 不可达，域隔离检查记 SKIP"
    elif ! echo "$h2" | grep -qiE 'hit'; then
        echo "⚠️ 负样本同 URL 二发未命中（对象不可缓存），无法证明 query 隔离，记 SKIP"
    elif echo "$h3" | grep -qiE 'hit'; then
        echo "❌ 非 CDN 域的不同 query 也复用了缓存——store_id_access 域限定失效"
        neg_rc=1
    else
        echo "✅ 非 CDN 域换 query 仍 MISS → store_id 只作用于两个 CDN 域"
        neg_rc=0
    fi
    step negative "$([ $neg_rc = 2 ] && echo SKIP || echo $neg_rc)" $(( $(date +%s) - t0 ))
fi

# --- ⑦ 同名替换实验：同 release 里同名换内容是否被旧副本污染 ------------------
t0=$(date +%s)
phase_replace; repl_rc=$?
step replace "$([ "$repl_rc" = 2 ] && echo SKIP || echo "$repl_rc")" $(( $(date +%s) - t0 ))

# --- 结论 -------------------------------------------------------------------
echo
echo "== 证据（$DETAIL）=="
cat "$DETAIL"
if [ "$lfs_rc" = 1 ] || [ "$asset_rc" = 1 ] || [ "$cons_rc" = 1 ] || [ "$neg_rc" = 1 ] || [ "$repl_rc" = 1 ]; then
    echo "== 结论：FAIL =="
    exit 1
fi
if [ "$lfs_rc" = 0 ] || [ "$asset_rc" = 0 ] || [ "$repl_rc" = 0 ]; then
    echo "== 结论：PASS =="
    exit 0
fi
echo "== 结论：SKIP（两个 CDN 域的前提都不成立）=="
exit 2
