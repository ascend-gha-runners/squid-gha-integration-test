#!/usr/bin/env bash
# =============================================================================
# repro-apt-byhash.sh —— apt by-hash 索引长缓存验证（chart 0.1.31，PR #2746）
#
# 背景（issue #2443）：
#   repo.huaweicloud.com 的 /ubuntu(-ports)/dists/<suite>/<component>/by-hash/<alg>/<hash>
#   落在 `cache deny hc_repo mutable_meta_with_by_hash` 的覆盖范围内，被当成可变
#   索引拒绝缓存 → 每次 apt-get update 全量回源（cn12-001 单副本 81 分钟：
#   592 次请求 / 28 个对象 / 560 次 TCP_MISS / 1.8 GiB）。
#   但 by-hash 是内容寻址的不可变对象：文件名就是内容 sha256，源站给
#   `Cache-Control: max-age=1296000`（15 天）+ ETag（实测 Expires 是过去时间）
#   → 可安全长缓存。
#
# 修复（chart 0.1.31）三件套：
#   ① acl by_hash urlpath_regex -i /by-hash/
#      cache deny hc_repo mutable_meta_with_by_hash !by_hash   （同一条 deny 内排除）
#   ② refresh_pattern .../dists/.*/by-hash/ 10080 100% 525600 ... override-expire
#      必须排在 apt 前缀短 TTL 规则之前（refresh_pattern 首匹配生效）
#   ③ immutable_file 追加 /by-hash/（长缓存后 Age 必然 >3600s，避免点亮
#      squid_stale_index_hit_total / SquidStaleIndexServed）
#
# 子命令：
#   byhash  —— 主判定：从真实 Release 的 SHA256 段解析出 by-hash 对象 URL，经
#              squid 连打 N 发。必须出现 HIT（说明 deny 例外 + 长 TTL 生效），
#              且每发 200 的响应体 sha256 必须等于文件名哈希（内容寻址完整性：
#              证明缓存下来/回源拿到的确实是该对象，而不是别的变体）。
#   mutable —— 负样本守卫：同一个 dists 下的非 by-hash 可变索引（InRelease 与
#              原 Packages.gz）经 squid 连打，不得由缓存作答——证明 `!by_hash`
#              例外没有把可变索引一起放开（deny 仍是 deny）。
#   immutable —— 证明 by-hash 对象确实不可变（长缓存的前提）：源站真值两遍 +
#              条件请求（If-None-Match→304）+ 对端镜像一致 + 非 by-hash 索引本体
#              绑定，每一路都要求 sha256 == 文件名哈希。任一不符即判红。
#
# 用法：
#   bash test-squid/repro-apt-byhash.sh byhash
#   bash test-squid/repro-apt-byhash.sh mutable
#
# 可覆盖：
#   PX                 squid 地址（默认取 HTTP_PROXY/http_proxy；空=直连 → SKIP）
#   RESULTS            结果目录（默认 /tmp/repro-apt-byhash）
#   BYHASH_RELEASE_URL 默认 https://repo.huaweicloud.com/ubuntu/dists/jammy/Release
#   BYHASH_INDEX       Release 里要跟的索引路径（默认 main/binary-amd64/Packages.gz）
#   BYHASH_SHOTS       正向连打次数（默认 6：多副本各自成缓存，靠重复发命中同 pod）
#   BYHASH_STRICT      1=无 HIT 判红（默认 1；0=只留档、不判结论）
#   MUTABLE_SHOTS      负样本每种 URL 连打次数（默认 3）
#   MUTABLE_URLS       空格分隔的负样本 URL（默认由 BYHASH_RELEASE_URL 派生：
#                      dists/<suite>/InRelease 与 dists/<suite>/<BYHASH_INDEX>）
#   BYHASH_PEER_HOSTS  对端镜像主机（空格分隔，默认 mirrors.huaweicloud.com；
#                      immutable 阶段用来做跨站点一致性互证，主机不适用时跳过）
#
# 退出码：0=PASS；1=FAIL；2=SKIP（无代理 / 上游不可达 / 证据不足）
#
# 注：③ 的 immutable_file 豁免只影响 squid 内部 index.log / Prometheus
# （squid_stale_index_hit_total），runner 侧无法观测；本脚本只留档 HIT 时的
# Age——by-hash 的源站 Age 实测已 >3600s，命中后必然更大，可作旁证。
# =============================================================================
set -uo pipefail

results="${RESULTS:-${RESULTS_DIR:-/tmp/repro-apt-byhash}}"
mkdir -p "$results"

PX="${PX:-${HTTP_PROXY:-${http_proxy:-}}}"
RELEASE_URL="${BYHASH_RELEASE_URL:-https://repo.huaweicloud.com/ubuntu/dists/jammy/Release}"
INDEX_PATH="${BYHASH_INDEX:-main/binary-amd64/Packages.gz}"
SHOTS="${BYHASH_SHOTS:-6}"
STRICT="${BYHASH_STRICT:-1}"
MUTABLE_SHOTS="${MUTABLE_SHOTS:-3}"

release_dir="${RELEASE_URL%/*}/"
index_dir="${INDEX_PATH%/*}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

hdr_val() {  # hdr_val <header-name> <hdr-file>
    grep -i "^$1:" "$2" 2>/dev/null | tail -1 | tr -d '\r' | cut -d: -f2- | sed 's/^ *//'
}

squid_trace() {  # 响应头里是否有 squid 专属痕迹（Cache-Status/X-Cache-Lookup/Via）
    grep -qiE '^cache-status:.*squid|^x-cache-lookup:|^x-squid-error:|^via:.*squid' "$1" 2>/dev/null
}

cached_served() {  # 该响应是否由缓存对象作答（HIT / fwd=stale / Vary mismatch）
    grep -qiE '^cache-status:.*(hit|fwd=stale|detail=mismatch)|^x-cache-lookup:.*hit' "$1" 2>/dev/null
}

cache_hit_strict() {  # 严格的缓存命中：Cache-Status 里出现独立 hit 段（detail=mismatch 不算）
    grep -qiE '^cache-status:[^;]*;hit(;|$)|^x-cache-lookup:.*hit' "$1" 2>/dev/null
}

# 源站直连取 Release 真值（cache-buster 双保险：no-cache 头 + 沿途绕开）
fetch_release() {
    local code
    code=$(curl -sS -L --max-time 60 --noproxy '*' \
           -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
           -D "$results/release.hdr" -o "$results/release.txt" \
           -w '%{http_code}' "$RELEASE_URL" 2>"$results/release.err") || code="000"
    echo "$code"
}

# 从真实 Release 解析目标索引的 sha256 → 拼出 by-hash 对象 URL（BH_SHA / BH_URL）
resolve_byhash() {
    local code
    code=$(fetch_release)
    if [ "$code" != "200" ]; then
        echo "⚠️ Release 直连不可达（http=$code，$RELEASE_URL）——无法取得 by-hash 真值，记 SKIP"
        head -c 160 "$results/release.err" 2>/dev/null | sed 's/^/    | /'
        return 2
    fi
    if ! grep -qi '^Acquire-By-Hash: *yes' "$results/release.txt"; then
        echo "ℹ️ 该套件 Release 未声明 Acquire-By-Hash: yes（apt 不会走 by-hash，数据留档）"
    fi

    # Release 的 SHA256 段：每行 " <sha256> <size> <path>"（awk 默认按空白切分）
    BH_SHA=$(awk -v want="$INDEX_PATH" '
        /^SHA256:/ { f=1; next }
        /^[A-Za-z][A-Za-z0-9-]*:/ { f=0 }
        f && $3 == want { print $1; exit }
    ' "$results/release.txt")
    if ! echo "$BH_SHA" | grep -qE '^[0-9a-f]{64}$'; then
        echo "⚠️ Release 的 SHA256 段里找不到 $INDEX_PATH（换 BYHASH_INDEX 再跑），记 SKIP"
        return 2
    fi
    BH_URL="${release_dir}${index_dir}/by-hash/SHA256/${BH_SHA}"
    return 0
}

# =============================================================================
# byhash 子命令：by-hash 对象应可缓存（命中 HIT）且内容哈希自洽
# =============================================================================
byhash_case() {
    if [ -z "$PX" ]; then
        echo "⚠️ 无代理 env（HTTP_PROXY 为空）——必须经 squid，记 SKIP（本地只能验脚本逻辑）"
        return 2
    fi

    local sha url i hcode st age bytes body_sha ok200=0 hit=0 miss=0 other=0 trace=0 mismatch=0 vmismatch=0
    local hits_lines=""

    resolve_byhash || return $?
    sha="$BH_SHA"
    url="$BH_URL"
    echo "by-hash URL：$url"
    echo "源站 Release 头：Cache-Control=$(hdr_val 'cache-control' "$results/release.hdr")  Age=$(hdr_val 'age' "$results/release.hdr")"
    log "经 squid 连打 ${SHOTS} 发（Accept-Encoding: identity，与 apt 取索引形态一致）"

    : > "$results/byhash.tsv"
    for i in $(seq 1 "$SHOTS"); do
        hcode=$(NO_PROXY='' no_proxy='' curl -sS --max-time 120 -x "$PX" \
                -H 'Accept-Encoding: identity' \
                -D "$results/byhash-$i.hdr" -o "$results/byhash-$i.bin" \
                -w '%{http_code}' "$url" 2>"$results/byhash-$i.err") || hcode="000"
        st=$(hdr_val 'cache-status' "$results/byhash-$i.hdr")
        age=$(hdr_val 'age' "$results/byhash-$i.hdr")
        bytes=""
        [ -f "$results/byhash-$i.bin" ] && bytes=$(wc -c < "$results/byhash-$i.bin" | tr -d ' ')
        bytes="${bytes:-0}"
        body_sha=$(sha256sum "$results/byhash-$i.bin" 2>/dev/null | cut -d' ' -f1)
        [ "$hcode" = "200" ] && ok200=$((ok200 + 1))
        if [ "$hcode" = "200" ] && [ "$body_sha" != "$sha" ]; then
            mismatch=$((mismatch + 1))
        fi
        printf 'byhash-%d\t%s\t%s\tAge=%s\tbytes=%s\tsha256=%s\n' \
            "$i" "$hcode" "${st:-N/A}" "${age:-N/A}" "${bytes:-0}" "${body_sha:0:12}" \
            >> "$results/byhash.tsv"
        echo "  第 $i 发：http=$hcode  Cache-Status=${st:-N/A}  Age=${age:-N/A}  bytes=${bytes:-0}"

        squid_trace "$results/byhash-$i.hdr" && trace=$((trace + 1))
        if [ "$hcode" != "200" ]; then
            other=$((other + 1))
        elif cache_hit_strict "$results/byhash-$i.hdr"; then
            hit=$((hit + 1))
            hits_lines="${hits_lines}    第 $i 发 HIT：Cache-Status=$st Age=${age:-N/A}"$'\n'
        elif echo "$st" | grep -qiE 'detail=mismatch'; then
            # 缓存里有条目但 Vary/编码变体不一致 → 本次仍回源，不算命中
            vmismatch=$((vmismatch + 1))
            echo "  ⚠️ 第 $i 发：Cache-Status=$st（变体不一致 → 仍回源，不计 HIT）"
        elif echo "$st" | grep -qiE 'miss|no-cache'; then
            # miss=none;no-cache 是 squid 判「不可缓存」的标记：cache deny 命中即此形态
            miss=$((miss + 1))
        else
            other=$((other + 1))
        fi
    done

    if [ "$trace" -eq 0 ]; then
        echo "⚠️ ${SHOTS} 发都无 squid 专属痕迹——流量未经过 squid，记 SKIP"
        return 2
    fi
    if [ "$ok200" -eq 0 ]; then
        echo "⚠️ ${SHOTS} 发都非 200（上游不可达或该对象已下架）——记 SKIP"
        return 2
    fi
    if [ "$mismatch" -gt 0 ]; then
        echo "❌ 有 ${mismatch} 发响应体 sha256 与文件名哈希不一致（内容寻址对象被换掉/变体混入）"
        echo "   期望 sha256=$sha；逐发明细见 $results/byhash.tsv"
        return 1
    fi

    if [ "$hit" -gt 0 ]; then
        echo "✅ by-hash 索引可缓存：${SHOTS} 发中 ${hit} 发 HIT（MISS ${miss} / 变体不一致 ${vmismatch} / 其它 ${other}），且响应体 sha256 与文件名一致"
        echo "   HIT 明细（Age 为源站年龄 + 缓存年龄，>3600s 属预期，靠 immutable_file 豁免不进陈旧指标）："
        printf '%s' "$hits_lines"
        return 0
    fi

    if [ "$vmismatch" -gt 0 ]; then
        echo "❌ by-hash 在缓存里有条目，但 ${vmismatch} 发都因 Vary/编码变体不一致而回源（0 发命中）"
        echo "   含义：缓存键被 Accept-Encoding 等变体拆散，长缓存收益不成立；核对 squid.conf 的 Vary 处理"
        return 1
    fi

    if [ "$STRICT" = "1" ]; then
        echo "❌ by-hash 索引仍未被缓存：${SHOTS} 发全为 MISS / no-cache（${miss}），无一次 HIT"
        echo "   含义：chart 未到 0.1.31 或 squid.conf 未生效（deny 例外未落地），apt-get update 仍全量回源"
        echo "   排查：StatefulSet 的 checksum/config-squid 注解与 pod 启动时间；squid -k parse 是否含"
        echo "         'cache deny hc_repo mutable_meta_with_by_hash !by_hash'"
        return 1
    fi
    echo "⚠️ BYHASH_STRICT=0：${SHOTS} 发全为 MISS（无 HIT），只留档不判红"
    return 0
}

# 取源站真值：优先直连（--noproxy '*'），不通再经 squid（带 Cache-Control: no-cache）。
# via 写到 <prefix>.via，返回 http code（000=两路都不通）
origin_get() {  # origin_get <url> <out-prefix> [额外 curl 参数...]
    local url="$1" pfx="$2"; shift 2
    local code
    code=$(curl -sS -L --max-time 120 --noproxy '*' -H 'Cache-Control: no-cache' "$@" \
           -D "$pfx.hdr" -o "$pfx.bin" -w '%{http_code}' "$url" 2>"$pfx.err") || code="000"
    echo direct > "$pfx.via"
    if [ "$code" = "000" ] && [ -n "$PX" ]; then
        code=$(NO_PROXY='' no_proxy='' curl -sS -L --max-time 120 -x "$PX" \
               -H 'Cache-Control: no-cache' "$@" \
               -D "$pfx.hdr" -o "$pfx.bin" -w '%{http_code}' "$url" 2>"$pfx.err") || code="000"
        echo proxy > "$pfx.via"
    fi
    echo "$code"
}

# 单路校验：200 必须 sha256 == 文件名哈希；304 视为「实体未变」的证据
immut_check() {  # <label> <prefix> <code>
    local label="$1" pfx="$2" code="$3" h="" via
    via=$(cat "$pfx.via" 2>/dev/null)
    if [ "$code" = "200" ]; then
        h=$(sha256sum "$pfx.bin" 2>/dev/null | cut -d' ' -f1)
        IMM_EVID=$((IMM_EVID + 1))
        if [ "$h" != "$BH_SHA" ]; then
            IMM_BAD=$((IMM_BAD + 1))
            echo "  ❌ $label：body sha256=${h:0:16}… ≠ 名字哈希（镜像破坏了内容寻址契约）"
        else
            echo "  ✅ $label：200 且 body sha256 = 名字哈希（via=${via:-?}）"
        fi
    elif [ "$code" = "304" ]; then
        IMM_EVID=$((IMM_EVID + 1))
        echo "  ✅ $label：304 Not Modified（实体与真值 ETag 一致，从未变过）"
    else
        echo "  ⚠️ $label：http=$code（via=${via:-?}）——该路证据缺失，不判红"
    fi
    printf '%s\t%s\t%s\tsha256=%s\tETag=%s\n' "$label" "$code" "${via:-?}" "${h:0:16}" \
        "$(hdr_val 'etag' "$pfx.hdr")" >> "$results/immutable.tsv"
}

# =============================================================================
# immutable 子命令：证明 by-hash 对象确实不可变（内容寻址语义在镜像侧成立）
#
# 为什么可信：URL 里的 sha256 就是内容哈希。任何一次取回的字节算出来不等于
# 这个名字，就说明镜像破坏了 by-hash 契约（对象被替换 / 编码变体混入），
# 长缓存就不安全。四路互证 + 一路缓存副本：
#   ① 源站真值两遍（不同 cache-buster，绕开边缘缓存）→ 两次都哈希成名字值；
#   ② 条件请求（If-None-Match 用①的 ETag）→ 源站 304，证明实体从未变过；
#   ③ 对端镜像同路径 → 同一 sha256（跨站点一致）；
#   ④ 非 by-hash 的同名索引（Release 列的那份）→ 同一 sha256（名字↔内容绑定）；
#   ⑤ 若注入 squid：经 squid 取 2 发，200 体也须哈希成名字值（存储副本未毒化）。
# 说明：不可变性由内容寻址保证；本阶段验证「镜像遵守该约定」。不需要等时间流逝
# 也不会漏检——一旦内容漂移，哈希必然不等，每一轮都会判红。
# =============================================================================
immutable_case() {
    local token c1 c2 cr cp ci p_url peer i hcode

    IMM_BAD=0
    IMM_EVID=0
    resolve_byhash || return $?

    token="$(date +%s)-$$"
    echo "被测对象：$BH_URL"
    echo "文件名哈希（真值）：$BH_SHA"
    : > "$results/immutable.tsv"

    # ① 源站真值两遍
    c1=$(origin_get "${BH_URL}?__immut=a-${token}" "$results/imm-a" -H 'Accept-Encoding: identity')
    c2=$(origin_get "${BH_URL}?__immut=b-${token}" "$results/imm-b" -H 'Accept-Encoding: identity')
    immut_check '源站真值·第1遍' "$results/imm-a" "$c1"
    immut_check '源站真值·第2遍' "$results/imm-b" "$c2"
    echo "  源站审计头：ETag=$(hdr_val 'etag' "$results/imm-a.hdr")  Last-Modified=$(hdr_val 'last-modified' "$results/imm-a.hdr")"

    # ② 条件请求：拿①的 ETag 问源站「还是这份吗」
    if [ -n "$(hdr_val 'etag' "$results/imm-a.hdr")" ]; then
        cr=$(origin_get "$BH_URL" "$results/imm-r" \
             -H "If-None-Match: $(hdr_val 'etag' "$results/imm-a.hdr")")
        immut_check '条件请求（If-None-Match）' "$results/imm-r" "$cr"
    else
        echo "  ⚠️ 源站未给 ETag，跳过条件请求这一路"
    fi

    # ③ 对端镜像同路径（跨站点一致）
    for peer in ${BYHASH_PEER_HOSTS:-mirrors.huaweicloud.com}; do
        p_url="${BH_URL/repo.huaweicloud.com/$peer}"
        if [ "$p_url" = "$BH_URL" ]; then
            echo "  ⚠️ 对端镜像 $peer 不适用于当前 Release 域名，跳过"
            continue
        fi
        cp=$(origin_get "${p_url}?__immut=p-${token}" "$results/imm-p")
        immut_check "对端镜像 $peer" "$results/imm-p" "$cp"
    done

    # ④ 名字↔内容绑定：非 by-hash 的同名索引此刻的内容也必须是这个名字的哈希
    ci=$(origin_get "${release_dir}${INDEX_PATH}?__immut=idx-${token}" "$results/imm-idx" \
         -H 'Accept-Encoding: identity')
    immut_check "索引本体（非 by-hash）" "$results/imm-idx" "$ci"

    # ⑤ 经 squid 的存储副本（若注入了代理）
    if [ -n "$PX" ]; then
        for i in 1 2; do
            hcode=$(NO_PROXY='' no_proxy='' curl -sS --max-time 120 -x "$PX" \
                    -H 'Accept-Encoding: identity' \
                    -D "$results/imm-s$i.hdr" -o "$results/imm-s$i.bin" \
                    -w '%{http_code}' "$BH_URL" 2>"$results/imm-s$i.err") || hcode="000"
            echo squid > "$results/imm-s$i.via"
            immut_check "经 squid·第${i}发" "$results/imm-s$i" "$hcode"
        done
    else
        echo "  ℹ️ 无代理 env：跳过经 squid 的存储副本校验（本地只验源站语义）"
    fi

    if [ "$IMM_BAD" -gt 0 ]; then
        echo "❌ by-hash 不可变契约被破坏：${IMM_BAD} 路内容哈希与文件名不符——禁止长缓存"
        echo "   明细见 $results/immutable.tsv"
        return 1
    fi
    if [ "$IMM_EVID" -eq 0 ]; then
        echo "⚠️ 没有任何一路拿到 200/304（源站与镜像都不可达）——证据不足，记 SKIP"
        return 2
    fi
    echo "✅ by-hash 不可变性成立：${IMM_EVID} 路证据自洽（内容寻址 + 条件请求 304 + 跨镜像一致 + 索引本体绑定）"
    return 0
}

# =============================================================================
# mutable 子命令：非 by-hash 的可变索引仍必须不缓存（例外未放宽的负样本守卫）
# 每 run 带唯一 query：保证缓存键是本 run 首次出现，任何 HIT 都只能来自本 run
# 内的二次请求（排除历史缓存条目干扰）。deny 的 urlpath_regex 是路径前缀，
# query 不影响命中。
# =============================================================================
mutable_case() {
    if [ -z "$PX" ]; then
        echo "⚠️ 无代理 env——无法判定可变索引缓存性，记 SKIP"
        return 2
    fi

    local token urls u i hcode st age hit=0 miss=0 other=0 trace=0 ok200=0 failed=0
    token="$(date +%s)-$$"
    urls="${MUTABLE_URLS:-${release_dir}InRelease ${release_dir}${INDEX_PATH}}"

    : > "$results/mutable.tsv"
    for u in $urls; do
        case "$u" in
            *\?*) qurl="$u&__byhash_guard=$token" ;;
            *)    qurl="$u?__byhash_guard=$token" ;;
        esac
        echo "负样本：$u"
        for i in $(seq 1 "$MUTABLE_SHOTS"); do
            hcode=$(NO_PROXY='' no_proxy='' curl -sS --max-time 120 -x "$PX" \
                    -H 'Accept-Encoding: identity' \
                    -D "$results/mutable-$i.hdr" -o "$results/mutable-$i.bin" \
                    -w '%{http_code}' "$qurl" 2>"$results/mutable-$i.err") || hcode="000"
            st=$(hdr_val 'cache-status' "$results/mutable-$i.hdr")
            age=$(hdr_val 'age' "$results/mutable-$i.hdr")
            printf '%s\t%d\t%s\t%s\tAge=%s\n' "$u" "$i" "$hcode" "${st:-N/A}" "${age:-N/A}" \
                >> "$results/mutable.tsv"
            echo "  第 $i 发：http=$hcode  Cache-Status=${st:-N/A}  Age=${age:-N/A}"
            squid_trace "$results/mutable-$i.hdr" && trace=$((trace + 1))
            if [ "$hcode" = "200" ]; then
                ok200=$((ok200 + 1))
            else
                other=$((other + 1))
                continue
            fi
            if cached_served "$results/mutable-$i.hdr"; then
                hit=$((hit + 1))
                echo "  ❌ 该可变索引被缓存作答（Cache-Status=$st）"
            elif echo "$st" | grep -qiE 'miss|no-cache'; then
                miss=$((miss + 1))
            else
                other=$((other + 1))
            fi
        done
    done

    if [ "$trace" -eq 0 ]; then
        echo "⚠️ 负样本无 squid 专属痕迹——流量未经过 squid，记 SKIP"
        return 2
    fi
    if [ "$ok200" -eq 0 ]; then
        echo "⚠️ 负样本全部非 200（上游不可达）——证据不足，记 SKIP（非 200 ${other} 发）"
        return 2
    fi
    if [ "$hit" -gt 0 ]; then
        echo "❌ 非 by-hash 可变索引被缓存（${hit} 发 HIT）——!by_hash 例外放太宽，deny 失效"
        echo "   后果：镜像重新生成索引后仍供旧页（2026-10-29 post2 事故形态）"
        echo "   明细见 $results/mutable.tsv"
        return 1
    fi
    if [ "$miss" -ge 3 ]; then
        echo "✅ 可变索引仍不缓存：${miss} 发 MISS/no-cache、0 发 HIT（by-hash 例外未误伤 deny）"
        return 0
    fi
    echo "⚠️ 判定证据不足（MISS ${miss} / HIT ${hit} / 其它 ${other}）——记 SKIP"
    return 2
}

case "${1:-}" in
    byhash)    byhash_case ;;
    immutable) immutable_case ;;
    mutable)   mutable_case ;;
    *) echo "用法: $0 byhash|immutable|mutable（byhash=须可缓存；immutable=内容寻址不可变性；mutable=可变索引仍不得缓存）" >&2; exit 2 ;;
esac
